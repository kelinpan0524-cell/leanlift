import '../l10n/lang.dart';
import 'engine.dart';
import 'weight_unit.dart' show fmtWithUnit;

export '../models/models.dart' show ChainRule;

/// 渐进超负荷规则链引擎（调研条目 15，设计借鉴 LiftLog 的规则链语义，
/// 未搬任何源码；语义文档见 docs/progression-rules.md）。
///
/// 核心思想：
/// - 每条规则带**轴**（次数/重量）、**步长**、**天花板**、**触顶后行为**
///   （进位下一条 / 停住），可编排成有序链；
/// - 会话结束**全场每组都达标**才推进「链中第一条还有空间的规则」；
/// - 经典的「8→12 加重归 8」双阶梯不是硬编码，而是
///   `[次数轴 8→12 触顶进位] → [重量轴 +2.5kg 并把次数复位到 8]`
///   两条规则组合后的**自然涌现**；
/// - [unreachableRuleIndexes] 提供静态可达性检查（学 LiftLog 的
///   unreachableFrom：被 hold 堵点截断的后续规则永远轮不到，UI 可据此置灰）。
///
/// 与旧引擎（evaluateProgression）的关系：
/// - 达标判定口径完全一致（全部正式组达目标次数 + 末组余力容差 1 次）；
/// - 减重分支一致（有组低于 reps_min → 减 5%，负重量同向）；
/// - 差异只在达标后的目标语义：旧引擎固定要求顶格 reps_max，新链的
///   目标次数会从上次成绩出发逐场 +1 爬升（见 chainStateFromHistory）。

/// 链状态：当前重量档 + 当前次数目标。
class ChainState {
  final double weightKg;
  final int targetReps;

  const ChainState({required this.weightKg, required this.targetReps});

  @override
  bool operator ==(Object other) =>
      other is ChainState &&
      other.weightKg == weightKg &&
      other.targetReps == targetReps;

  @override
  int get hashCode => Object.hash(weightKg, targetReps);

  @override
  String toString() => 'ChainState(${weightKg}kg x$targetReps)';
}

/// 规则链：有序规则列表。null/空链时用 [defaultFor] 从旧式
/// ProgressionRule 参数派生默认双阶梯，保证老数据行为连续。
class ProgressionChain {
  final List<ChainRule> rules;

  const ProgressionChain(this.rules);

  /// 从旧式规则参数派生默认双阶梯：
  /// 1. 次数轴：达标目标 +1 次，天花板 = reps_max，触顶进位；
  /// 2. 重量轴：+increment_kg（不设上限），触顶停住，执行后次数复位到 reps_min。
  /// 「加重归下限」由此涌现——派生链与旧引擎的加重行为一致。
  factory ProgressionChain.defaultFor(ProgressionRule rule) => ProgressionChain([
        ChainRule(
          axis: 'reps',
          step: 1,
          ceiling: rule.repsMax.toDouble(),
          advanceOnCap: true,
        ),
        ChainRule(
          axis: 'load',
          step: rule.incrementKg,
          ceiling: null,
          advanceOnCap: false,
          resetRepsTo: rule.repsMin,
        ),
      ]);

  /// 自重动作的默认链（LoadMode.bodyweight，v14）：只有次数轴——
  /// 天花板 = reps_max、触顶停住（advanceOnCap: false）。没有重量轴，
  /// 0kg 档永远不会进位到负重组件；次数到顶后的渐进表达交给
  /// logging_modes.dart 的 bodyweightExtraSetTarget 建议加组。
  factory ProgressionChain.defaultBodyweightFor(ProgressionRule rule) =>
      ProgressionChain([
        ChainRule(
          axis: 'reps',
          step: 1,
          ceiling: rule.repsMax.toDouble(),
          advanceOnCap: false,
        ),
      ]);

  /// 规则优先级：bodyweight 负荷强制走自重链（显式 chain 里即便配了
  /// 重量轴也不执行——自重渐进不碰重量）；其余 显式配置的 chain >
  /// 旧参数派生的默认双阶梯。缺省 loadType 保证现有调用行为不变。
  static ProgressionChain of(ProgressionRule rule,
          {String loadType = LoadMode.weighted}) =>
      loadType == LoadMode.bodyweight
          ? ProgressionChain.defaultBodyweightFor(rule)
          : (rule.chain != null && rule.chain!.isNotEmpty)
              ? ProgressionChain(rule.chain!)
              : ProgressionChain.defaultFor(rule);

