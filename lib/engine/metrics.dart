/// 引擎层共享的基础度量与日期工具。
///
/// 这些函数原本定义在 `engine.dart` 里，但 `weekly_recap.dart` 与
/// `muscle_insights.dart` 也需要它们；抽到独立文件后，各引擎模块可以
/// 直接依赖这里，避免通过 `engine.dart` 互相绕成导入环。
library;

/// 1RM 估算分公式（调研报告点名条目，docs/open-source-research-2026-09-25.md
/// 「1RM 分公式（LibreFit，仅参考）」的保守口径；公式本体为公开运动科学公式，
/// 不涉及 LibreFit 的 GPL 代码）：
/// - 1 次：直接取实际完成重量（实测即真值）；
/// - 2-5 次：Epley，w × (1 + reps/30)；
/// - 6 次及以上：Epley 与 Brzycki（w × 36/(37-reps)）的平均——
///   Epley 在高次数端偏乐观、Brzycki 偏保守，取平均得到更稳的估计。
double estimate1RM(double weight, int reps) {
  if (reps <= 0 || weight <= 0) return 0;
  if (reps == 1) return weight;
  final epley = weight * (1 + reps / 30.0);
  if (reps <= 5) return epley;
  final denom = 37 - reps;
  // 37 次及以上 Brzycki 分母非正、公式失效，退回 Epley（该次数档已远离力量区间）。
  if (denom <= 0) return epley;
  final brzycki = weight * 36 / denom;
  return (epley + brzycki) / 2;
}

/// 肌肉群清单（热力图分区）。
const kMuscleRegions = ['胸', '肩', '背', '手臂', '腿', '核心', '其他'];

DateTime parseDate(String d) {
  final p = d.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

String fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 本周一的日期。
DateTime mondayOf(DateTime d) {
  final wd = d.weekday; // 1=Mon
  return DateTime(d.year, d.month, d.day).subtract(Duration(days: wd - 1));
}
