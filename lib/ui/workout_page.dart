import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/engine.dart';
import '../engine/superset.dart';
import '../engine/weight_unit.dart';
import '../l10n/lang.dart';
import '../l10n/names.dart';
import '../presets/exercise_library.dart' show libraryMetaForLift;
import '../presets/start_weights.dart' show warmupBarKgFor;
import '../services/heart_rate_service.dart';
import '../services/session_controller.dart';
import 'exercise_detail_sheet.dart';
import 'exercise_picker_page.dart';
import 'heart_rate_page.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 该动作是否属于超级组（跳页面板/休息页小标记共用，与轮转引擎同口径）。
bool _sessionInSuperset(List<SessionExercise> exs, int i) =>
    supersetMembersOf(i, [for (final e in exs) e.supersetTag]) != null;

/// 一键切换重量单位（kg↔lb，2026-10-17）：训练面板大数字旁与休息页步进区
/// 两个入口共用。同步全局静态值 + 持久化 + 刷新常驻通知卡；
/// 不弹窗（红线：训练中禁止弹窗打断），页面靠各自 setState / InheritedNotifier 刷新。
void toggleWeightUnit(BuildContext context, SessionController s) {
  HapticFeedback.selectionClick();
  final c = app(context);
  c.settings.toggleWeightUnit();
  c.settings.save();
  s.notifyCard();
}

/// 训练页（全屏）：动作态 / 休息态；折叠屏（≥840dp）双栏。
/// 训练中不弹窗：结束训练用长按 2 秒环形进度（调研条目 5）；
/// 整屏状态色随相位切换：练=暗绿调、歇=暗红调（调研条目 11）。
class WorkoutPage extends StatefulWidget {
  const WorkoutPage({super.key});

  @override
  State<WorkoutPage> createState() => _WorkoutPageState();
}

class _WorkoutPageState extends State<WorkoutPage> with WidgetsBindingObserver {
  WorkoutPhase? _lastPhase;
  Timer? _distractTimer;

  /// 收尾确认回调挂载点（2026-10-07 结束确认弹窗）：initState 不能读
  /// InheritedWidget，addPostFrameCallback 后取 app(context).session 接线；
  /// dispose 成对清空，防泄漏到下个会话。
  SessionController? _sc;

  // ---------- 页面流（调研条目 8，wger gym_mode 思路） ----------
  /// 当前展示的页：由「会话动作 + 已记组」库内真值推导（workout_flow.dart），
  /// 不维护手工导航堆栈——保存一组→写库→状态机重算当前页→这里自动翻页。
  FlowPage? _shown;

  /// 起始页可见性：null = 尚未决定（首次构建时按"零记录"判定）。
  /// 全新会话先看一眼今天练什么；中途恢复（已有记录）直接落到当前记录页。
  bool? _startVisible;

  /// 总结页数据（收尾流程采集；null = 尚未收尾）。
  TrainingSummary? _summary;
  bool _finishing = false;
  bool _finishScheduled = false; // 占位页兜底收尾只调度一次

