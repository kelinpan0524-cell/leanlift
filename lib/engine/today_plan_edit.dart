// 今日开练编辑（2026-10-07）：开练前对「今天练什么」做的临时调整——
// 只影响当天这次会话，绝不写回长期计划模板。本文件是纯 Dart 推导层：
// 默认参数、规则重建、超级组标记清理与组序归一化全部是无副作用纯函数，
// 不碰数据库与 UI，可独立单测（test/today_plan_edit_test.dart）。
//
// 与计划编辑器的口径关系（逐条对齐，防两处漂移）：
// - 默认参数照抄 PlanEditorPage._pickFromLibrary（复合 4×6-10/休150/步2.5，
//   辅助 3×8-12/休90/步1.25）；
// - 规则重建照抄 PlanEditorPage._openExerciseSheet 的 rule 构造
//   （改组数/次数必须重建规则，渐进引擎按 rule 判定）；
// - 超级组标记清理复用引擎 supersetTagClears（同 tag 相邻 ≥2 人才成组）。
// orderIdx 归一化是硬要求：startFromDay 按 pe.orderIdx 写 SessionExercise，
// 被杀恢复与历史明细都按 ORDER BY order_idx 读回（db.dart dayExercises /
// setsOfSession），不归一则编辑后内存顺序正确、恢复后动作回旧序。
import '../l10n/lang.dart';
import '../models/models.dart';
import 'superset.dart';

/// 从动作库挑入当天时的默认参数（照抄 PlanEditorPage._pickFromLibrary）：
/// 复合 4 组×6-10 次/休 150s/步长 2.5kg；辅助 3 组×8-12 次/休 90s/步长 1.25kg。
PlanExercise todayExerciseDefaults({
  required int dayId,
  required int orderIdx,
  required bool isCompound,
}) {
  return PlanExercise(
    dayId: dayId,
    name: '',
    orderIdx: orderIdx,
    sets: isCompound ? 4 : 3,
    repsMin: isCompound ? 6 : 8,
    repsMax: isCompound ? 10 : 12,
    restSec: isCompound ? 150 : 90,
    kind: isCompound ? 'compound' : 'assistance',
    rule: todayRuleFor(
      sets: isCompound ? 4 : 3,
      repsMin: isCompound ? 6 : 8,
      repsMax: isCompound ? 10 : 12,
      kind: isCompound ? 'compound' : 'assistance',
    ),
  );
}

/// 按组数/次数区间/动作类型重建渐进规则（与 PlanEditorPage._openExerciseSheet
/// 同口径）：改组数/次数后必须重建，训练引擎的渐进判定按 rule 走。
ProgressionRule todayRuleFor({
  required int sets,
  required int repsMin,
  required int repsMax,
  required String kind,
}) {
  final compound = kind == 'compound';
  return ProgressionRule(
    repsMin: repsMin,
    repsMax: repsMax,
    incrementKg: compound ? 2.5 : 1.25,
    workingSets: sets,
    desc: compound
        ? tx('全部正式组达 $repsMax 次且末组余力≥1 → 加 2.5kg；有组低于 $repsMin 次 → 减 5%',
            en: 'All working sets reach $repsMax reps with ≥1 in reserve on the last set → add 2.5kg; any set below $repsMin reps → reduce 5%')
        : tx('全部正式组达 $repsMax 次且末组余力≥1 → 加 1.25kg',
            en: 'All working sets reach $repsMax reps with ≥1 in reserve on the last set → add 1.25kg'),
  );
}

/// 重排/删除后的超级组标记清理：取 tags 跑 supersetTagClears，
/// 命中（被拆散或只剩单人）的下标 copyWith(supersetTag: '') 返回新列表。
/// 引擎按相邻同 tag 分组，不改也能跑，但今日卡 ⇄ 徽标会不一致，必须清理。
List<PlanExercise> clearSupersetTagsAfterMutation(List<PlanExercise> list) {
  final clears = supersetTagClears([for (final e in list) e.supersetTag]);
  if (clears.isEmpty) return list;
  return [
    for (var i = 0; i < list.length; i++)
      clears.contains(i) ? list[i].copyWith(supersetTag: '') : list[i],
  ];
}

/// 组序归一化：orderIdx 与列表下标强一致（编辑增删拖后必须调用，
/// pop 返回前再兜底跑一次）。数据只进本次会话快照，orderIdx 错了会
/// 破坏被杀恢复落点与历史明细排序。
List<PlanExercise> renumberOrderIdx(List<PlanExercise> list) => [
      for (var i = 0; i < list.length; i++) list[i].copyWith(orderIdx: i),
    ];
