import '../l10n/lang.dart';
import '../models/models.dart';
import 'progression_chain.dart';

/// 动作记录形态支持（v14）：按时间记录、单侧动作、自重负荷的纯函数工具。
///
/// 判定逻辑零新增——计时动作的链状态「次数」字段承载秒数，规则链
/// （progression_chain.dart）原样复用，本文件只做三件事：
/// - 形态判别与展示单位换算（供 UI 层）；
/// - 单侧动作的目标偶数化（每边均分）；
/// - 自重负荷的链形态选择与「触顶加组」建议（渐进表达在次数/组数上，
///   不进位到负重组件）。
/// 全部无 Flutter 依赖，可直接单元测试。

/// 是否按时间记录（链状态与 reps 字段承载秒数）。
bool isTimedLogging(String logging) => logging == LoggingMode.time;

/// 是否单侧动作（箭步蹲/单臂划船等，记总数、显示「每边 N 次」）。
bool isPerSideLogging(String logging) => logging == LoggingMode.repsPerSide;

/// 是否自重负荷（无重量列，渐进只走次数轴）。
bool isBodyweightLoad(String loadType) => loadType == LoadMode.bodyweight;

/// 单侧动作目标就近取偶（最小 2）：总数要能两侧均分，奇数目标上取整；
/// 0/1 这类无法成组的目标抬到每边 1 次（总数 2）。其他形态原样返回。
int normalizeTarget(int target, String logging) {
  if (!isPerSideLogging(logging)) return target;
  final even = target % 2 == 0 ? target : target + 1;
  return even < 2 ? 2 : even;
}

/// 次数/秒数单位标签（展示层用）：计时动作链状态里的数字是秒。
String repsUnitLabel(String logging) =>
    isTimedLogging(logging) ? tx('秒', en: 's') : tx('次', en: 'reps');

/// 英文判定文案里的「N 次/N 秒」修饰语（'8-rep' / '8s'）。
/// 仅供 reason 拼接，默认形态输出与历史文案逐字节一致。
String enRepPhrase(int n, String logging) =>
    isTimedLogging(logging) ? '${n}s' : '$n-rep';

/// 「目标为什么是这个数字」（v14 可解释化）：面向**本次训练**的一句话解释，
/// 纯展示文案、不参与判定。把当前链状态沿规则链前进一步，按落点给口径：
/// - 次数轴还有空间：「全部组做到 N 次 → 下次目标 M 次」（timed 用秒表述）；
/// - 次数轴触顶且 weighted：「全部组顶住 N → 下次加重至 X kg、目标回到 Y 次」；
/// - bodyweight 触顶：「全部组顶住 N 秒/次 → 下次加练一组」（组数 =
///   [bodyweightExtraSetTarget] 的建议值）；
/// - 全链到头：保持当前档。
/// [logging] 决定单位表述（计时=秒、单侧=每边均分），[loadType] 决定链形态；
/// 缺省参数下输出常规负重按次数的口径。
String chainTargetWhy({
  required ProgressionRule rule,
  required ChainState state,
  String loadType = LoadMode.weighted,
  String logging = LoggingMode.reps,
}) {
  final timed = isTimedLogging(logging);
  final unit = timed ? '秒' : '次';
  final enUnit = timed ? 's' : 'reps';
  final perSide = isPerSideLogging(logging);
  // 单侧动作的链目标按偶数口径表述（与记录页「每边 N 次」同源换算）
  final n = normalizeTarget(state.targetReps, logging);
  String zhN([int? v]) {
    final x = normalizeTarget(v ?? n, logging);
    return perSide ? '$x 次（每边 ${x ~/ 2}）' : '$x $unit';
  }

  String enN([int? v]) {
    final x = normalizeTarget(v ?? n, logging);
    return perSide ? '$x reps (${x ~/ 2}/side)' : '$x $enUnit';
  }

  final chain = ProgressionChain.of(rule, loadType: loadType);
  final next = chain.advance(state, rule);
  if (next == state) {
    if (isBodyweightLoad(loadType)) {
      // 自重触顶：渐进表达转到「加组」（advance 原样返回 = 次数轴已到顶）
      final sets = bodyweightExtraSetTarget(
            state: state,
            rule: rule,
            loadType: loadType,
          ) ??
          rule.workingSets + 1;
      return tx(
        '全部组顶住 ${zhN()} → 下次加练一组（$sets 组）',
        en: 'Hold ${enN()} across all sets → add one extra set next time ($sets sets)',
      );
    }
    return tx(
      '已到规则链尽头，全部组顶住 ${zhN()} → 保持当前档',
      en: 'Chain topped out — hold ${enN()} at this tier',
    );
  }
  if (next.weightKg != state.weightKg) {
    return tx(
      '全部组顶住 ${zhN()} → 下次加重至 ${next.weightKg}kg、目标回到 ${zhN(next.targetReps)}',
      en: 'Hold ${enN()} across all sets → add weight to ${next.weightKg}kg, target resets to ${enN(next.targetReps)}',
    );
  }
  return tx(
    '全部组做到 ${zhN()} → 下次目标 ${zhN(next.targetReps)}',
    en: 'Hit ${enN()} on every set → next target ${enN(next.targetReps)}',
  );
}

/// 自重触顶加组建议：bodyweight 动作的链（[ProgressionChain.defaultBodyweightFor]）
/// 已无推进空间（advance 后 next == state，即次数轴到顶）时，渐进改用
/// 「加组」表达——返回建议正式组数 = workingSets + 1，封顶 workingSets + 2
/// （最多加两组，防止无限堆容量）。链还有空间或非 bodyweight 负荷 → null
/// （调用方维持现有组数，走正常链推进）。
int? bodyweightExtraSetTarget({
  required ChainState state,
  required ProgressionRule rule,
  required String loadType,
}) {
  if (!isBodyweightLoad(loadType)) return null;
  final next = ProgressionChain.of(rule, loadType: loadType).advance(state, rule);
  if (next != state) return null; // 链还有空间：正常推进，不加组
  final cap = rule.workingSets + 2;
  final suggested = rule.workingSets + 1;
  return suggested > cap ? cap : suggested;
}
