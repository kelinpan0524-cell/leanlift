import 'package:flutter_test/flutter_test.dart';

import 'package:baoji_timer/engine/plates.dart';
import 'package:baoji_timer/engine/weight_unit.dart';

void main() {
  // 每个用例自带单位状态，先归位 kg 防串扰
  setUp(() => WeightUnits.setResolved(WeightUnit.kg));

  group('kg↔lb 换算', () {
    test('精确定义：1lb = 0.45359237kg', () {
      expect(lbToKg(1), closeTo(0.45359237, 1e-12));
      expect(kgToLb(1), closeTo(2.2046226218, 1e-9));
      // 双向换算回到原值（浮点容差内）
      expect(lbToKg(kgToLb(100)), closeTo(100, 1e-9));
    });

    test('lbSnap 落 0.5lb 网格', () {
      expect(lbSnap(220.46), 220.5);
      expect(lbSnap(220.2), 220.0);
      expect(lbSnap(45.0), 45.0);
      expect(lbSnap(-66.14), -66.0); // 负数（辅助配重）同样 snap
      expect(lbSnap(0), 0);
    });

    test('换算 + snap：220lb 存 99.79kg 回显仍 220lb', () {
      final kg = lbToKg(220);
      expect(kg, closeTo(99.7903, 1e-4));
      WeightUnits.setResolved(WeightUnit.lb);
      expect(fmtVal(kg), '220'); // 回显无漂移
    });
  });

  group('格式化（fmtVal / fmtWithUnit / unitLabel）', () {
    test('kg 模式与旧口径逐字节一致', () {
      expect(fmtVal(100), '100');
      expect(fmtVal(62.5), '62.5');
      expect(fmtVal(102.25), '102.25');
      expect(fmtWithUnit(100), '100kg');
      expect(fmtWithUnit(-30), '-30kg');
      expect(unitLabel(), 'kg');
    });

    test('lb 模式换算并带 lb 后缀', () {
      WeightUnits.setResolved(WeightUnit.lb);
      expect(fmtVal(100), '220.5'); // 100kg = 220.46lb → snap 220.5
      expect(fmtWithUnit(100), '220.5lb');
      expect(fmtVal(20), '44'); // 20kg = 44.09lb → 44
      expect(fmtWithUnit(0), '0lb');
      expect(unitLabel(), 'lb');
    });
  });

  group('步长（stepLabels / nudgedKg）', () {
    test('kg 模式沿用原四档', () {
      expect(stepLabels(), [0.5, 1.25, 2.5, 5.0]);
    });

    test('lb 模式换美制片组', () {
      WeightUnits.setResolved(WeightUnit.lb);
      expect(stepLabels(), [1.25, 2.5, 5, 10]);
    });

    test('kg 模式直接加步长（与旧行为一致）', () {
      expect(nudgedKg(100, 2.5), 102.5);
      expect(nudgedKg(100, -0.5), 99.5);
    });

    test('lb 模式先 snap 网格再加步长，连续点按不漂移', () {
      WeightUnits.setResolved(WeightUnit.lb);
      // 100kg → snap 220.5lb → +2.5lb = 223lb → 换算回 kg
      final one = nudgedKg(100, 2.5);
      expect(kgToLb(one), closeTo(223, 1e-9));
      // 从 220lb（=99.79kg 脏值）步进：先 snap 回 220 再 ±，不累积
      final dirty = lbToKg(220);
      expect(kgToLb(nudgedKg(dirty, 2.5)), closeTo(222.5, 1e-9));
      expect(kgToLb(nudgedKg(dirty, -2.5)), closeTo(217.5, 1e-9));
    });
  });

  group('lb 杠铃片速配（复用 platesForLoad）', () {
    test('45lb 杆 + 美制片组能配平常见重量', () {
      // 225lb（杠铃卧推经典 two-plate）：每边两块 45lb
      final b = platesForLoad(225, barKg: kLbBar, inventory: kLbPlateSizes);
      expect(b.exact, isTrue);
      expect(b.perSide, [45, 45]);
      // 135lb（空杆 + 每边 1×45lb）→ 每边 45
      final b2 = platesForLoad(135, barKg: kLbBar, inventory: kLbPlateSizes);
      expect(b2.exact, isTrue);
      expect(b2.perSide, [45]);
    });

    test('空杆与配不平口径', () {
      final empty = platesForLoad(45, barKg: kLbBar, inventory: kLbPlateSizes);
      expect(empty.perSide, isEmpty);
      expect(empty.exact, isTrue);
      // 50lb：每边 2.5lb，exact
      final b = platesForLoad(50, barKg: kLbBar, inventory: kLbPlateSizes);
      expect(b.exact, isTrue);
      expect(b.perSide, [2.5]);
      // 46lb：每边 0.5lb 配不出 → 配不平余 0.5
      final b2 = platesForLoad(46, barKg: kLbBar, inventory: kLbPlateSizes);
      expect(b2.exact, isFalse);
      expect(b2.leftoverPerSide, closeTo(0.5, 1e-9));
    });
  });

  group('WeightUnits 全局切换', () {
    test('toggle 双向切换', () {
      expect(WeightUnits.current, WeightUnit.kg);
      WeightUnits.toggle();
      expect(WeightUnits.current, WeightUnit.lb);
      expect(WeightUnits.isLb, isTrue);
      WeightUnits.toggle();
      expect(WeightUnits.current, WeightUnit.kg);
      expect(WeightUnits.isLb, isFalse);
    });
  });
}
