/// 训练块与减载（P1-C）：把「线性加重一直冲」变成有周期、有出口的计划。
///
/// 口径（2026-10-18）：
/// - 块起点 = 当前计划第一次 **done** 训练（`Db.firstDoneSessionDateOfPlan`）；
/// - 默认 5 周一块，第 5 周为减载周；块长可在设置里改，0 = 关闭；
/// - 减载周建议重量 0.9×、正式组数 -1（最少 1 组）；
/// - 减载周之外仍是原规则链（线性加重/保持/减重 5%）。
///
/// 纯 Dart 无 Flutter 依赖，块周/减载调整可单测（test/training_block_test.dart）。
library;

/// 默认块长（周）：5 周一块，第 5 周减载。
const int kDefaultTrainingBlockWeeks = 5;

/// 减载周的重量系数（负荷比例）：0.9×。
const double kDeloadWeightFactor = 0.9;

/// 块内周次（1 起）。[blockWeeks] <= 0 或 [blockStart] 为空 → null（关闭）。
///
/// 每 [blockWeeks] 周循环一次：第 1 周从块起点当天开始，第 N 周是减载周；
/// 减载周结束后的下周回到第 1 周，开始下一块。
/// 用 UTC 日期差计算，避开夏令时把 7 天算成 6 天的问题。
int? trainingBlockWeekOf({
  required DateTime? blockStart,
  required DateTime date,
  required int blockWeeks,
}) {
  if (blockWeeks <= 0 || blockStart == null) return null;
  final start = DateTime.utc(
    blockStart.year,
    blockStart.month,
    blockStart.day,
  );
  final day = DateTime.utc(date.year, date.month, date.day);
  final diff = day.difference(start).inDays;
  // 计划还没开始（块起点在未来，通常是手动改过日期/时区边界）按第 1 周
  if (diff < 0) return 1;
  return diff ~/ 7 % blockWeeks + 1;
}

/// 是否减载周：块内第 [blockWeeks] 周。关闭（blockWeeks <= 0）恒为 false。
bool isDeloadWeekOf({
  required DateTime? blockStart,
  required DateTime date,
  required int blockWeeks,
}) {
  if (blockWeeks <= 0) return false;
  return trainingBlockWeekOf(
        blockStart: blockStart,
        date: date,
        blockWeeks: blockWeeks,
      ) ==
      blockWeeks;
}

/// 减载周建议重量：0.9×，**向下**取整到 0.5kg 网格——保证结果不超过
/// 0.9×（就近取整会让 2.5kg 档的 2.25 变成 2.5，等于没减）。
/// - 0kg（自重档位）保持 0——减载表达在组数上，不把自重改成负重量；
/// - 负重量（辅助器械配重）按绝对值 ×1.1 后**向上**取整（更负 = 辅助
///   更多 = 实际负荷更小，方向与正重量 ×0.9 一致）；
/// - 正重量最低 0.5kg：2.5kg → 2.0kg；0.5kg 已是最小片，保持 0.5kg。
double deloadWeightKg(double weightKg) {
  if (weightKg == 0) return 0;
  if (weightKg < 0) {
    final assist = 2 - kDeloadWeightFactor;
    return -((weightKg.abs() * assist * 2).ceilToDouble() / 2);
  }
  final cut =
      (weightKg * kDeloadWeightFactor * 2).floorToDouble() / 2;
  if (cut > 0) return cut;
  return weightKg < 0.5 ? weightKg : 0.5;
}

/// 减载周建议正式组数：-1，最少 1 组；计划组数为 0/未知时保持 0
/// （不凭空造 1 组——消费端会回退 rule.workingSets）。
int deloadWorkingSets(int plannedSets) {
  if (plannedSets <= 0) return 0;
  return plannedSets <= 1 ? 1 : plannedSets - 1;
}
