import '../l10n/lang.dart';
import 'engine.dart';

/// 数据页统计升级（openGym 统计设计借鉴，2026-10-17）：
/// - 概览 KPI 四件套（总次数/本月次数/连续周/30 天体重 Δ）
/// - 近 12 个月 GitHub 风格活动热力图（时长/容量双口径）
/// - 余力（RIR）分布直方图 + 一句话解读
/// - 1RM 卡「顶组」口径：动作 → 训练日 → 当日最大正式组重量

// ---------------- 概览 KPI ----------------

/// 概览页顶部 KPI 四件套。
/// [weightDelta30d] 为 null = 体重数据不足以算 30 天变化（UI 显「—」）。
class StatsKpi {
  final int totalSessions;
  final int thisMonth;

  /// 连续训练周数：从本周（本周还没练则从上周）向前数
  /// 连续「有 ≥1 次 done 训练」的自然周数。
  final int weekStreak;

  /// 最近一条体重 − 30 天前（含）最近一条体重；正 = 涨、负 = 降。
  final double? weightDelta30d;

  const StatsKpi({
    required this.totalSessions,
    required this.thisMonth,
    required this.weekStreak,
    required this.weightDelta30d,
  });
}

/// 统计口径只认 status == 'done' 的 Session。
/// [weightGoalKg] 不参与 Δ 数值计算（Δ 恒为原始差值），
/// 颜色语义（朝目标/背离）由 UI 结合目标自行判定。
StatsKpi computeStatsKpi({
  required List<Session> sessions,
  required List<BodyMetric> bodyMetrics,
  required DateTime now,
  double? weightGoalKg,
}) {
  final done = sessions.where((s) => s.status == 'done').toList();
  final total = done.length;
  final thisMonth = done.where((s) {
    final d = parseDate(s.date);
    return d.year == now.year && d.month == now.month;
  }).length;

  // 连续周：有训练的自然周集合（键 = 该周周一的 epoch 天数）
  final doneWeeks = <int>{
    for (final s in done)
      mondayOf(parseDate(s.date)).millisecondsSinceEpoch ~/ 86400000
  };
  final today = DateTime(now.year, now.month, now.day);
  var cursor = mondayOf(today);
  // 本周还没练不断链：从上周开始数
  if (!doneWeeks.contains(cursor.millisecondsSinceEpoch ~/ 86400000)) {
    cursor = cursor.subtract(const Duration(days: 7));
  }
  var streak = 0;
  while (doneWeeks.contains(cursor.millisecondsSinceEpoch ~/ 86400000)) {
    streak++;
    cursor = cursor.subtract(const Duration(days: 7));
  }

  // 30 天体重 Δ：最近一条体重 − 30 天前（含）最近一条体重
  final weights = bodyMetrics.where((m) => m.weightKg != null).toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  double? delta;
  if (weights.length >= 2) {
    final latest = weights.last;
    final cutoff =
        fmtDate(parseDate(latest.date).subtract(const Duration(days: 30)));
    for (final m in weights.reversed) {
      if (m.date.compareTo(cutoff) <= 0) {
        delta = latest.weightKg! - m.weightKg!;
        break;
      }
    }
  }
  return StatsKpi(
    totalSessions: total,
    thisMonth: thisMonth,
    weekStreak: streak,
    weightDelta30d: delta,
  );
}

// ---------------- 活动热力图 ----------------

