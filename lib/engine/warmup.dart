/// 热身建议（P2-A）：首次训练不再冷身直接上正式组。
/// 纯计算、只给建议——不落库、不自动生成热身组，展示层自己决定怎么画。
library;

import 'plates.dart' show kStandardBarKg;
import 'weight_unit.dart' show kLbBar, kgToLb, lbToKg;

/// 热身建议档位：
/// - [none]：不进热身（辅助配重这类负重量没有正重量口径）；
/// - [bodyweight]：自重/弹力带，给「一组慢速标准动作」的简化建议；
/// - [light]：正式重量 ≤40kg，简化为 40%/60% 两档（杠铃另加空杆）；
/// - [standard]：40%/60%/80% 三档，杠铃另加空杆。
enum WarmupMode { none, bodyweight, light, standard }

/// 热身阶梯的一步（kg，含杆）。
class WarmupStep {
  const WarmupStep(this.weightKg, this.reps, {this.percent});

  final double weightKg;
  final int reps;

  /// 百分比来源（40/60/80）；null = 空杆步。
  final int? percent;

  @override
  String toString() =>
      'WarmupStep(${percent == null ? 'bar' : '$percent%'}: '
      '${weightKg}kg × $reps)';

  @override
  bool operator ==(Object other) =>
      other is WarmupStep &&
      other.weightKg == weightKg &&
      other.reps == reps &&
      other.percent == percent;

  @override
  int get hashCode => Object.hash(weightKg, reps, percent);
}

/// 一次热身建议：档位 + 阶梯（bodyweight 档位没有重量阶梯）。
class WarmupPlan {
  const WarmupPlan(this.mode, this.steps);

  const WarmupPlan.none()
    : mode = WarmupMode.none,
      steps = const <WarmupStep>[];

  final WarmupMode mode;
  final List<WarmupStep> steps;

  bool get hasSteps => steps.isNotEmpty;
}

/// 正式重量 [targetWeightKg]（kg，含杆；0=自重，负=辅助配重）对应的热身建议。
/// [gear] 为动作库的细分器械中文键（'杠铃' 才加空杆步）。
/// [useLb]：按 lb 显示口径取整——空杆 45lb、杠铃 5lb 网格、其他器械
/// 2.5lb 网格，避免出现挂不出来的 44lb/60.5lb。
/// [barKgOverride]：具体器械的空杆重量（如 EZ 杠 10kg）；null = 标准奥杆。
///
/// 规则（与验收口径一致）：
/// - ≤40kg：40%×5、60%×3（简化版）；
/// - >40kg：40%×5、60%×3、80%×1；
/// - 杠铃只要正式重量不低于空杆（lb 制允许 1lb 显示取整差），就先做空杆×5；
/// - 自重/弹力带：不给重量，只提示 1 组慢速标准动作；
/// - 辅助配重（负值）：不提示（负值语义是辅助越大越省力）。
WarmupPlan warmupPlanFor({
  required double targetWeightKg,
  String gear = '',
  bool useLb = false,
  double? barKgOverride,
}) {
  if (targetWeightKg.isNaN || targetWeightKg.isInfinite) {
    return const WarmupPlan.none();
  }
  if (targetWeightKg < 0) return const WarmupPlan.none();
  if (targetWeightKg == 0) {
    return const WarmupPlan(WarmupMode.bodyweight, <WarmupStep>[]);
  }

  final barbell = gear == '杠铃';
  // 空杆口径随显示单位：kg 标准奥杆 20kg，lb 美制 45lb（与挂片提示同源）。
  final barKg = barKgOverride ?? (useLb ? lbToKg(kLbBar) : kStandardBarKg);
  final standard = targetWeightKg > 40;
  final steps = <WarmupStep>[];

  // ≤40kg 的杠铃同样从空杆起（20kg 单关节的启发式默认值也要有热身行）；
  // 正式重量还不到空杆的极轻目标不硬凑。lb 制 20kg 目标显示为 44lb，
  // 与 45lb 空杆只差显示取整，按 1lb 容差仍给空杆步。
  final barToleranceKg = useLb ? lbToKg(1) : 0.0;
  if (barbell && targetWeightKg >= barKg - barToleranceKg) {
    steps.add(WarmupStep(barKg, 5));
  }
  final percents = standard ? const [40, 60, 80] : const [40, 60];
  for (final percent in percents) {
    final weight = _roundForUnit(
      targetWeightKg * percent / 100,
      barbell: barbell,
      useLb: useLb,
    );
    final reps = percent == 40 ? 5 : (percent == 60 ? 3 : 1);
    _addStep(
      steps,
      WarmupStep(weight, reps, percent: percent),
      minKg: barbell ? barKg : (useLb ? lbToKg(2.5) : 2.5),
    );
  }

  if (steps.isEmpty) return const WarmupPlan.none();
  return WarmupPlan(
    standard ? WarmupMode.standard : WarmupMode.light,
    List<WarmupStep>.unmodifiable(steps),
  );
}

/// 百分比档按显示单位取整：kg 杠铃 2.5kg、其他 0.5kg；
/// lb 杠铃 5lb、其他 2.5lb（美制片重口径）。
double _roundForUnit(double kg, {required bool barbell, required bool useLb}) {
  if (useLb) {
    final grid = barbell ? 5.0 : 2.5;
    return lbToKg((kgToLb(kg) / grid).roundToDouble() * grid);
  }
  return barbell ? _roundTo(kg, 2.5) : _roundTo(kg, 0.5);
}

/// 去重（同重量只留第一档）并过滤掉低于器械最小可加载重量的步骤。
void _addStep(List<WarmupStep> out, WarmupStep step, {required double minKg}) {
  if (step.weightKg <= 0 || step.weightKg < minKg) return;
  if (out.any((s) => (s.weightKg - step.weightKg).abs() < 1e-9)) return;
  out.add(step);
}

double _roundTo(double value, double grid) =>
    (value / grid).roundToDouble() * grid;
