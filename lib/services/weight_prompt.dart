/// 开练前「顺手记体重」判定（2026-10 开场设置）：
/// 纯函数、无 Flutter/DB 依赖，供 home_page 与单测共用。
/// 口径：开关开 && 最新一次身体记录不是今天（body_metrics 按天 upsert，
/// 只要今天有一行——哪怕只记了腰围——就不弹，与「每天最多问一次」一致）。
bool shouldAskWeightOnStart({
  required bool enabled,
  required String? lastMetricDate,
  required String today,
}) =>
    enabled && lastMetricDate != today;
