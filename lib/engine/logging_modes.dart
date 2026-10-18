import '../l10n/lang.dart';
import '../models/models.dart';
import '../presets/exercise_library.dart' show isLibraryBodyweightExercise;
import 'exercise_identity.dart' show canonicalExerciseNameOf, exerciseKeyOf;
import 'progression_chain.dart';
import 'weight_unit.dart' show fmtWithUnit;

/// 动作记录形态支持（v14）：按时间记录、单侧动作、自重负荷的纯函数工具。
///
/// 判定逻辑零新增——计时动作的链状态「次数」字段承载秒数，规则链
/// （progression_chain.dart）原样复用，本文件只做三件事：
/// - 形态判别与展示单位换算（供 UI 层）；
/// - 单侧动作的目标偶数化（每边均分）；
/// - 自重负荷的链形态选择与「触顶加组」建议（渐进表达在次数/组数上，
///   不进位到负重组件）；
/// - 自重变式阶梯（P2-E）：次数顶格后「下一档练什么」的纯数据查询。
/// 全部无 Flutter 依赖，可直接单元测试。

/// 是否按时间记录（链状态与 reps 字段承载秒数）。
bool isTimedLogging(String logging) => logging == LoggingMode.time;

/// 是否单侧动作（箭步蹲/单臂划船等，记总数、显示「每边 N 次」）。
bool isPerSideLogging(String logging) => logging == LoggingMode.repsPerSide;

/// 是否自重负荷（无重量列，渐进只走次数轴）。
bool isBodyweightLoad(String loadType) => loadType == LoadMode.bodyweight;

/// 训练页 UI 的自重判定口径（H3 收尾）：在存储值上只叠加规则①——
/// 名字是显式负重变体（[isExplicitWeightedVariantName]，如改名保留旧键的
/// 「引体向上（负重版）」）时按负重 UI 处理，要给重量输入。
/// 刻意**不**接整函数 [effectiveLoadTypeFor]：那里的 0kg 推断会把
/// stored-weighted 的 0kg 俯卧撑也翻成自重 UI，丢失加重量入口。
bool isBodyweightUi({
  required String exerciseName,
  required String loadType,
}) =>
    isBodyweightLoad(loadType) && !isExplicitWeightedVariantName(exerciseName);

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
  int plannedSets = 0,
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
            plannedSets: plannedSets,
          ) ??
          (plannedSets > 0 ? plannedSets : rule.workingSets) + 1;
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
      '全部组顶住 ${zhN()} → 下次加重至 ${fmtWithUnit(next.weightKg)}、目标回到 ${zhN(next.targetReps)}',
      en: 'Hold ${enN()} across all sets → add weight to ${fmtWithUnit(next.weightKg)}, target resets to ${enN(next.targetReps)}',
    );
  }
  return tx(
    '全部组做到 ${zhN()} → 下次目标 ${zhN(next.targetReps)}',
    en: 'Hit ${enN()} on every set → next target ${enN(next.targetReps)}',
  );
}

/// 自重触顶加组建议：bodyweight 动作的链（[ProgressionChain.defaultBodyweightFor]）
/// 已无推进空间（advance 后 next == state，即次数轴到顶）时，渐进改用
/// 「加组」表达——返回建议正式组数 = 计划组数 + 1，封顶计划组数 + 2
/// （最多加两组，防止无限堆容量）。[plannedSets] 为会话快照组数（缺省 0
/// 回退 rule.workingSets），避免快照 4 组/规则 3 组时把「4 组」当成加组。
/// 链还有空间或非 bodyweight 负荷 → null（调用方维持现有组数，走正常链推进）。
int? bodyweightExtraSetTarget({
  required ChainState state,
  required ProgressionRule rule,
  required String loadType,
  int plannedSets = 0,
}) {
  if (!isBodyweightLoad(loadType)) return null;
  final next = ProgressionChain.of(rule, loadType: loadType).advance(state, rule);
  if (next != state) return null; // 链还有空间：正常推进，不加组
  final base = plannedSets > 0 ? plannedSets : rule.workingSets;
  final cap = base + 2;
  final suggested = base + 1;
  return suggested > cap ? cap : suggested;
}

