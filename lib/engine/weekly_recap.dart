import '../l10n/lang.dart';
import '../l10n/names.dart';
import '../models/models.dart';
import 'exercise_identity.dart';
import 'metrics.dart';
import 'muscle_insights.dart';
import 'weight_unit.dart' show fmtWithUnit;

/// 本地周复盘（P1-E1，2026-10-18）：不依赖 AI / 网络，纯本地算出一周的
/// 「练得怎么样、下周做什么」。
///
/// 口径（与数据页既有统计保持一致）：
/// - 只认 `sessions.status == 'done'`（调用方传入的 sessions 应来自
///   `Db.sessionsBetween` / `sessionRowsBetween`，本身已过滤 active/quit）；
/// - 正式组 = `kind != warmup`（力竭组计入，与容量/每周组数口径一致）；
/// - 计划训练数 / 计划正式组来自调用方按**当前排程**解析好的
///   [plannedByDate]（键 `yyyy-MM-dd`，值含模板日 id 与当日计划正式组数；
///   只有组数 > 0 的日期才算一个计划训练日）。循环计划同一周轮到同一模板日
///   时每天各计一次、漏练的 occurrence 照算；去重只发生在调用方用
///   [RecapPlannedDay.postponedFrom] 显式声明的顺延承接对上（真实链路的
///   自动顺延会先给原日期落休息墓碑，原日期进不了 [plannedByDate]）；
/// - 计划完成按「日期 + Session.planDayId」精确匹配：加练 / 自由训练
///   不顶替漏掉的计划日，额外训练单独计入 [completedSessions] 与
///   [completedWorkingSets]；
/// - 进步 / 停滞按「本周最佳估算 1RM」对比「上周最佳估算 1RM」：
///   本周没超过上周（差值 ≤ 0.01kg）即停滞；两周都练过才有对比，
///   只练了一周（新动作）不硬判进步或停滞；
/// - 减载周 / 停练回归会话（[excludeProgressSessionIds]）不参与 1RM
///   进步/停滞判断——主动降负荷不是停滞，与 SessionController 的
///   渐进回溯口径一致；
/// - 肌群周组数复用 [weeklyWorkingSetsByMuscle] 的主 1 / 次 0.5 口径；
/// - 体重趋势取截至 [now] 的最近 7 天（含今天），不足两条时 Δ 为 null。
class RecapSetRow {
  /// 动作显示名（历史页原始名即可）。
  final String name;

  /// 动作稳定身份键（空 = 按 [name] 现算，与历史查询同口径）。
  final String exerciseKey;

  final double weightKg;
  final int reps;
  final String kind;
  final DateTime date;

  /// 所属会话 id（用于计划组数归属与减载会话排除）；null = 调用方未提供。
  final int? sessionId;

  /// 记录形态（[LoggingMode]）：计时动作的 reps 是秒数，不参与 1RM 估算。
  final String logging;

  const RecapSetRow({
    required this.name,
    this.exerciseKey = '',
    required this.weightKg,
    required this.reps,
    this.kind = SetKind.working,
    required this.date,
    this.sessionId,
    this.logging = LoggingMode.reps,
  });
}

/// 一个计划训练日：模板日 id + 当日计划正式组数。
class RecapPlannedDay {
  final int? dayId;
  final int workingSets;

  /// 本日期承接自哪个原日期（`yyyy-MM-dd`）：自动顺延把原日期的内容挪到
  /// 本日期、且调用方绕过休息墓碑解析把原日期也放进了 [plannedByDate] 时，
  /// 用它声明「两日是同一份计划」——复盘只算本日期一次，原日期并入。
  /// null = 正常排程日。循环计划同一周重复出现的模板日**不要**标记，
  /// 每个 occurrence 各算一次。
  final String? postponedFrom;

  const RecapPlannedDay({
    this.dayId,
    required this.workingSets,
    this.postponedFrom,
  });
}

/// 某动作本周相对上周的 1RM 变化。
class RecapExerciseChange {
  final String name;
  final double previousBest1Rm;
  final double best1Rm;

  const RecapExerciseChange({
    required this.name,
    required this.previousBest1Rm,
    required this.best1Rm,
  });