  /// 保存一组的"划线标记"确认窗口：窗口内冻结当前页并盖「已记录」章
  /// （划线展示刚存的组），窗口结束才应用状态机算出的下一页（自动翻页）。
  bool _holdMark = false;
  String _markText = '';
  Timer? _markTimer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addObserver(this);
    // 收尾确认接线（2026-10-07 结束确认弹窗）：initState 不能同步读
    // InheritedWidget，首帧后再取 AppContainer 的会话控制器挂回调
    // （addPostFrameCallback 为全仓通用写法，先例 home_page.dart /
    // plan_editor_page.dart）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = app(context).session;
      _sc = s;
      s.confirmAutoFinish = _confirmAutoFinish;
    });
    _distractTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkDistractingApp();
      // 常驻通知文案由 SessionController 心跳驱动（秒级、屏幕内外都更新）
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 训练中切去别的 App 再回来：查最近 90 秒是否刷了分心 App
    if (state == AppLifecycleState.resumed) {
      _checkDistractingApp();
    }
  }

  Future<void> _checkDistractingApp() async {
    if (!mounted) return;
    final c = app(context);
    final s = c.session;
    if (!s.hasActive) return;
    final hit = await c.focus.recentDistractingApp();
    if (hit == null || !mounted) return;
    final (pkg, sec) = hit;
    s.showFocusBanner(tx('刚切去${_friendlyName(pkg)}玩了 $sec 秒，回来继续！',
        en: 'Spent $sec s in ${_friendlyName(pkg)} — back to it!'));
  }

  String _friendlyName(String pkg) {
    final known = {
      'com.smile.gifmaker': tx('抖音', en: 'Douyin (TikTok)'),
      'com.ss.android.ugc.aweme': tx('抖音', en: 'Douyin (TikTok)'),
      'com.kuaishou.app': tx('快手', en: 'Kuaishou'),
      'com.xingin.xhs': tx('小红书', en: 'Xiaohongshu (RED)'),
      'com.sina.weibo': tx('微博', en: 'Weibo'),
      'tv.danmaku.bili': tx('B站', en: 'Bilibili'),
      'com.tencent.weishi': tx('微视', en: 'Weishi'),
    };
    return known[pkg] ?? tx('分心 App', en: 'Distracting app');
  }

  @override
  void deactivate() {
    // 系统返回退出训练页时清掉休息通知与精确闹钟，避免离开后照响
    if (app(context).session.hasActive) {
      app(context).notify.cancelRest();
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _sc?.confirmAutoFinish = null; // 成对解绑：页面卸载后不再拦截自动结束
    _distractTimer?.cancel();
    _markTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// 相位切换的页面级兜底：离开休息态时取消可能残留的精确提醒。
  /// 常驻训练卡与精确提醒的常规调度统一在 SessionController/App 容器
  /// （屏幕内外一致），页面不再单独刷新通知文案。
  void _syncPhaseSideEffects(WorkoutPhase phase) {
    if (_lastPhase == phase) return;
    final old = _lastPhase;
    _lastPhase = phase;
    if (old == WorkoutPhase.resting && phase != WorkoutPhase.resting) {
      app(context).notify.cancelRest();
    }
  }

  // ---------- 页面流推导与翻页 ----------

  /// 目标页：起始页（入口态）→ 记录/休息页（状态机算）→ 总结页（收尾后）。
  /// 返回 null = 会话已结束但总结未就绪（收尾中：保持当前页不闪占位）。
  FlowPage? _deriveTarget(SessionController s, WorkoutFlow flow) {
    if (!s.hasActive) {
      return _summary == null ? null : const FlowPage.summary();
    }
    if (_startVisible ?? false) return const FlowPage.start();
    return flow.currentPage(
      resting: s.phase == WorkoutPhase.resting,
      curExIdx: s.curExIdx,
    );
  }

  /// 每次控制器通知后对齐展示页。划线确认窗口内冻结当前页，
  /// 窗口结束（_markTimer）后下一次构建才应用新页。
  void _syncShown(SessionController s, WorkoutFlow flow) {
    _startVisible ??= flow.donePlannedSets == 0;
    final target = _deriveTarget(s, flow);
    if (target == null || _holdMark) return;
    _shown = target;
  }

  /// 保存一组成功（会话未结束）→ 划线标记窗口 → 自动翻到下一页。
  /// wger 的"保存→划线→自动翻页"三步：写库已由控制器完成，
  /// 这里盖「已记录」章（划线展示刚存的组），900ms 后放行翻页。
  void _onSetRecorded(String mark) {
    _markTimer?.cancel();
    setState(() {
      _holdMark = true;
      _markText = mark;
    });
    _markTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() => _holdMark = false);
    });
  }

  /// 收尾并进入总结页（最后一组自动结束 / 顶栏"结束并保存"共用）。
  /// 幂等：_finishing 防重入；finish() 自身幂等（已结束的会话不重复落库），
  /// 飞书回填保持与收尾入口一致的无条件语义。
  Future<void> _finishFlow() async {
    if (_finishing || _summary != null) return;
    final c = app(context);
    final s = c.session;
    if (s.session == null) return;
    // 忘停表守护（2026-09-26）：可疑长会话保存前先问一句再落库；
    // 只在用户主动收尾 / 最后一组自动结束的时点出现，不碰训练中禁弹窗。
    if (!await _forgottenStopGuard(s)) return;
    _finishing = true;
    try {
      final stats = await s.stats();
      final verdicts = await s.verdicts();
      final date = s.session?.date ?? fmtDate(DateTime.now());
      final title = s.session?.planDayTitle ?? '';
      final prNames = s.prHit.toList();
      final durationMin = s.session?.durationMin ?? 0;
      await s.finish();
      c.notify.cancelRest();
      // 净时长（训练/休息分桶）在 finish 落库后回读
      final restMin = ((s.session?.restMs ?? 0) / 60000).ceil();
      final activeMin = ((s.session?.activeMs ?? 0) / 60000).ceil();
      final summaryBuf = StringBuffer();
      summaryBuf.writeln(
        '$title 完成：总容量 ${fmtVolume(stats.volume)}，${stats.workingSets} 个正式组，${stats.exercises.length} 个动作，总时长 $durationMin 分钟（训练 $activeMin / 休息 $restMin）。',
      );
      for (final v in verdicts) {
        summaryBuf.writeln('- $v');
      }
      unawaited(
        c.lark.backfillSessionSummary(date: date, summary: summaryBuf.toString()),
      );

      if (!mounted) return;
      setState(() {
        _summary = TrainingSummary(
          stats: stats,
          verdicts: verdicts,
          title: title,
          prNames: prNames,
          durationMin: durationMin,
          activeMin: activeMin,
          restMin: restMin,
        );
      });
    } finally {
      _finishing = false;
    }
  }

  /// 忘停表守护：时长可疑（一组没记挂机 30 分钟+ / 有记录但组均超 15 分钟）
  /// 时弹收起面板让用户拍板。返回是否继续正常收尾；选「不留记录」在这里
  /// 直接 quit 并退出训练页。可疑时截断由 truncateDurationToLastSet 落库前生效
  /// （ended_at 截到最后一条记录 +2 分钟，时长桶扣掉挂机段，只减不增）。
  Future<bool> _forgottenStopGuard(SessionController s) async {
    if (!isSuspiciousSessionDuration(
      startedAtMs: s.session!.startedAt,
      nowMs: DateTime.now().millisecondsSinceEpoch,
      setCount: s.setCount,
    )) {
      return true;
    }
    final wallMin =
        (DateTime.now().millisecondsSinceEpoch - s.session!.startedAt) ~/ 60000;
    final wallText = wallMin >= 60
        ? tx('${wallMin ~/ 60} 小时 ${wallMin % 60} 分',
            en: '${wallMin ~/ 60}h ${wallMin % 60}m')
        : tx('$wallMin 分钟', en: '$wallMin min');
    final last = s.lastSetDoneAtMs;
    final lastText = last == null
        ? ''
        : tx(
            '最后一条记录在 '
            '${DateTime.fromMillisecondsSinceEpoch(last).hour.toString().padLeft(2, '0')}:${DateTime.fromMillisecondsSinceEpoch(last).minute.toString().padLeft(2, '0')}',
            en:
                'Last set logged at ${DateTime.fromMillisecondsSinceEpoch(last).hour.toString().padLeft(2, '0')}:${DateTime.fromMillisecondsSinceEpoch(last).minute.toString().padLeft(2, '0')}',
          );
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                tx('这次开了 $wallText，是不是忘停表了？',
                    en: 'This session ran $wallText — forgot to stop the timer?'),
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            if (lastText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(lastText,
                    style:
                        const TextStyle(color: AppTheme.textDim, fontSize: 13)),
              ),
            ListTile(
              leading:
                  const Icon(Icons.content_cut, color: AppTheme.primary),
              title: Text(tx('截到最后一条记录保存（推荐）',
                  en: 'Trim to last set & save (recommended)')),
              onTap: () => Navigator.pop(ctx, 'truncate'),
            ),
            ListTile(
              leading: const Icon(Icons.save_outlined),
              title: Text(tx('照原样保存', en: 'Save as is')),
              onTap: () => Navigator.pop(ctx, 'asis'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppTheme.danger),
              title: Text(tx('不留记录', en: 'Discard session')),
              onTap: () => Navigator.pop(ctx, 'discard'),
            ),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'truncate':
        s.truncateDurationToLastSet();
        return true;
      case 'discard':
        if (!mounted) return false;
        final navigator = Navigator.of(context);
        await s.quit();
        navigator.pop(); // 退出训练页回首页
        return false;
      default:
        return true; // 照原样保存 / 下拉取消
    }
  }

  /// 计划内最后一组完成后的收尾确认（2026-10-07 结束确认弹窗）：
  /// 属「结束时点」弹窗豁免（先例 _forgottenStopGuard），不碰训练中
  /// 禁弹窗红线。返回 true = 结束并保存；false = 继续训练。上滑关闭/
  /// 点外部得 null → 按继续训练处理（最稳妥可逆：误关面板不会把会话
  /// 结束掉，用户随时可再长按顶栏收尾）。弹窗 await 期间会话仍 active，
  /// 训练卡/常亮/心跳照常。
  Future<bool> _confirmAutoFinish() async {
    final s = _sc;
    if (s == null) return true; // 防御：未接线时保持原自动结束语义
    final flow = WorkoutFlow(exercises: s.exercises, setsByEx: s.setsByEx);
    final remaining = flow.totalPlannedSets - flow.donePlannedSets;
    // 「还剩 N 组」档逐动作灰字（口径照抄跳页面板：只列未练满动作，
    // 已完成数封顶在各自计划组数上，加练不虚报）。
    final unfinishedLines = <String>[];
    if (remaining > 0) {
      for (final ex in s.exercises) {
        final raw = (s.setsByEx[ex.id] ?? const <SetEntry>[])
            .where((x) => x.kind == SetKind.working)
            .length;
        final planned = plannedSetsOf(ex);
        final done = raw > planned ? planned : raw;
        if (done < planned) {
          unfinishedLines.add(tx(
            '${exname(ex.name)} 已完成 $done/$planned',
            en: '${exname(ex.name)} $done/$planned done',
          ));
        }
      }
    }
    if (!mounted) return true;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                remaining > 0
                    ? tx('还剩 $remaining 组没做，现在结束吗？',
                        en: '$remaining set(s) left — finish now?')
                    : tx('全部组完成，结束训练吗？',
                        en: 'All sets done — finish the workout?'),
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            for (final line in unfinishedLines)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(line,
                      style: const TextStyle(
                          color: AppTheme.textDim, fontSize: 13)),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.play_arrow, color: AppTheme.primary),
              title: Text(tx('继续训练', en: 'Keep Training')),
              onTap: () => Navigator.pop(ctx, 'continue'),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle, color: AppTheme.primary),
              title: Text(tx('结束并保存', en: 'Finish & Save')),
              onTap: () => Navigator.pop(ctx, 'finish'),
            ),
          ],
        ),
      ),
    );
    return choice == 'finish';
  }

  /// 跳页面板（收起面板，红线禁弹窗）：列出全程每个计划组页，已完成的
  /// 划线标记且不可跳；点其他未练满动作的行直接跳过去（jumpToExercise）。
  Future<void> _showJumpSheet(BuildContext context) async {
    final s = app(context).session;
    final flow = WorkoutFlow(exercises: s.exercises, setsByEx: s.setsByEx);
    final refs = flow.setRefs();
    final cur = _shown;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                tx('全程页面 · 点未完成组的行直接跳过去',
                    en: 'All pages · Tap an unfinished set to jump'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
              ),
            ),
            for (var i = 0; i < s.exercises.length; i++) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_sessionInSuperset(s.exercises, i) ? '⇄ ' : ''}${i + 1}. ${exname(s.exercises[i].name)}',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      tx(
                        '已完成 ${refs.where((r) => r.exerciseIndex == i && r.done && !r.extra).length}/${plannedSetsOf(s.exercises[i])}',
                        en: '${refs.where((r) => r.exerciseIndex == i && r.done && !r.extra).length}/${plannedSetsOf(s.exercises[i])} done',
                      ),
                      style: const TextStyle(
                        color: AppTheme.textDim,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              for (final ref in refs)
                if (ref.exerciseIndex == i)
                  ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    // 已完成的组划线锁定；当前动作的组按序推进不从面板跳
                    enabled: !ref.done && ref.exerciseIndex != s.curExIdx,
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      s.jumpToExercise(ref.exerciseIndex);
                    },
                    leading: ref.done
                        ? const Icon(
                            Icons.check_rounded,
                            size: 18,
                            color: AppTheme.primary,
                          )
                        : SizedBox(
                            width: 18,
                            child: Center(
                              child: Text(
                                '${ref.setNumber}',
                                style: const TextStyle(
                                  color: AppTheme.textDim,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                    title: Text(
                      ref.extra
                          ? tx('第 ${ref.setNumber} 组（加练）',
                              en: 'Set ${ref.setNumber} (extra)')
                          : tx('第 ${ref.setNumber} 组',
                              en: 'Set ${ref.setNumber}'),
                      style: TextStyle(
                        fontSize: 14,
                        color: ref.done ? AppTheme.textDim : AppTheme.text,
                        decoration:
                            ref.done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    trailing: _isCurrentPage(cur, ref)
                        ? Text(
                            tx('当前', en: 'Current'),
                            style: const TextStyle(
                              color: AppTheme.accent,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        : null,
                  ),
                // 进行中的加练组（尚未落库，不在 refs 里）：补一行当前占位，
                // 让「加练了」在面板上可见（2026-09-26 Arono）。
                if (_currentExtraRef(cur, i) case final FlowSetRef extraRef)
                  ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    enabled: false,
                    leading: SizedBox(
                      width: 18,
                      child: Center(
                        child: Text(
                          '${extraRef.setNumber}',
                          style: const TextStyle(
                            color: AppTheme.textDim,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                    title: Text(
                      tx('第 ${extraRef.setNumber} 组（加练）',
                          en: 'Set ${extraRef.setNumber} (extra)'),
                      style: const TextStyle(fontSize: 14),
                    ),
                    trailing: Text(
                      tx('当前', en: 'Current'),
                      style: const TextStyle(
                        color: AppTheme.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }

  /// 当前正处于「加练记录页」时返回该行（供面板补当前占位）。
  FlowSetRef? _currentExtraRef(FlowPage? cur, int exerciseIndex) {
    if (cur == null ||
        cur.kind != FlowPageKind.record ||
        !cur.extra ||
        cur.exerciseIndex != exerciseIndex) {
      return null;
    }
    return FlowSetRef(
      exerciseIndex: cur.exerciseIndex,
      setNumber: cur.setNumber,
      done: false,
      extra: true,
    );
  }

  bool _isCurrentPage(FlowPage? cur, FlowSetRef ref) =>
      cur != null &&
      (cur.kind == FlowPageKind.record || cur.kind == FlowPageKind.rest) &&
      cur.exerciseIndex == ref.exerciseIndex &&
      cur.setNumber == ref.setNumber;

  @override
  Widget build(BuildContext context) {
    final c = app(context);
    final s = c.session;
    _syncPhaseSideEffects(s.phase);

    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        _syncPhaseSideEffects(s.phase);
        if (!s.hasActive && _summary == null && !_finishing) {
          // 兜底收尾（2026-09-28 模拟器实测）：最后一组保存后控制器立即结束
          // 会话，页面先重建成占位页、把记录面板从树上卸载——面板保存回调里的
          // onSessionEnded 因 context 失效被跳过，总结页永远出不来。
          // 这里从页面层补一枪：占位分支出现时自动调度收尾，下一帧进总结页。
          if (!_finishScheduled) {
            _finishScheduled = true;
            Future.microtask(_finishFlow);
          }
          return Scaffold(
            backgroundColor: AppTheme.bg,
            body: Center(child: Text(tx('本次训练已结束', en: 'Workout finished'))),
          );
        }
        final flow = WorkoutFlow(exercises: s.exercises, setsByEx: s.setsByEx);
        _syncShown(s, flow);
        final page = _shown;
        return Scaffold(
          backgroundColor: AppTheme.bg,
          // 整屏状态色（条目 11）：练=暗绿调、歇=暗红调，渐变过渡不闪变
          body: AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
            color: s.phase == WorkoutPhase.resting && page != null && page.kind == FlowPageKind.rest
                ? AppTheme.bgRest
                : AppTheme.bgLift,
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  ValueListenableBuilder<String>(
                    valueListenable: s.focusBanner,
                    builder: (context, msg, _) => msg.isEmpty
                        ? const SizedBox.shrink()
                        : Container(
                            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.warn.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.warning_amber_rounded,
                                  color: AppTheme.warn,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    msg,
                                    style: const TextStyle(
                                      color: AppTheme.warn,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                  // 页面流顶部条：计划文案 +『第 N/M 组』（条目 8；点开跳页面板）
                  if (page != null &&
                      (page.kind == FlowPageKind.record ||
                          page.kind == FlowPageKind.rest))
                    _FlowHeader(
                      s: s,
                      page: page,
                      onJumpSheet: () => _showJumpSheet(context),
                    ),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: LayoutBuilder(
                            builder: (context, cons) {
                              // 600dp 断点：更窄的屏（手机竖屏/分屏小窗）用紧凑面板，
                              // 压大数字字号并收起备注行，给「完成本组」留出空间。
                              final narrow = cons.maxWidth < 600;
                              final wide = cons.maxWidth >= 840;
                              Widget? content = _pageChild(
                                s,
                                flow,
                                page,
                                compact: narrow,
                              );
                              // 窄屏/中屏：操作区最大宽度 560，单手可达
                              // （总结页自带全宽布局，不参与收窄）
                              if (content != null &&
                                  !wide &&
                                  page?.kind != FlowPageKind.summary) {
                                content = Center(
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 560),
                                    child: content,
                                  ),
                                );
                              }
                              // 页面流翻页动画：换页由 FlowPage 判等驱动
                              return AnimatedSwitcher(
                                duration: const Duration(milliseconds: 280),
                                child: KeyedSubtree(
                                  key: ValueKey(page?.key ?? 'empty'),
                                  child: content ?? const SizedBox.shrink(),
                                ),
                              );
                            },
                          ),
                        ),
                        if (_holdMark) _buildMarkOverlay(),
                      ],
                    ),
                  ),
                  _buildProgressBar(flow, page),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 页面流各页的组件映射（起始 / 记录 / 休息 / 总结）。
  Widget? _pageChild(
    SessionController s,
    WorkoutFlow flow,
    FlowPage? page, {
    required bool compact,
  }) {
    if (page == null) return null;
    switch (page.kind) {
      case FlowPageKind.start:
        return _StartPage(
          s: s,
          flow: flow,
          onStart: () => setState(() => _startVisible = false),
        );
      case FlowPageKind.record:
        return _LiftView(
          s: s,
          compact: compact,
          onRecorded: _onSetRecorded,
          onSessionEnded: _finishFlow,
        );
      case FlowPageKind.rest:
        // 非 const：休息页内容（「再来一组」按钮、「下一组 · 加练」文案）
        // 要随 session notify 重渲染——const 实例会让 Flutter 短路跳过
        // 整棵子树（2026-10-17 加练带休息计时后不再靠换页刷新）。
        return _RestView();
      case FlowPageKind.summary:
        final sum = _summary;
        if (sum == null) return null;
        return _SummaryPage(
          s: s,
          stats: sum.stats,
          verdicts: sum.verdicts,
          title: sum.title,
          prNames: sum.prNames,
          durationMin: sum.durationMin,
          activeMin: sum.activeMin,
          restMin: sum.restMin,
        );
    }
  }

  /// 保存划线确认（wger 的"保存→划线→翻页"里的划线步）：
  /// 半透明遮罩上盖「已记录」章，刚存的组带删除线展示，不打断计时。
  Widget _buildMarkOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(
          color: AppTheme.bg.withValues(alpha: 0.55),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
              decoration: BoxDecoration(
                color: AppTheme.card,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.check_circle_rounded,
                    color: AppTheme.primary,
                    size: 40,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tx('已记录', en: 'Logged'),
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _markText,
                    style: const TextStyle(
                      fontSize: 16,
                      color: AppTheme.textDim,
                      decoration: TextDecoration.lineThrough,
                      decorationColor: AppTheme.textDim,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 底部 3px 细进度条（wger gym_mode navigation.dart 的
  /// LinearProgressIndicator(minHeight: 3, ratioCompleted) 口径）：
  /// 全程完成比例，加练不超 1，总结页恒为 1。
  Widget _buildProgressBar(WorkoutFlow flow, FlowPage? page) {
    final value = page?.kind == FlowPageKind.summary ? 1.0 : flow.ratioCompleted;
    return Semantics(
      label: tx('全程完成 ${(value * 100).round()}%',
          en: '${(value * 100).round()}% complete'),
      child: LinearProgressIndicator(
        key: const Key('workoutFlowProgress'),
        minHeight: 3,
        value: value,
        backgroundColor: AppTheme.cardHi,
        valueColor: const AlwaysStoppedAnimation(AppTheme.accent),
      ),
    );
  }
}

/// 页面流顶部条（每页一致）：计划文案（日标题）+『第 N/M 组』，
/// 组号 chip 点开跳页面板。起始/总结页有自己的标题，不显示本条。
class _FlowHeader extends StatelessWidget {
  const _FlowHeader({required this.s, required this.page, this.onJumpSheet});

  final SessionController s;
  final FlowPage page;
  final VoidCallback? onJumpSheet;

  @override
  Widget build(BuildContext context) {
    final label = page.setLabel();
    // 动作页的恢复标记：停练回归优先于减载（两者同时命中时处方按
    // 更低的 85% 一档，不能显示成「本周减载」误导）。
    final hasRecoveryChip = s.inLayoff || s.inDeloadWeek;
    final recoveryColor = s.inLayoff ? AppTheme.accent : AppTheme.warn;
    final recoveryIcon =
        s.inLayoff ? Icons.replay : Icons.spa_outlined;
    final recoveryLabel = s.inLayoff
        ? tx('停练 ${s.layoffDays} 天', en: '${s.layoffDays}d off')
        : tx('本周减载', en: 'Deload');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              dname(s.session?.planDayTitle ?? ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTheme.textDim, fontSize: 14),
            ),
          ),
          // 动作页恢复标记（P1-C/P1-D）：放进顶部条的现成行里，只占宽度、
          // 不新增高度，不遮挡动作名/三要素；休息页用完整横幅。
          if (hasRecoveryChip && page.kind == FlowPageKind.record) ...[
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: recoveryColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: recoveryColor.withValues(alpha: 0.35)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(recoveryIcon, size: 13, color: recoveryColor),
                  const SizedBox(width: 4),
                  Text(
                    recoveryLabel,
                    style: TextStyle(
                      color: recoveryColor,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (label.isNotEmpty)
            GestureDetector(
              onTap: onJumpSheet,
              child: Semantics(
                button: true,
                label: tx('打开全程页面面板', en: 'Open all-pages panel'),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.cardHi,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          color: AppTheme.accent,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Icon(
                        Icons.keyboard_arrow_down,
                        size: 18,
                        color: AppTheme.textDim,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 本组目标文案（v14 按记录形态换口径）：计时→秒、单侧→每边均分、
/// 常规→次数；上下限相同只给单值。记录页目标行与起始页共用。
String targetTextFor(SessionExercise ex) {
  final lo = ex.rule.repsMin;
  final hi = ex.rule.repsMax;
  if (isTimedLogging(ex.logging)) {
    return lo == hi
        ? tx('目标 $lo 秒', en: 'Target ${lo}s')
        : tx('目标 $lo-$hi 秒', en: 'Target $lo-$hi s');
  }
  if (isPerSideLogging(ex.logging)) {
    final plo = normalizeTarget(lo, ex.logging) ~/ 2;
    final phi = normalizeTarget(hi, ex.logging) ~/ 2;
    return plo == phi
        ? tx('目标 每边 $plo 次', en: 'Target $plo/side')
        : tx('目标 每边 $plo-$phi 次', en: 'Target $plo-$phi/side');
  }
  return lo == hi
      ? tx('目标 $lo 次', en: 'Target $lo reps')
      : tx('目标 $lo-$hi 次', en: 'Target $lo-$hi reps');
}

/// 起始页动作卡副标题：组数 × 目标（口径随记录形态：计时=秒、
/// 单侧=每边均分）· RIR。
String startCardSub(SessionExercise ex) {
  final sets = plannedSetsOf(ex);
  final rir = ex.rule.rirTarget;
  if (isTimedLogging(ex.logging)) {
    return tx('$sets 组 × ${ex.rule.repsMin}-${ex.rule.repsMax} 秒 · RIR $rir',
        en: '$sets sets × ${ex.rule.repsMin}-${ex.rule.repsMax}s · RIR $rir');
  }
  if (isPerSideLogging(ex.logging)) {
    final lo = normalizeTarget(ex.rule.repsMin, ex.logging) ~/ 2;
    final hi = normalizeTarget(ex.rule.repsMax, ex.logging) ~/ 2;
    return lo == hi
        ? tx('$sets 组 × 每边 $lo 次 · RIR $rir',
            en: '$sets sets × $lo/side · RIR $rir')
        : tx('$sets 组 × 每边 $lo-$hi 次 · RIR $rir',
            en: '$sets sets × $lo-$hi/side · RIR $rir');
  }
  return tx('$sets 组 × ${ex.rule.repsMin}-${ex.rule.repsMax} 次 · RIR $rir',
      en: '$sets sets × ${ex.rule.repsMin}-${ex.rule.repsMax} reps · RIR $rir');
}

/// 起始页首个动作的热身建议文案（P2-A）：只展示，不自动落库。
/// 空串 = 不显示（辅助配重这种负重量没有正重量口径）。
String warmupHintTextFor({
  required String name,
  required double targetWeightKg,
  required String loadType,
  String logging = LoggingMode.reps,
}) {
  String bodyweightText() {
    if (isTimedLogging(logging)) {
      return tx('热身：先做 1 组 20-30 秒的轻强度热身',
          en: 'Warm-up: 1 easy 20-30s set');
    }
    if (isPerSideLogging(logging)) {
      return tx('热身：每边 5-8 次慢速标准动作',
          en: 'Warm-up: 5-8 slow reps per side');
    }
    return tx('热身：先做 1 组 5-8 次慢速标准动作',
        en: 'Warm-up: 1 slow set of 5-8 clean reps');
  }

  if (loadType == LoadMode.bodyweight) return bodyweightText();
  final meta = libraryMetaForLift(name);
  final useLb = WeightUnits.isLb;
  final plan = warmupPlanFor(
    targetWeightKg: targetWeightKg,
    gear: meta?.gear ?? '',
    useLb: useLb,
    barKgOverride: warmupBarKgFor(name, useLb: useLb),
  );
  if (plan.mode == WarmupMode.none) return '';
  if (plan.mode == WarmupMode.bodyweight) return bodyweightText();
  // 热身阶梯的量随记录形态换口径：计时→秒（重量热身按 20/15/10 秒），
  // 单侧→每边次数，常规→次数。
  String amount(WarmupStep st) {
    if (isTimedLogging(logging)) {
      final sec = st.percent == 60 ? 15 : (st.percent == 80 ? 10 : 20);
      return tx('$sec 秒', en: '${sec}s');
    }
    if (isPerSideLogging(logging)) {
      return tx('每边 ${st.reps} 次', en: '${st.reps}/side');
    }
    return tx('${st.reps} 次', en: '${st.reps} reps');
  }

  final parts = <String>[];
  for (final st in plan.steps) {
    if (st.percent == null) {
      parts.add(tx('空杆 ${fmtWithUnit(st.weightKg)}×${amount(st)}',
          en: 'bar ${fmtWithUnit(st.weightKg)}×${amount(st)}'));
    } else {
      parts.add(tx(
        '${st.percent}% ${fmtWithUnit(st.weightKg)}×${amount(st)}',
        en: '${st.percent}% ${fmtWithUnit(st.weightKg)}×${amount(st)}',
      ));
    }
  }
  final label = plan.mode == WarmupMode.light
      ? tx('热身（简化）：', en: 'Warm-up (light): ')
      : tx('热身：', en: 'Warm-up: ');
  return '$label${parts.join(' · ')}';
}

/// 停练回归横幅（P1-D）：非弹窗、只占一行高；未触发时完全隐形。
/// 说明为什么今天轻、组数少，以及下一次间隔正常就回到原档。
class _LayoffBanner extends StatelessWidget {
  const _LayoffBanner();

  @override
  Widget build(BuildContext context) {
    final s = app(context).session;
    if (!s.hasActive || !s.inLayoff) return const SizedBox.shrink();
    final days = s.layoffDays;
    final dual = s.inDeloadWeek
        ? tx('（本周同时是减载周，取更低的 85% 一档，不重复打折）',
            en: ' (deload week too — the lower 85% factor applies once, no double discount)')
        : '';
    return Container(
      key: const Key('layoffBanner'),
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.replay, size: 16, color: AppTheme.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tx(
                '停练 $days 天，今天按 85% 找感觉：负重约 85%（辅助配重 +15%），正式组数 -1（最少 1 组）；下次间隔正常后回到原档。$dual',
                en: 'Back after $days days off — today at 85%: loaded lifts ~85% (machine assist +15%), one fewer working set (min 1); back to normal once you train again within 14 days.$dual',
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTheme.accent, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 减载周横幅（P1-C）：非弹窗、只占一行高；不是减载周时完全隐形。
/// 说明本周为什么轻（90% 重量、少 1 组）以及下周怎么接回去。
class _DeloadBanner extends StatelessWidget {
  const _DeloadBanner();

  @override
  Widget build(BuildContext context) {
    final s = app(context).session;
    if (!s.hasActive || !s.inDeloadWeek) return const SizedBox.shrink();
    // 停练回归同时命中时由 _LayoffBanner 统一说明（取更低的 85% 一档），
    // 不再并列显示「约 90%」造成两套系数打架。
    if (s.inLayoff) return const SizedBox.shrink();
    final weeks = s.trainingBlockWeeks;
    final week = s.trainingBlockWeek <= 0 ? weeks : s.trainingBlockWeek;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.warn.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.warn.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.spa_outlined, size: 16, color: AppTheme.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tx(
                '第 $week/$weeks 周 · 本周减载：负重动作按约 90% 负荷（辅助配重增加约 10%），所有动作正式组数 -1（最少 1 组）；自重动作只减组，下周回到原档继续',
                en: 'Week $week/$weeks · Deload week: loaded lifts at ~90% (machine assist +10%) and one fewer working set (min 1) for all; bodyweight lifts drop a set only. Back to normal next week',
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTheme.warn, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 起始页（wger gym_mode 的开始页思路）：先看一眼今天练什么——
/// 计划文案 + 每个动作的组次目标；大按钮进第一记录页。
/// 只在"零记录"的全新会话出现；中途恢复直接落到当前记录页。
class _StartPage extends StatelessWidget {
  const _StartPage({
    required this.s,
    required this.flow,
    required this.onStart,
  });

  final SessionController s;
  final WorkoutFlow flow;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    // 首个动作的热身建议（P2-A）：只展示，不落库、不生成热身组。
    // 800×360 这类超矮横屏下压成单行，并收起底部「点动作看解析」提示，
    // 避免把 88dp 开始按钮挤出视口（widget_layout_test 的横屏回归场景）。
    final compactHeight = MediaQuery.sizeOf(context).height < 480;
    final warmupHint = s.exercises.isEmpty
        ? ''
        : warmupHintTextFor(
            name: s.exercises.first.name,
            targetWeightKg: s.weightDraft,
            loadType: s.exercises.first.loadType,
            logging: s.exercises.first.logging,
          );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.session == null
                ? tx('今日训练', en: 'Today\'s Workout')
                : dname(s.session!.planDayTitle),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            tx('共 ${s.exercises.length} 个动作 · ${flow.totalPlannedSets} 个正式组',
                en: '${s.exercises.length} exercises · ${flow.totalPlannedSets} working sets'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textDim, fontSize: 15),
          ),
          const SizedBox(height: 12),
          // 停练回归说明（P1-D）：开练前先知道今天为什么轻、组数少。
          const _LayoffBanner(),
          // 减载周说明（P1-C）：开练前先知道这周为什么轻、组数少。
          const _DeloadBanner(),
          const SizedBox(height: 8),
          for (var i = 0; i < s.exercises.length; i++)
            GestureDetector(
              // 开练前先过一眼图文解析（2026-09-27）：点动作行打开
              onTap: () => showExerciseDetailSheet(
                context,
                name: s.exercises[i].name,
                exerciseKey: s.exercises[i].exerciseKey,
              ),
              child: Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                children: [
                  Text(
                    '${i + 1}.',
                    style: const TextStyle(
                      color: AppTheme.textDim,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          exname(s.exercises[i].name),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        // 目标口径随记录形态（v14）：计时→秒、单侧→每边
                        Text(
                          startCardSub(s.exercises[i]),
                          style: const TextStyle(
                            color: AppTheme.textDim,
                            fontSize: 13,
                          ),
                        ),
                        // 器械设置（P2-C）：开练前先看到该动作的固定设置；
                        // 空备注零尺寸，不额外占行。
                        SetupNoteView(
                          note: s.setupNoteOf(s.exercises[i]),
                          compact: true,
                        ),
                        // 首个动作的热身建议（P2-A）：只展示，不自动落库。
                        if (i == 0 && warmupHint.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(top: 1),
                                child: Icon(
                                  Icons.local_fire_department,
                                  size: 14,
                                  color: AppTheme.accent,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  warmupHint,
                                  key: const Key('startWarmupHint'),
                                  style: const TextStyle(
                                    color: AppTheme.accent,
                                    fontSize: 12.5,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        // 「为什么是这个数字」主口在记录页目标行下（小屏/横屏
                        // 起始页不加行——800×360 下会把开始按钮挤出视口）。
                      ],
                    ),
                  ),
                ],
              ),
              ),
            ),
          if (!compactHeight) ...[
            const SizedBox(height: 8),
            Text(
              tx('点动作可先看图文解析',
                  en: 'Tap an exercise for the illustrated guide'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          // 冻结基线：主操作按钮高度 ≥88dp，拇指可达区
          BigButton(
              label: tx('开始训练', en: 'Start Workout'),
              height: 88,
              onPressed: onStart),
        ],
      ),
    );
  }
}

// ================= 动作态 =================

class _LiftView extends StatelessWidget {
  const _LiftView({
    required this.s,
    this.compact = false,
    this.onRecorded,
    this.onSessionEnded,
  });

  final SessionController s;

  /// <600dp 窄屏：压缩面板（大数字字号降档、隐藏备注行）。
  final bool compact;

  /// 保存一组成功后的划线标记回调（宿主盖「已记录」章并自动翻页）。
  final void Function(String mark)? onRecorded;

  /// 最后一组触发状态机自动结束后：宿主收尾并把总结页接进页面流。
  final Future<void> Function()? onSessionEnded;

  @override
  Widget build(BuildContext context) {
    final ex = s.currentEx;
    if (ex == null) return const SizedBox.shrink();
    // 折叠屏/平板横屏（≥840dp）：左信息右操作双栏
    return LayoutBuilder(
      builder: (context, cons) {
        final wide = cons.maxWidth >= 840;
        if (wide) {
            return Column(
              children: [
                _TopBar(s: s, onFinish: onSessionEnded),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: _ExerciseInfo(s: s, ex: ex),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SingleChildScrollView(
                          child: _ActionPanel(
                            s: s,
                            ex: ex,
                            key: ValueKey(ex.id),
                            onRecorded: onRecorded,
                            onSessionEnded: onSessionEnded,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }
        // 单栏：信息区 + 操作面板装进同一滚动区。内容装得下时用 min-height
        // 撑满视口（信息居中、面板贴底，与原布局一致）；装不下（横屏 ~360dp
        // 可用高、系统大字号）时整体可滚动，「完成本组」不再被挤出屏幕。
        return Column(
          children: [
            _TopBar(s: s, onFinish: onSessionEnded),
            Expanded(
              child: LayoutBuilder(
                builder: (context, viewport) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: viewport.maxHeight),
                    child: IntrinsicHeight(
                      child: Column(
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              child: _ExerciseInfo(s: s, ex: ex),
                            ),
                          ),
                          _ActionPanel(
                            s: s,
                            ex: ex,
                            key: ValueKey(ex.id),
                            compact: compact,
                            onRecorded: onRecorded,
                            onSessionEnded: onSessionEnded,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TopBar extends StatefulWidget {
  const _TopBar({required this.s, this.onFinish});

  final SessionController s;

  /// 「结束并保存」：宿主收尾（finish 落库 + 飞书回填）并把总结页接进页面流。
  final Future<void> Function()? onFinish;

  @override
  State<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<_TopBar> {
  bool _holdHint = false; // 进度不足松手的内联提示（非弹窗非 toast）
  Timer? _hintTimer;

  /// 长按 2 秒确认后给三个出口：继续练 / 放弃本次（不留记录）/ 结束并保存。
  /// P1-12 的"放弃不保存"出口保留在这里，防误触由长按手势承担。
  Future<void> _showEndOptions() async {
    setState(() => _holdHint = false);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow, color: AppTheme.primary),
              title: Text(tx('继续训练', en: 'Resume Workout')),
              onTap: () => Navigator.pop(ctx, 'continue'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppTheme.danger),
              title: Text(
                  tx('放弃本次（不留记录）', en: 'Discard (no record saved)')),
              subtitle: Text(
                tx('误开的训练用这个，历史不会多一次',
                    en: 'For accidental starts; nothing is added to history'),
                style: const TextStyle(fontSize: 12),
              ),
              onTap: () => Navigator.pop(ctx, 'quit'),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle, color: AppTheme.primary),
              title: Text(tx('结束并保存', en: 'Finish & Save')),
              onTap: () => Navigator.pop(ctx, 'finish'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'finish') {
      await widget.onFinish?.call();
    } else if (choice == 'quit') {
      final c = app(context);
      final navigator = Navigator.of(context);
      await c.session.quit();
      if (!mounted) return;
      navigator.pop(); // 退出训练页回首页
    }
  }

  /// 进度不足 30% 就松手：教手势（FitoTrack 思路），用页面内联提示而非
  /// toast/弹窗——不抢焦点、不挡训练计时（红线：训练中不弹窗）。
  void _onShortRelease() {
    setState(() => _holdHint = true);
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _holdHint = false);
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLastEx = widget.s.curExIdx >= widget.s.exercises.length - 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // 计划文案与『第 N/M 组』由宿主顶栏条统一显示，这里只放操作；
              // 两个入口用 Expanded+ellipsis：系统大字号下不挤出 HoldToEndButton
              Expanded(
                child: TextButton(
                  onPressed: () => _showExerciseAdjustSheet(context),
                  child: Text(
                    tx('换/加动作', en: 'Swap / Add Exercise'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textDim,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: TextButton(
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    widget.s.skipExercise();
                  },
                  child: Text(
                    isLastEx
                        ? tx('已是最后一个', en: 'Last exercise')
                        : tx('跳过动作', en: 'Skip Exercise'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: isLastEx
                          ? AppTheme.textDim.withValues(alpha: 0.4)
                          : AppTheme.textDim,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              HoldToEndButton(
                onConfirmed: _showEndOptions,
                onShortRelease: _onShortRelease,
              ),
            ],
          ),
          // 内联手势提示（条目 5）：只占一行高度，出现/消失不挤压训练区
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _holdHint
                ? Padding(
                    key: const ValueKey('holdHint'),
                    padding: const EdgeInsets.only(top: 2),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        tx('按住「结束训练」不放，转满一圈才生效',
                            en: 'Keep holding Finish until the ring completes'),
                        style: const TextStyle(
                          color: AppTheme.warn,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey('noHint')),
          ),
        ],
      ),
    );
  }

  /// 训练中临时调整动作：加动作到队尾 / 替换当前动作（器械被占时用）。
  /// 只影响本次训练，不改计划；当前动作已记组时不可替换（防串名）。
  Future<void> _showExerciseAdjustSheet(BuildContext context) async {
    final s = widget.s;
    final canReplace = s.currentSets.isEmpty;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.playlist_add, color: AppTheme.primary),
              title: Text(tx('添加动作到队尾', en: 'Add Exercise to End')),
              subtitle: Text(
                tx('从动作库挑选，只进本次训练',
                    en: 'Pick from the library; this workout only'),
                style: const TextStyle(fontSize: 12),
              ),
              onTap: () => Navigator.pop(ctx, 'append'),
            ),
            ListTile(
              leading: const Icon(Icons.swap_horiz, color: AppTheme.accent),
              title: Text(
                canReplace
                    ? tx('替换当前动作（${exname(s.currentEx?.name ?? '')}）',
                        en: 'Replace Current (${exname(s.currentEx?.name ?? '')})')
                    : tx('替换当前动作', en: 'Replace Current'),
              ),
              subtitle: Text(
                canReplace
                    ? tx('沿用原组次规则，只换动作名',
                        en: 'Keeps the set/reps rule; only the name changes')
                    : tx('当前动作已记组，不能替换；可改用"跳过动作"',
                        en: 'Sets already logged; use "Skip Exercise" instead'),
                style: const TextStyle(fontSize: 12),
              ),
              onTap: canReplace ? () => Navigator.pop(ctx, 'replace') : null,
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // 替换时把当前动作也标为已存在，防止挑到它自己
    final existing = s.exercises.map((e) => e.name).toSet();
    final picked = await Navigator.of(context).push<List<ExerciseMeta>>(
      MaterialPageRoute(
        builder: (_) => ExercisePickerPage(existingNames: existing),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    if (choice == 'append') {
      await s.appendExercises(picked);
      s.showFocusBanner(tx('已加 ${picked.length} 个动作到队尾',
          en: 'Added ${picked.length} exercise(s) to the end'));
    } else {
      final ok = await s.replaceCurrentExercise(picked.first);
      if (ok) {
        s.showFocusBanner(tx('已换成 ${exname(picked.first.name)}',
            en: 'Switched to ${exname(picked.first.name)}'));
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text(tx('替换失败：该动作已在本次训练里',
                en: 'Replace failed: already in this workout')),
            backgroundColor: AppTheme.cardHi,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}

/// 长按 2 秒结束训练（调研条目 5，FitoTrack HoldToStopButton 思路 + 无障碍补强）：
/// 环形进度 2 秒填满触发；按住期间每 100ms 一次触觉 tick；松手即取消；
/// 进度不足 30% 松手回调 [onShortRelease] 给页面内联提示（父组件渲染，
/// 非弹窗非 toast）。无障碍替代路径：读屏（TalkBack）开启时退化为单击
/// 直通三选——长按+进度对读屏不可用，FitoTrack 原实现未处理，这里补上。
/// 公开类便于 widget 测试覆盖（test/hold_to_stop_test.dart）。
class HoldToEndButton extends StatefulWidget {
  const HoldToEndButton({
    super.key,
    required this.onConfirmed,
    this.onShortRelease,
  });

  final VoidCallback onConfirmed;
  final VoidCallback? onShortRelease;

  @override
  State<HoldToEndButton> createState() => _HoldToEndButtonState();
}

class _HoldToEndButtonState extends State<HoldToEndButton> {
  static const _holdMs = 2000;

  Timer? _timer;
  int _elapsedMs = 0;
  int _lastTick = -1;
  double _progress = 0;

  bool get _accessible => MediaQuery.of(context).accessibleNavigation;

  void _startHold() {
    if (_timer != null) return;
    HapticFeedback.selectionClick();
    _elapsedMs = 0;
    _lastTick = -1;
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) => _step());
  }

  void _step() {
    // 进度按 50ms tick 计数推进（UI 提示用途，非计时权威——休息计时
    // 仍以墙钟为准）：误差 ≤50ms 无感，且在 fake-clock 测试里行为一致。
    _elapsedMs += 50;
    // 触觉 tick（条目 5）：每 100ms 一次轻震，给"正在计时"的体感，
    // 与完成组的确认震动（mediumImpact）区分开。
    final tick = _elapsedMs ~/ 100;
    if (tick != _lastTick) {
      _lastTick = tick;
      HapticFeedback.selectionClick();
    }
    if (_elapsedMs >= _holdMs) {
      _cancelHold();
      HapticFeedback.heavyImpact();
      widget.onConfirmed();
      return;
    }
    setState(() => _progress = _elapsedMs / _holdMs);
  }

  void _onRelease() {
    final p = _progress;
    _cancelHold();
    if (p > 0 && p < 0.3) widget.onShortRelease?.call();
  }

  void _cancelHold() {
    _timer?.cancel();
    _timer = null;
    _elapsedMs = 0;
    if (mounted && _progress != 0) setState(() => _progress = 0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accessible = _accessible;
    final Widget child;
    if (accessible) {
      // 读屏替代路径：TalkBack 双击即开三选（P1-12 出口不受影响）
      child = TextButton(
        onPressed: widget.onConfirmed,
        child: Text(
          tx('结束训练', en: 'Finish'),
          style: const TextStyle(color: AppTheme.textDim, fontSize: 14),
        ),
      );
    } else {
      child = GestureDetector(
        onLongPressStart: (_) => _startHold(),
        onLongPressEnd: (_) => _onRelease(),
        onLongPressCancel: _onRelease,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 环形进度：平时一枚暗环暗示"可环形握住"，按住时危险色填充
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  value: _progress <= 0 ? 0 : _progress,
                  strokeWidth: 2.5,
                  strokeCap: StrokeCap.round,
                  color: _progress > 0 ? AppTheme.danger : AppTheme.textDim,
                  backgroundColor: AppTheme.textDim.withValues(alpha: 0.25),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                _progress > 0
                    ? tx('继续按住…', en: 'Keep holding…')
                    : tx('结束训练', en: 'Finish'),
                style: TextStyle(
                  color: _progress > 0 ? AppTheme.danger : AppTheme.textDim,
                  fontSize: 14,
                  fontWeight: _progress > 0 ? FontWeight.w800 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Semantics(
      button: true,
      label: tx('结束训练', en: 'Finish'),
      hint: accessible
          ? tx('点按两下打开结束选项', en: 'Double-tap for finish options')
          : tx('长按两秒打开结束选项', en: 'Long-press 2s for finish options'),
      child: child,
    );
  }
}

class _ExerciseInfo extends StatelessWidget {
  const _ExerciseInfo({required this.s, required this.ex});

  final SessionController s;
  final SessionExercise ex;

  @override
  Widget build(BuildContext context) {
    final last = s.lastWorkout[ex.name] ?? const <SetEntry>[];
    // 上次成绩口径随记录形态（v14）：计时→秒、单侧→总次数（每边 M）、
    // 自重→纯次数；不再出现「0kg×N」假重量。
    final bool timed = isTimedLogging(ex.logging);
    final bool perSide = isPerSideLogging(ex.logging);
    final bool bodyweight = isBodyweightUi(
        exerciseName: ex.name, loadType: ex.loadType);
    String lastCell(SetEntry e, bool en) {
      final n = timed ? (e.durationSec ?? e.reps) : e.reps;
      if (timed) return en ? '${n}s' : '$n 秒';
      if (perSide) {
        return en ? 'total $n (${n ~/ 2}/side)' : '总 $n 次（每边 ${n ~/ 2}）';
      }
      if (bodyweight) return en ? '$n reps' : '$n 次';
      return en
          ? '${fmtWt(e.weightKg)} × $n'
          : '${fmtWt(e.weightKg)}×$n';
    }

    final lastText = last.isEmpty
        ? tx('首次训练这个动作', en: 'First time on this exercise')
        : tx(
            '上次：${last.map((e) => lastCell(e, false)).join('  ')}',
            en: 'Last time: ${last.map((e) => lastCell(e, true)).join('  ')}');
    // 组数/目标行已升格为动作面板第一行的大字号条（2026-09-26 Arono），
    // 这里不再重复显示，避免同屏两处组号且挤占小屏纵向空间。
    final info = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${s.curExIdx + 1} / ${s.exercises.length}',
          style: const TextStyle(color: AppTheme.textDim, fontSize: 15),
        ),
        const SizedBox(height: 4),
        Text(
          exname(ex.name),
          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
        ),
        // 临时调整痕迹（点名条目三）：替换/追加过的动作显示来源，可追溯
        if (ex.trace.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              ex.trace,
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          lastText,
          style: const TextStyle(color: AppTheme.textDim, fontSize: 15),
        ),
        // 器械设置（P2-C）：只在该动作第一组前显示（空备注不占空间）；
        // 开始记录后收起，不挤占后续组的动作区。
        if (s.currentSets.isEmpty)
          SetupNoteView(note: s.setupNoteOf(ex), compact: true),
        // 动作解析入口（2026-09-27）：图文解析收在这个主动点按的入口后，
        // 不占三要素空间；弹层随时划掉，计时不受影响。
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showExerciseDetailSheet(
              context,
              name: ex.name,
              exerciseKey: ex.exerciseKey,
            ),
            child: Semantics(
              button: true,
              label: tx('查看 ${exname(ex.name)} 的动作解析',
                  en: 'View form guide for ${exname(ex.name)}'),
              child: Text(
                tx('📖 动作解析', en: '📖 Form Guide'),
                style:
                    const TextStyle(color: AppTheme.textDim, fontSize: 13),
              ),
            ),
          ),
        ),
        if (s.currentSets.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GestureDetector(
              onTap: () => s.undoLastSet(),
              child: Text(
                tx('↩ 撤销上一组', en: '↩ Undo last set'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
              ),
            ),
          ),
      ],
    );
    return info;
  }
}

/// 重量键盘输入层：点重量数字 / 休息页「直接输入重量」唤起。
/// 只在用户主动点按时出现、划掉或点空白处即取消，不属于训练中打断弹窗；
/// 正数=负重，0=自重，负数=辅助器械配重。
Future<void> showWeightInputSheet(BuildContext context, SessionController s) {
  // lb 模式（2026-10-17）：输入框按 lb 初始与提交，落库前换算回 kg；
  // 示例值也随单位给（62.5kg 量级 ≈ 135lb）。
  final ctrl = TextEditingController(text: fmtVal(s.weightDraft));
  final exPos = WeightUnits.isLb ? '135' : '62.5';
  final exNeg = WeightUnits.isLb ? '-66' : '-30';
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.card,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) {
        void submit() {
          final v = double.tryParse(ctrl.text.trim().replaceAll(',', '.'));
          if (v == null) {
            setSheetState(() {}); // 刷新 errorText 提示
            return;
          }
          HapticFeedback.selectionClick();
          s.setWeightDraft(WeightUnits.isLb ? lbToKg(v) : v);
          Navigator.pop(sheetCtx);
        }

        final invalid =
            double.tryParse(ctrl.text.trim().replaceAll(',', '.')) == null;
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tx('输入重量（${unitLabel()}）',
                      en: 'Enter Weight (${unitLabel()})'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  tx('正数 = 负重；0 = 自重；负数 = 辅助器械配重（如 $exNeg）',
                      en: 'Positive = loaded; 0 = bodyweight; negative = machine assist (e.g. $exNeg)'),
                  style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      RegExp(r'^-?\d{0,3}(\.\d{0,2})?$'),
                    ),
                    LengthLimitingTextInputFormatter(7),
                  ],
                  onSubmitted: (_) => submit(),
                  style: AppTheme.bigNum(30),
                  decoration: InputDecoration(
                    hintText: tx('如 $exPos', en: 'e.g. $exPos'),
                    errorText: invalid
                        ? tx('请输入数字，如 $exPos 或 $exNeg',
                            en: 'Enter a number, e.g. $exPos or $exNeg')
                        : null,
                  ),
                ),
                const SizedBox(height: 16),
                BigButton(
                    label: tx('确认', en: 'Confirm'),
                    height: 64,
                    onPressed: submit),
                TextButton(
                  onPressed: () => Navigator.pop(sheetCtx),
                  child: Text(
                    tx('取消', en: 'Cancel'),
                    style: const TextStyle(color: AppTheme.textDim),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// 自定义次数直输（2026-09-26 Arono）：轻重量高次数（12/15+）超出计划
/// ±2 的点选范围时直接键入，1-99 的整数。与重量直输同款交互：
/// 用户主动点按唤起键盘、可取消，不算打断训练。
Future<void> showRepsInputSheet(
  BuildContext context, {
  required int current,
  required ValueChanged<int> onPicked,
}) {
  final ctrl = TextEditingController(text: '$current');
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.card,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) {
        int? parsed() {
          final v = int.tryParse(ctrl.text.trim());
          if (v == null || v < 1 || v > 99) return null;
          return v;
        }

        void submit() {
          final v = parsed();
          if (v == null) {
            setSheetState(() {}); // 刷新 errorText 提示
            return;
          }
          HapticFeedback.selectionClick();
          onPicked(v);
          Navigator.pop(sheetCtx);
        }

        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tx('输入次数', en: 'Enter Reps'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  tx('轻重量高次数直接键入，如 12 或 15（1-99）',
                      en: 'Type any rep count, e.g. 12 or 15 (1-99)'),
                  style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(2),
                  ],
                  onSubmitted: (_) => submit(),
                  style: AppTheme.bigNum(30),
                  decoration: InputDecoration(
                    hintText: tx('如 15', en: 'e.g. 15'),
                    errorText: parsed() == null
                        ? tx('请输入 1-99 的次数', en: 'Enter 1-99 reps')
                        : null,
                  ),
                ),
                const SizedBox(height: 16),
                BigButton(
                    label: tx('确认', en: 'Confirm'),
                    height: 64,
                    onPressed: submit),
                TextButton(
                  onPressed: () => Navigator.pop(sheetCtx),
                  child: Text(
                    tx('取消', en: 'Cancel'),
                    style: const TextStyle(color: AppTheme.textDim),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _ActionPanel extends StatefulWidget {
  const _ActionPanel({
    super.key,
    required this.s,
    required this.ex,
    this.compact = false,
    this.onRecorded,
    this.onSessionEnded,
  });

  final SessionController s;
  final SessionExercise ex;

  /// <600dp 窄屏压缩：重量大数字 84→56、收起备注行；
  /// 步进按钮与「完成本组」高度不动（冻结基线）。
  final bool compact;

  /// 保存一组成功（会话未结束）：宿主盖「已记录」章并自动翻到下一页。
  final void Function(String mark)? onRecorded;

  /// 最后一组触发状态机自动结束：宿主收尾并把总结页接进页面流。
  final Future<void> Function()? onSessionEnded;

  @override
  State<_ActionPanel> createState() => _ActionPanelState();
}

class _ActionPanelState extends State<_ActionPanel> {
  String _kind = SetKind.working;
  int? _reps;
  int? _rir;
  bool _rirPrompt = false; // 余力没填写提醒：第一按只提示不落库
  // 余力真实性（P0-C 复核，2026-10-18）：[rirRecorded] 的判据不是「_rir 有值」
  // 而是「用户亲手点过余力行」。「带入上次成绩」只预填数值（重量/次数/余力
  // 展示值），不置此标记——预填的 R2 不是本场观测，落库 rir_recorded=0，
  // 统计与渐进判定不会把它当成真的余力记录。
  bool _rirTouched = false;
  // 疼痛标记（P2-B）：0/'' = 未填。默认收起，用户主动点「＋疼痛」才展开
  // 部位/程度；不弹窗、不抢焦点，绝不打断训练（安全底线只记录不拦人）。
  int _painLevel = 0;
  String _painArea = '';
  bool _painOpen = false;
  String _note = '';
  bool _noteOpen = false;
  bool _saving = false; // 防抖：力竭手抖双击不能记两组
  late final _noteCtrl = TextEditingController();
  // 步长随单位（2026-10-17）：kg [0.5,1.25,2.5,5] / lb [1.25,2.5,5,10]。
  static List<double> get _steps => stepLabels();

  /// 点单位标签切 kg↔lb 后立即刷新本面板（动态单位勿用 const 构造）。
  void _toggleUnit(SessionController s) {
    toggleWeightUnit(context, s);
    setState(() {});
  }

  // 工作计时（v14 计时动作）：墙钟起表 + 每秒刷新显示。
  // 与休息计时完全独立；从本页切走（撤销回退/跳页面板/换动作/翻组）即
  // 放弃当次计时——面板状态销毁或重新起表，不落库。
  int _workStartMs = 0;
  Timer? _workTick;

  @override
  void initState() {
    super.initState();
    if (isTimedLogging(widget.ex.logging)) _armWorkTimer();
  }

  /// 工作计时起表：进入本页（或新的一组页）从零累计。
  void _armWorkTimer() {
    _workStartMs = DateTime.now().millisecondsSinceEpoch;
    _workTick?.cancel();
    _workTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {}); // 只刷计时数字
    });
  }

  /// 本页已保持秒数（墙钟差值，地板 1——起表即按也算这组开始了）。
  int get _elapsedSec {
    if (_workStartMs == 0) return 0;
    final sec =
        ((DateTime.now().millisecondsSinceEpoch - _workStartMs) / 1000).floor();
    return sec < 1 ? 1 : sec;
  }

  /// 工作计时展示（分:秒，与休息倒计时同风格的大数字）。
  String get _workClockText {
    final total = _elapsedSec;
    return '${(total ~/ 60).toString().padLeft(2, '0')}:'
        '${(total % 60).toString().padLeft(2, '0')}';
  }

  @override
  void didUpdateWidget(_ActionPanel old) {
    super.didUpdateWidget(old);
    if (old.ex.id != widget.ex.id) {
      _reps = null;
      _kind = SetKind.working;
      _rir = null;
      _rirTouched = false;
      _rirPrompt = false;
      _painLevel = 0;
      _painArea = '';
      _painOpen = false;
    }
    // 计时动作换了「组页」（换动作/撤销回退改变完成组数）→ 重新起表：
    // 上一组的计时已随翻页放弃，这一组从 0 秒开始
    if (isTimedLogging(widget.ex.logging) &&
        (old.ex.id != widget.ex.id ||
            old.s.workingSetsDone != widget.s.workingSetsDone)) {
      _armWorkTimer();
    }
  }

  @override
  void dispose() {
    _workTick?.cancel();
    _noteCtrl.dispose();
    super.dispose();
  }

  /// 渐进提醒行（2026-09-26）：当前重量与平台期重量一致时提醒可加重。
  /// hitTop（次数已到顶）→ 直接给目标重量；否则提示冲到目标次数就加。
  List<Widget> _plateauRow(BuildContext context, SessionController s) {
    final info = s.plateauFor(widget.ex.name);
    if (info == null) return const [];
    // 减载周/停练回归不叠加平台期提醒：这场的处方就是恢复，提示减载/加重会打架。
    if (s.inDeloadWeek || s.inLayoff) return const [];
    // 只在"正停留在这个重量上"时提醒：已经加重/在调别的重量不打扰
    if ((info.weightKg - s.weightDraft).abs() > 0.01) return const [];
    final rule = widget.ex.rule;
    // P1-C 停滞协议：未顶格的平台期给「减载 10% 或换变式」，
    // 已顶格保留加重建议；2 次/12 天的老口径仍提示冲次数。
    final protocol = plateauProtocolOf(
      info,
      rule: rule,
      logging: widget.ex.logging,
      loadType: widget.ex.loadType,
    );
    final reduce = protocol.action == 'reduce';
    final msg = protocol.action != 'none'
        ? protocol.reason
        : tx(
            '已连续 ${info.sessions} 次·${info.days} 天 ${fmtWt(info.weightKg)}——次数冲到 ${rule.repsMax} 就该 +${fmtWt(rule.incrementKg)}',
            en: '${fmtWt(info.weightKg)} for ${info.sessions} sessions · ${info.days} days — once you reach ${rule.repsMax} reps, add +${fmtWt(rule.incrementKg)}');
    final color = reduce ? AppTheme.warn : AppTheme.primary;
    return [
      const SizedBox(height: 4),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(reduce ? Icons.trending_down : Icons.trending_up,
              size: 15, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              msg,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              style: TextStyle(color: color, fontSize: 12.5),
            ),
          ),
        ],
      ),
    ];
  }

  /// 上次成绩行（无历史不显示）。
  /// 计时动作比秒数、自重动作比次数（v14）——「上次：0kg×45」这类
  /// 假重量口径不再出现。
  List<Widget> _lastPerformanceRow(BuildContext context, SessionController s) {
    final last = s.lastPerformance(widget.ex.name);
    if (last == null) return const [];
    // 余力真实性（P0-C）：上次没点过余力时 rir 只是计划默认值，
    // 不以「R2」伪装成观测；带入时也只当展示值预填（配合 _rirTouched，
    // 不落成 rir_recorded=1 的假观测）。
    final lastRirRecorded = last.rirRecorded;
    final rirText = lastRirRecorded && last.rir >= 0 ? ' R${last.rir}' : '';
    final bool timed = isTimedLogging(widget.ex.logging);
    final bool bodyweight = isBodyweightUi(
        exerciseName: widget.ex.name, loadType: widget.ex.loadType);
    final lastNum =
        timed ? (last.durationSec ?? last.reps) : last.reps;
    final String zhLast;
    final String enLast;
    if (timed) {
      zhLast = '$lastNum 秒';
      enLast = '${lastNum}s';
    } else if (bodyweight) {
      zhLast = '$lastNum 次';
      enLast = '$lastNum reps';
    } else {
      zhLast = '${fmtWt(last.weightKg)}×$lastNum';
      enLast = '${fmtWt(last.weightKg)} × $lastNum';
    }
    return [
      const SizedBox(height: 4),
      GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          s.setWeightDraft(last.weightKg);
          setState(() {
            // 只预填数值（2026-10-18）：余力展示值一并带入，但 touched 不置真
            // ——预填值不是本场点选的观测，落库按「未记录」走。
            _reps = last.reps;
            _rir = lastRirRecorded ? last.rir : null;
            _rirTouched = false;
          });
        },
        child: Semantics(
          button: true,
          label: tx(
            '带入上次成绩：${timed || bodyweight ? '' : fmtWt(last.weightKg)}$lastNum${timed ? '秒' : '次'}${lastRirRecorded ? '余力${last.rir}' : ''}',
            en: 'Apply last set: $enLast${lastRirRecorded ? ', RIR ${last.rir}' : ''}',
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.history, size: 15, color: AppTheme.accent),
                const SizedBox(width: 5),
                Text(
                  tx('上次：$zhLast$rirText（点按整套带入）',
                      en: 'Last time: $enLast$rirText (tap to apply)'),
                  style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final ex = widget.ex;
    final compact = widget.compact;
    // 动作记录形态（v14）：计时 / 单侧 / 自重，三种形态共用本面板
    final timed = isTimedLogging(ex.logging);
    final perSide = isPerSideLogging(ex.logging);
    // H3 收尾：UI 自重判定带「显式负重变体名」规则，改名负重变体给重量输入
    final bodyweight = isBodyweightUi(
        exerciseName: ex.name, loadType: ex.loadType);
    // 次数点选：单侧动作 ±2 步进（总数要能两侧均分），其余 ±1
    final List<int> repsChoices;
    if (perSide) {
      var start = normalizeTarget(ex.rule.repsMin, ex.logging) - 2;
      if (start < 2) start = 2;
      repsChoices = [
        for (var r = start;
            r <= normalizeTarget(ex.rule.repsMax, ex.logging) + 2;
            r += 2)
          r,
      ];
    } else {
      repsChoices = <int>{
        for (
          var r = (ex.rule.repsMin - 2).clamp(1, 99);
          r <= ex.rule.repsMax + 2;
          r++
        )
          r,
      }.toList()
        ..sort();
    }
    final doneAll = s.workingSetsDone >= plannedSetsOf(ex);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 组数 + 目标常显（2026-09-26 Arono：帮人数组、防忘目标）：
          // 放在动作面板视线主区第一行；加练态显示绝对组号
          // 「第 N 组（加练）」（2026-10-08 口径统一），组号继续涨，
          // 不再被夹回计划数。
          Builder(
            builder: (context) {
              final planned = plannedSetsOf(ex);
              // 目标行按记录形态换口径（v14）：计时→秒、单侧→每边均分
              final targetText = targetTextFor(ex);
              final setText = s.workingSetsDone >= planned
                  ? tx('第 ${s.workingSetsDone + 1} 组（加练）',
                      en: 'Set ${s.workingSetsDone + 1} (extra)')
                  : tx('第 ${s.workingSetsDone + 1}/$planned 组',
                      en: 'Set ${s.workingSetsDone + 1}/$planned');
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: setText,
                        style: TextStyle(
                          fontSize: compact ? 20 : 24,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.primary,
                        ),
                      ),
                      TextSpan(
                        text: '  ·  ',
                        style: TextStyle(
                          fontSize: compact ? 15 : 17,
                          color: AppTheme.textDim,
                        ),
                      ),
                      TextSpan(
                        text: targetText,
                        style: TextStyle(
                          fontSize: compact ? 15 : 17,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.text,
                        ),
                      ),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
              );
            },
          ),
          // 「目标为什么是这个数字」（v14 可解释化）：规则链推导一句话，
          // 视觉从属的小字行——在目标下方、不抢三要素；空串（未预载的
          // 临时动作）不占位直接收起。
          Builder(
            builder: (context) {
              final why = s.targetWhyOf(s.curExIdx);
              if (why.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  why,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: AppTheme.textDim, fontSize: 12),
                ),
              );
            },
          ),
          // 中部主区按记录形态分块（v14）：
          // 计时 → 大号工作计时（分:秒、墙钟累计，屏幕最大元素之一），
          // 与休息计时完全独立，切走/跳过即放弃不落库；
          // 自重 → 「自重」标识 + 上次对比（不再出现 0kg 假重量）；
          // 常规负重 → 原重量大数字 + 杠铃片速配 + ± 步进（交互不动）。
          if (timed) ...[
            const SizedBox(height: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _workClockText,
                key: const Key('workTimerText'),
                style: AppTheme.bigNum(compact ? 56 : 84),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              tx('计时中 · 点「完成」记录本组用时',
                  en: 'Timing · tap Done to log this hold'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
            ),
            ..._lastPerformanceRow(context, s),
          ] else if (bodyweight) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    tx('自重', en: 'Bodyweight'),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF06220F),
                    ),
                  ),
                ),
              ],
            ),
            ..._lastPerformanceRow(context, s),
          ] else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Flexible+FittedBox：键盘可输任意值（999.5 / 辅 300），
                // 数字放不下时等比缩小而不是溢出裁切；放得下保持原字号
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        showWeightInputSheet(context, s);
                      },
                      onLongPress: () => s.setWeightDraft(0),
                      // 负值=辅助配重（辅30），0=自重，正值=常规负重（fmtLoad 统一口径）；
                      // 点按弹数字键盘直输，长按清零（老入口保留）
                      child: Text(
                        fmtLoad(s.weightDraft),
                        key: const ValueKey('weightDraftNum'),
                        style: AppTheme.bigNum(
                          compact || s.weightDraft <= 0 ? 56 : 84,
                        ),
                      ),
                    ),
                  ),
                ),
                // 单位标签即开关（2026-10-17）：点一下 kg↔lb 全局切换，
                // 大数字/步长/输入/历史同步换算；不弹窗、不抢焦点。
                Padding(
                  padding: const EdgeInsets.only(left: 6, bottom: 10),
                  child: Tooltip(
                    message: tx('点按切换重量单位（kg/lb），历史数据同步换算显示',
                        en: 'Tap to switch weight unit (kg/lb); history converts too'),
                    child: GestureDetector(
                      onTap: () => _toggleUnit(s),
                      child: Text(
                        unitLabel(),
                        style: TextStyle(
                          color: AppTheme.primary,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
                // 自重/负重一键切换（长按清零的老入口保留，这里给可见入口）
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 12),
                  child: Tooltip(
                    message: tx(
                      '自重/辅助动作点这里：在自重和上次重量间切换；点大数字可直接键入重量（负值 = 辅助器械配重，如 -30）',
                      en: 'For bodyweight/assisted moves: switch between bodyweight and last weight; tap the big number to type a weight (negative = machine assist, e.g. -30)',
                    ),
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        s.toggleBodyweightDraft();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: s.weightDraft == 0
                              ? AppTheme.accent
                              : AppTheme.cardHi,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          s.weightDraft == 0
                              ? tx('自重', en: 'Bodyweight')
                              : tx('自重?', en: 'Bodyweight?'),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: s.weightDraft == 0
                                ? const Color(0xFF06220F)
                                : AppTheme.textDim,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // 杠铃片速配（2026-09-26 Arono）：杠铃动作改重量时短暂显示
            // 每边挂片，约 4 秒自动收起；非杠铃动作完全不占位。
            _PlateHintStrip(
                s: s,
                exName: ex.name,
                gear: libraryMetaForLift(ex.name)?.gear ?? ''),
            // 上次成绩行（调研条目 7，wger/LibreFit 思路）：与渐进引擎建议值
            // （大数字 = 本组推荐起点）并列的第二起点，点按整套带入重量/次数/
            // RIR；不替换建议值、不弹窗，无需手动步进即可重现上次配置。
            ..._lastPerformanceRow(context, s),
            // 渐进提醒行（2026-09-26 Arono：薄肌渐进超负荷主动提示）：
            // 同一重量停留过久时一行小字提醒可加重——与上次成绩行同级克制，
            // 不弹窗不打断（红线：训练中禁止弹窗）。
            ..._plateauRow(context, s),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final step in _steps)
                  WeightStepButton(
                    delta: step,
                    // lb 模式先 snap 0.5lb 网格再加步长（防换算漂移），kg 原样
                    onTap: () => s.setWeightDraft(nudgedKg(s.weightDraft, step)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final step in _steps)
                  WeightStepButton(
                    delta: -step,
                    onTap: () =>
                        s.setWeightDraft(nudgedKg(s.weightDraft, -step)),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          // 组类型三选：Wrap 而非 Row——系统大字号（1.6x）下三枚 chip
          // 挤不进一行的窄屏时自动换行，不再 RenderFlex 溢出
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              _kindChip(tx('热身', en: 'Warm-up'), SetKind.warmup),
              _kindChip(tx('正式', en: 'Working'), SetKind.working),
              _kindChip(tx('力竭', en: 'Failure'), SetKind.failure),
              // 疼痛小标记（P2-B）：与组类型同排的「＋疼痛」小 chip，
              // 收起时只占一枚 chip 的横向位置（不占纵向空间），
              // 点开才展开部位/程度。不弹窗、不拦「完成本组」。
              _painChip(),
            ],
          ),
          if (_painOpen) ...[
            const SizedBox(height: 8),
            Container(
              key: const Key('workoutPainPanel'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(
                    color: AppTheme.warn.withValues(alpha: 0.7), width: 1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      Text(tx('部位', en: 'Area'),
                          style: const TextStyle(
                              color: AppTheme.textDim, fontSize: 12)),
                      for (final a in PainArea.all) _painAreaChip(a),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      Text(tx('程度', en: 'Level'),
                          style: const TextStyle(
                              color: AppTheme.textDim, fontSize: 12)),
                      _painLevelChip(1, tx('1 轻', en: '1 Mild')),
                      _painLevelChip(2, tx('2 中', en: '2 Mod')),
                      _painLevelChip(3, tx('3 重', en: '3 Severe')),
                      _painLevelChip(0, tx('无痛', en: 'None')),
                    ],
                  ),
                  // 等级 ≥2 的非弹窗建议（P2-B）：就地一行小字，不打断计时，
                  // 也不改本组重量/次数——只提示减负荷或换变式。
                  if (_painLevel >= 2) ...[
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.trending_down,
                            size: 15, color: AppTheme.warn),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            tx(
                              '建议：下一组减约 10% 重量或换更轻的变式，别硬顶；持续疼或加重就停下',
                              en: 'Tip: drop ~10% load or switch to an easier variation next set; stop if it persists or worsens',
                            ),
                            style: const TextStyle(
                                color: AppTheme.warn, fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          // RIR（余力）：默认用计划目标值，可点选覆盖。
          // Wrap 而非 Row：系统大字号（1.6x）下窄屏一行放不下时自动换行。
          // _rirPrompt：忘了填余力时整行高亮 + 行下提示（第一按不落库）。
          Container(
            padding: _rirPrompt
                ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
                : null,
            decoration: _rirPrompt
                ? BoxDecoration(
                    border: Border.all(color: AppTheme.warn, width: 1.5),
                    borderRadius: BorderRadius.circular(12),
                  )
                : null,
            child: Column(
              children: [
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Tooltip(
                      message: tx(
                          '余力(RIR) = 做完这组还能再做几次；不确定可留空，按计划默认记但不计入统计',
                          en: 'RIR = reps left in the tank; leave it blank to log the plan default (not counted as recorded)'),
                      child: Text(
                        _rirPrompt
                            ? tx('余力没填写 ', en: 'RIR missing ')
                            : tx('余力 ', en: 'RIR '),
                        style: TextStyle(
                          color: _rirPrompt
                              ? AppTheme.warn
                              : AppTheme.textDim,
                          fontSize: 14,
                          fontWeight: _rirPrompt
                              ? FontWeight.w800
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                    for (var r = 0; r <= 4; r++)
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() {
                            _rir = (_rir == r) ? null : r;
                            if (_rir != null) _rirPrompt = false;
                            // 用户亲手点过余力行：此后本组的余力才算真实观测。
                            _rirTouched = true;
                          });
                        },
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: _rir == r ? AppTheme.accent : AppTheme.cardHi,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '$r',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: _rir == r
                                  ? const Color(0xFF06220F)
                                  : (_rirPrompt
                                      ? AppTheme.text
                                      : AppTheme.textDim),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                if (_rirPrompt) ...[
                  const SizedBox(height: 4),
                  Text(
                    tx('点一个数字；不确定就再按一次「完成本组」，按计划默认记（标为未记录）',
                        en: 'Pick a number, or tap Done again to log the plan default (marked unrecorded)'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: AppTheme.warn, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          // 次数点选（v14）：计时动作没有次数概念，整块收起——
          // 「完成」记实际用时；单侧动作 chips 走 ±2 步进（每边均分）。
          if (!timed) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final r in repsChoices)
                  ChoiceChip(
                    label: Text('$r'),
                    selected: _reps == r,
                    labelStyle: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color:
                          _reps == r ? const Color(0xFF06220F) : AppTheme.text,
                    ),
                    selectedColor: AppTheme.primary,
                    backgroundColor: AppTheme.cardHi,
                    side: BorderSide.none,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    onSelected: (_) {
                      HapticFeedback.selectionClick();
                      setState(() => _reps = r);
                    },
                  ),
                // 自定义次数（2026-09-26 Arono）：轻重量高次数（12/15+）
                // 超出计划 ±2 的点选范围时直接键入；选中后 chip 显示实际次数。
                // 单侧动作键入值就近取偶（保存口径与 chips 一致）。
                Builder(
                  builder: (context) {
                    final custom =
                        (_reps != null && !repsChoices.contains(_reps))
                            ? _reps!
                            : null;
                    return ChoiceChip(
                      label: Text(
                          custom != null ? '$custom' : tx('自定义', en: 'Custom')),
                      selected: custom != null,
                      labelStyle: TextStyle(
                        fontSize: custom != null ? 17 : 14,
                        fontWeight: FontWeight.w700,
                        color: custom != null
                            ? const Color(0xFF06220F)
                            : AppTheme.textDim,
                      ),
                      selectedColor: AppTheme.primary,
                      backgroundColor: AppTheme.cardHi,
                      side: BorderSide.none,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      onSelected: (_) {
                        HapticFeedback.selectionClick();
                        showRepsInputSheet(
                          context,
                          current: _reps ?? ex.rule.repsMin,
                          onPicked: (v) =>
                              setState(() => _reps = normalizeTarget(v, ex.logging)),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ],
          // 备注入口（默认收起，PRD P0 字段：单组备注）；
          // <600dp 窄屏压缩时整段收起，给完成按钮留高度。
          if (!compact) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => setState(() => _noteOpen = !_noteOpen),
              child: Text(
                _note.isEmpty && !_noteOpen
                    ? tx('+ 备注（可选）', en: '+ Note (optional)')
                    : tx('备注：${_note.isEmpty ? "编辑" : _note}',
                        en: 'Note: ${_note.isEmpty ? "edit" : _note}'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: _note.isEmpty ? AppTheme.textDim : AppTheme.accent,
                ),
              ),
            ),
            if (_noteOpen)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: TextField(
                  controller: _noteCtrl,
                  autofocus: false,
                  maxLines: 1,
                  onChanged: (v) => _note = v,
                  decoration: InputDecoration(
                    hintText: tx('这组的感受/状态（可选）',
                        en: 'How this set felt (optional)'),
                    isDense: true,
                  ),
                ),
              ),
          ],
          const SizedBox(height: 12),
          // key 仅供 widget 测试定位（test/widget_layout_test.dart），无行为含义。
          // 计划组练满后按钮变成"加练一组"（加练组按正式组记录），不再是死灰按钮。
          // 计时动作（v14）：「完成」记录实际用时；旁边「跳过」放弃本次
          // 计时直接翻组——不落库、不弹窗（红线：训练中禁止弹窗）。
          if (timed)
            Row(
              children: [
                Expanded(
                  child: BigButton(
                    key: const Key('workoutCompleteSet'),
                    label: doneAll
                        ? tx('加练一组（正式组）', en: 'Extra Set (Working)')
                        : tx('完成', en: 'Done'),
                    color:
                        _kind == SetKind.failure ? AppTheme.warn : AppTheme.primary,
                    onPressed:
                        _saving ? null : () => _saveCurrentSet(context),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: _saving
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          // 跳过 = 重起工作计时、不落库（与"切走放弃"同语义）
                          setState(_armWorkTimer);
                        },
                  child: Text(
                    tx('跳过', en: 'Skip'),
                    style: const TextStyle(
                        color: AppTheme.textDim, fontSize: 15),
                  ),
                ),
              ],
            )
          else
            BigButton(
              key: const Key('workoutCompleteSet'),
              label: doneAll
                  ? tx('加练一组（正式组）', en: 'Extra Set (Working)')
                  : tx('完成本组', en: 'Done'),
              color: _kind == SetKind.failure ? AppTheme.warn : AppTheme.primary,
              onPressed: _saving ? null : () => _saveCurrentSet(context),
            ),
        ],
      ),
    );
  }

  /// 「完成本组 / 完成」统一落库路径：先过余力提醒，再按记录形态组装
  /// 数据写库（v14）：
  /// - 计时：weight=0、reps=durationSec=实际秒数，划线文案「N 秒」；
  /// - 单侧：保存值就近取偶（每边均分口径，奇数输入自动归一）；
  /// - 常规负重：重量取当前草稿、次数取点选值（原行为不变）。
  Future<void> _saveCurrentSet(BuildContext context) async {
    final s = widget.s;
    final ex = widget.ex;
    final timed = isTimedLogging(ex.logging);
    // H3 收尾：负重变体改名保留旧键时，保存不再强制 0kg
    final bodyweight = isBodyweightUi(
        exerciseName: ex.name, loadType: ex.loadType);
    // 余力没填写提醒（2026-09-26 Arono）：正式组第一按不落库，
    // 高亮余力行提示补填；再按一次按计划默认记（不拦人）。
    // 热身/力竭组不提醒（力竭本身就是 RIR 0）。
    if (_kind == SetKind.working && _rir == null && !_rirPrompt) {
      HapticFeedback.selectionClick();
      setState(() => _rirPrompt = true);
      return;
    }
    _saving = true;
    HapticFeedback.mediumImpact();
    final int? durationSec;
    final int reps;
    if (timed) {
      durationSec = _elapsedSec; // 墙钟差值，切走前最后一刻取值
      reps = durationSec;
    } else {
      durationSec = null;
      // 单侧动作保存取偶（normalizeTarget 非单侧原样返回）
      reps = normalizeTarget(_reps ?? ex.rule.repsMin, ex.logging);
    }
    // 计时/自重动作不落重量（自重链 recommendWeight 恒 0，保持 0kg 口径）
    final weight = (timed || bodyweight) ? 0.0 : s.weightDraft;
    // 余力真实性（P0-C）：只有本组真的点过 chip 才算「已记录」；连按两次
    // 走计划默认值、或「带入上次成绩」只预填了数值时，rir 照存当前值，
    // 但 rir_recorded=0（预填不是观测）。
    final rirRecorded = _rir != null && _rirTouched;
    // 疼痛标记（P2-B）：保存前先记下本组的值（保存后与余力一起清空，
    // 下一组重新问），落库与提示都用这份快照。
    final painLevel = _painLevel;
    final painArea = _painArea;
    final pr = await s.completeSet(
      weight: weight,
      reps: reps,
      rir: _rir ?? ex.rule.rirTarget,
      kind: _kind,
      note: _note,
      durationSec: durationSec,
      rirRecorded: rirRecorded,
      painLevel: painLevel,
      painArea: painArea,
    );
    _saving = false;
    _rirPrompt = false;
    _note = '';
    // await 期间面板可能已被换页卸载（最后一组 → 确认收尾 → 总结页）：
    // 已 dispose 的 TextEditingController 不可再 clear，全部守卫
    if (mounted) {
      // 余力/疼痛选择只代表刚记录的这组：下一组重新问，避免把上一组的
      // 点选无感带成「已记录」。
      _rir = null;
      _rirTouched = false;
      _painLevel = 0;
      _painArea = '';
      _noteCtrl.clear();
      if (_noteOpen || _painOpen) {
        setState(() {
          _noteOpen = false;
          _painOpen = false;
        });
      }
    }
    // 等级 ≥2 的非弹窗建议（P2-B）：用页面顶部横幅（与 PR 祝贺同一机制，
    // 5 秒自动收起），不弹窗、不拦流程；最后一组也照常提示。
    if (painLevel >= 2) {
      s.showFocusBanner(tx(
        '疼痛 ${painname(painArea)} $painLevel 级：下一组减约 10% 重量或换更轻的变式，别硬顶',
        en: 'Pain ${painname(painArea)} level $painLevel: drop ~10% load or switch to an easier variation next set',
      ));
    }
    if (!context.mounted) return;
    // 最后一个动作的最后一组：状态机已自动结束，
    // 宿主收尾（总结页 + 渐进建议 + 飞书回填）接进页面流
    if (!s.hasActive) {
      await widget.onSessionEnded?.call();
      return;
    }
    // 保存流程（调研条目 8）：校验→写库（completeSet）→
    // 划线标记→自动翻页（宿主在窗口结束后应用下一页）
    widget.onRecorded?.call(
      timed
          ? tx('$durationSec 秒', en: '$durationSec s')
          : '${fmtLoadU(weight)} × $reps',
    );
    // 重量 PR 祝贺只对常规负重形态有意义（计时/自重恒 0kg，没有重量轴）；
    // 疼痛 ≥2 时让位给安全提示（同一横幅位，安全优先于庆祝）。
    if (pr && !timed && !bodyweight && painLevel < 2) {
      s.showFocusBanner(tx('🏆 ${exname(ex.name)} 重量新高 PR！',
          en: '🏆 ${exname(ex.name)} New PR!'));
    }
  }

  Widget _kindChip(String label, String kind) {
    final sel = _kind == kind;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _kind = kind);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: sel ? AppTheme.accent : AppTheme.cardHi,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: sel ? const Color(0xFF06220F) : AppTheme.textDim,
          ),
        ),
      ),
    );
  }

  /// 疼痛入口 chip（P2-B）：收起时是一枚与组类型同排的小 chip；
  /// 已标记时显示「部位 + 等级」并转暖色，点按展开/收起编辑区。
  /// 【不打断】只是本面板内的展开，不弹窗、不挡「完成本组」。
  Widget _painChip() {
    final active = _painLevel > 0;
    final label = active
        ? tx('疼痛 ${painname(_painArea)} · $_painLevel',
            en: 'Pain ${painname(_painArea)} · $_painLevel')
        : tx('＋疼痛', en: '+ Pain');
    return Semantics(
      button: true,
      toggled: _painOpen,
      label: active
          ? tx('已标记疼痛：${painname(_painArea)} $_painLevel 级，点按修改',
              en: 'Pain marked: ${painname(_painArea)} level $_painLevel, tap to edit')
          : tx('标记本组疼痛（可选），点按展开',
              en: 'Mark pain for this set (optional), tap to expand'),
      child: GestureDetector(
        key: const Key('workoutPainMarker'),
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _painOpen = !_painOpen);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: active ? AppTheme.warn : AppTheme.cardHi,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.healing,
                size: 14,
                color: active ? AppTheme.bgDeep : AppTheme.textDim,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: active ? AppTheme.bgDeep : AppTheme.textDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _painAreaChip(String area) {
    final sel = _painArea == area && _painLevel > 0;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() {
          // 选了部位就视为「有疼痛」：程度默认 1 级，用户可再点 2/3 覆盖。
          _painArea = area;
          if (_painLevel == 0) _painLevel = 1;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: sel ? AppTheme.warn : AppTheme.cardHi,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          painname(area),
          style: TextStyle(
            fontSize: 13,
            fontWeight: sel ? FontWeight.w700 : FontWeight.w400,
            color: sel ? AppTheme.bgDeep : AppTheme.textDim,
          ),
        ),
      ),
    );
  }

  Widget _painLevelChip(int level, String label) {
    final sel = _painLevel == level;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() {
          if (level == 0) {
            _painLevel = 0;
            _painArea = '';
          } else if (_painLevel == level) {
            // 再点一次已选等级 = 取消标记
            _painLevel = 0;
            _painArea = '';
          } else {
            _painLevel = level;
            if (_painArea.isEmpty) _painArea = PainArea.other;
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: sel ? AppTheme.warn : AppTheme.cardHi,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: sel ? FontWeight.w700 : FontWeight.w400,
            color: sel ? AppTheme.bgDeep : AppTheme.textDim,
          ),
        ),
      ),
    );
  }
}

// ================= 休息态 =================

class _RestView extends StatefulWidget {
  const _RestView();

  @override
  State<_RestView> createState() => _RestViewState();
}

class _RestViewState extends State<_RestView> {
  bool _weightOpen = false; // 展开"下一组重量"步进（休息中可调重量）
  // 步长随单位（2026-10-17）：kg [0.5,1.25,2.5,5] / lb [1.25,2.5,5,10]。
  static List<double> get _steps => stepLabels();

  @override
  Widget build(BuildContext context) {
    final c = app(context);
    final s = c.session;
    final ex = s.currentEx;
    final isLastEx = s.curExIdx >= s.exercises.length - 1;
    final plannedWorking = ex == null ? 0 : plannedSetsOf(ex);
    final doneAll = s.workingSetsDone >= plannedWorking;
    // 练满动作上的休息 = 落点是它的加练组（「再来一组」回退后休息继续；
    // 或收尾确认选「继续训练」后的加练态——含轮转末组落在非末位动作的
    // 情形）。练满必已切走或回退，不存在「练满且未练满下一动作」的
    // 普通推进休息，所以不再有「下一个动作：X」分支（2026-10-17）。
    final nextText = doneAll
        ? (isLastEx
              ? tx('准备结束训练', en: 'Ready to Finish')
              : tx('下一组 · ${exname(ex?.name ?? '')} 加练：${fmtLoadU(s.weightDraft)} × ${ex?.rule.repsMin}-${ex?.rule.repsMax} 次',
                  en: 'Next · ${exname(ex?.name ?? '')} extra: ${fmtLoadU(s.weightDraft)} × ${ex?.rule.repsMin}-${ex?.rule.repsMax} reps'))
        // 下一组带动作名 + 组号（2026-09-26 Arono：休息中要知道接下来
        // 练什么动作、第几组、做多少次）。尾巴不放操作提示：412 宽会
        // 折成两行，破坏休息页"一眼看完"的极简版式（点按展开本就是常态）
        : tx('下一组 · ${exname(ex?.name ?? '')} 第 ${s.workingSetsDone + 1}/$plannedWorking 组：${fmtLoadU(s.weightDraft)} × ${ex?.rule.repsMin}-${ex?.rule.repsMax} 次',
            en: 'Next · ${exname(ex?.name ?? '')} set ${s.workingSetsDone + 1}/$plannedWorking · ${fmtLoadU(s.weightDraft)} × ${ex?.rule.repsMin}-${ex?.rule.repsMax} reps');

    // 上半（倒计时）+ 底部操作区装进同一滚动区：装得下时 min-height 撑满
    // 视口（操作区贴底，与原布局一致）；横屏/矮屏装不下时可滚动，
    // 「跳过休息，直接开练」不再被挤出屏幕。
    return LayoutBuilder(
      builder: (context, viewport) {
        // 轻量战报只在竖向空间充裕时显示（调研条目 9）：矮屏（横屏手机）
        // 保持"倒计时+操作区"的冻结布局不增高——战报默认收起、绝不占屏，
        // 空间不够时整个收起。
        final showBrief = viewport.maxHeight >= 480;
        return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: viewport.maxHeight),
          child: IntrinsicHeight(
            child: Column(
              children: [
                // 停练回归在休息页也保留一句说明（非弹窗、不占三要素）。
                const _LayoffBanner(),
                // 减载周在休息页也保留一句说明（非弹窗、不占三要素）；
                // 非减载周完全隐形，不增加休息页高度。
                const _DeloadBanner(),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        tx('组间休息', en: 'Rest'),
                        style: const TextStyle(
                            color: AppTheme.textDim, fontSize: 18),
                      ),
                      const SizedBox(height: 8),
                      ValueListenableBuilder<int>(
                        valueListenable: s.restRemainingMs,
                        builder: (context, ms, _) {
                          final remain = (ms / 1000).ceil();
                          final frac = s.restTotalMs <= 0
                              ? 1.0
                              : ms / s.restTotalMs;
                          final color = frac > 0.2
                              ? AppTheme.primary
                              : (frac > 0 ? AppTheme.warn : AppTheme.danger);
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: FittedBox(
                              // 大字体缩放/窄屏下五个字符可能超出屏宽，
                              // Text 会软换行把末位挤到第二行——
                              // 永不换行，放不下就整体等比缩小，
                              // 缩小后仍是屏内最大元素（红线不破）。
                              fit: BoxFit.scaleDown,
                              child: Text(
                                fmtDuration(remain),
                                maxLines: 1,
                                softWrap: false,
                                style: AppTheme.bigNum(
                                  // 下限 56（原 72）：横屏/矮屏下先给底部操作区
                                  // 留出空间，数字仍远大于页内其他文字（18/24 号），
                                  // 保持屏内最大元素。
                                  (MediaQuery.of(context).size.height *
                                          (_isWide(context) ? 0.20 : 0.15))
                                      .clamp(56.0, 260.0),
                                  color: color,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      // 简约心率小标（2026-10-17 Arono 拍板）：只进休息页、
                      // 已连接才出现，♥ + bpm 一行小字不抢主视线——
                      // 三要素红线不破；点按进设备管理页。
                      if (showBrief) ...[
                        const SizedBox(height: 10),
                        const HrRestChip(),
                      ],
                      // 心率自适应建议（P2-F）：已连接且读数偏高/已恢复时
                      // 多一行小字 + 手动 ±30 秒；未连接时零占位。
                      // 只给建议，绝不自动改休息时间、绝不弹窗。
                      // 矮屏（横屏手机，showBrief<480）也保留：恢复与否
                      // 直接影响训练决策，用紧凑布局不挤占倒计时与操作区。
                      _HrRestAdvice(compact: !showBrief),
                      if (showBrief) ...[
                        const SizedBox(height: 12),
                        // 轻量战报（调研条目 9，Fast N Fitness 思路）：
                        // 只放休息等待页、默认收起、点开可展开——
                        // 绝不进训练计时主界面、绝不默认占屏。
                        _RestBrief(),
                      ],
                      // 渐进主动提醒（2026-09-26 Arono：薄肌渐进超负荷，
                      // 让人不错过加重机会）：破纪录 / 平台期该加重两条横幅，
                      // 只在休息等待页出现、小字不上屏主计时——不碰红线。
                      if (showBrief) ...[
                        const SizedBox(height: 8),
                        _ProgressNudges(),
                      ],
                      const SizedBox(height: 12),
                      // 超级组提示（v9）：当前/接下来轮到的动作在超级组里，
                      // 提醒交替执行方式；不占主视线，小字放在「下一组」上方。
                      if (_sessionInSuperset(s.exercises, s.curExIdx)) ...[
                        Text(
                          tx('⇄ 超级组 · 交替执行', en: '⇄ Superset · alternating'),
                          style: const TextStyle(
                            color: AppTheme.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                      // 点"下一组"展开重量步进：休息中就能调下一组重量
                      GestureDetector(
                        onTap: () => setState(() => _weightOpen = !_weightOpen),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.cardHi,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            nextText,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppTheme.text,
                              fontSize: 18,
                            ),
                          ),
                        ),
                      ),
                      if (_weightOpen) ...[
                        const SizedBox(height: 10),
                        // 键盘直输入口 + 单位切换（2026-10-17）：休息中调重量
                        // 也能一键 kg↔lb，与训练面板大数字旁同款入口
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () {
                                  HapticFeedback.selectionClick();
                                  showWeightInputSheet(context, s);
                                },
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size.fromHeight(48),
                                ),
                                child: Text(
                                  tx('直接输入重量', en: 'Enter Weight'),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Tooltip(
                              message: tx(
                                  '点按切换重量单位（kg/lb），历史数据同步换算显示',
                                  en: 'Tap to switch weight unit (kg/lb); history converts too'),
                              child: OutlinedButton(
                                onPressed: () {
                                  toggleWeightUnit(context, s);
                                  setState(() {});
                                },
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(64, 48),
                                  padding: EdgeInsets.zero,
                                ),
                                child: Text(
                                  unitLabel(),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            for (final step in _steps)
                              WeightStepButton(
                                delta: step,
                                // lb 模式先 snap 0.5lb 网格再加步长（防漂移）
                                onTap: () => s.setWeightDraft(
                                    nudgedKg(s.weightDraft, step)),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            for (final step in _steps)
                              WeightStepButton(
                                delta: -step,
                                onTap: () => s.setWeightDraft(
                                    nudgedKg(s.weightDraft, -step)),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        TextButton(
                          onPressed: () => s.toggleBodyweightDraft(),
                          child: Text(
                            s.weightDraft == 0
                                ? tx('当前：自重', en: 'Current: bodyweight')
                                : (s.weightDraft < 0
                                      ? tx('当前：${fmtLoadU(s.weightDraft)}（点切自重）',
                                          en: 'Current: ${fmtLoadU(s.weightDraft)} (tap for bodyweight)')
                                      : tx('改为自重', en: 'Switch to bodyweight')),
                            style: const TextStyle(
                              color: AppTheme.textDim,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  decoration: const BoxDecoration(
                    color: AppTheme.card,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 组间/练满都常显：休息中觉得状态好就回刚完成的动作再来一组
                      if (s.extraSetExerciseName != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: OutlinedButton(
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                s.startExtraSet();
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppTheme.primary,
                              ),
                              // 大字体缩放下长标签放不下：整行（图标+文字）
                              // 等比缩小而不是折行裁切。
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.replay,
                                      size: 18,
                                      color: AppTheme.primary,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      tx(
                                          '再来一组 · ${exname(s.extraSetExerciseName ?? '')}（继承上次重量）',
                                          en: 'One More Set · ${exname(s.extraSetExerciseName ?? '')} (last weight)'),
                                      maxLines: 1,
                                      softWrap: false,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      Row(
                        children: [
                          // 精确闹钟由控制器 onRestAlarmChanged 回调随
                          // restEndAt 统一重排；训练卡由控制器心跳驱动
                          _RestActionBtn(
                            label: tx('-30 秒', en: '-30s'),
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              s.extendRest(-30);
                            },
                          ),
                          const SizedBox(width: 8),
                          _RestActionBtn(
                            label: tx('+30 秒', en: '+30s'),
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              s.extendRest(30);
                            },
                          ),
                          const SizedBox(width: 8),
                          _RestActionBtn(
                            label: s.isRestPaused
                                ? tx('继续', en: 'Resume')
                                : tx('暂停', en: 'Pause'),
                            foreground: s.isRestPaused
                                ? AppTheme.primary
                                : AppTheme.text,
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              s.isRestPaused ? s.resumeRest() : s.pauseRest();
                            },
                          ),
                          const SizedBox(width: 8),
                          _RestActionBtn(
                            label: tx('撤销', en: 'Undo'),
                            foreground: AppTheme.textDim,
                            weight: FontWeight.w600,
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              s.undoLastSet();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      BigButton(
                        label: tx('跳过休息，直接开练', en: 'Skip Rest, Start Lifting'),
                        height: 80,
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          c.notify.cancelRest();
                          s.skipRest();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      }
    );
  }

  bool _isWide(BuildContext context) =>
      MediaQuery.of(context).size.width >= 840;
}

/// 休息页底部操作小按钮（±30 秒 / 暂停 / 撤销）。
/// 四个按钮平分一排，宽度只有约屏宽 1/4：大字体缩放下
/// 「-30 秒」这类标签放不下会折行——文字永不换行，
/// 放不下整体等比缩小（与倒计时数字同一策略）。
class _RestActionBtn extends StatelessWidget {
  const _RestActionBtn({
    required this.label,
    required this.onPressed,
    this.foreground,
    this.weight = FontWeight.w700,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color? foreground;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: SizedBox(
        height: 64,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            backgroundColor: AppTheme.cardHi,
            side: BorderSide.none,
            foregroundColor: foreground,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontSize: 16, fontWeight: weight),
            ),
          ),
        ),
      ),
    );
  }
}

/// 心率自适应休息建议（P2-F）：心率数据参与决策，而不只是显示。
/// - 只在「已连接且有心率读数」时出现，未连接时零占位，现有休息流程不变；
/// - 判定交给纯函数 [restAdvice]（阈值见 rest_rules.dart）；读数走
///   [HeartRateService.freshBpm]——超过 10 秒的旧读数不作为建议依据；
/// - 偏高 → 「心率仍高，建议多休 30 秒」+ 手动 +30 秒；
///   已恢复 → 「心率已恢复，可提前 30 秒开练」+ 手动 -30 秒；
/// - 两条建议都只是提醒：用户点按钮才改休息时间，绝不自动加时、绝不弹窗；
/// - [compact] = 矮屏（横屏手机）模式：收 margin/字号/按钮高度，
///   保证建议行在 showBrief<480 的冻结布局里也不挤占倒计时与操作区。
class _HrRestAdvice extends StatelessWidget {
  const _HrRestAdvice({this.compact = false});

  final bool compact;

  /// 刚完成那组的余力：休息开始时 extraSetExerciseName 指向刚完成的动作
  /// （与「再来一组」/破纪录横幅同一数据源），练满推进后也能拿到；否则
  /// 回落当前动作最后一组。没有记录时用 2（计划常见默认值）。
  int _rirOf(SessionController s) {
    final name = s.extraSetExerciseName;
    if (name != null) {
      for (final e in s.exercises) {
        if (e.name == name) {
          final sets = s.setsByEx[e.id] ?? const <SetEntry>[];
          if (sets.isNotEmpty) return sets.last.rir;
        }
      }
    }
    final sets = s.currentSets;
    return sets.isEmpty ? 2 : sets.last.rir;
  }

  @override
  Widget build(BuildContext context) {
    final c = app(context);
    final s = c.session;
    final hr = c.hr;
    return ListenableBuilder(
      listenable: Listenable.merge([hr, s.restRemainingMs]),
      builder: (context, _) {
        if (!s.hasActive ||
            s.phase != WorkoutPhase.resting ||
            hr.link != HrLink.connected) {
          return const SizedBox.shrink();
        }
        // 新鲜度：超过约 10 秒的旧读数不作为建议依据（设备可能已断流）
        final bpm = hr.freshBpm;
        if (bpm == null) return const SizedBox.shrink();
        final advice = restAdvice(
          bpm,
          c.settings.hrRest,
          s.restRemainingMs.value ~/ 1000,
          _rirOf(s),
        );
        if (advice.action == RestAdviceAction.ok) {
          return const SizedBox.shrink();
        }
        final extend = advice.action == RestAdviceAction.extend;
        final accent = extend ? AppTheme.warn : AppTheme.primary;
        final delta = extend ? 30 : -30;
        return Container(
          key: const Key('restHrAdvice'),
          margin: EdgeInsets.only(top: compact ? 4 : 8),
          padding: EdgeInsets.fromLTRB(compact ? 10 : 12, compact ? 2 : 4,
              compact ? 4 : 6, compact ? 2 : 4),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.favorite, size: compact ? 12 : 15, color: accent),
              SizedBox(width: compact ? 4 : 6),
              Flexible(
                child: Text(
                  advice.reason,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: accent, fontSize: compact ? 11.5 : 12.5),
                ),
              ),
              SizedBox(width: compact ? 2 : 4),
              TextButton(
                key: Key(extend
                    ? 'restHrAdviceExtend'
                    : 'restHrAdviceShorten'),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  s.extendRest(delta);
                },
                style: TextButton.styleFrom(
                  foregroundColor: accent,
                  minimumSize:
                      Size(compact ? 44 : 52, compact ? 28 : 36),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  extend ? tx('+30 秒', en: '+30s') : tx('-30 秒', en: '-30s'),
                  style: TextStyle(
                      fontSize: compact ? 12 : 13,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 休息页渐进主动提醒（2026-09-26 Arono）：刚完成的组若破纪录 → 🏆 横幅；
/// 当前动作停在同一重量过久（≥3 次或 ≥2 次跨约两周）→ 📈 平台期横幅。
/// 只在休息等待页渲染、永不弹窗；无提醒时完全隐形。
class _ProgressNudges extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = app(context);
    final s = c.session;
    if (!s.hasActive) return const SizedBox.shrink();
    // 定位"刚完成的动作"：练满推进时 currentEx 已切到下一动作，
    // extraSetExerciseName 在每次进休息前都指向刚完成的动作（与
    // 「再来一组」同一数据源）——收动作的最后一组也能看到提醒。
    final name = s.extraSetExerciseName ?? s.currentEx?.name;
    if (name == null) return const SizedBox.shrink();
    SessionExercise? ex;
    for (final e in s.exercises) {
      if (e.name == name) {
        ex = e;
        break;
      }
    }
    if (ex == null) return const SizedBox.shrink();
    final sets = s.setsByEx[ex.id] ?? const <SetEntry>[];
    if (sets.isEmpty) return const SizedBox.shrink();
    final last = sets.last;
    // 只对正式组提醒（热身组破纪录不算数，与 PR 判定同口径）
    if (last.kind != SetKind.working) return const SizedBox.shrink();

    final banners = <Widget>[];
    // ① 破纪录：刚完成的组重量超过此前历史最佳（isPrWeight 同口径；
    // 空历史不算 PR——新动作第一组不弹"此前最佳 0kg"）
    final history = s.historyBefore[ex.name] ?? const <SetEntry>[];
    if (history.isNotEmpty) {
      final priorBest =
          history.fold(0.0, (m, e) => e.weightKg > m ? e.weightKg : m);
      if (last.weightKg > priorBest + 0.01) {
        banners.add(_nudge(
          context,
          icon: Icons.emoji_events_outlined,
          color: AppTheme.warn,
          text: tx(
              '新纪录！${fmtWt(last.weightKg)} × ${last.reps}（此前最佳 ${fmtWt(priorBest)}）',
              en: 'New PR! ${fmtWt(last.weightKg)} × ${last.reps} (previous best ${fmtWt(priorBest)})'),
        ));
      }
    }
    // ② 平台期：同重量停留过久 → 有原因的下一步（P1-C 停滞协议）。
    // 减载周/停练回归不叠加（处方是恢复，不催加重也不催再减）。
    final info = (s.inDeloadWeek || s.inLayoff) ? null : s.plateauFor(ex.name);
    if (info != null && (info.weightKg - last.weightKg).abs() <= 0.01) {
      final rule = ex.rule;
      final protocol = plateauProtocolOf(
        info,
        rule: rule,
        logging: ex.logging,
        loadType: ex.loadType,
      );
      if (protocol.action == 'reduce') {
        banners.add(_nudge(
          context,
          icon: Icons.trending_down,
          color: AppTheme.warn,
          text: protocol.reason,
        ));
      } else if (protocol.action == 'add') {
        banners.add(_nudge(
          context,
          icon: Icons.trending_up,
          color: AppTheme.primary,
          text: protocol.reason,
        ));
      } else {
        banners.add(_nudge(
          context,
          icon: Icons.trending_up,
          color: AppTheme.primary,
          text: tx(
              '已连续 ${info.sessions} 次·${info.days} 天 ${fmtWt(info.weightKg)}——次数冲到 ${rule.repsMax} 就 +${fmtWt(rule.incrementKg)}',
              en: '${fmtWt(info.weightKg)} for ${info.sessions} sessions · ${info.days} days — reach ${rule.repsMax} reps, then +${fmtWt(rule.incrementKg)}'),
        ));
      }
    }
    // ③ 自重变式阶梯（P2-E）：练满计划组、全部达标、末组余力达标且次数
    // 顶到 reps_max 才提示；减载周/停练回归的处方是「回到原档」，
    // 不在此叠加升级建议（与平台期提醒同一 guard）。
    if (!s.inDeloadWeek && !s.inLayoff) {
      final nextVariation = bodyweightVariationSuggestion(
        exerciseName: ex.name,
        exerciseKey: ex.exerciseKey,
        rule: ex.rule,
        loadType: ex.loadType,
        logging: ex.logging,
        workingSets: sets,
        plannedSets: plannedSetsOf(ex),
      );
      if (nextVariation != null) {
        banners.add(_nudge(
          context,
          icon: Icons.stairs_outlined,
          color: AppTheme.accent,
          text: tx(
              '次数到顶，试试${exname(nextVariation)}——同一动作的下一档，不改你的计划',
              en: 'Reps topped out — try ${exname(nextVariation)}, the next step in this progression. Your plan stays the same'),
        ));
      }
    }
    if (banners.isEmpty) return const SizedBox.shrink();
    return Column(children: banners);
  }

  Widget _nudge(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String text,
  }) =>
      Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 12.5),
              ),
            ),
          ],
        ),
      );
}

/// 休息页轻量战报（调研条目 9）：默认收起的一行入口，点开展开 3 行小结
/// （已完成组数 / 本日容量 / 已练时长）。放在休息等待页而非计时主界面，
/// 默认不占屏——不碰"交互三要素以外信息一律收起"的红线。
class _RestBrief extends StatefulWidget {
  @override
  State<_RestBrief> createState() => _RestBriefState();
}

class _RestBriefState extends State<_RestBrief> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = app(context);
    final s = c.session;
    final sess = s.session;
    if (!s.hasActive || sess == null) return const SizedBox.shrink();
    final stats = sessionStatsFrom(
      s.setsByEx,
      s.exercises,
      // 自重动作按 系数×体重 折算进容量（点名条目二）
      bodyWeightKg: c.settings.bodyWeightKg,
    );
    final minutes =
        ((DateTime.now().millisecondsSinceEpoch - sess.startedAt) / 60000)
            .floor();
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _open = !_open);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.cardHi,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.assessment_outlined,
                    size: 16, color: AppTheme.textDim),
                const SizedBox(width: 6),
                Text(
                  tx('本次战报 · ${stats.workingSets} 组',
                      en: stats.workingSets == 1
                          ? 'Session Report · 1 set'
                          : 'Session Report · ${stats.workingSets} sets'),
                  style: const TextStyle(
                      color: AppTheme.textDim, fontSize: 13),
                ),
                Icon(
                  _open
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 18,
                  color: AppTheme.textDim,
                ),
              ],
            ),
            if (_open) ...[
              const SizedBox(height: 6),
              Text(
                tx(
                  '已完成 ${stats.workingSets} 个正式组${stats.totalSets > stats.workingSets ? '（含热身 ${stats.totalSets - stats.workingSets} 组）' : ''} · ${stats.exercises.length}/${s.exercises.length} 个动作',
                  en: '${stats.workingSets} working sets done${stats.totalSets > stats.workingSets ? ' (incl. ${stats.totalSets - stats.workingSets} warm-up)' : ''} · ${stats.exercises.length}/${s.exercises.length} exercises',
                ),
                style: const TextStyle(color: AppTheme.text, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              Text(
                tx('本日容量 ${fmtVolume(stats.volume)} · 已练 $minutes 分钟',
                    en: 'Today\'s volume ${fmtVolume(stats.volume)} · $minutes min trained'),
                style: const TextStyle(color: AppTheme.text, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ================= 结束 + 总结 =================

/// 一次训练的总结数据（页面流的总结页数据源）。
class TrainingSummary {
  const TrainingSummary({
    required this.stats,
    required this.verdicts,
    required this.title,
    required this.prNames,
    required this.durationMin,
    required this.activeMin,
    required this.restMin,
  });

  final SessionStats stats;
  final List<String> verdicts;
  final String title;
  final List<String> prNames;
  final int durationMin;
  final int activeMin;
  final int restMin;
}

class _SummaryPage extends StatelessWidget {
  const _SummaryPage({
    required this.s,
    required this.stats,
    required this.verdicts,
    required this.title,
    required this.prNames,
    required this.durationMin,
    required this.activeMin,
    required this.restMin,
  });

  final SessionController s;
  final SessionStats stats;
  final List<String> verdicts;
  final String title;
  final List<String> prNames;
  final int durationMin;
  final int activeMin;
  final int restMin;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        // 收工按钮钉底常驻（拇指可达红线；2026-10-08 v12「本次组数」卡片
        // 加高后，滚动内容末尾的按钮在 360×800 会被顶出屏）。内容区仍为
        // 非惰性 SingleChildScrollView，一页半以内全量构建。
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 24),
                    Text(
                      tx('训练完成 💪', en: 'Workout Complete 💪'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 32, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      dname(title),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppTheme.textDim, fontSize: 16),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        _statCell(
                            tx('总容量', en: 'Total Volume'), fmtVolume(stats.volume)),
                        _statCell(tx('正式组', en: 'Working Sets'),
                            '${stats.workingSets}'),
                        _statCell(tx('动作数', en: 'Exercises'),
                            '${stats.exercises.length}'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      durationMin > 0
                          ? (activeMin > 0 || restMin > 0
                                ? tx('总时长 $durationMin 分钟 · 训练 $activeMin 分 · 休息 $restMin 分',
                                    en: 'Total $durationMin min · Active $activeMin min · Rest $restMin min')
                                : tx('训练时长 $durationMin 分钟',
                                    en: 'Duration $durationMin min'))
                          : tx('训练完成', en: 'Workout complete'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppTheme.textDim),
                    ),
                    const SizedBox(height: 24),
                    // 主观自评（wger 的 impression 三档）：总结页点选即存、可改选；
                    // 不弹窗不打断——出现在训练结束之后，收工前顺手一击。
                    _ImpressionSelector(s: s),
                    const SizedBox(height: 16),
                    if (prNames.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppTheme.warn.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          tx('🏆 PR 突破：${prNames.map(exname).join('、')}',
                              en: '🏆 New PR: ${prNames.map(exname).join(', ')}'),
                          style: const TextStyle(
                            color: AppTheme.warn,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    // 本次组数（v12 加练标注，2026-10-08）：逐动作一行，加练组
                    // 单列出来——「计划目标 3 组」下挂 4 行不再没有解释。数据源
                    // 是控制器内存（finish 不清 exercises/setsByEx），收工前
                    // 加练组确认在。
                    SectionCard(
                      title: tx('本次组数', en: 'Sets This Session'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final ex in s.exercises)
                            if ((s.setsByEx[ex.id] ?? const <SetEntry>[])
                                .isNotEmpty) ...[
                              _sessionSetsRow(ex),
                              ..._bwExtraHint(ex),
                            ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 心率曲线（2026-10-17）：会话期间连过心率设备才有
                    // 采样，没数据整卡不出现；配置了 AI 时附「AI 解析心率」。
                    if (s.session?.id != null)
                      HrSessionCard(
                        samplesFuture:
                            app(context).db.hrSamplesOfSession(s.session!.id!),
                      ),
                    const SizedBox(height: 16),
                    SectionCard(
                      title: tx('渐进建议（下次训练）', en: 'Progression (Next Workout)'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final v in verdicts)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                '· $v',
                                style: const TextStyle(fontSize: 15),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: BigButton(
                label: tx('收工', en: 'Finish'),
                height: 72,
                onPressed: () =>
                    Navigator.of(context).popUntil((r) => r.isFirst),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCell(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          // 360dp 屏每格仅约 104 逻辑像素，"9999kg" 在字体缩放或小屏下
          // 放不下：FittedBox 等比缩字，避免溢出/与邻格重叠。
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: AppTheme.bigNum(30, color: AppTheme.primary),
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: AppTheme.textDim)),
        ],
      ),
    );
  }

  /// 『本次组数』逐动作一行：「动作名 · N 组（含加练 X 组）」。
  Widget _sessionSetsRow(SessionExercise ex) {
    final sets = s.setsByEx[ex.id] ?? const <SetEntry>[];
    final extra = sets.where((x) => x.isExtra).length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        tx(
          '${exname(ex.name)} · ${sets.length} 组'
          '${extra > 0 ? '（含加练 $extra 组）' : ''}',
          en: '${exname(ex.name)} · ${sets.length} set(s)'
              '${extra > 0 ? ' (incl. $extra extra set(s))' : ''}',
        ),
        style: const TextStyle(fontSize: 15),
      ),
    );
  }

  /// 自重动作「次数到顶 → 下次加练一组 / 试试下一档变式」提示（v14 / P2-E）：
  /// 计划正式组记满后用本场表现回放链状态，触顶才给建议——只做展示层口径，
  /// 不改计划本身（改组数/换动作走计划编辑）。
  /// 减载周/停练回归的处方是「回到原档」，不叠加升级建议（与休息页同一 guard）。
  List<Widget> _bwExtraHint(SessionExercise ex) {
    if (s.inDeloadWeek || s.inLayoff) return const [];
    final today = (s.setsByEx[ex.id] ?? const <SetEntry>[])
        .where((x) => x.kind == SetKind.working)
        .toList();
    final planned = plannedSetsOf(ex);
    // 与休息页变式建议同一道闸（P2-E 复核）：练满计划组 + 全部达标 +
    // 末组余力达标 + 次数轴触顶，任一条不满足都不给升级建议。
    final ready = bodyweightProgressionReady(
      exerciseName: ex.name,
      exerciseKey: ex.exerciseKey,
      rule: ex.rule,
      loadType: ex.loadType,
      logging: ex.logging,
      workingSets: today,
      plannedSets: planned,
    );
    if (!ready) return const [];
    final extra = bodyweightExtraSetTarget(
      state: chainStateFromHistory(today, ex.rule),
      rule: ex.rule,
      loadType: LoadMode.bodyweight,
      plannedSets: planned,
    );
    if (extra == null) return const [];
    // 变式阶梯（P2-E）：同一动作的下一档，纯建议、不自动换。
    final nextVariation = nextBodyweightVariation(
      ex.name,
      exerciseKey: ex.exerciseKey,
    );
    return [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(
          tx('次数到顶，下次建议加练一组（$extra 组）',
              en: 'Reps topped out — add an extra set next time ($extra sets)'),
          style: const TextStyle(color: AppTheme.primary, fontSize: 12.5),
        ),
      ),
      if (nextVariation != null)
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            tx('也可以试试${exname(nextVariation)}：同一动作的下一档（不改计划）',
                en: 'Or try ${exname(nextVariation)} — the next step up (your plan stays the same)'),
            style: const TextStyle(color: AppTheme.accent, fontSize: 12.5),
          ),
        ),
    ];
  }
}

/// 总结页三档自评（wger impression：差/一般/好）。
/// 本地持选态 + 落库；未选不强迫（收工跳过 = null 未评）。
class _ImpressionSelector extends StatefulWidget {
  const _ImpressionSelector({required this.s});

  final SessionController s;

  @override
  State<_ImpressionSelector> createState() => _ImpressionSelectorState();
}

class _ImpressionSelectorState extends State<_ImpressionSelector> {
  int? _sel;

  @override
  void initState() {
    super.initState();
    _sel = widget.s.session?.impression;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tx('这次练得怎么样？', en: 'How did it feel?'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, color: AppTheme.textDim),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final (v, label, icon) in [
              (1, tx('差', en: 'Rough'), Icons.sentiment_dissatisfied),
              (2, tx('一般', en: 'Okay'), Icons.sentiment_neutral),
              (3, tx('好', en: 'Great'), Icons.sentiment_satisfied_alt),
            ])
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(left: v == 1 ? 0 : 6),
                  child: ChoiceChip(
                    key: Key('impression_$v'),
                    avatar: Icon(icon,
                        size: 18,
                        color: _sel == v
                            ? const Color(0xFF06220F)
                            : AppTheme.textDim),
                    label: Text(label),
                    selected: _sel == v,
                    onSelected: (_) {
                      HapticFeedback.selectionClick();
                      setState(() => _sel = v);
                      widget.s.setImpression(v);
                    },
                    selectedColor: AppTheme.primary,
                    backgroundColor: AppTheme.cardHi,
                    side: BorderSide.none,
                    labelStyle: TextStyle(
                      color: _sel == v
                          ? const Color(0xFF06220F)
                          : AppTheme.text,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 杠铃片速配（2026-09-26 Arono）：杠铃动作下改重量时，在重量数字下方
/// 短暂显示每边挂片组合，约 4 秒自动收起。低调不弹窗：字号小、暗色、
/// 不挡任何操作；非杠铃动作整块不渲染。
class _PlateHintStrip extends StatefulWidget {
  const _PlateHintStrip(
      {required this.s, required this.exName, required this.gear});

  final SessionController s;

  /// 当前动作名：杆重口径与起始页热身同源（warmupBarKgFor，EZ 杠 10kg/25lb）。
  final String exName;

  /// 当前动作的细分器械（动作库词表外为空 → 不显示）。
  final String gear;

  @override
  State<_PlateHintStrip> createState() => _PlateHintStripState();
}

class _PlateHintStripState extends State<_PlateHintStrip> {
  Timer? _hideTimer;
  bool _visible = false;
  String _text = '';

  /// 上次见到的重量草稿：s 是同一个控制器对象，old.s.weightDraft 与
  /// widget.s.weightDraft 读到的都是当前值（永远相等），判变化只能自己记。
  double? _lastDraft;

  @override
  void initState() {
    super.initState();
    _lastDraft = widget.s.weightDraft;
  }

  @override
  void didUpdateWidget(_PlateHintStrip old) {
    super.didUpdateWidget(old);
    // 只在重量变化时闪现；切动作但重量没动不闪（换动作的推荐值变化除外，
    // 那也是一次"该挂几片"的有效提示）
    final draft = widget.s.weightDraft;
    if (draft != _lastDraft) _flash();
    _lastDraft = draft;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _flash() {
    _hideTimer?.cancel();
    final w = widget.s.weightDraft;
    if (widget.gear != '杠铃' || w <= 0) {
      _collapse();
      return;
    }
    // 杆重口径与起始页热身同源（2026-10-18）：EZ 杠 10kg/25lb，
    // 其余标准奥杆 20kg/45lb；warmupBarKgFor 返回 null = 标准奥杆。
    final useLb = WeightUnits.isLb;
    final ezBarKg = warmupBarKgFor(widget.exName, useLb: useLb);
    final barKg = ezBarKg ?? kStandardBarKg;
    // lb 模式在 lb 空间配片（美制片组），显示值先 snap 0.5lb 网格；
    // 标准奥杆取 45lb 整数，不走 20kg 换算（避免 44lb 漂移）。
    final barLb = ezBarKg != null ? lbSnap(kgToLb(ezBarKg)) : kLbBar;
    final b = useLb
        ? platesForLoad(lbSnap(kgToLb(w)),
            barKg: barLb, inventory: kLbPlateSizes)
        : platesForLoad(w, barKg: barKg);
    final String t;
    if (b.perSide.isEmpty) {
      final barTxt = useLb ? '${_fmtPlate(barLb)}lb' : '${_fmtPlate(barKg)}kg';
      t = tx('空杆 $barTxt，不用挂片', en: 'Empty $barTxt bar, no plates needed');
    } else if (b.exact) {
      t = tx('每边 ${b.perSide.map(_fmtPlate).join(' + ')}',
          en: 'Per side: ${b.perSide.map(_fmtPlate).join(' + ')}');
    } else {
      t = tx('配不平：每边还差 ${_fmtPlate(b.leftoverPerSide)}${unitLabel()}',
          en: "Can't match exactly: ${_fmtPlate(b.leftoverPerSide)}${unitLabel()} short per side");
    }
    setState(() {
      _visible = true;
      _text = t;
    });
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) _collapse();
    });
  }

  void _collapse() {
    if (!mounted) return;
    setState(() => _visible = false);
  }

  static String _fmtPlate(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    if (widget.gear != '杠铃') return const SizedBox.shrink();
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: _visible ? 1 : 0,
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            _text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
          ),
        ),
      ),
    );
  }
}
