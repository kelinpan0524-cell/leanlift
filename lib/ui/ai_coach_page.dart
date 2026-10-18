import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../core/app.dart';
import '../engine/engine.dart';
import '../l10n/lang.dart';
import '../services/ai_service.dart';
import '../services/plan_actions.dart';
import '../services/plan_repository.dart';
import 'plan_preview_sheet.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'workout_page.dart';

/// AI 教练：应用内对话 + 一键阶段复盘 + 对话式排计划（统一一条对话）。
///
/// 设计纪律（2026-09-25 Arono 需求）：
/// - **不静默回落本地规则**——配置了 AI 就必须走 AI；请求失败明示原因并给
///   「重试」，绝不拿本地规则假装 AI 回答（计划拆解页的本地回落只在那里保留）；
/// - 未配置时给配置引导，不空报错；
/// - 训练数据包（近 8 周，ExportService.buildAiData）在首轮注入上下文，
///   多轮共用；人设与安全边界见 AiService.kCoachPersona；
/// - **对话即排计划（2026-09-26 Arono 需求）**：排计划契约并入每次对话，
///   不再有模式开关——AI 给出完整计划 JSON 时气泡下出现「预览并保存为计划」，
///   保存前仍走 plan_preview_sheet 逐动作人工确认（与计划页同一纪律，
///   绝不直接落库），确认后写入 App 并设为使用中。
class AiCoachPage extends StatefulWidget {
  const AiCoachPage({super.key});

  @override
  State<AiCoachPage> createState() => _AiCoachPageState();
}

class _AiCoachPageState extends State<AiCoachPage> {
  final _turns = <AiMessage>[]; // 已完成的 user/assistant 对话轮
  final _planByIndex = <int, List<AiDaySpec>>{}; // 回复序号 → 提取出的计划
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  String? _dataPack; // 训练数据包（首轮加载）
  String? _dataError;
  String? _pendingUser; // 发送中的用户输入（成功才进 _turns，失败可重试）
  String? _error; // 最近一次请求的可读失败原因
  bool _sending = false;

  // ---- 多对话（2026-09-29）：线程列表 + 当前线程 ----
  // 出差期间可在一个线程里连续安排多日训练；「历史对话」里翻找/切换/删除。
  List<AiChatThread> _threads = [];
  String _currentThreadId = '';

  AiChatThread _freshThread() => AiChatThread(
        id: 't${DateTime.now().millisecondsSinceEpoch}',
        title: '',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        messages: const [],
      );

  @override
  void initState() {
    super.initState();
    // initState 里不能同步读 InheritedWidget，延后一帧
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // 恢复上次对话（2026-09-26 Arono：会话历史本地保存，退出再进不丢）
        _loadHistory();
        _loadData();
      }
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 恢复对话（2026-09-29 起为多线程）：线程数组从本地设置读回，
  /// 当前线程取最近更新的；旧版单会话平面数组由 parseAiChatThreads
  /// 自动包成一个线程（无感迁移）。回复里的计划重新提取——内容就在
  /// 消息文本里，重建索引即可，不用额外存计划结构。
  void _loadHistory() {
    final c = app(context);
    _threads = parseAiChatThreads(c.settings.aiChatHistoryJson);
    AiChatThread cur;
    if (_threads.isEmpty) {
      cur = _freshThread();
      _threads = [cur];
    } else {
      cur = _threads.first; // parse 返回已按 updatedAt 降序？不——按存储序
      // 取最近更新的线程为当前
      for (final t in _threads) {
        if (t.updatedAt > cur.updatedAt) cur = t;
      }
    }
    _currentThreadId = cur.id;
    _turns
      ..clear()
      ..addAll(cur.messages);
    _rebuildPlanIndex();
    if (_turns.isNotEmpty) setState(() {});
  }

  /// 当前线程消息 → 计划按钮索引（加载/切换线程后调用）。
  void _rebuildPlanIndex() {
    final c = app(context);
    _planByIndex.clear();
    for (var i = 0; i < _turns.length; i++) {
      if (_turns[i].role != 'assistant') continue;
      final plan = c.ai.tryExtractPlan(_turns[i].content);
      if (plan != null) _planByIndex[i] = plan;
    }
  }