// ---------------- 自重变式阶梯（P2-E） ----------------

/// 自重变式阶梯（易 → 难，每级用内置动作库的规范名）。
///
/// 自重动作的次数轴顶到 `reps_max` 后，继续堆次数的边际收益越来越低，
/// 升级到下一档变式才是更自然的渐进。这里只提供「下一档是谁」的纯数据，
/// **不自动改计划**——换动作由用户在计划编辑器里自己决定。
/// 覆盖任务点名的四类：俯卧撑 / 引体向上 / 双杠臂屈伸 / 深蹲·臀桥。
const kBodyweightLadders = <List<String>>[
  // 推：手撑得越高越省力，脚垫高变难
  ['上斜俯卧撑', '俯卧撑', '下斜俯卧撑（脚垫高）'],
  // 拉：水平拉 → 反手引体 → 正手引体 → 负重引体
  ['反向划船', '引体向上（反手）', '引体向上', '负重引体向上'],
  // 三头版 → 胸版（前倾更多）→ 负重；两个双杠条目都收，
  // 用「双杠臂屈伸（挺胸）」的用户也能查到下一档
  ['凳上臂屈伸', '双杠臂屈伸', '双杠臂屈伸（挺胸）', '负重双杠臂屈伸'],
  // 腿：双腿 → 单腿稳定
  ['徒手深蹲', '箭步蹲'],
  ['臀桥', '单腿臀桥'],
];

/// 阶梯查询用的身份键候选：显式稳定键优先，其次按名字归一。
List<String> _ladderKeys(String exerciseName, String exerciseKey) => <String>[
      if (exerciseKey.trim().isNotEmpty) exerciseKey.trim(),
      exerciseKeyOf(exerciseName),
    ].where((k) => k.isNotEmpty).toSet().toList(growable: false);

/// 动作是否在自重变式阶梯上（**含阶梯末端**；末端只是没有下一档）。
/// 用于运行期自重推断：末端动作（下斜俯卧撑/箭步蹲/单腿臀桥）同样算
/// 自重动作，不能因为查不到「下一档」就被当成负重。
bool isBodyweightLadderExercise(String exerciseName,
    {String exerciseKey = ''}) {
  final keys = _ladderKeys(exerciseName, exerciseKey);
  for (final key in keys) {
    for (final ladder in kBodyweightLadders) {
      for (final rung in ladder) {
        if (exerciseKeyOf(rung) == key) return true;
      }
    }
  }
  return false;
}

/// 阶梯查询：动作名/稳定键 → 下一档变式规范名。
/// [exerciseKey] 优先（用户改名但保留旧键的自重动作仍能查到）；为空或
/// 查不到时回退按名字归一后的身份键。不在任何阶梯上、或已经是最后一档
/// → null。
String? nextBodyweightVariation(String exerciseName,
    {String exerciseKey = ''}) {
  final keys = _ladderKeys(exerciseName, exerciseKey);
  for (final key in keys) {
    for (final ladder in kBodyweightLadders) {
      for (var i = 0; i < ladder.length - 1; i++) {
        if (exerciseKeyOf(ladder[i]) == key) return ladder[i + 1];
      }
    }
  }
  return null;
}

/// 是否**显式负重变体**：「负重」出现在动作名任何位置都算——既包括前缀
/// 「负重引体向上/负重双杠臂屈伸」，也包括改名后的后缀注记「引体向上
/// （负重版）」。这类动作训练时要记外加载重，不能按自重推断。
bool isExplicitWeightedVariantName(String name) =>
    canonicalExerciseNameOf(name).contains('负重');