  /// 正 = 进步，负 = 退步；0 附近 = 停滞。
  double get deltaKg => best1Rm - previousBest1Rm;
}

/// 低于每周组数目标下限的肌群。
class RecapMuscleShortfall {
  final String muscle;
  final double sets;
  final int targetMin;
  final int targetMax;

  const RecapMuscleShortfall({
    required this.muscle,
    required this.sets,
    required this.targetMin,
    required this.targetMax,
  });

  /// 还差多少组到目标下限（正数 = 差这么多组）。
  double get deficit => targetMin - sets;
}

/// 一条体重记录（只保留日期与体重）。
class RecapWeightPoint {
  final String date;
  final double weightKg;

  const RecapWeightPoint(this.date, this.weightKg);
}

/// 最近 7 天体重趋势：首条 → 末条；只有一条时 Δ 为 null。
class RecapWeightTrend {
  final List<RecapWeightPoint> points;

  const RecapWeightTrend(this.points);

  bool get hasData => points.isNotEmpty;
  double? get startKg => points.isEmpty ? null : points.first.weightKg;
  double? get endKg => points.isEmpty ? null : points.last.weightKg;
  double? get deltaKg =>
      points.length < 2 ? null : points.last.weightKg - points.first.weightKg;
}

/// 周复盘结果。所有字段均为本地计算结果，可直接渲染。
class WeeklyRecap {
  final DateTime weekStart;
  final DateTime weekEnd;

  /// 本周计划训练日数（[plannedByDate] 中组数 > 0 且未被顺延承接并入的
  /// 日期数；循环计划同一周重复出现的模板日每天各计一次）。
  final int plannedSessions;

  /// 本周实际完成的 done 训练次数（含加练 / 自由训练）。
  final int completedSessions;

  /// 与计划精确对上的训练日数（日期 + planDayId 都匹配）。
  final int completedPlannedSessions;

  /// 本周计划正式组总数。
  final int plannedWorkingSets;

  /// 本周实际完成的正式组总数（含加练，含力竭组、不含热身组）。
  final int completedWorkingSets;

  /// 与计划对上的训练日里完成的正式组数，按当日计划组数封顶；
  /// 超出部分计入 [extraWorkingSets]。
  final int completedPlannedWorkingSets;

  /// 本周还没到、也还没练的计划训练日数（不含已被顺延挪走的日子）。
  final int remainingPlannedSessions;

  /// 本周 1RM 超过上周的动作（按提升幅度降序）。
  final List<RecapExerciseChange> improvedExercises;

  /// 本周 1RM 没超过上周的动作（按退步幅度升序）。
  final List<RecapExerciseChange> stalledExercises;

  /// 低于每周组数目标下限的肌群（按缺口从大到小）。
  final List<RecapMuscleShortfall> underTargetMuscles;

  /// 本周每肌群正式组数（主 1 / 次 0.5，键覆盖 [kMuscleRegions]）。
  final Map<String, double> weeklySetsByMuscle;

  /// 最近 7 天体重趋势（截至 now）。
  final RecapWeightTrend weightTrend;

  /// 一条明确的行动建议（优先顺序：补训练次数 → 补计划组数
  /// → 补肌群组数 → 破停滞 → 继续加重 → 保持）。
  final String action;

  const WeeklyRecap({
    required this.weekStart,
    required this.weekEnd,
    required this.plannedSessions,
    required this.completedSessions,
    required this.completedPlannedSessions,
    required this.plannedWorkingSets,
    required this.completedWorkingSets,
    required this.completedPlannedWorkingSets,
    required this.remainingPlannedSessions,
    required this.improvedExercises,
    required this.stalledExercises,
    required this.underTargetMuscles,
    required this.weeklySetsByMuscle,
    required this.weightTrend,
    required this.action,
  });

  /// 没有对上计划日的额外训练次数（加练 / 自由训练）。
  int get extraSessions => completedSessions - completedPlannedSessions;

  /// 计划外正式组数：计划日之外的组 + 计划日内超出计划组数的加组。
  int get extraWorkingSets =>
      completedWorkingSets - completedPlannedWorkingSets;
}

