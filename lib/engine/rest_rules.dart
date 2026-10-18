import '../l10n/lang.dart';
import '../models/models.dart';

/// 休息时长规则（调研条目 9，docs/open-source-research-2026-09-25.md）：
/// - LiftLog 的结果分档：达标给标准休息、未达标给更长休息；
/// - Flexify 的两条：热身组不触发计时、逐动作覆盖休息时长；
/// - Strong 的热身/正式组分设休息同方向。
///
/// 设计约束（AGENTS.md）：休息规则保持可预期可配置——分档只按
/// 「刚完成那组是否达标」二分，倍率固定，不做 Fitbod 式的不可持久动态推荐。

/// 刚完成那组的结果档位。
enum RestTier {
  /// 热身组：不触发休息计时（Flexify 规则）。
  none,

  /// 达标正式组：给标准休息。
  standard,

  /// 未达标正式组 / 力竭组：给更长休息（LiftLog 的 failureRest 思路）。
  extended,
}

/// 未达标档放大系数：×1.5 后向上取整到 30 秒网格，
/// 结果仍落在可预期的整档上（180→270、120→180、60→90）。
const kRestExtendedFactor = 1.5;

/// 休息秒数的取整网格与上限（上限与 AI 解析 rest_sec 钳制一致）。
const kRestGridSec = 30;
const kRestMaxSec = 600;

/// 按刚完成那组的结果定档。
/// [kind] 该组类型（warmup/working/failure）；[reps] 该组次数；
/// [repsMax] 该动作次数上限（达到即视为达标）。
RestTier restTierForSet({
  required String kind,
  required int reps,
  required int repsMax,
}) {
  if (kind == SetKind.warmup) return RestTier.none;
  if (kind == SetKind.failure) return RestTier.extended;
  return reps >= repsMax ? RestTier.standard : RestTier.extended;
}

/// 标准休息 → 未达标休息：×1.5 向上取 30 秒网格，下限不低于原值。
int extendRestSec(int baseSec) =>
    (((baseSec * kRestExtendedFactor) / kRestGridSec).ceil() * kRestGridSec)
        .clamp(baseSec, kRestMaxSec);

/// 综合入口：刚完成一组后该歇多久（秒）。0 = 不触发计时（热身组）。
///
/// [overriddenSec] 逐动作覆盖（计划里该动作配置的 rest_sec，>0 生效，
/// Flexify 的「逐动作覆盖休息时长」）；[baseSec] 覆盖未配置时的全局基础值
/// （按 compound/assistance 区分的用户偏好，engine.defaultRestSec 的产物）。
int restSecondsAfterSet({
  required String kind,
  required int reps,
  required int repsMax,
  required int baseSec,
  int? overriddenSec,
}) {
  final tier = restTierForSet(kind: kind, reps: reps, repsMax: repsMax);
  if (tier == RestTier.none) return 0;
  final base = (overriddenSec != null && overriddenSec > 0)
      ? overriddenSec
      : baseSec.clamp(5, kRestMaxSec);
  return tier == RestTier.extended ? extendRestSec(base) : base;
}

// ================= 心率自适应休息建议（P2-F） =================
//
// 心率参与决策，但不替用户改休息时间：本函数只回答「现在该多歇、
// 正常歇、还是可以提前开练」，并给一句话原因。UI 只在休息页把
// extend / shorten 显示成建议 + 手动 ±30 秒按钮——绝不自动加时，
// 也绝不弹窗。没连接/没读数时返回 ok 的「无数据」分支，现有休息
// 流程完全不受影响。

/// 建议动作。
enum RestAdviceAction {
  /// 心率仍偏高：建议多休 30 秒（用户点按钮才生效）。
  extend,

  /// 心率在可接受区间（或没有数据）：按原计划休息。
  ok,

  /// 心率已回落：可以提前 30 秒开练（用户点按钮才生效）。
  shorten,
}

