import '../models/models.dart';
import 'metrics.dart';

/// 肌肉洞察纯函数（2026-10-17）：
/// - untrainedRegions：统计期内没练到的肌群点名（数据页「肌群容量占比」卡）
/// - planMuscleShare：计划静态预览——不依赖任何训练记录，直接从计划
///   动作推各肌群预期占比（计划编辑页「命中预览」）
///
/// 每周肌群「剂量」口径（2026-10-18 P1-B，从占比升级为组数）：
/// - weeklyWorkingSetsByMuscle：统计期内实际练到的每周组数
/// - planWeeklyWorkingSetsByMuscle：按计划静态推算的每周组数
/// - kWeeklySetTargets / weeklySetStatusOf：每个肌群的目标区间与不足/达标/过量状态

/// 统计期内没练到的肌群点名：kMuscleRegions 去掉「其他」，占比 < threshold 的区。
/// 顺序按 kMuscleRegions 规范序；loadShare 为空/全零 → 返回全部肌群。
List<String> untrainedRegions(Map<String, double> loadShare,
    {double threshold = 0.02}) {
  final all = [for (final r in kMuscleRegions) if (r != '其他') r];
  final total = loadShare.values.fold(0.0, (a, b) => a + b);
  // 空窗口 / 全零（统计期内没练过）→ 六大肌群全部点名
  if (total <= 0) return all;
  return [
    for (final r in all)
      if ((loadShare[r] ?? 0) < threshold) r
  ];
}

/// 计划静态预览：不依赖任何训练记录，直接从计划动作推各肌群预期占比。
/// 单动作代理负荷 = sets × 中位次数((repsMin+repsMax)/2)；
/// 主肌群记满 1 份，次肌群各记 0.5 份；按 kMuscleRegions 归一化为 0-1 占比。
/// 查不到 meta 的动作归入「其他」。
Map<String, double> planMuscleShare(
    List<PlanExercise> exercises, Map<String, ExerciseMeta> metaByName) {
  final load = {for (final r in kMuscleRegions) r: 0.0};
  void add(String region, double amount) {
    // 词表外的脏肌群名统一归「其他」，保证键始终落在 kMuscleRegions 内
    final k = load.containsKey(region) ? region : '其他';
    load[k] = load[k]! + amount;
  }

  for (final ex in exercises) {
    final unit = ex.sets * ((ex.repsMin + ex.repsMax) / 2.0);
    if (unit <= 0) continue; // 组数/次数为 0 的动作不产生负荷
    final meta = metaByName[ex.name];
    add(meta?.muscles.main ?? '其他', unit);
    for (final s in meta?.muscles.secondary ?? const <String>[]) {
      add(s, unit * 0.5);
    }
  }
  final total = load.values.fold(0.0, (a, b) => a + b);
  if (total <= 0) return load;
  return load.map((k, v) => MapEntry(k, v / total));
}

// ---------------- 每周组数（剂量） ----------------

/// 次肌群折算系数（P1-B 剂量口径，2026-10-18）：
/// 一个正式组里主肌群记满 1 组，次肌群只承担部分刺激，各记 0.5 组。
/// 与 [planMuscleShare] 的 1:0.5 权重一致；不把一组同时按满组记给两个
/// 肌群——否则一个全身动作会让每个肌群都虚高，目标区间失去意义。
const double kSecondaryMuscleSetWeight = 0.5;

/// 每周每肌群正式组数目标区间（P1-B，参考常见的每周训练容量建议）：
/// 胸/背/腿 = 10-20 组，肩/手臂 = 8-16 组，核心 = 6-12 组。
/// 「其他」（词表外动作）不设目标，只显示原始组数。
class WeeklySetTarget {
  final int min;
  final int max;
  const WeeklySetTarget(this.min, this.max);

  /// 目标区间的展示文本（如 10-20）。
  @override
  String toString() => '$min-$max';
}

const Map<String, WeeklySetTarget> kWeeklySetTargets = {
  '胸': WeeklySetTarget(10, 20),
  '背': WeeklySetTarget(10, 20),
  '腿': WeeklySetTarget(10, 20),
  '肩': WeeklySetTarget(8, 16),
  '手臂': WeeklySetTarget(8, 16),
  '核心': WeeklySetTarget(6, 12),
};

/// 每周组数相对目标区间的状态。
enum WeeklySetStatus {
  /// 低于目标下限（还差剂量）。
  low,

  /// 落在目标区间内（含边界）。
  onTarget,

  /// 高于目标上限（练量偏大）。
  high,
}