  /// 对话落盘（多线程版）：当前线程消息只留最近 60 条，线程列表按更新
  /// 时间保留最近 20 个（encodeAiChatThreads 内 LRU 淘汰）。空线程不落盘。
  void _persistHistory() {
    final c = app(context);
    final recent = _turns.length > 60
        ? _turns.sublist(_turns.length - 60)
        : _turns;
    final title = _threadTitle(recent);
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = AiChatThread(
      id: _currentThreadId,
      title: title,
      updatedAt: now,
      messages: List.of(recent),
    );
    final others = _threads.where((t) => t.id != _currentThreadId).toList();
    _threads = [updated, ...others];
    // 空线程（还没发过消息）不写进持久层，避免列表里堆「新对话」
    final toSave = updated.messages.isEmpty ? others : _threads;
    c.settings.aiChatHistoryJson = encodeAiChatThreads(toSave);
    unawaited(c.settings.save());
  }

  /// 线程标题：优先沿用旧标题（保持稳定），新线程取首条用户消息前 16 字。
  String _threadTitle(List<AiMessage> msgs) {
    for (final t in _threads) {
      if (t.id == _currentThreadId && t.title.isNotEmpty) return t.title;
    }
    for (final m in msgs) {
      if (m.role == 'user' && m.content.trim().isNotEmpty) {
        final s = m.content.trim().replaceAll('\n', ' ');
        return s.length > 16 ? s.substring(0, 16) : s;
      }
    }
    return '';
  }

  /// 切换线程：换当前线程 + 重建消息与计划索引。
  void _switchThread(AiChatThread t) {
    if (t.id == _currentThreadId) return;
    setState(() {
      _currentThreadId = t.id;
      _turns
        ..clear()
        ..addAll(t.messages);
      _planByIndex.clear();
    });
    _rebuildPlanIndex();
    if (mounted) setState(() {});
    _scrollToBottom();
  }

  /// 新建对话：当前空线程直接忽略，非空的留在列表里可随时切回。
  void _newThread() {
    final t = _freshThread();
    _threads = [t, ..._threads.where((x) => x.id != t.id)];
    setState(() {
      _currentThreadId = t.id;
      _turns.clear();
      _planByIndex.clear();
      _error = null;
    });
  }

  /// 删除线程：当前线程被删则切到剩余里最新的（没有就新建）。
  void _deleteThread(AiChatThread t) {
    final rest = _threads.where((x) => x.id != t.id).toList();
    final wasCurrent = t.id == _currentThreadId;
    _threads = rest;
    if (wasCurrent) {
      if (rest.isEmpty) {
        _newThread();
      } else {
        var newest = rest.first;
        for (final x in rest) {
          if (x.updatedAt > newest.updatedAt) newest = x;
        }
        _currentThreadId = newest.id;
        _turns
          ..clear()
          ..addAll(newest.messages);
        _planByIndex.clear();
        _rebuildPlanIndex();
      }
    }
    final s = app(context).settings;
    s.aiChatHistoryJson = encodeAiChatThreads(rest);
    unawaited(s.save());
    if (mounted) setState(() {});
  }