/// 近 N 周活动格网（GitHub 风格）：外层 = 周（旧→新），内层 = 周一..周日。
/// - 时长口径（byVolume=false）：格值 = 当日训练时长分钟
///   (activeMs+restMs)/60000，为 0 回退 (endedAt-startedAt)/60000，
///   再为 0 按该日组数 ×4 分钟估（[setCountsByDate] 提供每日组数）。
/// - 容量口径（byVolume=true）：格值 = 当日正式组 volume 之和
///   （[volumeByDate] 提供每日容量，键 yyyy-MM-dd，由调用方按
///   SetEntry.volume 预聚合）。
/// 网格从「第一次训练所在周」与「[weeks] 周前」较晚者开始
/// （新用户不铺满 53 列空格）；无训练时为 [weeks] 列全零。
List<List<double>> activityHeatmap({
  required List<Session> sessions,
  required DateTime now,
  int weeks = 53,
  required bool byVolume,
  Map<String, double>? volumeByDate,
  Map<String, int>? setCountsByDate,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final endMonday = mondayOf(today);
  final floorMonday = endMonday.subtract(Duration(days: 7 * (weeks - 1)));
  // 起始周 = max(第一次训练所在周, weeks 周前)
  DateTime? firstMonday;
  for (final s in sessions) {
    if (s.status != 'done') continue;
    final m = mondayOf(parseDate(s.date));
    if (firstMonday == null || m.isBefore(firstMonday)) firstMonday = m;
  }
  final startMonday = firstMonday == null || firstMonday.isBefore(floorMonday)
      ? floorMonday
      : firstMonday;
  final colCount = endMonday.difference(startMonday).inDays ~/ 7 + 1;
  final grid = [
    for (var i = 0; i < colCount; i++) List.filled(7, 0.0),
  ];

  // 日期 → 格网坐标
  void addAt(DateTime day, double value) {
    final idx = DateTime(day.year, day.month, day.day)
        .difference(startMonday)
        .inDays;
    if (idx < 0 || idx >= colCount * 7) return;
    grid[idx ~/ 7][idx % 7] += value;
  }

  if (byVolume) {
    if (volumeByDate != null) {
      for (final e in volumeByDate.entries) {
        if (e.value > 0) addAt(parseDate(e.key), e.value);
      }
    }
  } else {
    for (final s in sessions) {
      if (s.status != 'done') continue;
      var minutes = (s.activeMs + s.restMs) / 60000.0;
      if (minutes <= 0 && s.endedAt != null) {
        minutes = (s.endedAt! - s.startedAt) / 60000.0;
      }
      if (minutes <= 0) {
        minutes = (setCountsByDate?[s.date] ?? 0) * 4.0;
      }
      if (minutes > 0) addAt(parseDate(s.date), minutes);
    }
  }
  return grid;
}

/// 格色 5 档（0 空 / 1 低 / 2 中 / 3 高 / 4 顶）：
/// 0 = 当日无活动；1-4 按「当周合计值」在正数周合计中的四分位分档
/// （同一周内有活动的日子共享该周的档位，周的训练量大小一眼可比）。
List<List<int>> activityLevels(List<List<double>> grid) {
  final weekTotals = [for (final w in grid) w.fold(0.0, (a, b) => a + b)];
  final positive = weekTotals.where((t) => t > 0).toList()..sort();
  if (positive.isEmpty) {
    return [for (final w in grid) List.filled(w.length, 0)];
  }
  double quantile(double p) {
    final pos = p * (positive.length - 1);
    final lo = pos.floor();
    final hi = pos.ceil();
    final frac = pos - lo;
    return positive[lo] + (positive[hi] - positive[lo]) * frac;
  }

  final t1 = quantile(0.25);
  final t2 = quantile(0.5);
  final t3 = quantile(0.75);
  return [
    for (var w = 0; w < grid.length; w++)
      [
        for (var d = 0; d < grid[w].length; d++)
          if (grid[w][d] <= 0 || weekTotals[w] <= 0)
            0
          else if (weekTotals[w] <= t1)
            1
          else if (weekTotals[w] <= t2)
            2
          else if (weekTotals[w] <= t3)
            3
          else
            4,
      ],
  ];
}

// ---------------- 余力（RIR）分布 ----------------

/// 正式组 RIR 直方图：键 = 桶 0..5（5 含 5+），值 = 组数。
/// 非 working 组一律不计；[since] 给定时只统计 doneAt ≥ 该时刻的组。
Map<int, int> rirDistribution(List<SetEntry> workingSets, {DateTime? since}) {
  final dist = {for (var i = 0; i <= 5; i++) i: 0};
  final sinceMs = since?.millisecondsSinceEpoch;
  for (final s in workingSets) {
    if (s.kind != SetKind.working) continue;
    if (sinceMs != null && s.doneAt < sinceMs) continue;
    final r = s.rir <= 0 ? 0 : (s.rir >= 5 ? 5 : s.rir);
    dist[r] = dist[r]! + 1;
  }
  return dist;
}

/// 依据分布给一句话解读（双语）：
/// 多数组落在 1-2 → 接近力竭，刺激到位；多数 ≥3 → 留力偏多；
/// 多数直接 0 → 力竭频繁；无多数 → 中性一句。
String rirInsightLine(Map<int, int> dist) {
  final total = dist.values.fold(0, (a, b) => a + b);
  if (total == 0) {
    return tx('记几组之后，这里解读你的余力分布',
        en: 'Log a few sets to see your RIR breakdown');
  }
  final s0 = dist[0] ?? 0;
  final s12 = (dist[1] ?? 0) + (dist[2] ?? 0);
  final s3p = (dist[3] ?? 0) + (dist[4] ?? 0) + (dist[5] ?? 0);
  if (s12 / total >= 0.5) {
    return tx('多数组落在 1-2 次余力：接近力竭，增肌刺激到位',
        en: 'Most sets land at 1-2 reps in reserve — close to failure, growth stimulus on point');
  }
  if (s3p / total >= 0.5) {
    return tx('多数组余力 ≥3：留力偏多，可以再冲一点',
        en: 'Most sets keep 3+ reps in reserve — you have more in the tank, push a bit harder');
  }
  if (s0 / total >= 0.5) {
    return tx('多数组直接力竭：刺激够猛，注意动作安全与恢复',
        en: 'Most sets go straight to failure — strong stimulus, watch form and recovery');
  }
  return tx('深浅组搭配，训练强度有节奏',
      en: 'A mix of hard and easy sets — intensity has a good rhythm');
}

// ---------------- 顶组（当日最大正式组重量） ----------------

/// 「顶组」口径累计器（与 DailyBest1Rm 同构）：
/// 动作名 → 训练日（epoch 天）→ 当日最大正式组重量（kg）。
class DailyTopSet {
  final Map<String, Map<int, double>> byExercise = <String, Map<int, double>>{};

  void add(String exerciseName, DateTime date, double weightKg) {
    final dayKey =
        DateTime(date.year, date.month, date.day).millisecondsSinceEpoch ~/
            86400000;
    final byDate = byExercise.putIfAbsent(exerciseName, () => <int, double>{});
    if (weightKg > (byDate[dayKey] ?? double.negativeInfinity)) {
      byDate[dayKey] = weightKg;
    }
  }
}