/// 查某肌群的每周组数状态；「其他」等无目标分区返回 null。
/// 边界值算达标：10..20 两端都算在区间内。
WeeklySetStatus? weeklySetStatusOf(String region, double sets) {
  final t = kWeeklySetTargets[region];
  if (t == null) return null;
  if (sets < t.min) return WeeklySetStatus.low;
  if (sets > t.max) return WeeklySetStatus.high;
  return WeeklySetStatus.onTarget;
}

/// 把一个动作的组数按主/次肌群折算进 [out]。
/// 主肌群 = 1 组/组，次肌群 = [kSecondaryMuscleSetWeight] 组/组；
/// 词表外的脏肌群名与查不到 meta 的动作统一归「其他」。
void _addSetDose(Map<String, double> out, ExerciseMeta? meta, double sets) {
  if (sets <= 0) return;
  final main = meta?.muscles.main;
  final mainKey = main != null && out.containsKey(main) ? main : '其他';
  out[mainKey] = out[mainKey]! + sets;
  for (final s in meta?.muscles.secondary ?? const <String>[]) {
    final k = out.containsKey(s) ? s : '其他';
    out[k] = out[k]! + sets * kSecondaryMuscleSetWeight;
  }
}

/// 统计期内各肌群的每周正式组数（剂量口径，2026-10-18 P1-B）。
/// [workingSetsByName] 为 (动作名, 该动作的组) 列表；只计 `kind='working'`
/// 的正式组——与全库容量统计纪律一致（docs/progression-rules.md §6：
/// 容量/剂量统计只认正式组，热身组与力竭组都不计，概览趋势与肌群
/// 容量占比同口径）。主肌群记 1 组、次肌群各记
/// [kSecondaryMuscleSetWeight]（0.5）组。
/// 返回键覆盖 [kMuscleRegions] 全部区域（含「其他」，空数据全零）。
Map<String, double> weeklyWorkingSetsByMuscle(
  List<MapEntry<String, List<SetEntry>>> workingSetsByName,
  Map<String, ExerciseMeta> metaByName,
) {
  final out = {for (final r in kMuscleRegions) r: 0.0};
  for (final entry in workingSetsByName) {
    final n = entry.value.where((s) => s.kind == SetKind.working).length;
    if (n <= 0) continue;
    _addSetDose(out, metaByName[entry.key], n.toDouble());
  }
  return out;
}

/// 循环排程的每周折算系数（P1-B 修正，2026-10-18）。
///
/// 应用的循环语义（lib/services/plan_repository.dart 的 _cycleDayFor）：
/// 「练 N 休 M」每个 (N+M) 天周期只练 N 次，模板日按全局训练序号
/// occ % 训练日数 轮转。也就是说一个周期里 N 次训练分散到
/// [trainableDays] 个模板日上，每个模板日平均每周期出现 N / trainableDays 次。
/// 整份计划（全部模板日求和）每周出现次数 =
///     7 × N / ((N + M) × trainableDays)
///
/// 注意不是 7 / (N + M)：那是「每个周期把全部模板日各练一遍」的口径；
/// 模板日多于连练数时（如 6 个训练日 + 练2休1），一个周期只轮到其中
/// 2 个模板日，直接乘 7/(N+M) 会把周组数放大到真实值的
/// (trainableDays / N) 倍。
double cycleWeeklyFactor({
  required int train,
  required int rest,
  required int trainableDays,
}) {
  if (train <= 0 || trainableDays <= 0) return 0;
  final period = train + (rest > 0 ? rest : 0);
  if (period <= 0) return 0;
  return 7.0 * train / (period * trainableDays);
}

/// 计划静态推演：按计划动作推算的每周每肌群正式组数。
/// 与 [weeklyWorkingSetsByMuscle] 同一计数口径（主 1 / 次 0.5），
/// 只是用计划处方 [PlanExercise.sets] 代替实际落库的正式组。
/// [weeklyFactor] 用于把「整份计划模板日的组数之和」折算到每周：
/// 按星期排程传 1；循环排程用 [cycleWeeklyFactor] 计算——循环的一个
/// 周期只练 N 次、模板日可能更多，不能简单传 7 / (N + M)。
Map<String, double> planWeeklyWorkingSetsByMuscle(
  List<PlanExercise> exercises,
  Map<String, ExerciseMeta> metaByName, {
  double weeklyFactor = 1,
}) {
  final out = {for (final r in kMuscleRegions) r: 0.0};
  if (weeklyFactor <= 0) return out;
  for (final ex in exercises) {
    if (ex.sets <= 0) continue;
    _addSetDose(out, metaByName[ex.name], ex.sets * weeklyFactor);
  }
  return out;
}
