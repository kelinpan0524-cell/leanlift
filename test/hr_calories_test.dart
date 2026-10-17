import 'package:baoji_timer/engine/engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 60 个每秒一条的恒速采样 = 完整 60 秒
  List<HrSample> chain(int bpm, {int n = 60}) => [
        for (var i = 0; i < n; i++) (ts: i * 1000, bpm: bpm),
      ];

  group('keyTelKcalPerMin', () {
    test('Keytel 2005 系数：HR150/70kg/30 岁', () {
      expect(keyTelKcalPerMin(150, 70, 30, HrSex.male),
          closeTo(14.22, 0.05));
      expect(keyTelKcalPerMin(150, 70, 30, HrSex.female),
          closeTo(9.58, 0.05));
    });

    test('性别未设取男女两式均值', () {
      expect(keyTelKcalPerMin(150, 70, 30, HrSex.unset),
          closeTo((14.22 + 9.58) / 2, 0.05));
    });
  });

  group('computeHrCalories', () {
    test('60 秒积分 = 速率 × 抗阻修正系数', () {
      final r = computeHrCalories(chain(150),
          bodyWeightKg: 70, age: 30, sex: HrSex.male);
      expect(r.activeKcal, closeTo(14.22 * kResistanceFactor, 0.05));
      // 无高区间数据时 EPOC 取基数 6
      expect(r.epocKcal, closeTo(6, 0.001));
      expect(r.totalKcal, closeTo(14.22 * kResistanceFactor + 6, 0.05));
    });

    test('低心率负值被静息地板（1 MET）钳住', () {
      // HR40 时男性公式出负值；70kg 地板 = 1.225 kcal/min
      final r = computeHrCalories(chain(40),
          bodyWeightKg: 70, age: 30, sex: HrSex.male);
      expect(r.activeKcal, closeTo(1.225 * kResistanceFactor, 0.05));
    });

    test('采样间隔按真实时间戳加权，超长空洞封顶 10 秒', () {
      // 只有两条采样、间隔 60 秒：首条 1 秒 + 间隔钳到 10 秒 = 11 秒
      final r = computeHrCalories([
        (ts: 0, bpm: 150),
        (ts: 60000, bpm: 150),
      ], bodyWeightKg: 70, age: 30, sex: HrSex.male);
      expect(r.activeKcal,
          closeTo(14.22 * kResistanceFactor * 11 / 60, 0.05));
    });

    test('EPOC 随 Z4/Z5 时长增长并钳在 70', () {
      final r = computeHrCalories(chain(150, n: 2),
          bodyWeightKg: 70,
          age: 30,
          sex: HrSex.male,
          z4Sec: 600, // 10 分钟 ×2
          z5Sec: 300); // 5 分钟 ×2.5 → 6+20+12.5
      expect(r.epocKcal, closeTo(38.5, 0.01));

      final capped = computeHrCalories(chain(150, n: 2),
          bodyWeightKg: 70, age: 30, sex: HrSex.male, z5Sec: 7200);
      expect(capped.epocKcal, 70);
    });

    test('空采样返回零；缺年龄/体重走兜底不抛异常', () {
      final empty = computeHrCalories(const [],
          bodyWeightKg: 70, age: 30, sex: HrSex.male);
      expect(empty.activeKcal, 0);
      expect(empty.totalKcal, 0);

      final fallback = computeHrCalories(chain(120),
          bodyWeightKg: 0, age: 0, sex: HrSex.unset);
      expect(fallback.activeKcal, greaterThan(0));
    });
  });
}
