import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../engine/superset.dart';
import '../engine/today_plan_edit.dart';
import '../l10n/lang.dart';
import '../l10n/names.dart';
import 'exercise_picker_page.dart';
import 'plan_editor_page.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 开练前编辑（2026-10-07）：点「开始训练」先弹这页，让用户对「今天练什么」
/// 做临时调整——增删/换动作、拖拽排序、点行改组次。全程零 DB 写：列表在
/// 内存里改，确认后把完整清单交回 home_page._start 喂给 startFromDay
/// （startFromDay 只吃内存快照写 sessions/session_exercises），「只影响
/// 当天、不写回长期计划」由这一语义保证；但列表内 orderIdx 必须随编辑
/// 归一化（renumberOrderIdx），否则被杀恢复落点与历史明细排序回旧序。
/// 返回 null = 取消不开练；非空 = 编辑后的完整清单（orderIdx 已归一化）。
Future<List<PlanExercise>?> showTodayEditSheet(
  BuildContext context, {
  required PlanDay day,
  required List<PlanExercise> initial,
}) async {
  // 动作词表一次性载入（只读，供点行编辑表单做名称联想）
  final metas = await app(context).db.allExerciseMeta();
  if (!context.mounted) return null;
  return showModalBottomSheet<List<PlanExercise>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.card,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) =>
        _TodayEditSheet(day: day, initial: initial, metas: metas),
  );
}

class _TodayEditSheet extends StatefulWidget {
  const _TodayEditSheet({
    required this.day,
    required this.initial,
    required this.metas,
  });

  final PlanDay day;
  final List<PlanExercise> initial;
  final List<ExerciseMeta> metas;

  @override
  State<_TodayEditSheet> createState() => _TodayEditSheetState();
}

class _TodayEditSheetState extends State<_TodayEditSheet> {
  late List<PlanExercise> _list = [...widget.initial];

  Map<String, ExerciseMeta> get _metaByName =>
      {for (final m in widget.metas) m.name: m};

  List<String> get _tags => [for (final e in _list) e.supersetTag];

  /// i 所属超级组（同 tag 相邻 ≥2 人）；null = 未配对（口径同首页今日卡）。
  bool _grouped(int i) => supersetMembersOf(i, _tags) != null;

