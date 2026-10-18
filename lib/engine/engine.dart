import '../l10n/lang.dart';
import '../models/models.dart';
import 'logging_modes.dart';
import 'metrics.dart';
import 'training_block.dart';
import 'volume.dart';
import 'weight_unit.dart' show fmtWithUnit;

export '../models/models.dart';
export 'exercise_identity.dart';
export 'hr_calories.dart';
export 'hr_load.dart';
export 'layoff.dart';
export 'local_plan.dart';
export 'logging_modes.dart';
export 'metrics.dart';
export 'muscle_insights.dart';
export 'plates.dart';
export 'progression_chain.dart';
export 'recovery.dart';
export 'rest_rules.dart';
export 'stats_kpi.dart';
export 'training_block.dart';
export 'trends.dart';
export 'volume.dart';
export 'warmup.dart';
export 'weekly_recap.dart';
export 'workout_flow.dart';

/// 纯函数业务引擎：渐进超负荷判定、1RM、容量、肌肉分布。
/// 不依赖 Flutter，全部可单元测试。

/// 判定一次训练后某动作的渐进结果。
/// [workingSets] 本次训练该动作的正式组；[rule] 该动作的规则。
enum ProgressionAction { increase, hold, decrease }

class ProgressionVerdict {
  final ProgressionAction action;
  final double deltaKg;
  final String reason;

  const ProgressionVerdict(this.action, this.deltaKg, this.reason);
}

/// 旧引擎判定（与规则链 evaluateChain 的达标口径一致）。
/// [logging]（v14）：'time' 时链状态数字承载秒数，reason 文案把
/// 「X 次」表述换成「X 秒」，数字判定逻辑完全不变；缺省值保证
/// 现有调用行为不变。
ProgressionVerdict evaluateProgression({
  required List<SetEntry> workingSets,
  required double currentWeight,
  required ProgressionRule rule,
  String logging = LoggingMode.reps,
}) {
  // 计时形态（v14）：数字判定不变，仅 reason 文案「X 次」→「X 秒」
  final unit = logging == LoggingMode.time ? '秒' : '次';
  final ws = workingSets
      .where((s) => s.kind == SetKind.working)
      .toList(growable: false);
  if (ws.isEmpty) {
    return ProgressionVerdict(
        ProgressionAction.hold, 0, tx('本次无正式组记录，重量保持不变',
        en: 'No working sets logged this time — weight stays the same'));
  }
  // 只统计当前重量附近的正式组（重量波动 >5% 视为另一档）。
  // 负重量（辅助配重）下 5% 容差同样取绝对值，否则阈值变负、
  // 过滤恒为空 → 辅助器械动作永远判不出渐进。
  final near = ws
      .where((s) =>
          (s.weightKg - currentWeight).abs() <= currentWeight.abs() * 0.05)
      .toList(growable: false);
  if (near.isEmpty) {
    return ProgressionVerdict(
        ProgressionAction.hold, 0, tx('本次重量与历史档位不同，重量保持不变',
        en: 'Weight differs from your usual tier — weight stays the same'));
  }

  final allReachedMax = near.every((s) => s.reps >= rule.repsMax);
  final lastSet = near.last;
  final lastSetRirOk = lastSet.rir >= rule.rirTarget - 1; // 允许差 1 次余力
  final anyBelowMin = near.any((s) => s.reps < rule.repsMin);

  if (allReachedMax && lastSetRirOk) {
    return ProgressionVerdict(
        ProgressionAction.increase,
        rule.incrementKg,
        tx(
        // 建议文案随显示单位（2026-10-17）：kg 模式输出与旧版逐字节一致
        '${near.length} 组全部达到 ${rule.repsMax} $unit，末组余力 ${lastSet.rir} 次 → 下次加重 ${fmtWithUnit(rule.incrementKg)}',
        en:
            'All ${near.length} sets hit ${enRepPhrase(rule.repsMax, logging)}, last set RIR ${lastSet.rir} → add ${fmtWithUnit(rule.incrementKg)} next time'),
    );
  }
  if (anyBelowMin) {
    // 减重方向对负重量同样成立：delta 为负 = 正重量更轻 / 辅助配重更多
    final cut = -_round05(currentWeight.abs() * 0.05);
    return ProgressionVerdict(
      ProgressionAction.decrease,
      cut,
      tx('有组未达到下限 ${rule.repsMin} $unit → 建议减重约 5%（${fmtWithUnit(cut)}），先稳动作',
        en: 'Some sets missed the ${enRepPhrase(rule.repsMin, logging)} floor → reduce ~5% (${fmtWithUnit(cut)}) and re-groove the form'),
    );
  }
  return ProgressionVerdict(
      ProgressionAction.hold, 0, tx('完成情况在区间内 → 重量保持，继续冲${logging == LoggingMode.time ? '秒数' : '次数'}',
        en: 'Reps landed in range — hold weight and chase more ${logging == LoggingMode.time ? 'seconds' : 'reps'}'));
}