  /// 规则是否「还有空间」（可再推进一步）。
  bool _hasRoom(ChainRule r, ChainState s) {
    if (r.axis == 'reps') {
      return r.ceiling == null || s.targetReps < r.ceiling!;
    }
    return r.ceiling == null || s.weightKg < r.ceiling!;
  }

  /// 链推进：执行第一条还有空间的规则；无空间且 advanceOnCap 的规则被
  /// 跳过（进位），遇到无空间且 hold 的规则整链停住。
  /// 仅在「全场每组达标」时由 [evaluateChain] 调用。
  ChainState advance(ChainState s, ProgressionRule rule) {
    for (final r in rules) {
      if (_hasRoom(r, s)) {
        if (r.axis == 'reps') {
          return ChainState(
            weightKg: s.weightKg,
            targetReps: s.targetReps + r.step.round(),
          );
        }
        return ChainState(
          weightKg: round05(s.weightKg + r.step),
          targetReps: r.resetRepsTo ?? s.targetReps,
        );
      }
      if (!r.advanceOnCap) {
        return s; // 触顶且停住：整链不再推进
      }
      // 触顶且进位：看下一条规则
    }
    return s; // 全链无空间
  }

  /// 静态可达性（学 LiftLog unreachableFrom）：从链首找第一条有空间的规则
  /// 意味着「无空间且进位」的规则会被跳过，但一旦遇到「无空间且 hold」的
  /// 规则整链停住——它之后的规则永远轮不到。返回这些规则的链下标。
  /// 状态相关的空间判断不在此处（运行时才有），此处只查 hold 堵点截断。
  List<int> unreachableRuleIndexes() {
    final out = <int>[];
    var blocked = false;
    for (var i = 0; i < rules.length; i++) {
      if (blocked) {
        out.add(i);
      } else if (!rules[i].advanceOnCap) {
        // 第一条 hold 规则本身可达（有空间时会被执行），其后全部不可达
        blocked = true;
      }
    }
    return out;
  }
}

/// 链判定结果。
class ChainVerdict {
  /// 'advance'（达标推进）/ 'hold'（保持）/ 'decrease'（减重）
  final String action;
  final ChainState next;
  final String reason;

  /// hold 的具体原因（P1-C 复核用，非 hold 为空串）：
  /// 'no_sets' / 'different_tier' / 'insufficient_sets' / 'chain_end' /
  /// 'target_miss'。调用方据此判断「继续冲」的 hold 是否适合被平台期
  /// 协议替换——少做/没记录/换档位不能被改写为「加重/减载」。
  final String holdKind;

  const ChainVerdict(this.action, this.next, this.reason,
      {this.holdKind = ''});
}

/// 从「上次该动作的正式组」推导当前链状态：
/// - 重量 = 上次最后一组重量（与旧引擎 currentWeight 同源）；
/// - 次数目标 = 上次全部正式组的最小 reps，clamp 到 [reps_min, reps_max]
///   （低于下限视为还没站上下限台阶；高于上限说明超量完成，顶到上限）；
/// - 无历史 → 次数目标 = reps_min（重量由 presetStart 另行填充）。
///
/// 由此旧用户平滑迁移：一直顶格练的人，推导目标 = reps_max = 次数轴
/// 天花板 → 第一次达标就进位加重，与旧行为一致；而从区间内某档起步
/// 的人获得逐场 +1 的平滑爬升。
ChainState chainStateFromHistory(
    List<SetEntry> lastSessionWorkingSets, ProgressionRule rule) {
  // 加练组（isExtra）是超计划的额外容量，不代表计划本身的完成水平：
  // 既不能用它最后一组的重量当档位，也不能让它的次数拉低/抬高目标。
  final ws = lastSessionWorkingSets
      .where((s) => s.kind == SetKind.working && !s.isExtra)
      .toList(growable: false);
  if (ws.isEmpty) {
    return ChainState(weightKg: 0, targetReps: rule.repsMin);
  }
  final last = ws.last;
  // 同一次训练的组时间相邻（训练总时长一般 <4 小时），
  // 不能用毫秒相等判断——每组 doneAt 至少差 1ms。
  const sessionWindowMs = 4 * 3600 * 1000;
  final sameSession = ws
      .where((s) =>
          last.doneAt - s.doneAt < sessionWindowMs &&
          s.doneAt >= last.doneAt - sessionWindowMs)
      .toList();
  final minReps =
      sameSession.map((s) => s.reps).fold(sameSession.first.reps, (a, b) => b < a ? b : a);
  final clamped = minReps < rule.repsMin
      ? rule.repsMin
      : (minReps > rule.repsMax ? rule.repsMax : minReps);
  return ChainState(weightKg: last.weightKg, targetReps: clamped);
}