  /// 每次增/删/拖/改后统一收口：超级组标记清理（被拆散或单人自动解除，
  /// 不提供新建配对——保留模板既有 tag）+ orderIdx 归一化（硬要求）。
  void _apply(List<PlanExercise> next) {
    setState(() {
      _list = renumberOrderIdx(clearSupersetTagsAfterMutation(next));
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    final next = [..._list];
    final item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    _apply(next);
  }

  void _removeRow(int i) {
    _apply([..._list]..removeAt(i));
  }

  /// 「换」动作：沿用 replaceCurrentExercise 先例只换名字，组次/休息/
  /// 规则/kind 全保留（session_controller.dart 同口径）。挑选页里本动作
  /// 之外的名字全部标「已添加」禁选，天然防重名。
  Future<void> _swapRow(int i) async {
    final picked = await Navigator.of(context).push<List<ExerciseMeta>>(
      MaterialPageRoute(
        builder: (_) => ExercisePickerPage(
          existingNames: {
            for (var k = 0; k < _list.length; k++)
              if (k != i) _list[k].name,
          },
        ),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final next = [..._list];
    next[i] = next[i].copyWith(name: picked.first.name);
    _apply(next);
  }

  /// 点行 → 动作编辑表单（与计划编辑器共用）：确认后改名需查重（同名
  /// toast 拒绝），其余字段 copyWith 并按新组次/次数重建渐进规则。
  Future<void> _editRow(int i) async {
    final ex = _list[i];
    final result = await showModalBottomSheet<ExerciseFormResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => ExerciseEditSheet(
        initial: ex,
        knownMetas: widget.metas,
        initialMuscle: _metaByName[ex.name]?.muscles.main,
      ),
    );
    if (result == null || !mounted) return;
    final renamed = result.name != ex.name;
    if (renamed && _list.any((e) => e.name == result.name)) {
      toast(context,
          tx('已有同名动作「${exname(result.name)}」，换个名字',
              en: '"${exname(result.name)}" is already in the list; pick another name'));
      return;
    }
    final next = [..._list];
    next[i] = next[i].copyWith(
      name: result.name,
      sets: result.sets,
      repsMin: result.repsMin,
      repsMax: result.repsMax,
      restSec: result.restSec,
      kind: result.kind,
      rule: todayRuleFor(
        sets: result.sets,
        repsMin: result.repsMin,
        repsMax: result.repsMax,
        kind: result.kind,
      ),
    );
    _apply(next);
  }

  /// 从动作库批量追加：默认参数照抄计划编辑器（todayExerciseDefaults）。
  Future<void> _addFromLibrary() async {
    final picked = await Navigator.of(context).push<List<ExerciseMeta>>(
      MaterialPageRoute(
        builder: (_) => ExercisePickerPage(
          existingNames: {for (final e in _list) e.name},
        ),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final next = [..._list];
    for (final m in picked) {
      next.add(todayExerciseDefaults(
        dayId: widget.day.id ?? 0,
        orderIdx: next.length,
        isCompound: m.isCompound,
      ).copyWith(name: m.name));
    }
    _apply(next);
  }

  @override
  Widget build(BuildContext context) {
    final sheetHeight = MediaQuery.of(context).size.height * 0.85;
    return SizedBox(
      height: sheetHeight,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // 头部：返回=取消（不开练）+ 只读标题 + 取消按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Row(
                children: [
                  BackButton(
                      onPressed: () => Navigator.pop(context, null)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(dname(widget.day.title),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w700)),
                        Text(
                            tx('开练前可调整，只影响今天',
                                en: 'Quick edit — today only'),
                            style: const TextStyle(
                                color: AppTheme.textDim, fontSize: 12)),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, null),
                    child: Text(tx('取消', en: 'Cancel')),
                  ),
                ],
              ),
            ),
            if (_list.isEmpty)
              Expanded(
                child: Center(
                  child: Text(tx('至少保留一个动作', en: 'Keep at least one exercise'),
                      style: const TextStyle(color: AppTheme.textDim)),
                ),
              )
            else
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  buildDefaultDragHandles: false,
                  // 与计划编辑器同款（plan_editor_page.dart:556-572）：
                  // onReorderItem 的 newIndex 已由框架修正，直接插即可
                  onReorderItem: _onReorder,
                  proxyDecorator: (child, index, animation) => Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(16),
                    color: AppTheme.cardHi,
                    child: child,
                  ),
                  itemCount: _list.length,
                  itemBuilder: (BuildContext ctx, int i) => _row(i,
                      key: ValueKey(
                          '${_list[i].id ?? 'new'}-${_list[i].name}')),
                ),
              ),
            // 底部常驻（拇指区）：从动作库添加 + 88dp 大按钮一键开练
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _addFromLibrary,
                      icon: const Icon(Icons.library_books, size: 18),
                      label: Text(tx('从动作库添加', en: 'Add from library')),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  BigButton(
                    label: tx('开始训练', en: 'Start Workout'),
                    height: 88,
                    onPressed: _list.isEmpty
                        ? null
                        : () => Navigator.pop(context, renumberOrderIdx(_list)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(int i, {required Key key}) {
    final e = _list[i];
    return Card(
      key: key,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ReorderableDelayedDragStartListener(
        index: i,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _editRow(i),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: Row(
              children: [
                const SizedBox(
                    width: 32,
                    height: 44,
                    child: Icon(Icons.drag_indicator,
                        size: 20, color: AppTheme.textDim)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '${_grouped(i) ? '⇄ ' : ''}${exname(e.name)}',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                            '${e.sets}×${e.repsMin}-${e.repsMax} · ${tx('休 ${e.restSec}s', en: 'Rest ${e.restSec}s')} · ${e.kind == 'compound' ? tx('复合', en: 'Compound') : tx('辅助', en: 'Assistance')}',
                            style: const TextStyle(
                                color: AppTheme.textDim, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: tx('换动作（保留组次）',
                      en: 'Swap exercise (keep sets)'),
                  onPressed: () => _swapRow(i),
                  icon: const Icon(Icons.swap_horiz,
                      size: 20, color: AppTheme.textDim),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: tx('删除', en: 'Delete'),
                  onPressed: () => _removeRow(i),
                  icon: const Icon(Icons.delete_outline,
                      size: 20, color: AppTheme.danger),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