/// 0.5kg 步进取整（引擎与状态机共用）。
double round05(double v) => (v * 2).roundToDouble() / 2;

double _round05(double v) => round05(v);

/// 根据历史记录给出某动作的建议起始重量。
/// 规则：取"最后一次训练"（与末组时间差 <4 小时的组视为同一次训练）
/// → 应用渐进判定；无历史返回 null（由用户首填）。
/// [loadType]（v14）：'bodyweight' 时无论判定结果如何都返回 0.0——
/// 自重动作重量恒 0，渐进表达在次数/组数上（不走重量轴）。
double? recommendWeight({
  required List<SetEntry> historyWorkingSets,
  required ProgressionRule rule,
  String loadType = LoadMode.weighted,
}) {
  if (loadType == LoadMode.bodyweight) return 0.0;
  if (historyWorkingSets.isEmpty) return null;
  final last = historyWorkingSets.last;
  // 同一次训练的组时间相邻（训练总时长一般 <4 小时），
  // 不能用毫秒相等判断——每组 doneAt 至少差 1ms。
  const sessionWindowMs = 4 * 3600 * 1000;
  final sameSession = historyWorkingSets
      .where((s) => last.doneAt - s.doneAt < sessionWindowMs && s.doneAt >= last.doneAt - sessionWindowMs)
      .toList();
  final v = evaluateProgression(
    workingSets: sameSession,
    currentWeight: last.weightKg,
    rule: rule,
  );
  final next = last.weightKg + v.deltaKg;
  return next > 0 ? _round05(next) : _round05(last.weightKg);
}

/// 按动作类型给默认休息秒数。
int defaultRestSec(String kind, {int? compound, int? assistance}) {
  if (kind == 'compound') return compound ?? 180;
  return assistance ?? 120;
}

/// 汇总一次训练的指标。
class SessionStats {
  final double volume;
  final int totalSets;
  final int workingSets;
  final int reps;
  final List<String> exercises;

  const SessionStats({
    required this.volume,
    required this.totalSets,
    required this.workingSets,
    required this.reps,
    required this.exercises,
  });
}

SessionStats sessionStatsFrom(
    Map<int, List<SetEntry>> setsByExercise, List<SessionExercise> order,
    {double bodyWeightKg = 0}) {
  var volume = 0.0, total = 0, working = 0, reps = 0;
  final names = <String>[];
  for (final se in order) {
    final sets = setsByExercise[se.id] ?? const <SetEntry>[];
    if (sets.isEmpty) continue;
    names.add(se.name);
    for (final s in sets) {
      total++;
      if (s.kind == SetKind.working) {
        working++;
        reps += s.reps;
        // bodyWeightKg > 0 时自重动作按 系数×体重 折算进容量（点名条目二）；
        // 不传体重时维持旧口径（自重记 0），调用点不传则行为不变。
        volume += bodyWeightKg > 0
            ? setVolumeWithBodyweight(s,
                exerciseName: se.name, bodyWeightKg: bodyWeightKg)
            : s.volume;
      }
    }
  }
  return SessionStats(
      volume: volume,
      totalSets: total,
      workingSets: working,
      reps: reps,
      exercises: names);
}

/// 周内各肌群正式组容量占比（0-1）。
/// 入参为 (动作名, 该动作本周正式组) 的列表。
/// bodyWeightKg > 0 时自重动作按 系数×体重 折算（点名条目二）。
Map<String, double> muscleLoadShare(
    List<MapEntry<String, List<SetEntry>>> weekWorkingByName,
    Map<String, ExerciseMeta> metaByName,
    {double bodyWeightKg = 0}) {
  final load = <String, double>{};
  for (final r in kMuscleRegions) {
    load[r] = 0;
  }
  for (final entry in weekWorkingByName) {
    final meta = metaByName[entry.key];
    final main = meta?.muscles.main ?? '其他';
    for (final s in entry.value) {
      load[main] = (load[main] ?? 0) +
          (bodyWeightKg > 0
              ? setVolumeWithBodyweight(s,
                  exerciseName: entry.key, bodyWeightKg: bodyWeightKg)
              : s.volume);
    }
  }
  final total = load.values.fold(0.0, (a, b) => a + b);
  if (total <= 0) return load;
  return load.map((k, v) => MapEntry(k, v / total));
}

