import 'package:flutter_test/flutter_test.dart';

import 'package:baoji_timer/engine/hr_load.dart';

void main() {
  // 基准口径：静息 60、年龄 30 → 最大 190，储备区间 130。
  // 50%→125 / 60%→138 / 70%→151 / 80%→164 / 90%→177。
  HrSample s(int bpm) => (ts: 0, bpm: bpm);

  group('resolveHrMax（最大心率取值优先级）', () {
    test('手动指定优先并截断到合理范围', () {
      expect(resolveHrMax(age: 30, override: 200, observedPeak: 180), 200);
      expect(resolveHrMax(age: 30, override: 99, observedPeak: 180), 120);
      expect(resolveHrMax(age: 30, override: 300, observedPeak: 180), 250);
    });
    test('无手动 → 220-年龄（钳制）', () {
      expect(resolveHrMax(age: 30, override: 0, observedPeak: 180), 190);
      expect(resolveHrMax(age: 5, override: 0, observedPeak: 180), 215);
      expect(resolveHrMax(age: 95, override: 0, observedPeak: 180), 125);
    });
    test('都没填 → 实测峰值兜底；再没有 → 190', () {
      expect(resolveHrMax(age: 0, override: 0, observedPeak: 176), 176);
      expect(resolveHrMax(age: 0, override: 0, observedPeak: 0), 190);
    });
  });

  group('computeHrLoad（Edwards TRIMP）', () {
    HrLoadResult load(List<HrSample> samples, {int hrRest = 60}) =>
        computeHrLoad(samples, age: 30, hrRest: hrRest, hrMaxOverride: 0);

    test('区间边界分档（Z1-Z5）', () {
      final r = load([
        s(125), // 恰 50% → Z1
        s(138), // 恰 60% → Z2
        s(151), // 恰 70% → Z3
        s(164), // 恰 80% → Z4
        s(177), // 恰 90% → Z5
        s(100), // <50% 不计
      ]);
      expect(r.zoneSec, [1, 1, 1, 1, 1]);
      expect(r.hrMaxUsed, 190);
      expect(r.hrRestUsed, 60);
    });

    test('负荷 = Σ(区间权重/60)：60 采样全 Z5 → trimp 5', () {
      final r = load([for (var i = 0; i < 60; i++) s(180)]);
      expect(r.zoneSec[4], 60);
      expect(r.trimp, closeTo(5.0, 1e-9));
    });

    test('混合区间加权', () {
      final r = load([
        for (var i = 0; i < 30; i++) s(165), // Z4
        for (var i = 0; i < 30; i++) s(180), // Z5
      ]);
      expect(r.zoneSec[3], 30);
      expect(r.zoneSec[4], 30);
      expect(r.trimp, closeTo(4.5, 1e-9));
    });

    test('静息心率参与分档', () {
      // 静息 50 → 区间 140：90% = 176
      final r = computeHrLoad([s(175), s(176)],
          age: 30, hrRest: 50, hrMaxOverride: 0);
      expect(r.zoneSec[3], 1);
      expect(r.zoneSec[4], 1);
    });

    test('参数异常（最大心率≈静息，储备区间过窄）返回零负荷', () {
      // override 65 会被钳到 120，真正触发零负荷要靠静息贴近最大值
      final r = computeHrLoad([s(170)],
          age: 30, hrRest: 115, hrMaxOverride: 120);
      expect(r.trimp, 0);
      expect(r.zoneSec, [0, 0, 0, 0, 0]);
      expect(r.hrMaxUsed, 120);
    });

    test('空采样返回零负荷', () {
      final r = load(const []);
      expect(r.trimp, 0);
      expect(r.hrMaxUsed, 0);
    });
  });

  group('zoneSummary', () {
    test('只列非零区间，分钟四舍五入', () {
      const r = HrLoadResult(
          trimp: 9, zoneSec: [0, 1080, 720, 0, 30], hrMaxUsed: 190, hrRestUsed: 60);
      expect(r.zoneSummary(), 'Z2 18分 · Z3 12分 · Z5 1分');
    });
    test('全零返回空串', () {
      const r = HrLoadResult(
          trimp: 0, zoneSec: [0, 0, 0, 0, 0], hrMaxUsed: 190, hrRestUsed: 60);
      expect(r.zoneSummary(), '');
    });
  });
}