/// 周复盘纯函数。所有时间均为本地时区；[weekStart] 为这周第一天（周一）。
///
/// [sessions] 可给更宽的范围，函数只取本周内的 done 会话；
/// [sets] 需覆盖本周与上周（1RM 对比用），本周外的行会被忽略。
/// [plannedByDate] 的键必须是 `yyyy-MM-dd`。
/// [excludeProgressSessionIds] 里的会话（减载周 / 停练回归）不计入
/// 1RM 进步/停滞，但仍计入实际完成组数与肌群剂量。
WeeklyRecap weeklyRecap({
  required DateTime now,
  required DateTime weekStart,
  required Map<String, RecapPlannedDay> plannedByDate,
  required List<Session> sessions,
  required List<RecapSetRow> sets,
  Set<int> excludeProgressSessionIds = const {},
  Map<String, ExerciseMeta> metaByName = const {},
  List<BodyMetric> bodyMetrics = const [],
}) {
  final start = DateTime(weekStart.year, weekStart.month, weekStart.day);
  final end = start.add(const Duration(days: 6));
  final startDate = fmtDate(start);
  final endDate = fmtDate(end);
  final prevStart = start.subtract(const Duration(days: 7));
  final prevEnd = start.subtract(const Duration(days: 1));

  // ---------- 训练次数 ----------
  final doneSessions = [
    for (final s in sessions)
      if (s.status == 'done' &&
          s.date.compareTo(startDate) >= 0 &&
          s.date.compareTo(endDate) <= 0)
        s,
  ];

  // ---------- 组明细：本周 / 上周 ----------
  final weekRows = <RecapSetRow>[];
  final prevRows = <RecapSetRow>[];
  for (final r in sets) {
    if (r.kind == SetKind.warmup) continue;
    final day = DateTime(r.date.year, r.date.month, r.date.day);
    if (!day.isBefore(start) && !day.isAfter(end)) {
      weekRows.add(r);
    } else if (!day.isBefore(prevStart) && !day.isAfter(prevEnd)) {
      prevRows.add(r);
    }
  }

  // ---------- 肌群周组数（主 1 / 次 0.5，与数据页同口径） ----------
  final byIdentity = <String, List<RecapSetRow>>{};
  final displayName = <String, String>{};
  for (final r in weekRows) {
    final key = exerciseIdentityKeyOf(r.name, r.exerciseKey);
    if (key.isEmpty) continue;
    byIdentity.putIfAbsent(key, () => <RecapSetRow>[]).add(r);
    displayName.putIfAbsent(key, () => canonicalExerciseNameOf(r.name));
  }
  final weeklySets = weeklyWorkingSetsByMuscle([
    for (final e in byIdentity.entries)
      MapEntry(displayName[e.key] ?? e.key, [
        for (final r in e.value)
          SetEntry(
            sessionExerciseId: 0,
            weightKg: r.weightKg,
            reps: r.reps,
            kind: r.kind,
            doneAt: r.date.millisecondsSinceEpoch,
          ),
      ]),
  ], metaByName);

  // ---------- 1RM 进步 / 停滞（本周 vs 上周） ----------
  Map<String, double> best1RmByIdentity(List<RecapSetRow> rows) {
    final best = <String, double>{};
    for (final r in rows) {
      // 主动减载 / 停练回归场不能把「进步/停滞」带偏（与渐进回溯同口径）。
      final sessionId = r.sessionId;
      if (sessionId != null && excludeProgressSessionIds.contains(sessionId)) {
        continue;
      }
      // 计时动作的「次数」是秒数、自重动作没有重量：都不估 1RM。
      if (r.logging == LoggingMode.time) continue;
      if (r.weightKg <= 0 || r.reps <= 0) continue;
      final key = exerciseIdentityKeyOf(r.name, r.exerciseKey);
      if (key.isEmpty) continue;
      final rm = estimate1RM(r.weightKg, r.reps);
      if (rm > (best[key] ?? 0)) best[key] = rm;
    }
    return best;
  }

  final weekBest = best1RmByIdentity(weekRows);
  final prevBest = best1RmByIdentity(prevRows);
  final improved = <RecapExerciseChange>[];
  final stalled = <RecapExerciseChange>[];
  for (final e in weekBest.entries) {
    final prev = prevBest[e.key];
    if (prev == null) continue; // 上周没练过：不给进步/停滞结论
    final change = RecapExerciseChange(
      name: displayName[e.key] ?? e.key,
      previousBest1Rm: prev,
      best1Rm: e.value,
    );
    if (e.value > prev + 0.01) {
      improved.add(change);
    } else {
      stalled.add(change);
    }
  }
  improved.sort((a, b) => b.deltaKg.compareTo(a.deltaKg));
  stalled.sort((a, b) => a.deltaKg.compareTo(b.deltaKg));

  // ---------- 计划训练数 / 计划组数 / 精确完成 ----------
  // 计划日按日期各算一个，不做任何 dayId 级猜测去重：
  // - 循环计划同一周轮到同一模板日（练2休2 配 3 模板，胸落在周一和周六）
  //   → 每天各计一次；漏练的 occurrence 也照算，否则「补训练次数」不会
  //   触发，漏练会被静默吞掉。
  // - 真实链路上自动顺延总是先给原日期落显式休息墓碑
  //   （PlanRepository.shiftScheduleOneDay → setOverride(dayId: null)），
  //   原日期解析为 null、进不了 [plannedByDate]，天然不会重复相加。
  // - 只有调用方用 [RecapPlannedDay.postponedFrom] 显式声明「本日期承接自
  //   某原日期」（绕过墓碑解析的调用方）时，才把那个原日期并入本日期、
  //   不单独计数；两个日期的 dayId 必须一致才算同一份计划。
  final rawPlanned = [
    for (final e in plannedByDate.entries)
      if (e.value.workingSets > 0) e,
  ]..sort((a, b) => a.key.compareTo(b.key));
  final absorbedByPostpone = <String>{};
  for (final e in rawPlanned) {
    final from = e.value.postponedFrom;
    if (from == null || from == e.key) continue;
    final origin = plannedByDate[from];
    if (origin == null ||
        origin.workingSets <= 0 ||
        origin.dayId != e.value.dayId) {
      continue;
    }
    absorbedByPostpone.add(from);
  }
  final plannedEntries = [
    for (final e in rawPlanned)
      if (!absorbedByPostpone.contains(e.key)) e,
  ];
  final plannedSessions = plannedEntries.length;
  final plannedWorkingSets = plannedEntries.fold<int>(
    0,
    (acc, e) => acc + e.value.workingSets,
  );
  final plannedSetsByDate = {
    for (final e in plannedEntries) e.key: e.value.workingSets,
  };
  final plannedDayByDate = {
    for (final e in plannedEntries) e.key: e.value.dayId,
  };

  // 计划完成必须「日期 + planDayId」同时对上：同一天的自由训练/加练
  // 不能顶替漏掉的计划日；同一天第二场同模板训练算加练。
  final completedPlannedDates = <String>{};
  final plannedSessionByDate = <String, int>{};
  for (final s in doneSessions) {
    final plannedDayId = plannedDayByDate[s.date];
    if (plannedDayId == null || s.planDayId == null) continue;
    if (s.planDayId != plannedDayId) continue;
    if (!completedPlannedDates.add(s.date)) continue;
    final id = s.id;
    if (id != null) plannedSessionByDate[s.date] = id;
  }
  // 计划内组数最多记到当日计划组数：计划 3 组做了 5 组时，多出的 2 组
  // 算「计划外正式组」，不能让计划完成度超过 100%，也不能掩盖其他计划日
  // 的组数缺口。
  var completedPlannedWorkingSets = 0;
  for (final e in plannedSessionByDate.entries) {
    final plannedSets = plannedSetsByDate[e.key] ?? 0;
    final doneSets = weekRows.where((r) => r.sessionId == e.value).length;
    completedPlannedWorkingSets += doneSets < plannedSets
        ? doneSets
        : plannedSets;
  }

  final today = fmtDate(now);
  var remaining = 0;
  for (final e in plannedEntries) {
    // 今天还没练的计划日算剩余。
    if (e.key.compareTo(today) >= 0 && !completedPlannedDates.contains(e.key)) {
      remaining++;
    }
  }

  // ---------- 低于目标的肌群 ----------
  final shortfalls = <RecapMuscleShortfall>[];
  for (final region in kMuscleRegions) {
    final target = kWeeklySetTargets[region];
    if (target == null) continue;
    final actual = weeklySets[region] ?? 0;
    if (actual < target.min) {
      shortfalls.add(
        RecapMuscleShortfall(
          muscle: region,
          sets: actual,
          targetMin: target.min,
          targetMax: target.max,
        ),
      );
    }
  }
  shortfalls.sort((a, b) {
    final byDeficit = b.deficit.compareTo(a.deficit);
    if (byDeficit != 0) return byDeficit;
    return kMuscleRegions
        .indexOf(a.muscle)
        .compareTo(kMuscleRegions.indexOf(b.muscle));
  });

  // ---------- 最近 7 天体重趋势（截至 now，含今天） ----------
  final weightEnd = DateTime(now.year, now.month, now.day);
  final weightStart = weightEnd.subtract(const Duration(days: 6));
  final weightStartDate = fmtDate(weightStart);
  final weightEndDate = fmtDate(weightEnd);
  final weightPoints = <RecapWeightPoint>[];
  for (final m in bodyMetrics) {
    final kg = m.weightKg;
    if (kg == null) continue;
    if (m.date.compareTo(weightStartDate) < 0 ||
        m.date.compareTo(weightEndDate) > 0) {
      continue;
    }
    weightPoints.add(RecapWeightPoint(m.date, kg));
  }
  weightPoints.sort((a, b) => a.date.compareTo(b.date));

  final action = _actionFor(
    plannedSessions: plannedSessions,
    completedSessions: doneSessions.length,
    completedPlannedSessions: completedPlannedDates.length,
    plannedWorkingSets: plannedWorkingSets,
    completedPlannedWorkingSets: completedPlannedWorkingSets,
    remaining: remaining,
    shortfalls: shortfalls,
    stalled: stalled,
    improved: improved,
  );

  return WeeklyRecap(
    weekStart: start,
    weekEnd: end,
    plannedSessions: plannedSessions,
    completedSessions: doneSessions.length,
    completedPlannedSessions: completedPlannedDates.length,
    plannedWorkingSets: plannedWorkingSets,
    completedWorkingSets: weekRows.length,
    completedPlannedWorkingSets: completedPlannedWorkingSets,
    remainingPlannedSessions: remaining,
    improvedExercises: improved,
    stalledExercises: stalled,
    underTargetMuscles: shortfalls,
    weeklySetsByMuscle: weeklySets,
    weightTrend: RecapWeightTrend(weightPoints),
    action: action,
  );
}