/// PR 检测：本次组是否超过历史最佳重量。
bool isPrWeight(double weight, List<SetEntry> historyBefore) {
  if (historyBefore.isEmpty) return false;
  final best =
      historyBefore.fold(0.0, (m, s) => s.weightKg > m ? s.weightKg : m);
  return weight > best + 0.01;
}

/// 平台期提醒数据（2026-09-26 Arono：薄肌渐进超负荷要主动提示，
/// 同一动作在同一重量停留过久时，训练中途提醒"可以加重了"）。
class PlateauInfo {
  /// 停滞中的重量（各次训练的最大正式组重量）。
  final double weightKg;

  /// 连续停留在这个重量上的训练次数。
  final int sessions;

  /// 从第一次用这个重量到最近一次的天数跨度。
  final int days;

  /// 最近一次训练在该重量的组里是否已把次数做到目标上限
  /// （是 → 可直接加重；否 → 次数冲到顶就该加重）。
  /// 只统计"顶格重量"的组：轻重量退让组做到再多也不算到顶。
  final bool hitTop;

  const PlateauInfo(
      this.weightKg, this.sessions, this.days, this.hitTop);
}

/// 平台期判定：同一动作按训练（sessionExerciseId 分组）取各次的
/// 最大正式组重量，从最近往回数连续停留在同一重量的次数与天数。
/// 阈值（薄肌渐进的"两周或几次"口径）：连续 ≥3 次，或 ≥2 次且跨度
/// ≥12 天。不满足返回 null。传入的 history 应为该动作全部历史
/// **正式组**（working，时间升序，即 SessionController.historyBefore）。
PlateauInfo? plateauOf(List<SetEntry> history, {required int repsMax}) {
  if (history.isEmpty) return null;
  // 按训练分组（history 升序、同训练的行相邻）；
  // topReps = 该次训练在"顶格重量"上的最好次数（轻于顶格的组不计入）
  final ids = <int>[];
  final tops = <double>[];
  final topReps = <int>[];
  final firstAt = <int>[];
  final lastAt = <int>[];
  for (final s in history) {
    if (ids.isNotEmpty && ids.last == s.sessionExerciseId) {
      final i = ids.length - 1;
      if (s.weightKg > tops[i] + 0.01) {
        tops[i] = s.weightKg;
        topReps[i] = s.reps;
      } else if ((s.weightKg - tops[i]).abs() <= 0.01 &&
          s.reps > topReps[i]) {
        topReps[i] = s.reps;
      }
      lastAt[i] = s.doneAt;
    } else {
      ids.add(s.sessionExerciseId);
      tops.add(s.weightKg);
      topReps.add(s.reps);
      firstAt.add(s.doneAt);
      lastAt.add(s.doneAt);
    }
  }
  // 从最近往回数同一重量的连续训练次数（±0.01kg 容差）
  final w = tops.last;
  var streak = 0;
  var streakFirstAt = firstAt.last;
  for (var i = ids.length - 1; i >= 0; i--) {
    if ((tops[i] - w).abs() > 0.01) break;
    streak++;
    streakFirstAt = firstAt[i];
  }
  final days = ((lastAt.last - streakFirstAt) / 86400000).round();
  if (streak < 3 && !(streak >= 2 && days >= 12)) return null;
  return PlateauInfo(w, streak, days, topReps.last >= repsMax);
}

/// 停滞协议决策（P1-C）：平台期不再只说「继续冲」，而是给出下一步。
///
/// - 连续 ≥3 次同重量且**未顶格** → `reduce`：建议减载 10% 或换变式
///   （自重 0kg 无法减重，只建议换变式；负重量按辅助配重 +10% 方向处理）；
/// - 已顶格 → `add`：保留加重建议（次数到顶不是停滞，是该加重量了）。
///   已顶格优先于次数门槛：2 次/≥12 天的平台期只要顶格也走 `add`；
/// - 2 次但跨度 ≥12 天且**未顶格**、或没有平台期 → `none`
///   （维持原有「冲次数」提醒，不提前减载）。
class PlateauProtocol {
  /// 'reduce'（减载/换变式）/ 'add'（加重）/ 'none'（不触发协议）
  final String action;

  /// 协议建议的下一次重量（kg）；`none` 时为 0。
  final double suggestedWeightKg;