  Future<void> _loadData() async {
    final c = app(context);
    setState(() {
      _dataError = null;
      _dataPack = null;
    });
    try {
      final pack = await c.export.buildAiData(
          weeks: 8,
          bodyWeightKg: c.settings.bodyWeightKg,
          planRepo: c.planRepo);
      if (mounted) setState(() => _dataPack = pack);
    } catch (e) {
      if (mounted) {
        setState(() => _dataError =
            tx('训练数据读取失败：$e', en: 'Failed to load workout data: $e'));
      }
    }
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (_sending || trimmed.isEmpty) return;
    final c = app(context);
    final pack = _dataPack;
    if (!c.settings.aiConfigured || pack == null) {
      setState(() => _error = pack == null
          ? tx('训练数据还没准备好', en: 'Workout data is not ready yet')
          : null);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
      _pendingUser = trimmed;
    });
    _scrollToBottom();
    try {
      // 同一条对话契约（人设 + 排计划契约）：聊数据、排计划都在这条通道里，
      // AI 输出完整计划 JSON 的轮次自动挂「预览并保存为计划」。
      final messages = c.ai.buildCoachMessages(pack,
          history: _turns, userText: trimmed);
      final reply = await c.ai.chat(messages);
      if (!mounted) return;
      setState(() {
        // assistant 落在 user 之后：当前长度 +1 即新回复的下标
        final replyIdx = _turns.length + 1;
        _turns
          ..add(AiMessage('user', trimmed))
          ..add(AiMessage('assistant', reply));
        _pendingUser = null;
        _sending = false;
        // 回复里带完整计划 JSON → 记录供气泡挂保存按钮；
        // 纯问答轮次提取不到，静默跳过（无保存按钮即常态）。
        final plan = c.ai.tryExtractPlan(reply);
        if (plan != null) _planByIndex[replyIdx] = plan;
      });
      _persistHistory();
      _scrollToBottom();
    } on AiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message; // 中文可读原因，重试按钮见 _errorBar
          _sending = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = tx('AI 请求失败，请重试（$e）',
              en: 'AI request failed, please retry ($e)');
          _sending = false;
        });
      }
    }
  }

  /// 气泡「预览并保存为计划」：仍走逐动作确认弹层，确认才落库。
  /// 保存目标可选：新建（原行为）或替换某个现有计划（2026-09-26 Arono）；
  /// 第三出口「作为今日临时训练直接开练」（2026-09-29 出差场景）——
  /// 不落计划模板，确认后的动作清单当天直接开一场临时会话。
  Future<void> _savePlanFromTurn(List<AiDaySpec> specs) async {
    final c = app(context);
    final plans = await c.db.allPlans();
    if (!mounted) return;
    final picked = await showPlanPreviewSheet(context, specs,
        localMode: false, existingPlans: plans);
    if (picked == null || !mounted) return;

    // 第三出口：临时开练
    final dayIdx = picked.adhocDayIndex;
    if (dayIdx != null) {
      if (c.session.hasActive) {
        toast(context,
            tx('已有进行中的训练，先完成或结束它', en: 'A workout is already in progress — finish or end it first'));
        return;
      }
      final spec = picked.specs[dayIdx];
      final exs = PlanRepository.planExercisesFromDaySpec(
        spec,
        c.ai.metaMap(),
        compoundRest: c.settings.restCompoundSec,
        assistanceRest: c.settings.restAssistanceSec,
      );
      if (exs.isEmpty) return;
      await c.planRepo.refreshRecommendations(exs);
      await c.session.startAdHoc(
        title: spec.title.trim().isEmpty ? tx('临时训练', en: 'Ad-hoc workout') : spec.title.trim(),
        planExercises: exs,
      );
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const WorkoutPage(),
      ));
      return;
    }

    final plan = picked.replacePlanId != null
        ? await replacePlanAndSync(
            c,
            planId: picked.replacePlanId!,
            specs: picked.specs,
            rename: picked.name.isEmpty ? null : picked.name,
          )
        : await saveAiPlanAndSync(
            c,
            name: picked.name.isEmpty
                ? tx('AI 生成 ${fmtDate(DateTime.now())}',
                    en: 'AI generated ${fmtDate(DateTime.now())}')
                : picked.name,
            specs: picked.specs,
          );
    if (mounted) {
      toast(
          context,
          picked.replacePlanId != null
              ? tx('已更新「${plan.name}」的内容', en: '"${plan.name}" updated')
              : tx('已保存并设为使用中「${plan.name}」，点任意一天可微调',
                  en: 'Saved and set as active "${plan.name}". Tap any day to fine-tune'));
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 清空对话（多线程版 2026-09-29）：删除当前线程并切到新空线程；
  /// 其他线程保留，可在「历史对话」里翻找。
  void _clearChat() {
    if (_sending) return;
    final cur = _threads.where((t) => t.id == _currentThreadId).firstOrNull;
    if (cur != null && cur.messages.isEmpty) return; // 已是空对话
    if (cur != null) {
      _deleteThread(cur);
    } else {
      _newThread();
    }
  }

  /// 历史对话列表（2026-09-29 多对话）：翻找/切换/删除线程 + 新建对话。
  /// 出差场景：第一天问酒店器械排了计划，第二天回到同一线程接着安排，
  /// AI 记得上下文（有什么器械、练了什么）。
  Future<void> _showThreadsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(tx('历史对话', en: 'Chat history'),
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                TextButton.icon(
                  onPressed: _sending
                      ? null
                      : () {
                          Navigator.pop(sheetCtx);
                          _newThread();
                        },
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tx('新建对话', en: 'New chat')),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final t in _sortedThreads()) ...[
              ListTile(
                dense: true,
                title: Text(
                  t.id == _currentThreadId
                      ? tx('${t.displayTitle}（当前）',
                          en: '${t.displayTitle} (current)')
                      : t.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: t.id == _currentThreadId
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: t.id == _currentThreadId
                        ? AppTheme.primary
                        : AppTheme.text,
                  ),
                ),
                subtitle: Text(
                  tx('${_threadTime(t.updatedAt)} · ${t.messages.length} 条消息',
                      en: '${_threadTime(t.updatedAt)} · ${t.messages.length} msgs'),
                  style:
                      const TextStyle(color: AppTheme.textDim, fontSize: 12),
                ),
                trailing: IconButton(
                  tooltip: tx('删除', en: 'Delete'),
                  icon: const Icon(Icons.delete_outline,
                      size: 20, color: AppTheme.danger),
                  onPressed: _sending
                      ? null
                      : () async {
                          final ok = await confirmDialog(
                            sheetCtx,
                            tx('删除这个对话？', en: 'Delete this chat?'),
                            tx('「${t.displayTitle}」将被删除，不可恢复。',
                                en: '"${t.displayTitle}" will be deleted permanently.'),
                            okLabel: tx('删除', en: 'Delete'),
                          );
                          if (!ok) return;
                          if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                          if (mounted) _deleteThread(t);
                        },
                ),
                onTap: t.id == _currentThreadId
                    ? null
                    : () {
                        Navigator.pop(sheetCtx);
                        _switchThread(t);
                      },
              ),
              const Divider(height: 1, color: AppTheme.cardHi),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 线程列表展示序：当前线程置顶，其余按更新时间降序。
  List<AiChatThread> _sortedThreads() {
    final cur =
        _threads.where((t) => t.id == _currentThreadId).toList();
    final rest = _threads.where((t) => t.id != _currentThreadId).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return [...cur, ...rest];
  }

  String _threadTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    if (fmtDate(d) == fmtDate(now)) {
      return '${two(d.hour)}:${two(d.minute)}';
    }
    if (d.year == now.year) {
      return tx('${d.month}月${d.day}日', en: '${d.month}/${d.day}');
    }
    return '${d.year}/${d.month}/${d.day}';
  }

  void _exportRecap(AiMessage recap) {
    final c = app(context);
    final now = DateTime.now();
    final title = tx('LeanLift 阶段复盘', en: 'LeanLift Phase Review');
    final stamp =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    unawaited(c.export.shareText(
      '$title $stamp',
      AiService.buildRecapMarkdown(now, title, recap.content),
      filename: 'leanlift-recap-'
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.md',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = app(context);
    final configured = c.settings.aiConfigured;
    final recap = AiService.lastRecapReply(_turns);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Text(tx('AI 教练', en: 'AI Coach')),
        actions: [
          // 历史对话（2026-09-29 多对话）：翻找/切换/新建线程
          IconButton(
            tooltip: tx('历史对话', en: 'Chat history'),
            onPressed: _sending ? null : _showThreadsSheet,
            icon: const Icon(Icons.forum),
          ),
          // 一键阶段复盘：数据包已注入，这里只发分析指令
          IconButton(
            tooltip: tx('一键阶段复盘', en: 'One-tap phase review'),
            onPressed:
                configured ? () => _send(AiService.kAnalysisInstruction) : null,
            icon: const Icon(Icons.bolt),
          ),
          IconButton(
            tooltip: tx('导出复盘存档', en: 'Export recap'),
            onPressed:
                recap == null || _sending ? null : () => _exportRecap(recap),
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(
            tooltip: tx('清空对话', en: 'Clear chat'),
            onPressed: _turns.isEmpty || _sending ? null : _clearChat,
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _statusLine(c, configured),
            Expanded(
              child: !configured
                  ? _guide(configured: false)
                  : _dataError != null
                      ? _dataErrorView()
                      : _chatList(),
            ),
            if (_error != null) _errorBar(),
            Divider(height: 1, color: AppTheme.cardHi),
            _inputRow(configured),
          ],
        ),
      ),
    );
  }

  /// 顶部状态行：模型名 + 数据包状态（对用户透明，方便排查"连的什么"）
  Widget _statusLine(AppContainer c, bool configured) {
    final model =
        c.settings.aiModel.isEmpty ? tx('未填模型名', en: 'not set') : c.settings.aiModel;
    final dataState = _dataError != null
        ? tx('数据包加载失败', en: 'Data pack failed to load')
        : _dataPack == null
            ? tx('数据包加载中…', en: 'Loading data pack…')
            : tx('已附近 8 周训练数据', en: 'Last 8 weeks of data loaded');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        children: [
          Icon(
            Icons.smart_toy_outlined,
            size: 14,
            // AI 触点统一用紫（2026-09-26 设计翻新：紫=智能、绿=训练）
            color: configured ? AppTheme.violetSoft : AppTheme.warn,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              tx('模型 $model · $dataState', en: 'Model $model · $dataState'),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _guide({required bool configured}) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      children: [
        const Center(
            child: Icon(Icons.smart_toy_outlined,
                size: 56, color: AppTheme.violetSoft)),
        const SizedBox(height: 12),
        Center(
          child: Text(tx('和你的训练数据对话', en: 'Chat with your training data'),
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            tx('基于手机里的真实训练记录回答：阶段复盘、找弱项、调计划、答疑。',
                en: 'Answers from your real workout logs on this phone: phase reviews, weak points, plan tweaks and Q&A.'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
          ),
        ),
        if (!configured) ...[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.warn.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              tx(
                '还没配置 AI 接口：\n'
                '1. 打开 设置 → AI 配置\n'
                '2. 填 Base URL、API Key、模型名（OpenAI 兼容格式）\n'
                '3. 点「测试连接」确认成功后回来即可对话',
                en: 'AI is not configured yet:\n'
                    '1. Open Settings → AI Config\n'
                    '2. Fill in Base URL, API Key and model name (OpenAI-compatible)\n'
                    '3. Tap "Test Connection", then come back to chat',
              ),
              style: const TextStyle(color: AppTheme.warn, fontSize: 13, height: 1.6),
            ),
          ),
        ] else ...[
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              tx(
                '问数据、找弱项、排计划都可以。教练给出完整计划时，'
                '回复下方会出现「预览并保存为计划」，逐动作确认后即写入 App 并设为使用中。',
                en: 'Ask about your data, find weak points or build a plan. '
                    'When the coach returns a full plan, "Preview & Save as Plan" '
                    'appears below the reply; confirm exercise by exercise and it '
                    'is saved and set as active.',
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _quickChip(tx('一键阶段复盘', en: 'One-tap phase review'),
                  AiService.kAnalysisInstruction),
              _quickChip(tx('我最近练得怎么样？', en: 'How have my workouts been lately?')),
              _quickChip(tx('我的弱项在哪，怎么补？', en: 'Where are my weak points and how do I fix them?')),
              _quickChip(tx('帮我安排一份每周四练的计划', en: 'Plan me a 4-day-per-week program')),
              _quickChip(tx('居家只有哑铃，每周三练', en: 'Dumbbells only at home, 3 days a week')),
              _quickChip(tx('基于我最近的数据安排下阶段', en: 'Plan my next phase from my recent data')),
            ],
          ),
        ],
      ],
    );
  }

  Widget _quickChip(String label, [String? text]) => ActionChip(
        backgroundColor: AppTheme.cardHi,
        side: BorderSide.none,
        label: Text(label,
            style: const TextStyle(fontSize: 13, color: AppTheme.text)),
        onPressed: () => _send(text ?? label),
      );

  Widget _dataErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 44, color: AppTheme.warn),
            const SizedBox(height: 12),
            Text(_dataError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textDim, fontSize: 13)),
            const SizedBox(height: 12),
            FilledButton.tonal(
                onPressed: _loadData,
                child: Text(tx('重试', en: 'Retry'))),
          ],
        ),
      ),
    );
  }

  Widget _chatList() {
    final children = <Widget>[
      for (var i = 0; i < _turns.length; i++)
        _bubble(_turns[i], plan: _planByIndex[i]),
    ];
    if (_pendingUser != null) {
      children.add(_bubble(AiMessage('user', _pendingUser!), pending: true));
      if (_sending) children.add(_thinkingRow());
    }
    if (_turns.isEmpty && _pendingUser == null) {
      return _guide(configured: true);
    }
    return ListView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      children: children,
    );
  }

  Widget _bubble(AiMessage m, {bool pending = false, List<AiDaySpec>? plan}) {
    final isUser = m.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? AppTheme.violet.withValues(alpha: 0.16)
              : AppTheme.cardHi,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isUser ? 14 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 14),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _bubbleContent(m, pending: pending, plan: plan),
            // 回复里提取到了完整计划 → 挂保存入口（仍走预览确认弹层）
            if (plan != null && !pending) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: _sending ? null : () => _savePlanFromTurn(plan),
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(tx('预览并保存为计划', en: 'Preview & Save as Plan')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 气泡正文：用户消息原样纯文本；AI 回复按 Markdown 排版
  /// （加粗/表格/列表/代码块，GFM 默认扩展集），可长按选择复制。
  /// 提取到计划时把 ```json 围栏从展示文本里摘掉——完整计划经
  /// 「预览并保存」查看更清楚，气泡只留说明文字。
  Widget _bubbleContent(
    AiMessage m, {
    required bool pending,
    List<AiDaySpec>? plan,
  }) {
    if (m.role != 'assistant') {
      return Text(
        m.content,
        style: TextStyle(
          fontSize: 15,
          height: 1.5,
          color: pending ? AppTheme.textDim : AppTheme.text,
        ),
      );
    }
    final data = plan == null
        ? m.content
        : m.content.replaceAll(
            RegExp(r'```(?:json)?\s*[\s\S]*?```'),
            tx('📋 **计划已生成**：点下方按钮预览并保存，也可以继续对话调整',
                en: '📋 **Plan generated**: tap the button below to preview and save, or keep chatting to adjust'));
    return MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: _mdStyle(context),
    );
  }

  /// 气泡内 Markdown 样式：对齐 App 深色主题（AI 输出的 Markdown
  /// 源码星号/竖线不再上屏，全部渲染成排版后的富文本）。
  MarkdownStyleSheet _mdStyle(BuildContext context) =>
      MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: const TextStyle(fontSize: 15, height: 1.5, color: AppTheme.text),
        h1: const TextStyle(
            fontSize: 17, height: 1.4, color: AppTheme.text, fontWeight: FontWeight.w700),
        h2: const TextStyle(
            fontSize: 16, height: 1.4, color: AppTheme.text, fontWeight: FontWeight.w700),
        h3: const TextStyle(
            fontSize: 15, height: 1.4, color: AppTheme.primary, fontWeight: FontWeight.w700),
        listBullet: const TextStyle(fontSize: 15, height: 1.5, color: AppTheme.textDim),
        blockquote: const TextStyle(color: AppTheme.textDim, fontSize: 14),
        blockquoteDecoration: BoxDecoration(
          border: const Border(left: BorderSide(color: AppTheme.cardHi, width: 3)),
          borderRadius: BorderRadius.circular(4),
        ),
        code: const TextStyle(
            fontFamily: 'monospace', fontSize: 13, color: AppTheme.accent),
        codeblockDecoration: BoxDecoration(
          color: AppTheme.bgDeep,
          borderRadius: BorderRadius.circular(8),
        ),
        tableHead: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.text),
        tableBody: const TextStyle(fontSize: 13, color: AppTheme.text),
        tableBorder: TableBorder.all(
            color: AppTheme.cardHi, width: 1, borderRadius: BorderRadius.circular(6)),
        tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      );

  Widget _thinkingRow() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              // 紫=AI：聊天流里的等待转圈跟随 AI 身份色，不吃全局主题绿
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppTheme.violetSoft),
            ),
            const SizedBox(width: 10),
            Text(
                tx('薄肌教练思考中…（通常 10-30 秒）',
                    en: 'Baoji coach is thinking… (usually 10-30s)'),
                style: const TextStyle(
                    color: AppTheme.textDim, fontSize: 13)),
          ],
        ),
      );

  Widget _errorBar() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: AppTheme.warn.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppTheme.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: AppTheme.warn, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: _pendingUser == null ? null : () => _send(_pendingUser!),
            child: Text(tx('重试', en: 'Retry')),
          ),
        ],
      ),
    );
  }

  Widget _inputRow(bool configured) {
    return Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom > 0 ? 8 : 12,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputCtrl,
              enabled: configured,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: configured ? (_) => _submit() : null,
              decoration: InputDecoration(
                hintText: tx('问点训练上的事…', en: 'Ask about your training…'),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: tx('发送', en: 'Send'),
            onPressed: configured && !_sending ? _submit : null,
            // 评审必修：styleFrom 的静态色会覆盖禁用态，未配置时紫底看着能点。
            // 按状态解析：禁用回落灰（与输入框置灰同语言），可用才上紫。
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? AppTheme.cardHi
                    : AppTheme.violet,
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? AppTheme.textDim
                    : Colors.white,
              ),
            ),
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.violetSoft),
                  )
                : const Icon(Icons.send),
          ),
        ],
      ),
    );
  }

  void _submit() {
    final text = _inputCtrl.text;
    if (text.trim().isEmpty) return;
    _inputCtrl.clear();
    _send(text);
  }
}
