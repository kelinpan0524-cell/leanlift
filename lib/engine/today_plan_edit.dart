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
//
// 20 分钟精简（P2-D）：shortSessionPlan / shortSessionDroppedNames 是纯函数
// 选型层——复合动作优先、最多 3 个动作、每个 2 组、组间休息 90 秒；
// 只生成内存清单，开练仍走 home_page._start（startFromDay 全链路），
// 不写回长期计划。
import '../l10n/lang.dart';
import '../models/models.dart';
import 'superset.dart';
import 'weight_unit.dart' show fmtWithUnit;

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
/// [base] 非空时以原 rule 为底：chain（自定义规则链）、rirTarget、desc
/// 等用户配置原样保留，只覆盖本次调整的组数/次数——精简清单不能把
/// 用户自配的链与余力目标压没。
ProgressionRule todayRuleFor({
  required int sets,
  required int repsMin,
  required int repsMax,
  required String kind,
  ProgressionRule? base,
}) {
  final compound = kind == 'compound';
  if (base != null) {
    return ProgressionRule(
      repsMin: repsMin,
      repsMax: repsMax,
      // 步长仍按动作类型推导（与计划编辑器同口径，精简不改步长语义）；
      // chain/rirTarget/desc 从 base 原样保留——用户自配的规则链与
      // 余力目标不能被「只有 20 分钟」压没。
      incrementKg: compound ? 2.5 : 1.25,
      rirTarget: base.rirTarget,
      workingSets: sets,
      desc: base.desc,
      chain: base.chain == null
          ? null
          : List<ChainRule>.of(base.chain!),
    );
  }
  return ProgressionRule(
    repsMin: repsMin,
    repsMax: repsMax,
    incrementKg: compound ? 2.5 : 1.25,
    workingSets: sets,
    desc: compound
        ? tx('全部正式组达 $repsMax 次且末组余力≥1 → 加 ${fmtWithUnit(2.5)}；有组低于 $repsMin 次 → 减 5%',
            en: 'All working sets reach $repsMax reps with ≥1 in reserve on the last set → add ${fmtWithUnit(2.5)}; any set below $repsMin reps → reduce 5%')
        : tx('全部正式组达 $repsMax 次且末组余力≥1 → 加 ${fmtWithUnit(1.25)}',
            en: 'All working sets reach $repsMax reps with ≥1 in reserve on the last set → add ${fmtWithUnit(1.25)}'),
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

/// 20 分钟精简清单的上限：最多 3 个动作。
const int kShortSessionMaxExercises = 3;

/// 20 分钟精简清单的单动作组数。
const int kShortSessionSets = 2;

/// 20 分钟精简清单的组间休息秒数。
const int kShortSessionRestSec = 90;

/// 生成「只有 20 分钟」的精简清单（P2-D）：复合动作优先、最多
/// [maxExercises] 个动作、每个最多 [sets] 组、组间休息 [restSec] 秒。
///
/// 组数取 min(原组数, [sets])：只压不增——原计划只安排 1 组的动作
/// 精简后仍是 1 组，不虚标。原 rule 里的 chain/rirTarget 等用户配置
/// 经 [todayRuleFor] 的 base 参数原样保留。
///
/// 纯函数：不改入参、不碰数据库。返回列表的 orderIdx 已归一化，
/// 超级组标记一律清空——精简会重排动作，原组对不再相邻，悬空 tag
/// 会让训练中的轮转推进错乱（见文件头 orderIdx/超级组口径）。
/// 次数区间、记录形态、负荷类型、动作稳定键原样保留，只压组数与休息。
List<PlanExercise> shortSessionPlan(
  List<PlanExercise> source, {
  int maxExercises = kShortSessionMaxExercises,
  int sets = kShortSessionSets,
  int restSec = kShortSessionRestSec,
}) {
  final picked = _shortSessionPicked(source, maxExercises);
  return renumberOrderIdx([
    for (final e in picked)
      // min(原组数, 上限)：脏数据 sets<=0 时回退上限，避免 0 组行
      e.copyWith(
        sets: e.sets > 0 && e.sets < sets ? e.sets : sets,
        restSec: restSec,
        rule: todayRuleFor(
          sets: e.sets > 0 && e.sets < sets ? e.sets : sets,
          repsMin: e.repsMin,
          repsMax: e.repsMax,
          kind: e.kind,
          base: e.rule,
        ),
        supersetTag: '',
      ),
  ]);
}

/// 精简清单会跳过的动作名（按原计划顺序）；与 [shortSessionPlan] 同一
/// 选择口径，供首页入口文案说明「删掉哪些动作」。
List<String> shortSessionDroppedNames(
  List<PlanExercise> source, {
  int maxExercises = kShortSessionMaxExercises,
}) {
  final picked = _shortSessionPicked(source, maxExercises);
  return [
    for (var i = 0; i < source.length; i++)
      if (!picked.contains(source[i])) source[i].name,
  ];
}

/// 选型本体：稳定分区——先按原顺序收全部复合动作，再按原顺序收辅助
/// 动作，最后截到上限。复合判定与全 App 同口径（kind == 'compound'）。
List<PlanExercise> _shortSessionPicked(
    List<PlanExercise> source, int maxExercises) {
  if (maxExercises <= 0 || source.isEmpty) return const [];
  final ordered = [
    for (final e in source)
      if (e.kind == 'compound') e,
    for (final e in source)
      if (e.kind != 'compound') e,
  ];
  return ordered.length <= maxExercises
      ? ordered
      : ordered.sublist(0, maxExercises);
}
