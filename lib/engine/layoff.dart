/// 停练回归降档（P1-D）：停练两周以上回来，先按 85% 找感觉。
///
/// 口径（2026-10-18）：
/// - 距上次 **done** 训练的自然日数 ≥ [kLayoffDaysThreshold]（14 天）时触发；
/// - 建议重量 = 当前工作重量 ×0.85，向下取整到 0.5kg 网格；
///   自重 0kg 保持 0；负重量（辅助配重）按绝对值 ×1.15（配重更负 =
///   辅助更多 = 实际负荷更小），与减载周的正重量方向一致；
/// - 正式组数 -1（最少 1 组，0/未知保持 0）；
/// - **与减载周不叠加**：两边同时命中时取更低的重量系数（0.85），
///   组数也只减 1 次；
/// - 回归场次与减载场一样不计入下次处方回溯，下一次间隔 <14 天自动
///   回到停练前的档位。
///
/// 纯 Dart 无 Flutter 依赖，可单测（test/layoff_test.dart）。
library;

import 'training_block.dart'
    show kDeloadWeightFactor, deloadWorkingSets;

/// 触发停练回归的天数阈值：≥14 天。
const int kLayoffDaysThreshold = 14;

/// 停练回归的重量系数（负荷比例）。
const double kLayoffWeightFactor = 0.85;

/// 距上次 done 训练的自然日数；[lastDoneDate] 为 yyyy-MM-dd。
/// 无记录/解析失败/未来日期一律返回 0（不触发）。
/// 用 UTC 自然日差，避开夏令时把 7 天算成 6 天的问题。
int layoffDaysSince(String? lastDoneDate, DateTime today) {
  if (lastDoneDate == null || lastDoneDate.isEmpty) return 0;
  final last = DateTime.tryParse(lastDoneDate);
  if (last == null) return 0;
  final a = DateTime.utc(last.year, last.month, last.day);
  final b = DateTime.utc(today.year, today.month, today.day);
  final diff = b.difference(a).inDays;
  return diff < 0 ? 0 : diff;
}

/// 是否达到停练回归阈值（含第 14 天当天）。
bool isLayoffAfter(String? lastDoneDate, DateTime today) =>
    layoffDaysSince(lastDoneDate, today) >= kLayoffDaysThreshold;

/// 按负荷比例 [factor] 下调当前工作重量，0.5kg 网格：
/// - 正重量**向下**取整（保证不超过 factor×，2.5kg 档不会四舍五入回原值）；
/// - 负重量（辅助配重）按 `abs × (2 - factor)` **向上**取整——0.85 负荷
///   = 辅助配重增加约 15%，更负 = 更省力；
/// - 0kg（自重档位）保持 0；正重量最低 0.5kg（0.5kg 已是最小片）。
double reducedWeightKg(double weightKg, double factor) {
  if (weightKg == 0) return 0;
  if (weightKg < 0) {
    final assist = 2 - factor;
    return -((weightKg.abs() * assist * 2).ceilToDouble() / 2);
  }
  final cut = (weightKg * factor * 2).floorToDouble() / 2;
  if (cut > 0) return cut;
  return weightKg < 0.5 ? weightKg : 0.5;
}

/// 停练回归建议重量：0.85×（口径见 [reducedWeightKg]）。
double layoffWeightKg(double weightKg) =>
    reducedWeightKg(weightKg, kLayoffWeightFactor);

/// 停练回归建议正式组数：-1，最少 1 组；0/未知保持 0。
/// 与减载周同一「少做 1 组」口径，两边同时命中只减一次。
int layoffWorkingSets(int plannedSets) => deloadWorkingSets(plannedSets);

/// 组合后的重量系数：停练回归与减载周不叠加，命中多个时取更低的
/// 一档（0.85 < 0.9）；都不命中返回 null。
double? recoveryWeightFactor({
  required bool layoff,
  required bool deload,
}) {
  if (layoff) return kLayoffWeightFactor;
  if (deload) return kDeloadWeightFactor;
  return null;
}