  /// 面向用户的一句话原因 + 下一步（中英由 tx 解析）。
  final String reason;

  const PlateauProtocol(this.action, this.suggestedWeightKg, this.reason);
}

/// 平台期 → 停滞协议。`historyBefore` 里没有平台期时传 null，返回 `none`。
/// [logging] 只影响文案单位（计时动作把「次」说成「秒」）；
/// [loadType] = bodyweight 时不做减重（0kg 档位没有重量可减）。
PlateauProtocol plateauProtocolOf(
  PlateauInfo? info, {
  required ProgressionRule rule,
  String logging = LoggingMode.reps,
  String loadType = LoadMode.weighted,
}) {
  if (info == null) {
    return const PlateauProtocol('none', 0, '');
  }
  final timed = logging == LoggingMode.time;
  final unit = timed ? '秒' : '次';
  final enUnit = timed ? 's' : 'reps';
  // 「次数」在计时动作里是「秒数」：文案别把平板支撑说成次数。
  final repWord = timed ? '秒数' : '次数';
  final w = fmtWithUnit(info.weightKg);
  final stuck = tx(
    '连续 ${info.sessions} 次 · ${info.days} 天停在 $w',
    en: '${info.sessions} sessions / ${info.days} days at $w',
  );
  if (info.hitTop) {
    // 自重动作的渐进表达是「加组」而不是加重（与 chainTargetWhy 同口径）；
    // 0kg 档位没有重量可加。
    if (loadType == LoadMode.bodyweight) {
      return PlateauProtocol(
        'add',
        0,
        tx(
          '$stuck，但$repWord已到 ${rule.repsMax} $unit上限 → 下次加练一组'
          '（原因：自重动作$repWord顶格，渐进靠加组）',
          en:
              '$stuck, but $enUnit already hit the ${rule.repsMax} cap → add one extra set next time'
              ' (reason: bodyweight progresses by adding sets)',
        ),
      );
    }
    final next = round05(info.weightKg + rule.incrementKg);
    return PlateauProtocol(
      'add',
      next,
      tx(
        '$stuck，但$repWord已到 ${rule.repsMax} $unit上限 → 继续加重到 ${fmtWithUnit(next)}'
        '（原因：$repWord顶格不是练不动，是重量该加了）',
        en:
            '$stuck, but $enUnit already hit the ${rule.repsMax} cap → add weight to ${fmtWithUnit(next)}'
            ' (reason: capped reps means it is time to load, not a stall)',
      ),
    );
  }
  // 2 次/≥12 天的老口径平台期（未顶格）：先按原有「冲次数」提醒，
  // 不提前减载；已顶格在上面已经走 add。
  if (info.sessions < 3) {
    return const PlateauProtocol('none', 0, '');
  }
  if (loadType == LoadMode.bodyweight || info.weightKg == 0) {
    return PlateauProtocol(
      'reduce',
      0,
      tx(
        '$stuck 且$repWord未到 ${rule.repsMax} $unit上限 → 建议换一个变式（自重动作没有重量可减），打破停滞',
        en:
            '$stuck without reaching the ${rule.repsMax}-$enUnit cap → switch to a variation'
            ' (bodyweight has no load to cut) to break the plateau',
      ),
    );
  }
  final cut = deloadWeightKg(info.weightKg);
  return PlateauProtocol(
    'reduce',
    cut,
    tx(
      '$stuck 且$repWord未到 ${rule.repsMax} $unit上限 → 建议减载 10%（约 ${fmtWithUnit(cut)}）'
      '或换一个变式，打破停滞',
      en:
          '$stuck without reaching the ${rule.repsMax}-$enUnit cap → cut ~10%'
          ' (about ${fmtWithUnit(cut)}) or switch to a variation to break the plateau',
    ),
  );
}

/// 忘停表守护（2026-09-26 Arono）：会话时长是否可疑。
/// 判据（调研 workout-timer 口径，只提示不自动改）：
/// - 一组没记且已挂机 30 分钟以上 → 开了训练走开了，基本是忘停；
/// - 有记录且总时长 ≥45 分钟但组均超过 15 分钟 → 练完后挂着没停表。
/// 正常大容量日（组均 <15 分钟）不会误伤。
bool isSuspiciousSessionDuration({
  required int startedAtMs,
  required int nowMs,
  required int setCount,
}) {
  if (nowMs <= startedAtMs) return false;
  final wallMin = (nowMs - startedAtMs) / 60000;
  if (setCount == 0) return wallMin >= 30;
  return wallMin >= 45 && wallMin / setCount > 15;
}
