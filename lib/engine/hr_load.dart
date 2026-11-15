import '../l10n/lang.dart';

/// 循环负荷（2026-10-17 Arono：训练后按心率区间自动算负荷，与容量
/// 统计并列）。Edwards TRIMP 口径：每个采样按心率储备百分比落
/// Z1-Z5 区间（权重 1-5），负荷 = Σ(区间权重 × 停留分钟)。采样约
/// 1Hz，每个采样按 1 秒计。纯 Dart 可单测；入参用记录类型，避免
/// 引擎耦合 db/sqflite。

/// 心率采样（引擎侧轻量记录；UI 从 db 的 HrPoint 映射）。
typedef HrSample = ({int ts, int bpm});

/// 循环负荷结果。
class HrLoadResult {
  const HrLoadResult({
    required this.trimp,
    required this.zoneSec,
    required this.hrMaxUsed,
    required this.hrRestUsed,
  });

  /// 循环负荷（≈加权分钟数：全程 Z3 一小时 ≈ 180）。
  final double trimp;

  /// Z1..Z5 各区间停留秒数。
  final List<int> zoneSec;

  /// 实际采用的最大/静息心率（展示与 AI 解析注明口径用）。
  final int hrMaxUsed;
  final int hrRestUsed;

  /// 非零区间摘要「Z2 18分 · Z3 12分」；全零返回空串。
  String zoneSummary() {
    final parts = <String>[];
    for (var i = 0; i < zoneSec.length; i++) {
      final m = (zoneSec[i] / 60).round();
      if (m > 0) parts.add('Z${i + 1} $m${tx('分', en: 'm')}');
    }
    return parts.join(' · ');
  }
}

int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

/// 最大心率取值优先级：手动指定 > 220-年龄 > 本场实测峰值 > 190 兜底
/// （实测峰值当上限会低估高区，但比拍脑袋的 190 更个人化）。
int resolveHrMax({
  required int age,
  required int override,
  required int observedPeak,
}) {
  if (override > 0) return _clamp(override, 120, 250);
  if (age > 0) return _clamp(220 - age, 120, 220);
  if (observedPeak > 0) return _clamp(observedPeak, 120, 250);
  return 190;
}

/// Edwards 循环负荷：[samples] 为会话内全部采样（时间无关，只看 bpm）。
/// 年龄/手动最大心率来自设置；静息心率默认 60。
HrLoadResult computeHrLoad(
  List<HrSample> samples, {
  required int age,
  required int hrRest,
  required int hrMaxOverride,
}) {
  if (samples.isEmpty) {
    return HrLoadResult(
        trimp: 0,
        zoneSec: const [0, 0, 0, 0, 0],
        hrMaxUsed: 0,
        hrRestUsed: hrRest > 0 ? hrRest : 60);
  }
  var peak = 0;
  for (final s in samples) {
    if (s.bpm > peak) peak = s.bpm;
  }
  final rest = hrRest > 0 ? hrRest : 60;
  final max =
      resolveHrMax(age: age, override: hrMaxOverride, observedPeak: peak);
  final range = max - rest;
  if (range <= 10) {
    // 参数异常（如最大心率填得比静息还低）：返回零负荷，不硬算
    return HrLoadResult(
        trimp: 0, zoneSec: const [0, 0, 0, 0, 0], hrMaxUsed: max, hrRestUsed: rest);
  }
  final zoneSecExact = List<double>.filled(5, 0);
  final hasTs = samples.any((s) => s.ts > 0);
  var trimp = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    final pct = (s.bpm - rest) / range;
    final zone = switch (pct) {
      < 0.5 => 0,
      < 0.6 => 1,
      < 0.7 => 2,
      < 0.8 => 3,
      < 0.9 => 4,
      _ => 5,
    };
    final double dtSec;
    if (!hasTs) {
      dtSec = 1.0;
    } else if (i + 1 < samples.length && samples[i + 1].ts >= s.ts) {
      final diffMs = samples[i + 1].ts - s.ts;
      // 超过 30 秒的断连空档不把静默整段算进高心率负荷，按单点 1 秒记
      dtSec = (diffMs <= 0 || diffMs > 30000) ? 1.0 : diffMs / 1000.0;
    } else if (i > 0 && s.ts > samples[i - 1].ts) {
      final diffMs = s.ts - samples[i - 1].ts;
      dtSec = diffMs > 30000 ? 1.0 : diffMs / 1000.0;
    } else {
      dtSec = 1.0;
    }
    if (zone == 0) continue;
    zoneSecExact[zone - 1] += dtSec;
    trimp += zone * (dtSec / 60.0);
  }
  final zoneSec = [for (final sec in zoneSecExact) sec.round()];
  return HrLoadResult(
      trimp: trimp, zoneSec: zoneSec, hrMaxUsed: max, hrRestUsed: rest);
}