/// 有效负荷类型（P2-E，运行期推断，**唯一判定入口**）：引擎（[chainTargetWhy]
/// 的链形态、[bodyweightProgressionReady] 的阶梯就绪）与控制器（verdict/
/// 目标解释/处方）都调用本函数，保证两侧结论一致。
///
/// 优先级从高到低：
/// ① 名字是显式负重变体（[isExplicitWeightedVariantName]）→ weighted。
///    改名保留旧键的动作经旧键仍会命中自重阶梯（[isBodyweightLadderExercise]），
///    名字里的「负重」是更明确的用户意图，必须压住阶梯推断——即使存的
///    loadType 是 bodyweight（改名前的旧行）也按 weighted 口径。
/// ② 显式存储的 bodyweight 原样返回（计划编辑器/动作库口径落库的值）。
/// ③ v14 的 PlanExercise 默认 weighted，会把内置计划/模板/老库里的俯卧撑、
///    引体向上等自重动作一律存成 weighted（见 models.dart 的默认值），
///    所以再加一条推断——本场该动作的正式组全部 0kg，且（在自重变式阶梯上
///    或动作库标注纯自重，含平板支撑这类不在阶梯上的动作）→ 按 bodyweight
///    处理。有任何一组真的加了重量（含辅助配重负值）就不推断：那属于负重
///    渐进，不该建议换变式。
String effectiveLoadTypeFor({
  required String exerciseName,
  required String loadType,
  required List<SetEntry> workingSets,
  String exerciseKey = '',
}) {
  // 「负重 X」「X（负重版）」是自重器械上的外加载重变体：即使本场 0kg
  // 也保持 weighted，训练页要能记录外加重量。
  if (isExplicitWeightedVariantName(exerciseName)) return LoadMode.weighted;
  if (isBodyweightLoad(loadType)) return loadType;
  final ws = workingSets
      .where((s) => s.kind == SetKind.working && !s.isExtra)
      .toList(growable: false);
  if (ws.isEmpty) return loadType;
  if (!ws.every((s) => s.weightKg.abs() < 0.001)) return loadType;
  if (!isBodyweightLadderExercise(exerciseName, exerciseKey: exerciseKey) &&
      !isLibraryBodyweightExercise(exerciseName)) {
    return loadType;
  }
  return LoadMode.bodyweight;
}

/// 自重动作是否到了「该升级」的时点（与 [evaluateChain] 的 `chain_end`
/// 同一口径）：计划组全部练满、全部达标、末组余力达标记、次数轴触顶。
/// 少做（insufficient_sets）/未达标/RIR 太低（target_miss）都是 hold，
/// 不算 ready——休息页的变式建议与总结页的加组建议共用这一道闸。
bool bodyweightProgressionReady({
  required String exerciseName,
  required ProgressionRule rule,
  required String loadType,
  required List<SetEntry> workingSets,
  int plannedSets = 0,
  String logging = LoggingMode.reps,
  String exerciseKey = '',
}) {
  final ws = workingSets
      .where((s) => s.kind == SetKind.working && !s.isExtra)
      .toList(growable: false);
  if (ws.isEmpty) return false;
  final effective = effectiveLoadTypeFor(
    exerciseName: exerciseName,
    loadType: loadType,
    workingSets: ws,
    exerciseKey: exerciseKey,
  );
  if (!isBodyweightLoad(effective)) return false;
  final v = evaluateChain(
    rule: rule,
    state: chainStateFromHistory(ws, rule),
    workingSets: ws,
    targetSets: plannedSets,
    logging: logging,
    loadType: effective,
  );
  return v.action == 'hold' && v.holdKind == 'chain_end';
}

/// 训练页「试试下一档」建议：自重动作到了升级时点
/// （[bodyweightProgressionReady]）且阶梯上还有下一档 → 返回下一档规范名；
/// 否则 null。
///
/// 只看正式组、不含加练组。负荷类型用 [effectiveLoadTypeFor] 推断，
/// 兼容内置计划/模板/老库把自重动作存成默认 weighted 的数据。
String? bodyweightVariationSuggestion({
  required String exerciseName,
  required ProgressionRule rule,
  required String loadType,
  required List<SetEntry> workingSets,
  int plannedSets = 0,
  String logging = LoggingMode.reps,
  String exerciseKey = '',
}) {
  final ready = bodyweightProgressionReady(
    exerciseName: exerciseName,
    rule: rule,
    loadType: loadType,
    workingSets: workingSets,
    plannedSets: plannedSets,
    logging: logging,
    exerciseKey: exerciseKey,
  );
  if (!ready) return null;
  return nextBodyweightVariation(exerciseName, exerciseKey: exerciseKey);
}