/// 综合判定：会话结束对该动作走一次链。
///
/// 口径（与旧 evaluateProgression 对齐的部分）：
/// - 只统计「正式组」里的非加练组（isExtra=false）；加练组无论次数高低
///   都不参与 advance/hold/decrease；
/// - 与当前重量档相差 >5% 的组视为另一档，不参与判定；
/// - **计划组全部达标**（每组 reps >= state.targetReps；末组 RIR 只有在
///   实际记录过时才参与判定，未记录则纯按次数）才推进链；
/// - 有组低于 reps_min → 减重约 5%（负重量同向：辅助配重变得更"负"
///   = 阻力更小，方向语义一致）；
/// - 其余 → hold（重量与次数目标都不动）。
///
/// [targetSets]（P0-B）：本次计划正式组数。缺省 0 = 保持旧行为（不检查
/// 组数）；>0 时若当前重量档的正式组数少于计划组数，直接 hold 并说明
/// 「本次只完成 X/Y 组，不推进」——少做不能用达标判定换推进。
/// [logging]（v14）：'time' 时链状态里的数字是秒，达标/保持等 reason
/// 文案把「X 次」表述换成「X 秒」；数字判定逻辑完全不变。
/// [loadType]（v14）：'bodyweight' 时链切换为自重链（无重量轴，
/// 0kg 档不进位到负重）；缺省值保证所有现有调用行为不变。
ChainVerdict evaluateChain({
  required ProgressionRule rule,
  required ChainState state,
  required List<SetEntry> workingSets,
  int targetSets = 0,
  String logging = LoggingMode.reps,
  String loadType = LoadMode.weighted,
}) {
  // 计时形态：展示单位换文案，判定与数字原样（'次' → '秒'）
  final unit = logging == LoggingMode.time ? '秒' : '次';
  final enUnit = logging == LoggingMode.time ? 's' : 'reps';
  final ws = workingSets
      .where((s) => s.kind == SetKind.working && !s.isExtra)
      .toList(growable: false);
  if (ws.isEmpty) {
    return ChainVerdict(
        'hold',
        state,
        tx('本次无正式组记录，重量保持不变',
            en: 'No working sets logged this time — weight stays the same'),
        holdKind: 'no_sets');
  }
  // 注意：state.weightKg == 0（自重动作的合法档位）不在此提前返回——
  // 0 档参与正常判定（±5% 档位过滤天然只收 0kg 组），达标同样可进位到
  // 负重 2.5kg（与旧引擎 evaluateProgression 的 0+delta 行为一致）；
  // 各分支文案按实际判定生成，不会把自重动作误报成「无正式组记录」。
  // 只统计当前重量附近的正式组（重量波动 >5% 视为另一档）。
  // 负重量（辅助配重）下 5% 容差同样取绝对值，否则阈值变负、
  // 过滤恒为空 → 辅助器械动作永远判不出渐进。
  final near = ws
      .where((s) =>
          (s.weightKg - state.weightKg).abs() <=
          state.weightKg.abs() * 0.05)
      .toList(growable: false);
  if (near.isEmpty) {
    return ChainVerdict(
        'hold',
        state,
        tx('本次重量与历史档位不同，重量保持不变',
            en: 'Weight differs from your usual tier — weight stays the same'),
        holdKind: 'different_tier');
  }
  // 少做不推进（P0-B）：计划组数没练够时，即便剩下的组都达标也不能
  // 晋升；也不能因为组少就误判减重——组数不足本身就是「继续保持」。
  // 只数当前重量档的非加练正式组，加练组不能补计划组数。
  if (targetSets > 0 && near.length < targetSets) {
    return ChainVerdict(
        'hold',
        state,
        tx(
            '本次只完成 ${near.length}/$targetSets 组，不推进'
            '（仅统计当前重量档，本次共 ${ws.length} 组正式组）',
            en: 'Only ${near.length}/$targetSets sets completed this time — no progression'
                ' (current weight tier only; ${ws.length} working sets logged)'),
        holdKind: 'insufficient_sets');
  }

  final allMetTarget = near.every((s) => s.reps >= state.targetReps);
  final lastSet = near.last;
  // 余力真实性（P0-C）：只有用户实际点过余力（rirRecorded）时，末组 RIR
  // 才参与判定；未记录时 rir 只是计划默认填充值，不能拿它卡渐进——
  // 按次数判定，并在 reason 里说明「余力未记录」，让用户看得懂依据。
  final rirRecorded = lastSet.rirRecorded;
  final lastSetRirOk = !rirRecorded || lastSet.rir >= rule.rirTarget - 1; // 允许差 1 次余力
  final anyBelowMin = near.any((s) => s.reps < rule.repsMin);
  final rirNote = rirRecorded
      ? ''
      : tx('（余力未记录，本次按次数判定）',
          en: ' (RIR not recorded — judged by reps)');

  if (allMetTarget && lastSetRirOk) {
    final chain = ProgressionChain.of(rule, loadType: loadType);
    final next = chain.advance(state, rule);
    if (next == state) {
      // 自重档位（0kg）不展示「重量 0kg 触顶」——0 是档位起点不是天花板
      final capDesc = state.weightKg == 0
          ? tx(
              logging == LoggingMode.time
                  ? '自重档位已到规则链尽头（保持 ${state.targetReps} 秒）'
                  : '自重档位已到规则链尽头（次数 ${state.targetReps} 次）',
              en: 'Bodyweight tier has reached the end of the chain (${state.targetReps} $enUnit)')
          : tx(
              logging == LoggingMode.time
                  ? '已到规则链尽头（保持 ${state.targetReps} 秒、重量 ${fmtWithUnit(state.weightKg)} 触顶）'
                  : '已到规则链尽头（次数 ${state.targetReps} 次、重量 ${fmtWithUnit(state.weightKg)} 触顶）',
              en: 'Chain topped out (${state.targetReps} $enUnit at ${fmtWithUnit(state.weightKg)})');
      return ChainVerdict('hold', state,
          tx('$capDesc → 保持当前档', en: '$capDesc → hold this tier'),
          holdKind: 'chain_end');
    }
    if (next.weightKg != state.weightKg) {
      return ChainVerdict(
        'advance',
        next,
        tx(
            '${near.length} 组全部达到 ${state.targetReps} $unit目标，次数轴触顶 → 下次加重至 ${fmtWithUnit(next.weightKg)}、目标回到 ${next.targetReps} $unit$rirNote',
            en: 'All ${near.length} sets hit the ${enRepPhrase(state.targetReps, logging)} target and the rep axis is topped out → add weight to ${fmtWithUnit(next.weightKg)}, target resets to ${next.targetReps} $enUnit$rirNote'),
      );
    }
    if (!rirRecorded) {
      return ChainVerdict(
        'advance',
        next,
        tx(
            '${near.length} 组全部达到 ${state.targetReps} $unit目标 → 下次目标 ${next.targetReps} $unit（重量不变）$rirNote',
            en: 'All ${near.length} sets hit the ${enRepPhrase(state.targetReps, logging)} target → next target ${next.targetReps} $enUnit (same weight)$rirNote'),
      );
    }
    return ChainVerdict(
      'advance',
      next,
      tx(
          '${near.length} 组全部达到 ${state.targetReps} $unit目标且末组余力 ${lastSet.rir} 次 → 下次目标 ${next.targetReps} $unit（重量不变）',
          en: 'All ${near.length} sets hit the ${enRepPhrase(state.targetReps, logging)} target with last-set RIR ${lastSet.rir} → next target ${next.targetReps} $enUnit (same weight)'),
    );
  }
  if (anyBelowMin) {
    // 减重方向对负重量同样成立：delta 为负 = 正重量更轻 / 辅助配重更多
    final cut = -round05(state.weightKg.abs() * 0.05);
    return ChainVerdict(
      'decrease',
      ChainState(
          weightKg: round05(state.weightKg + cut),
          targetReps: state.targetReps),
      tx('有组未达到下限 ${rule.repsMin} $unit → 建议减重约 5%（$cut kg），先稳动作',
          en: 'Some sets missed the ${enRepPhrase(rule.repsMin, logging)} floor → reduce ~5% ($cut kg) and re-groove the form'),
    );
  }
  return ChainVerdict(
      'hold',
      state,
      tx('完成情况未达 ${state.targetReps} $unit目标 → 重量与${logging == LoggingMode.time ? '秒数' : '次数'}目标保持，继续冲$rirNote',
          en: "Target of ${state.targetReps} $enUnit not met — hold weight and target, chase more ${logging == LoggingMode.time ? 'seconds' : 'reps'}$rirNote"),
      holdKind: 'target_miss');
}
