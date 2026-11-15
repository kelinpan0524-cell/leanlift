import '../models/models.dart';

/// 自重容量折算（调研报告点名条目二 / 候选「自重容量折算」，workout-timer 思路）：
/// 自重动作按 预置系数×体重 计入容量而非记 0——否则居家训练、引体类动作
/// 在容量趋势里完全隐形。
///
/// 系数口径：俯卧撑 0.64、引体向上 0.70 来自 ACE（American Council on
/// Exercise）公布的「自重动作负荷占体重百分比」研究口径；其余动作系数为按
/// 同一口径的工程估算（无逐项公开实测值），只用于容量趋势对比，
/// 不参与 1RM 估算与渐进超负荷判定。
/// 上/下斜俯卧撑、派克俯卧撑等变体的增减载比例参考 NSCA 教材对
/// 俯卧撑姿势变体的定性描述（脚垫高增载、手垫高减载）做的工程估算。

const kBodyweightLoadRatio = <String, double>{
  // —— ACE 口径（明确数值）——
  '俯卧撑': 0.64, // ACE：俯卧撑顶位约 64% 体重
  '引体向上': 0.70, // ACE：引体向上约 70% 体重
  '引体向上（反手）': 0.70, // 同正手引体口径，自重/负重按 70% 折算
  // —— 同口径工程估算（趋势参考，非逐项实测）——
  '负重引体向上': 0.70, // 自重部分同引体向上，外载另加
  '负重引体向上（反手）': 0.70, // 自重部分同反手引体，外载另加
  '上斜俯卧撑': 0.55, // 手垫高、负荷减轻
  '下斜俯卧撑': 0.70, // 脚垫高、负荷加重（兼容用户沉淀的无后缀变体名）
  '下斜俯卧撑（脚垫高）': 0.70, // 脚垫高、负荷加重
  '派克俯卧撑': 0.60, // 肩主导变体，负荷介于普通与下斜之间
  '双杠臂屈伸': 0.70,
  '负重双杠臂屈伸': 0.70,
  '双杠臂屈伸（挺胸）': 0.70,
  '负重双杠臂屈伸（挺胸）': 0.70,
  '凳上臂屈伸': 0.55,
  '徒手深蹲': 0.65,
  '箭步蹲': 0.65,
  '深蹲跳': 0.70, // 起跳离地瞬间负荷更高，取保守值
  '波比跳': 0.65, // 全身动作，取俯卧撑与深蹲之间的量级
  '臀桥': 0.35, // 地面支撑分担大部分体重
  '单腿臀桥': 0.50,
  '跪姿后踢腿': 0.20, // 四点跪撑单腿小幅度后踢，实际负荷很小
  '悬垂举腿': 0.55,
};

/// 子串匹配用的系数表快照：按键长度降序（最长命中优先）。
/// 否则短键会抢先——「上斜俯卧撑（宽距）」先命中「俯卧撑」0.64，
/// 而变体表里更具体的「上斜俯卧撑」0.55 才是正解。
final _rankedRatioEntries = () {
  final entries = kBodyweightLoadRatio.entries.toList()
    ..sort((a, b) => b.key.length.compareTo(a.key.length));
  return entries;
}();

/// 查某动作的自重负荷系数：先精确名，再子串匹配（最长键优先，兼容
/// 用户沉淀的变体名如「引体向上（宽握）」）。无系数动作返回 0
/// （容量语义不变）。
double bodyweightLoadRatio(String name) {
  if (name.isEmpty) return 0;
  final exact = kBodyweightLoadRatio[name];
  if (exact != null) return exact;
  for (final e in _rankedRatioEntries) {
    if (name.contains(e.key)) return e.value;
  }
  return 0;
}

/// 一组的容量计入口径（在 SetEntry.volume 的既有语义上叠加自重折算）：
/// - 热身组：0（既有语义，热身不进容量）；
/// - 辅助配重（负重量）：0（既有语义，「抵消负荷」不进容量）；
/// - 自重动作（重量记 0）：系数×体重×次数；
/// - 负重自重动作（如负重引体）：（系数×体重 + 外载）×次数；
/// - 无系数动作：维持 重量×次数（weight=0 时即 0）。
double setVolumeWithBodyweight(
  SetEntry s, {
  required String exerciseName,
  required double bodyWeightKg,
}) {
  if (s.kind == SetKind.warmup) return 0;
  if (s.weightKg < 0) return 0;
  final coef =
      bodyWeightKg > 0 ? bodyweightLoadRatio(exerciseName) : 0.0;
  final load = coef * bodyWeightKg + (s.weightKg > 0 ? s.weightKg : 0.0);
  return load * s.reps;
}