/// 高心率阈值：当前心率比静息高 [kRestAdviceHighDelta] bpm 以上，
/// 视为「还没缓过来」。休息 60-90 秒后多数人会从训练峰值回落
/// 30-50 bpm；仍高出静息 40 bpm 说明恢复不足。是建议阈值，不是
/// 医学判断。
const int kRestAdviceHighDelta = 40;

/// 末组余力 ≤1（接近力竭）时，高心率阈值下调到 30 bpm：力竭组
/// 恢复更慢，心率略高也值得多歇一会儿。
const int kRestAdviceHighDeltaHardSet = 30;

/// 已恢复阈值：距静息 [kRestAdviceRecoveredDelta] bpm 以内，
/// 视为心率已基本回落。
const int kRestAdviceRecoveredDelta = 15;

/// 只有剩余 ≥60 秒才建议「提前 30 秒」：剩余太短时减时没有意义，
/// 还可能把休息减到只剩几秒。
const int kRestAdviceShortenMinRemainingSec = 60;

/// 提前开练要求末组余力 ≥2：接近力竭的组不因心率低就催着开练。
const int kRestAdviceShortenMinRir = 2;

/// 一条休息建议：动作 + 面向用户的一句话原因。
class RestAdvice {
  const RestAdvice(this.action, this.reason);

  final RestAdviceAction action;
  final String reason;
}

/// 心率自适应休息建议（纯函数，便于单测）。
///
/// [currentBpm] 当前心率；null 或非正数 = 没有数据（未连接/读数无效）。
/// [restingBpm] 用户设置里的静息心率（默认 60；越界值按 60 兜底）。
/// [remainingSec] 本次休息剩余秒数（≤0 视为已结束）。
/// [rir] 刚完成那组的余力 0-5（越接近 0 越力竭；未记录时传 2）。
///
/// 判定顺序：
/// 1. 没有心率数据 → ok（不改变现有流程）；
/// 2. 休息已结束 → ok；
/// 3. 心率 ≥ 静息 + 阈值（力竭组用更低阈值）→ extend；
/// 4. 心率 ≤ 静息 + 15，且剩余 ≥60 秒、末组余力 ≥2 → shorten；
/// 5. 其余 → ok。
RestAdvice restAdvice(
  int? currentBpm,
  int restingBpm,
  int remainingSec,
  int rir,
) {
  // 静息心率的合法区间有界：设置被写坏时退回默认 60，不拿脏值算阈值。
  final rest = (restingBpm <= 0 || restingBpm > 120) ? 60 : restingBpm;
  final r = rir < 0 ? 0 : (rir > 5 ? 5 : rir);

  if (currentBpm == null || currentBpm <= 0) {
    return RestAdvice(
      RestAdviceAction.ok,
      tx('暂无心率数据，按计划休息',
          en: 'No heart-rate data — rest as planned'),
    );
  }
  if (remainingSec <= 0) {
    return RestAdvice(
      RestAdviceAction.ok,
      tx('休息已结束，按计划开练', en: 'Rest is over — start the next set'),
    );
  }

  final highDelta = r <= 1
      ? kRestAdviceHighDeltaHardSet
      : kRestAdviceHighDelta;
  if (currentBpm - rest >= highDelta) {
    return RestAdvice(
      RestAdviceAction.extend,
      tx('心率仍高，建议多休 30 秒',
          en: 'Heart rate still high — consider 30s more rest'),
    );
  }

  // 心率低也不催接近力竭的组提前开练：余力不足时按原计划休息。
  if (r < kRestAdviceShortenMinRir) {
    return RestAdvice(
      RestAdviceAction.ok,
      tx('末组接近力竭，按计划休息',
          en: 'Last set was near failure — rest as planned'),
    );
  }
  if (currentBpm - rest <= kRestAdviceRecoveredDelta &&
      remainingSec >= kRestAdviceShortenMinRemainingSec) {
    return RestAdvice(
      RestAdviceAction.shorten,
      tx('心率已恢复，可提前 30 秒开练',
          en: 'Heart rate recovered — you can start 30s early'),
    );
  }
  return RestAdvice(
    RestAdviceAction.ok,
    tx('心率平稳，按计划休息', en: 'Heart rate steady — rest as planned'),
  );
}
