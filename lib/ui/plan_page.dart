import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app.dart';
import '../engine/engine.dart';
import '../l10n/lang.dart';
import '../l10n/names.dart';
import '../presets/baoji_plan.dart';
import '../presets/exercise_library.dart';
import '../services/ai_service.dart';
import '../services/plan_actions.dart';
import '../services/plan_repository.dart';
import 'exercise_library_page.dart';
import 'plan_editor_page.dart';
import 'plan_preview_sheet.dart';
import 'schedule_views.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'workout_page.dart';

/// 计划页：多计划管理（查看/切换/重命名/复制/删除）+ 周视图 + AI 导入。
/// 点击某个训练日进入编辑器，可人工调整动作与组数次数。
class PlanPage extends StatefulWidget {
  const PlanPage({super.key});

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  bool _loading = true;
  List<Plan> _plans = [];
  Plan? _view; // 正在查看的计划（可为未启用计划）

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh({Plan? view}) async {
    final c = app(context);
    await c.planRepo.reload(includeAll: true);
    _plans = c.planRepo.allPlansCache;
    _view = view ??
        (_view == null
            ? c.planRepo.activePlan
            : _plans.where((p) => p.id == _view!.id).firstOrNull ??
                c.planRepo.activePlan);

    if (!mounted) return;
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_plans.isEmpty) {
      return _emptyState();
    }
    final active = app(context).planRepo.activePlan;
    final viewingActive = _view?.id == active?.id;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          children: [
            // 计划切换器
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => _showPlanSwitcher(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          tx('${dname(_view?.name ?? '无计划')}'
                              '（${viewingActive ? '使用中' : '未启用'}）',
                              en: '${dname(_view?.name ?? 'No plan')}'
                                  ' (${viewingActive ? 'Active' : 'Inactive'})'),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.expand_more,
                        size: 20,
                        color: AppTheme.textDim,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 回收站入口：删除的计划快照保留 7 天，可恢复（2026-09-26）
            IconButton(
              tooltip: tx('最近删除', en: 'Recently deleted'),
              onPressed: _openTrash,
              icon: const Icon(
                Icons.restore_from_trash_outlined,
                size: 20,
                color: AppTheme.textDim,
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'activate') {
                  _activateViewed();
                } else if (v == 'rename') {
                  _renamePlan();
                } else if (v == 'duplicate') {
                  _duplicatePlan();
                } else if (v == 'delete') {
                  _deletePlan();
                }
              },
              itemBuilder: (_) => [
                if (!viewingActive)
                  PopupMenuItem(
                    value: 'activate',
                    child: Row(
                      children: [
                        const Icon(Icons.play_circle_outline, size: 18),
                        const SizedBox(width: 8),
                        Text(tx('设为使用中', en: 'Set as active')),
                      ],
                    ),
                  ),
                PopupMenuItem(
                  value: 'rename',
                  child: Row(
                    children: [
                      const Icon(Icons.edit_outlined, size: 18),
                      const SizedBox(width: 8),
                      Text(tx('重命名', en: 'Rename')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'duplicate',
                  child: Row(
                    children: [
                      const Icon(Icons.copy_all_outlined, size: 18),
                      const SizedBox(width: 8),
                      Text(tx('复制一份', en: 'Duplicate')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      const Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: AppTheme.danger,
                      ),
                      const SizedBox(width: 8),
                      Text(tx('删除计划', en: 'Delete plan'),
                          style: const TextStyle(color: AppTheme.danger)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        Text(
          _sourceLabel(_view?.source),
          style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
        ),
        if (!viewingActive) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.warn.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              tx('此计划未启用：编辑不会影响今天的训练，设为使用中后才生效。',
                  en: "This plan is inactive: edits won't affect today's workout until it is set active."),
              style: const TextStyle(color: AppTheme.warn, fontSize: 13),
            ),
          ),
        ],
        const SizedBox(height: 8),
        // 排程模式 + 模板日编辑（日期化的排程视图见下方 ScheduleViews）
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _showPatternSheet,
                icon: const Icon(Icons.event_repeat, size: 18),
                label: Text(
                  _view?.isCycle == true
                      ? tx('循环：练${_view!.cycleTrain}休${_view!.cycleRest}',
                          en:
                              'Cycle: ${_view!.cycleTrain} on / ${_view!.cycleRest} off')
                      : tx('按星期排程', en: 'Weekly schedule'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _showTemplateDaysSheet,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(tx('编辑模板日', en: 'Edit template days'),
                    overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // 日期化排程：3日/周/月视图 + 拖拉改期（手动改动写覆盖行）
        if (_view != null)
          ScheduleViews(
            plan: _view!,
            onChanged: _onScheduleChanged,
          ),
        const SizedBox(height: 8),
        // 添加计划三入口：模板（推荐）/ AI / 空白
        FilledButton.tonalIcon(
          onPressed: () => _showTemplatePicker(),
          icon: const Icon(Icons.library_books, size: 18),
          label: Text(tx('从模板添加计划',
              en: 'Add from template')),
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.cardHi,
            foregroundColor: AppTheme.text,
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _showAiImport(),
                icon: const Icon(Icons.auto_awesome,
                    size: 16, color: AppTheme.violetSoft), // 紫=AI（全 App 统一）
                label: Text(tx('AI 拆解导入', en: 'AI import')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _createBlankPlan(),
                icon: const Icon(Icons.add, size: 18),
                label: Text(tx('新建空白', en: 'New blank')),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ExerciseLibraryPage()),
            ),
            icon: const Icon(Icons.fitness_center, size: 16),
            label: Text(tx('浏览动作库（肌群 · 居家/健身房）',
                en: 'Browse exercise library (muscle · home/gym)')),
          ),
        ),
      ],
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            tx('还没有计划', en: 'No plans yet'),
            style: const TextStyle(fontSize: 18, color: AppTheme.textDim),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final container = app(context);
              await container.planRepo.installBaojiPlan();
              await syncActivePlanToLark(container);
              if (mounted) {
                messenger.showSnackBar(
                  SnackBar(
                    content:
                        Text(tx('薄肌计划已安装', en: 'Baoji Plan installed')),
                    backgroundColor: AppTheme.cardHi,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
                await _refresh();
              }
            },
            child: Text(tx('一键安装薄肌计划', en: 'Install Baoji Plan')),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _showTemplatePicker(),
            child: Text(tx('从模板添加计划', en: 'Add plan from template')),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _showAiImport(),
            child: Text(tx('粘贴文本 · AI 拆解', en: 'Paste text · AI parse')),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _createBlankPlan(),
            child: Text(tx('新建空白计划', en: 'New blank plan')),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => _openTrash(),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(tx('从回收站恢复已删计划', en: 'Restore deleted plan from trash')),
          ),
        ],
      ),
    );
  }

  String _sourceLabel(String? source) {
    switch (source) {
      case 'preset':
        return tx('内置计划 · 点任意训练日可人工调整',
            en: 'Built-in plan · Tap any training day to adjust manually');
      case 'ai':
        return tx('AI 拆解计划 · 建议逐日校对后使用',
            en: 'AI-parsed plan · Review each day before use');
      case 'copy':
        return tx('复制计划', en: 'Copied plan');
      default:
        return tx('自定义计划', en: 'Custom plan');
    }
  }

  // ================= 排程模式与模板日 =================

  /// 排程视图改动后：刷新缓存并重同步飞书日历。
  Future<void> _onScheduleChanged() async {
    final container = app(context);
    await _refresh();
    await syncActivePlanToLark(container);
  }

  /// 切换排程模式：按星期（固定周几）/ 循环（练 N 休 M，如"隔两天休息一天"）。
  /// 手动改期过的覆盖行保留，不受模式切换影响。
  Future<void> _showPatternSheet() async {
    final plan = _view;
    if (plan == null || plan.id == null) return;
    final trainableN = await app(context).planRepo.trainableDayCount(plan.id!);
    if (!mounted) return;
    bool cycle = plan.isCycle;
    int train = plan.cycleTrain > 0 ? plan.cycleTrain : 2;
    int rest = plan.cycleRest > 0 ? plan.cycleRest : 1;
    DateTime start = plan.patternStart.isNotEmpty
        ? parseDate(plan.patternStart)
        : DateTime.now();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tx('排程方式', en: 'Schedule mode'),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                  tx('改的是"没有手动调整过的日子"怎么排；已手动改期的日子保持不变。',
                      en: 'Changes how days without manual edits are scheduled; manually moved days stay unchanged.'),
                  style: const TextStyle(
                      color: AppTheme.textDim, fontSize: 12)),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                      value: false,
                      label: Text(tx('按星期', en: 'By weekday'))),
                  ButtonSegment(
                      value: true, label: Text(tx('循环练休', en: 'Cycle'))),
                ],
                selected: {cycle},
                onSelectionChanged: (s) => setSheet(() => cycle = s.first),
                showSelectedIcon: false,
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.resolveWith((st) =>
                      st.contains(WidgetState.selected)
                          ? AppTheme.primary
                          : AppTheme.cardHi),
                  foregroundColor: WidgetStateProperty.resolveWith((st) =>
                      st.contains(WidgetState.selected)
                          ? const Color(0xFF06220F)
                          : AppTheme.textDim),
                  side: const WidgetStatePropertyAll(
                      BorderSide(color: Colors.transparent)),
                ),
              ),
              const SizedBox(height: 14),
              if (cycle) ...[
                _numStepper(tx('连练天数', en: 'Training days'), train, 1, 7,
                    setSheet, (v) => train = v),
                _numStepper(tx('休息天数', en: 'Rest days'), rest, 1, 7,
                    setSheet, (v) => rest = v),
                Text(
                    tx('循环示例：练 $train 休 $rest —— 从起始日开始每 ${train + rest} 天一轮。',
                        en: 'Cycle example: $train on / $rest off — one round every ${train + rest} days from the start date.'),
                    style: const TextStyle(
                        color: AppTheme.textDim, fontSize: 12)),
                if (trainableN > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      tx(
                        '计划的 $trainableN 个训练日将依次轮转：每练 $train 天休 $rest，'
                        '约 ${(trainableN / train).ceil()} 个训练窗口转完一圈，接着从头再来'
                        '（连练数不必等于训练日数）。',
                        en: "The plan's $trainableN training days rotate in turn: "
                            "$train on / $rest off, about ${(trainableN / train).ceil()} "
                            "training windows per full round, then it starts over "
                            "(consecutive days need not equal the number of training days).",
                      ),
                      style: const TextStyle(
                          color: AppTheme.textDim, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(tx('起始日  ', en: 'Start date  '),
                        style: const TextStyle(color: AppTheme.textDim)),
                    TextButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: start,
                          firstDate:
                              DateTime.now().subtract(const Duration(days: 365)),
                          lastDate:
                              DateTime.now().add(const Duration(days: 365)),
                        );
                        if (picked != null) setSheet(() => start = picked);
                      },
                      child: Text('${start.year}/${start.month}/${start.day}'),
                    ),
                  ],
                ),
              ] else
                Text(
                    tx('按星期模式：训练跟固定周几走（编辑模板日里改）。日期视图里也可以临时把某天挪走。',
                        en: 'Weekly mode: workouts follow fixed weekdays (edit under template days). You can also move a day temporarily in the date view.'),
                    style: const TextStyle(
                        color: AppTheme.textDim, fontSize: 12)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tx('保存', en: 'Save')),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await app(context).planRepo.updateSchedulePattern(
          planId: plan.id!,
          pattern: cycle ? 'cycle' : 'weekly',
          // 起始日始终存所选值：之前 patternStart 已存在时会丢弃新选的日期
          patternStart: cycle ? fmtDate(start) : plan.patternStart,
          cycleTrain: train,
          cycleRest: rest,
        );
    await _refresh();
    if (mounted) {
      toast(context,
          cycle
              ? tx('已切为循环练$train休$rest，训练日依次轮转',
                  en: 'Switched to cycle: $train on / $rest off, training days rotate in turn')
              : tx('已切为按星期排程', en: 'Switched to weekly schedule'));
    }
  }

  Widget _numStepper(String label, int value, int min, int max,
      void Function(void Function()) setSheet, ValueChanged<int> on) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          onPressed: value - 1 < min ? null : () => setSheet(() => on(value - 1)),
          icon: const Icon(Icons.remove_circle_outline),
        ),
        // FittedBox：大字号/窄屏下步进值整体缩放，数字不断行
        SizedBox(
            width: 44,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('$value',
                  maxLines: 1, textAlign: TextAlign.center),
            )),
        IconButton(
          onPressed: value + 1 > max ? null : () => setSheet(() => on(value + 1)),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }

  /// 模板日编辑：星期是"模板槽位"，具体哪天练由排程（星期/循环/手动改期）决定。
  Future<void> _showTemplateDaysSheet() async {
    final plan = _view;
    if (plan == null || plan.id == null) return;
    final c = app(context);
    final days = await c.db.planDays(plan.id!);
    final exMap = await c.db.daysExercisesMap(days.map((d) => d.id!).toList());
    // 循环模式下「周几」只是槽位排序键，展示成轮转序号「第N练」才不误导
    final rotation =
        plan.isCycle ? cycleRotationIndex(days, exMap) : const <int, int>{};
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          children: [
            Text(tx('模板日', en: 'Template days'),
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
                plan.isCycle
                    ? tx(
                        '循环模式：训练日按「第1练→第N练」的顺序依次轮转，空模板日跳过；哪天练哪个由循环排程决定。',
                        en: 'Cycle mode: training days rotate in order (Workout 1 → N), empty days are skipped; the cycle schedule decides which day trains what.')
                    : tx('这里是计划的内容骨架；具体哪天练哪个由排程决定（按星期/循环/手动拖动）。',
                        en: "This is the plan's content skeleton; which day trains what is decided by scheduling (weekly / cycle / manual drag)."),
                style: const TextStyle(
                    color: AppTheme.textDim, fontSize: 12)),
            const SizedBox(height: 8),
            for (final d in days)
              ListTile(
                leading: const Icon(Icons.fitness_center,
                    color: AppTheme.primary),
                title: Text(dname(d.title)),
                subtitle: Text(
                    plan.isCycle
                        ? (rotation.containsKey(d.id)
                            ? tx('第${rotation[d.id]}练 · ${(exMap[d.id] ?? const <PlanExercise>[]).length} 个动作',
                                en: 'Workout ${rotation[d.id]} · ${(exMap[d.id] ?? const <PlanExercise>[]).length} exercises')
                            : tx('未排内容 · 不参与轮转',
                                en: 'No exercises · not in rotation'))
                        : tx(
                            '周${'一二三四五六日'[d.weekday - 1]} · ${(exMap[d.id] ?? const <PlanExercise>[]).length} 个动作',
                            en: '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1]} · ${(exMap[d.id] ?? const <PlanExercise>[]).length} exercises'),
                    style: const TextStyle(fontSize: 12)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () async {
                  Navigator.pop(ctx);
                  if (!mounted) return;
                  final changed = await Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                        builder: (_) =>
                            PlanEditorPage(day: d, isCycle: plan.isCycle)),
                  );
                  if (changed == true && mounted) {
                    await _refresh();
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  // ================= 计划级操作 =================

  Future<void> _showPlanSwitcher() async {
    final c = app(context);
    final dayCounts = await c.db.planDayCounts();
    final exCounts = await c.db.planExerciseCounts();
    final plans = await c.db.allPlans();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          children: [
            Text(
              tx('切换计划', en: 'Switch plan'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              tx('点计划查看/编辑；「使用中」的计划决定每天的训练安排。',
                  en: "Tap a plan to view/edit; the active plan decides each day's workouts."),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
            ),
            const SizedBox(height: 8),
            for (final p in plans)
              ListTile(
                leading: p.id == c.planRepo.activePlan?.id
                    ? const Icon(Icons.check_circle, color: AppTheme.primary)
                    : const Icon(
                        Icons.radio_button_unchecked,
                        color: AppTheme.textDim,
                      ),
                title: Text(dname(p.name)),
                subtitle: Text(
                  tx('${dayCounts[p.id] ?? 0} 个训练日 · ${exCounts[p.id] ?? 0} 个动作',
                      en: '${dayCounts[p.id] ?? 0} training days · ${exCounts[p.id] ?? 0} exercises'),
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: p.id == _view?.id
                    ? Text(
                        tx('查看中', en: 'Viewing'),
                        style: const TextStyle(
                            color: AppTheme.accent, fontSize: 12),
                      )
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _view = p);
                  _refresh(view: p);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 「撤旧 + 写新」唯一入口：更换使用中计划的全部路径（切换/安装/保存）都走这里。
  /// 先记下旧使用中计划的训练日 → 执行 action（action 内须完成切换并 reload，
  /// 使 activePlan 已指向新计划）→ 撤下旧计划的日历日程 → 把新使用中计划写上日历。
  /// 撤旧/写新由 plan_actions 统一实现（与 AI 教练排计划共用，勿另写一份）。
  Future<T> _switchActivePlanAndSync<T>(
    AppContainer c,
    Future<T> Function() action,
  ) async {
    final oldId = c.planRepo.activePlan?.id;
    final oldDayIds = oldId == null
        ? <int>[]
        : (await c.db.planDays(oldId)).map((d) => d.id!).toList();
    final result = await action();
    unawaited(removePlanDayEvents(c, oldDayIds));
    await syncActivePlanToLark(c);
    return result;
  }

  Future<void> _activateViewed() async {
    final c = app(context);
    if (_view == null) return;
    final view = _view!;
    await _switchActivePlanAndSync(c, () async {
      await c.db.setActivePlan(view.id!);
      await c.planRepo.reload(includeAll: true);
    });
    if (mounted) {
      toast(context, tx('已设为使用中「${dname(view.name)}」', en: '"${dname(view.name)}" is now active'));
      await _refresh(view: view);
    }
  }

  Future<void> _renamePlan() async {
    if (_view == null) return;
    final ctrl = TextEditingController(text: _view!.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tx('重命名计划', en: 'Rename plan')),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tx('取消', en: 'Cancel'),
                style: const TextStyle(color: AppTheme.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tx('保存', en: 'Save'),
                style: const TextStyle(color: AppTheme.primary)),
          ),
        ],
      ),
    );
    if (name == null || !mounted || name.isEmpty) return;
    final c = app(context);
    await c.db.renamePlan(_view!.id!, name);
    await _refresh();
    if (mounted) toast(context, tx('已重命名', en: 'Renamed'));
  }

  Future<void> _duplicatePlan() async {
    if (_view == null) return;
    final c = app(context);
    final newId = await c.planRepo.duplicatePlan(
      _view!.id!,
      tx('${_view!.name}（副本）', en: '${_view!.name} (copy)'),
    );
    final plans = await c.db.allPlans();
    final copy = plans.where((p) => p.id == newId).firstOrNull;
    await _refresh(view: copy);
    if (mounted) {
      toast(context,
          tx('已复制为副本，可独立编辑不影响原计划',
              en: 'Duplicated as an independent copy; the original stays untouched'));
    }
  }

  Future<void> _deletePlan() async {
    if (_view == null) return;
    final planId = _view!.id!;
    final planName = _view!.name;
    final ok = await confirmDialog(
      context,
      tx('删除「${dname(planName)}」？', en: 'Delete "${dname(planName)}"?'),
      tx('计划的全部训练日和动作将移入回收站并保留 7 天，期间可恢复；历史训练记录保留。',
          en: 'All training days and exercises move to trash and are kept for 7 days (restorable); workout history is kept.'),
      okLabel: tx('删除', en: 'Delete'),
    );
    if (!ok || !mounted) return;
    final c = app(context);
    final dayIds = (await c.db.planDays(planId)).map((d) => d.id!).toList();
    await c.planRepo.deletePlanAndFixActive(planId);
    // 撤下该计划在日历上的未来日程（尽力而为）
    unawaited(removePlanDayEvents(c, dayIds));
    _view = null;
    await _refresh();
    // 删除后自动顶上的新使用中计划，把它的日程补写上日历
    if (c.planRepo.activePlan != null) {
      await syncActivePlanToLark(c);
    }
    if (mounted) {
      toast(context,
          tx('已删除（7 天内可在「最近删除」恢复）',
              en: 'Deleted (restorable from "Recently deleted" for 7 days)'));
    }
  }

  /// 最近删除（回收站）：删除的计划快照保留 7 天，可恢复为新计划。
  bool _trashRestoring = false;

  Future<void> _openTrash() async {
    final c = app(context);
    await c.db.purgeExpiredDeletedPlans();
    final rows = await c.db.listDeletedPlans();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          children: [
            Text(
                tx('最近删除（7 天内可恢复）',
                    en: 'Recently deleted (restorable for 7 days)'),
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              tx('恢复后会成为新计划（不自动启用），训练日与动作完整保留。',
                  en: 'Restored as a new plan (not auto-activated), with all days and exercises intact.'),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
            ),
            const SizedBox(height: 8),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(tx('回收站是空的', en: 'Trash is empty'),
                    style: const TextStyle(color: AppTheme.textDim)),
              )
            else
              for (final row in rows)
                ListTile(
                  leading: const Icon(Icons.delete_outline,
                      color: AppTheme.textDim),
                  title: Text(dname(row['name'] as String)),
                  subtitle: Text(_deletedAtLabel(row['deleted_at'] as String),
                      style: const TextStyle(fontSize: 12)),
                  trailing: TextButton(
                    onPressed: () async {
                      if (_trashRestoring) return; // 防双击并发恢复出两份
                      _trashRestoring = true;
                      try {
                        final plan = await c.planRepo
                            .restoreFromTrash(row['id'] as int);
                        if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                        if (plan != null && mounted) {
                          toast(
                              context,
                              tx('已恢复「${dname(plan.name)}」（未启用）',
                                  en: 'Restored "${dname(plan.name)}" (inactive)'));
                          await _refresh();
                        } else if (mounted) {
                          toast(context,
                              tx('恢复失败，请重试', en: 'Restore failed, please retry'));
                        }
                      } finally {
                        _trashRestoring = false;
                      }
                    },
                    child: Text(tx('恢复', en: 'Restore')),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  String _deletedAtLabel(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final left = 7 - DateTime.now().difference(d).inDays;
    return tx('删除于 ${fmtDate(d)} · 约 $left 天后清除',
        en: 'Deleted ${fmtDate(d)} · cleared in ~$left days');
  }

  Future<void> _createBlankPlan() async {
    final ctrl = TextEditingController(text: tx('我的计划', en: 'My plan'));
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tx('新建空白计划', en: 'New blank plan')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tx('创建后可自行编排每周训练日与动作。',
                  en: 'After creating, arrange the weekly training days and exercises yourself.'),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(controller: ctrl, autofocus: true),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tx('取消', en: 'Cancel'),
                style: const TextStyle(color: AppTheme.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tx('创建', en: 'Create'),
                style: const TextStyle(color: AppTheme.primary)),
          ),
        ],
      ),
    );
    if (name == null || !mounted || name.isEmpty) return;
    final c = app(context);
    final plan = await c.db.insertPlan(
      Plan(
        name: name,
        source: 'manual',
        createdAt: fmtDate(DateTime.now()),
        isActive: 0,
      ),
    );
    for (var wd = 1; wd <= 7; wd++) {
      await c.db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: wd, title: '训练日'),
      );
    }
    final created =
        (await c.db.allPlans()).where((p) => p.id == plan.id).firstOrNull;
    await _refresh(view: created);
    if (mounted) toast(context, tx('已创建，点击任意一天开始编排', en: 'Created; tap any day to start building'));
  }

  // ================= 模板选择 =================

  Future<void> _showTemplatePicker() async {
    final c = app(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          children: [
            Text(
              tx('选择计划模板', en: 'Choose a plan template'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              tx('安装后可逐日修改动作与组数；同模板重复安装不会重复建。',
                  en: 'After installing, edit exercises and sets day by day; reinstalling the same template will not create a duplicate.'),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
            ),
            const SizedBox(height: 12),
            _templateCard(
              ctx,
              name: kBaojiPlanName,
              intro: tx('每周三练（推/拉/腿），四大项渐进超负荷，为本 App 量身设计',
                  en: 'Three workouts a week (Push/Pull/Legs), progressive overload on the big four lifts, designed for this app'),
              note: tx('适合按邵艾伦薄肌计划训练的人',
                  en: "For those training on Shao Ailun's Baoji Plan"),
              install: () async {
                final plan = await _switchActivePlanAndSync(
                  c,
                  () => c.planRepo.installBaojiPlan(),
                );
                return tx('已安装并设为使用中「${dname(plan.name)}」，可在编辑器微调',
                    en: '"${dname(plan.name)}" installed and set active; fine-tune in the editor');
              },
            ),
            for (final t in kPlanTemplates)
              _templateCard(
                ctx,
                name: t.name,
                intro: t.intro,
                note: t.note,
                install: () async {
                  final (plan, created) = await _switchActivePlanAndSync(
                    c,
                    () => c.planRepo.installTemplate(t),
                  );
                  return created
                      ? tx('已安装并设为使用中「${dname(plan.name)}」，可在编辑器微调',
                          en: '"${dname(plan.name)}" installed and set active; fine-tune in the editor')
                      : tx('已存在同名模板计划，已设为使用中（未重复安装）',
                          en: 'A template plan with the same name already exists; set active (not installed again)');
                },
              ),
          ],
        ),
      ),
    );
    if (mounted) {
      await _refresh(view: null);
    }
  }

  Widget _templateCard(
    BuildContext ctx, {
    required String name,
    required String intro,
    required String note,
    required Future<String> Function() install, // 返回 SnackBar 文案
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          final navigator = Navigator.of(ctx);
          final messenger = ScaffoldMessenger.of(ctx);
          final message = await install();
          navigator.pop();
          messenger.showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: AppTheme.cardHi,
              behavior: SnackBarBehavior.floating,
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      dname(name),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.add_circle_outline,
                    size: 20,
                    color: AppTheme.primary,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(dname(intro), style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 4),
              Text(
                tx('适合：${dname(note)}', en: 'For: ${dname(note)}'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ================= AI 导入 =================

  Future<void> _showAiImport() async {
    final c = app(context);
    final ctrl = TextEditingController();
    bool genMode = false; // false=原文导入 true=描述生成
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx('AI 计划', en: 'AI Plan'),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                        value: false,
                        label: Text(tx('原文导入', en: 'Import text'))),
                    ButtonSegment(
                        value: true,
                        label: Text(tx('描述生成', en: 'Generate'))),
                  ],
                  selected: {genMode},
                  onSelectionChanged: (s) => setSheet(() => genMode = s.first),
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (st) => st.contains(WidgetState.selected)
                          ? AppTheme.primary
                          : AppTheme.cardHi,
                    ),
                    foregroundColor: WidgetStateProperty.resolveWith(
                      (st) => st.contains(WidgetState.selected)
                          ? const Color(0xFF06220F)
                          : AppTheme.textDim,
                    ),
                    side: const WidgetStatePropertyAll(
                      BorderSide(color: Colors.transparent),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  genMode
                      ? tx('用大白话描述你想要什么，AI 直接设计计划。例："每周四练，练背、胸、腿，增肌，家里只有哑铃"。',
                          en: 'Describe what you want in plain words and the AI designs the plan. Example: "Train every Thursday, back, chest and legs, muscle gain, only dumbbells at home."')
                      : tx('粘贴现成计划原文（如"周一 卧推 3×5-8 …"），AI 逐字转成结构化计划。',
                          en: 'Paste an existing plan (e.g. "Mon bench press 3×5-8 ...") and the AI converts it into a structured plan.'),
                  style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  maxLines: genMode ? 4 : 8,
                  onChanged: (_) => setSheet(() {}),
                  decoration: InputDecoration(
                    hintText: genMode
                        ? tx('描述你的目标、频率、部位、器械…',
                            en: 'Describe your goal, frequency, body parts, equipment...')
                        : tx('在此粘贴计划原文…', en: 'Paste plan text here...'),
                  ),
                ),
                const SizedBox(height: 12),
                if (!c.settings.aiConfigured)
                  Text(
                    tx('尚未配置 AI 接口：请先到 设置 → AI 配置 填写。',
                        en: 'AI is not configured yet: set it up in Settings → AI first.'),
                    style: const TextStyle(color: AppTheme.warn),
                  ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: ctrl.text.trim().isEmpty
                      ? null
                      : () => Navigator.pop(ctx, true),
                  child: Text(genMode
                      ? tx('生成计划', en: 'Generate plan')
                      : tx('开始拆解', en: 'Start parsing')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    // 无 Key 不再前置拦截（评审修复）：AI 服务层会给出可读错误，
    // 走下方「AI 不可用回落本地」路径，预览页明示本地模式与失败原因。
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog(
      context: context,
      barrierDismissible: false, // 可手动关闭，后台请求继续
      builder: (_) => PopScope(
        canPop: true,
        child: Center(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 14),
                  Text(tx('正在让 AI 处理计划…', en: 'AI is processing the plan...'),
                      style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 4),
                  Text(
                    tx('通常 10-30 秒，可关闭稍等',
                        en: 'Usually 10-30 s; you can close this and wait'),
                    style: TextStyle(color: AppTheme.textDim, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    List<AiDaySpec>? specs;
    var localMode = false;
    var aiError = '';
    try {
      // 未配置 Key 由服务层抛可读错误（AiService.parsePlan/designPlanFromDescription
      // 的 aiConfigured 检查），统一进回落路径，避免此处维护第二份拦截逻辑。
      specs = genMode
          ? await c.ai.designPlanFromDescription(ctrl.text.trim())
          : await c.ai.parsePlan(ctrl.text.trim());
    } on AiException catch (e) {
      aiError = e.message;
    } catch (e) {
      aiError = tx('AI 请求失败，请重试或换模型（$e）',
          en: 'AI request failed; retry or switch models ($e)');
    }
    if (nav.canPop()) nav.pop();

    // 调研条目 13：AI 不可用（无 Key/无网/失败）→ 自动回落 engine 本地
    // 规则生成，预览页明示「本地模式」；描述里实在提不出可用动作才报错。
    if (specs == null) {
      final local = localPlanFromDescription(ctrl.text.trim());
      if (local.isEmpty) {
        if (mounted) {
          toast(context,
              aiError.isEmpty ? tx('本地生成失败，请重试', en: 'Local generation failed; please try again') : aiError);
        }
        return;
      }
      specs = [
        for (final d in local)
          AiDaySpec(
            d.weekday,
            d.title,
            [
              for (final ex in d.exercises)
                AiExerciseSpec(
                  name: ex.name,
                  rawName: ex.name,
                  sets: ex.sets,
                  repsMin: ex.repsMin,
                  repsMax: ex.repsMax,
                  restSec: ex.restSec,
                  kind: ex.kind,
                  mainMuscle: ex.mainMuscle,
                ),
            ],
          ),
      ];
      localMode = true;
    }
    if (!mounted) return;

    // 调研条目 12：无论哪种来源都先进预览页逐动作确认，确认后才落库。
    // 回落时带上 AI 失败原因摘要（评审修复）：自配 API 的用户能看出
    // 是 Key 错还是网络错，而不是只见笼统的「AI 不可用」。
    final existingPlans = await c.db.allPlans();
    if (!mounted) return;
    final picked = await showPlanPreviewSheet(
      context,
      specs,
      localMode: localMode,
      aiError: localMode ? aiError : '',
      existingPlans: existingPlans,
    );
    if (picked == null || !mounted) return;
    final dayIdx = picked.adhocDayIndex;
    if (dayIdx != null) {
      if (c.session.hasActive) {
        toast(
          context,
          tx('已有进行中的训练，先完成或结束它',
              en: 'A workout is already in progress — finish or end it first'),
        );
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
        title: spec.title.trim().isEmpty
            ? tx('临时训练', en: 'Ad-hoc workout')
            : spec.title.trim(),
        planExercises: exs,
      );
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const WorkoutPage(),
      ));
      return;
    }
    final name = picked.name;
    final confirmed = picked.specs;
    // 替换现有计划（2026-09-26）：内容全量重建，计划行与启用态保留
    if (picked.replacePlanId != null) {
      final replaced = await replacePlanAndSync(
        c,
        planId: picked.replacePlanId!,
        specs: confirmed,
        rename: name.isEmpty ? null : name,
      );
      await _refresh();
      if (!mounted) return;
      toast(context,
          tx('已更新「${dname(replaced.name)}」的内容，计划保持${replaced.isActive == 1 ? '使用中' : '未启用'}',
              en: '"${dname(replaced.name)}" updated; plan stays ${replaced.isActive == 1 ? 'active' : 'inactive'}'));
      return;
    }
    final plan = await _switchActivePlanAndSync(
      c,
      () => c.planRepo.saveAiPlan(
        // 评审修复：本地模式空名回退「本地计划」而非「AI 生成/AI 计划」，
        // 名字不误导产物来源。
        name: name.isEmpty
            ? (localMode
                ? tx('本地计划 ${fmtDate(DateTime.now())}',
                    en: 'Local plan ${fmtDate(DateTime.now())}')
                : (genMode
                    ? tx('AI 生成 ${fmtDate(DateTime.now())}',
                        en: 'AI generated ${fmtDate(DateTime.now())}')
                    : tx('AI 计划 ${fmtDate(DateTime.now())}',
                        en: 'AI plan ${fmtDate(DateTime.now())}')))
            : name,
        specs: confirmed,
        metaMap: c.ai.metaMap(),
      ),
    );
    await _refresh();
    if (!mounted) return;
    toast(
      context,
      localMode
          ? tx('本地模式已生成「${dname(plan.name)}」（AI 不可用），请逐日校对',
              en: '"${dname(plan.name)}" generated in local mode (AI unavailable); review each day')
          : tx('已保存并设为使用中「${dname(plan.name)}」，点任意一天可微调',
              en: '"${dname(plan.name)}" saved and set active; tap any day to fine-tune'),
    );
  }

  /// 生成结果预览与逐动作候选确认已抽到 plan_preview_sheet.dart
  /// （与 AI 教练「排计划模式」共用同一确认纪律）。

  // ================= 飞书同步 =================
  // 撤旧日程/写新日程由 plan_actions.dart 统一实现（勿在页面再留副本）。
}
