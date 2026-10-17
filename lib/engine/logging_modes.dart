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