/// 一条可执行的下一步。优先级（先解决「没练够」，再谈优化）：
/// 1. 没计划 → 先排计划 / 说明计划为空；
/// 2. 本周还有剩余计划训练 → 先练完（即使一次没练也不说「下周」）；
/// 3. 计划日一次都没对上 → 先按计划的日子练；
/// 4. 完成次数少于计划 → 下周补次数；
/// 5. 次数够了但正式组没练够 → 下周把每组计划组数练满；
/// 6. 有肌群低于周组数下限 → 给它加组；
/// 7. 有动作停滞 → 同重量多冲 1 次，连续两周再减载/换变式；
/// 8. 有动作进步 → 下周继续加重；
/// 9. 全部达标 → 保持节奏。
String _actionFor({
  required int plannedSessions,
  required int completedSessions,
  required int completedPlannedSessions,
  required int plannedWorkingSets,
  required int completedPlannedWorkingSets,
  required int remaining,
  required List<RecapMuscleShortfall> shortfalls,
  required List<RecapExerciseChange> stalled,
  required List<RecapExerciseChange> improved,
}) {
  if (plannedSessions == 0) {
    if (completedSessions == 0) {
      return tx(
        '本周没有安排训练，也没有训练记录。下周先在计划页排几次训练，或直接开始一次自由训练。',
        en: 'No planned workouts and no sessions this week. Set up a few sessions on the Plan page next week, or start a free workout.',
      );
    }
    return tx(
      '本周练了 $completedSessions 次，但计划是空的。下周把训练日排进计划，复盘才有对照。',
      en: 'You trained $completedSessions times this week but have no plan. Schedule your training days next week so the recap has a baseline.',
    );
  }
  if (remaining > 0) {
    return tx(
      '本周还剩 $remaining 次计划训练，先把它们练完；已经错过的训练日，下周按计划补上。',
      en: '$remaining planned workouts are left this week — finish them first, and make up any missed training days next week.',
    );
  }
  if (completedPlannedSessions == 0) {
    if (completedSessions == 0) {
      return tx(
        '本周计划 $plannedSessions 次，一次也没练。下周先把第一次练出来，重量从上一次的 80% 起。',
        en: 'You planned $plannedSessions sessions this week but logged none. Get the first one in next week, starting at 80% of your last weights.',
      );
    }
    return tx(
      '本周练了 $completedSessions 次，但没有一次对上计划的训练日。下周按计划的日子练，计划才算完成。',
      en: 'You trained $completedSessions times this week, but none matched a planned training day. Train on the planned days next week so the plan counts.',
    );
  }
  if (completedPlannedSessions < plannedSessions) {
    final miss = plannedSessions - completedPlannedSessions;
    return tx(
      '本周完成 $completedPlannedSessions/$plannedSessions 次计划训练，差 $miss 次。下周先把训练次数补齐，再谈加量。',
      en: 'You completed $completedPlannedSessions/$plannedSessions planned workouts this week — $miss short. Close the gap next week before adding volume.',
    );
  }
  if (completedPlannedWorkingSets < plannedWorkingSets) {
    final miss = plannedWorkingSets - completedPlannedWorkingSets;
    return tx(
      '训练次数练够了，但正式组只完成 $completedPlannedWorkingSets/$plannedWorkingSets（少 $miss 组）。下周先把每组的计划组数练满。',
      en: 'You hit the planned sessions but completed $completedPlannedWorkingSets/$plannedWorkingSets working sets ($miss short). Finish the planned sets per session next week.',
    );
  }
  if (shortfalls.isNotEmpty) {
    final s = shortfalls.first;
    return tx(
      '下周给「${mname(s.muscle)}」加量：本周 ${_fmtSets(s.sets)} 组，目标至少 ${s.targetMin} 组，加一个动作或每组多做几组。',
      en: 'Add volume for ${mname(s.muscle)} next week: ${_fmtSets(s.sets)} sets this week vs a target of at least ${s.targetMin}. Add an exercise or a few sets.',
    );
  }
  if (stalled.isNotEmpty) {
    final s = stalled.first;
    final now = fmtWithUnit(s.best1Rm);
    final prev = fmtWithUnit(s.previousBest1Rm);
    final name = exname(s.name);
    return tx(
      '「$name」本周 1RM 没超过上周（$prev → $now）。下周先在同一重量上多冲 1 次；连续两周没进步，再减载 10% 或换变式。',
      en: '"$name" did not beat last week\'s 1RM ($prev → $now). Chase one more rep at the same weight next week; if it stays flat two weeks in a row, deload 10% or switch a variation.',
    );
  }
  if (improved.isNotEmpty) {
    final best = improved.first;
    final gain = fmtWithUnit(best.deltaKg.abs());
    final now = fmtWithUnit(best.best1Rm);
    final name = exname(best.name);
    return tx(
      '「$name」本周 1RM 提高了 $gain（到 $now）。下周按计划继续加重，把它放在训练日前面。',
      en: '"$name" gained $gain on estimated 1RM this week (now $now). Keep adding weight next week and put it early in the session.',
    );
  }
  return tx(
    '本周计划全部完成，肌群剂量也在目标内。下周保持节奏，主力动作按计划继续加重。',
    en: 'Plan completed and muscle targets are on point. Keep the rhythm next week and keep adding weight on your main lifts.',
  );
}

/// 组数展示：整数不带小数点，半组保留一位（与数据页 fmtSetDose 同规则）。
String _fmtSets(double sets) {
  final rounded = sets.roundToDouble();
  return (sets - rounded).abs() < 1e-9
      ? rounded.toStringAsFixed(0)
      : sets.toStringAsFixed(1);
}
