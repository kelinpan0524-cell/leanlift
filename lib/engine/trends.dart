import '../l10n/lang.dart';
import 'engine.dart';
import 'weight_unit.dart' show WeightUnits, kgToLb;

/// 数据页统计的纯函数集（wger 借鉴，2026-09-27）：
/// - 身体指标录入防呆区间（wger measurements/limits.py 的口径）
/// - 周/月分桶（统计维度升级）
/// - 肌群 → 上肢/下肢/核心 分组（上下肢分布卡）

// ---------------- 身体指标防呆区间 ----------------

/// 身体指标硬区间：超出直接拒绝录入（防手滑多敲一位 / 单位填错）。
/// 区间口径参考 wger measurements/limits.py（体重 20-350kg、体脂 2-60%），
/// 腰围 wger 没有，取常识区间 30-200cm。
const kBodyMetricLimits = <String, (double, double)>{
  'weight': (20, 350),
  'waist': (30, 200),
  'bodyfat': (2, 60),
};

/// 校验一组待写入的身体指标（null 字段跳过）。
/// 返回 null = 全部合法；否则返回中文错误文案（第一处越界即返回）。
String? validateBodyMetric({
  double? weightKg,
  double? waistCm,
  double? bodyFatPct,
}) {
  String? check(
    String key,
    double? v,
    String zhLabel,
    String enLabel,
    String unit,
  ) {
    final range = kBodyMetricLimits[key]!;
    if (v == null) return null;
    if (v < range.$1 || v > range.$2) {
      if (key == 'weight' && WeightUnits.isLb) {
        final loLb = kgToLb(range.$1).round();
        final hiLb = kgToLb(range.$2).round();
        final curLb = kgToLb(v).toStringAsFixed(1);
        return tx(
          '$zhLabel 必须在 $loLb-$hiLb lb 之间（当前填的是 ${curLb}lb）',
          en: '$enLabel must be between $loLb-$hiLb lb (entered ${curLb}lb)',
        );
      }
      return tx(
        '$zhLabel 必须在 ${range.$1}-${range.$2}$unit 之间（当前填的是 $v）',
        en: '$enLabel must be between ${range.$1}-${range.$2}$unit (entered $v)',
      );
    }
    return null;
  }

  return check('weight', weightKg, '体重', 'Weight', 'kg') ??
      check('waist', waistCm, '腰围', 'Waist', 'cm') ??
      check('bodyfat', bodyFatPct, '体脂率', 'Body fat', '%');
}

// ---------------- 周/月分桶 ----------------

/// 统计聚合粒度。
enum TrendGranularity { week, month }

/// 统计指标：容量 kg / 正式组数 / 平均强度 %。
enum TrendMetric { volume, sets, intensity }

/// 把日期折算成分桶键（epoch 天数）：
/// week = 所在周的周一；month = 所在月的一号。同桶同键，跨桶自然分离。
int trendKeyOf(DateTime d, TrendGranularity g) {
  final dayOnly = DateTime(d.year, d.month, d.day);
  switch (g) {
    case TrendGranularity.week:
      return mondayOf(dayOnly).millisecondsSinceEpoch ~/ 86400000;
    case TrendGranularity.month:
      return DateTime(d.year, d.month, 1).millisecondsSinceEpoch ~/ 86400000;
  }
}

/// 一个周期桶的累计值。容量/组数直接累加；强度按「有分母的组」求均值
/// （自重组 weight<=0 没有强度意义，不计入分母）。
class TrendAcc {
  double volume = 0;
  int sets = 0;
  double intensitySum = 0;
  int intensityCount = 0;

  void add({required double setVolume, double? intensity}) {
    volume += setVolume;
    sets++;
    if (intensity != null && intensity > 0) {
      intensitySum += intensity;
      intensityCount++;
    }
  }

  /// 该桶在指定指标下的取值（强度为百分比 0-100+，无样本返回 0）。
  double metricValue(TrendMetric m) {
    switch (m) {
      case TrendMetric.volume:
        return volume;
      case TrendMetric.sets:
        return sets.toDouble();
      case TrendMetric.intensity:
        return intensityCount == 0 ? 0 : intensitySum / intensityCount * 100;
    }
  }
}

// ---------------- 每日最佳 1RM ----------------

/// 每日最佳 1RM 累计器（wger 的 daily best 口径）：
/// 动作名 → 训练日（epoch 天）→ 当天全部正式组里的最高 1RM 估值。
/// 同一天多组/多场取最大；退步的天照记（诚实显示 dips）。
class DailyBest1Rm {
  final Map<String, Map<int, double>> byExercise = <String, Map<int, double>>{};

  void add(String exerciseName, DateTime date, double rm) {
    final dayKey = DateTime(date.year, date.month, date.day)
            .millisecondsSinceEpoch ~/
        86400000;
    final byDate = byExercise.putIfAbsent(exerciseName, () => <int, double>{});
    if (rm > (byDate[dayKey] ?? 0)) byDate[dayKey] = rm;
  }

  /// 某动作的训练日键升序列表（图表 x 轴顺序）
  List<int> sortedDaysOf(String exerciseName) {
    final keys =
        (byExercise[exerciseName] ?? const <int, double>{}).keys.toList()
          ..sort();
    return keys;
  }
}

// ---------------- 上下肢分组 ----------------

/// 肌群 → 大区分组：上肢（胸/肩/背/手臂）、下肢（腿）、核心、其他。
/// 与 wger 的 upper/lower 统计口径同思路，按我们的七分区词表映射。
String regionGroupOf(String muscle) {
  switch (muscle) {
    case '胸':
    case '肩':
    case '背':
    case '手臂':
      return '上肢';
    case '腿':
      return '下肢';
    case '核心':
      return '核心';
    default:
      return '其他';
  }
}

/// 七分区容量占比 → 大区占比（输入是 muscleLoadShare 的归一化结果，
/// 分组求和即可，归一化是线性变换不影响分组比例）。
Map<String, double> regionGroupShare(Map<String, double> muscleShare) {
  final out = <String, double>{};
  for (final e in muscleShare.entries) {
    final g = regionGroupOf(e.key);
    out[g] = (out[g] ?? 0) + e.value;
  }
  return out;
}
