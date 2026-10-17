import 'hr_load.dart';

/// 训练卡路里估算（2026-10-17 Arono：有心率后顺手给消耗数，但力量
/// 训练不能照搬跑表口径）。
///
/// 依据与口径：
/// 1. 基础方程 Keytel et al. 2005（115 人间接测热法标定），由心率/
///    体重/年龄回归 kJ/min，÷4.184 得 kcal/min；性别未知取两式均值。
/// 2. 抗阻修正：力量中心率与摄氧解耦（等长收缩、瓦式呼吸、组间居高），
///    手表类心率消耗在抗阻中普遍高估（2026 年效度研究 ICC 0.02-0.03），
///    积分结果乘 0.82 修正系数。
/// 3. EPOC（练后过量氧耗）：大重量抗阻实测约 50 kcal、持续数小时
///    （~10.6 L O₂）。不按心率积分，用高区间（Z4/Z5）时长粗估：
///    基数 6 + Z4 每分钟 2 + Z5 每分钟 2.5，钳 0..70。
/// 4. 按采样真实时间戳加权（BLE 掉线断档不计时）；逐分钟消耗钳在
///    静息地板（1 MET ≈ 0.0175×体重 kcal/min）之上，防低心率出负值。

enum HrSex { unset, male, female }

class HrCalorieResult {
  const HrCalorieResult(this.activeKcal, this.epocKcal);

  /// 训练进行中消耗（含组间休息，已乘抗阻修正系数）。
  final double activeKcal;

  /// 练后过量氧耗（EPOC）估算。
  final double epocKcal;

  /// 总消耗 = 训练中 + 练后。
  double get totalKcal => activeKcal + epocKcal;
}

/// 抗阻训练修正系数（有氧心率回归直接用于力量训练偏高）。
const double kResistanceFactor = 0.82;

/// Keytel 方程：即时速率 kcal/min（未做抗阻修正；暴露为公开纯函数
/// 便于单测与复用）。
double keyTelKcalPerMin(int hr, double weightKg, int age, HrSex sex) {
  final male =
      (-55.0969 + 0.6309 * hr + 0.1988 * weightKg + 0.2017 * age) / 4.184;
  final female =
      (-20.4022 + 0.4472 * hr - 0.1263 * weightKg + 0.0746 * age) / 4.184;
  return switch (sex) {
    HrSex.male => male,
    HrSex.female => female,
    HrSex.unset => (male + female) / 2,
  };
}

/// 由心率采样估算一场训练的消耗。[z4Sec]/[z5Sec] 来自
/// computeHrLoad 的区间停留秒数，用于 EPOC 估算。
HrCalorieResult computeHrCalories(
  List<HrSample> samples, {
  required double bodyWeightKg,
  required int age,
  required HrSex sex,
  int z4Sec = 0,
  int z5Sec = 0,
}) {
  if (samples.isEmpty) return const HrCalorieResult(0, 0);
  final effAge = age > 0 ? age : 30;
  final effWeight = bodyWeightKg > 20 ? bodyWeightKg : 70.0;
  // 静息地板 1 MET：kcal/min ≈ 3.5 mL/kg/min × 体重 × 5 kcal/L O₂
  final floor = 0.0175 * effWeight;
  var rawKcal = 0.0;
  int? prevTs;
  for (final s in samples) {
    // 首条按 1 秒计；后续按与上一条的真实间隔（掉线空洞封顶 10 秒，
    // 避免重连后一条采样背上几分钟的账）；时钟乱序的点忽略。
    final dt = prevTs == null
        ? 1.0
        : ((s.ts - prevTs) / 1000.0).clamp(0.0, 10.0);
    prevTs = s.ts;
    if (dt <= 0) continue;
    final rate = keyTelKcalPerMin(s.bpm, effWeight, effAge, sex);
    rawKcal += rate.clamp(floor, 40.0) * dt / 60.0;
  }
  final active = rawKcal * kResistanceFactor;
  final epoc =
      (6.0 + z4Sec / 60.0 * 2.0 + z5Sec / 60.0 * 2.5).clamp(0.0, 70.0);
  return HrCalorieResult(active, epoc);
}
