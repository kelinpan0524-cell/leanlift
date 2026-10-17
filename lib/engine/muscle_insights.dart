import 'engine.dart';

/// 肌肉洞察纯函数（2026-10-17）：
/// - untrainedRegions：统计期内没练到的肌群点名（数据页「肌群容量占比」卡）
/// - planMuscleShare：计划静态预览——不依赖任何训练记录，直接从计划
///   动作推各肌群预期占比（计划编辑页「命中预览」）

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
