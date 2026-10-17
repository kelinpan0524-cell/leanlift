// 肌肉洞察纯函数测试：未练点名 + 计划静态命中预览。
// 不依赖 Flutter/DB，全部走 engine.dart 导出的纯函数。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/engine/engine.dart';

/// 造一条计划动作（name/sets/reps 区间可配，其余字段给合理默认）。
PlanExercise ex(String name,
        {int sets = 3, int repsMin = 8, int repsMax = 12}) =>
    PlanExercise(
      dayId: 1,
      name: name,
      orderIdx: 0,
      sets: sets,
      repsMin: repsMin,
      repsMax: repsMax,
      restSec: 90,
      kind: 'assistance',
      rule: ProgressionRule(repsMin: repsMin, repsMax: repsMax),
    );

void main() {
  group('untrainedRegions（未练点名）', () {
    test('空 map → 六大肌群全部点名（「其他」永不点名）', () {
      expect(untrainedRegions({}),
          ['胸', '肩', '背', '手臂', '腿', '核心']);
    });

    test('全零 map → 六大肌群全部点名', () {
      final allZero = {for (final r in kMuscleRegions) r: 0.0};
      expect(untrainedRegions(allZero),
          ['胸', '肩', '背', '手臂', '腿', '核心']);
    });

    test('部分命中：只点未练到的，顺序按 kMuscleRegions 规范序', () {
      final share = {'胸': 0.5, '腿': 0.5};
      expect(untrainedRegions(share), ['肩', '背', '手臂', '核心']);
    });

    test('全部命中（每区 ≥ threshold）→ 不点名', () {
      // 每区 1/6 ≈ 0.167，远高于缺省 threshold 0.02
      final hit = {for (final r in kMuscleRegions) r: 1.0 / 6};
      expect(untrainedRegions(hit), isEmpty);
    });

    test('threshold 语义：占比 < threshold 才点名（边界值不点）', () {
      final share = {'胸': 0.05, '腿': 0.95};
      // 0.05 < 0.05 为假 → 胸不算未练
      expect(untrainedRegions(share, threshold: 0.05),
          ['肩', '背', '手臂', '核心']);
      // 阈值提高后胸落入点名区
      expect(untrainedRegions(share, threshold: 0.06),
          ['胸', '肩', '背', '手臂', '核心']);
    });

    test('「其他」不参与点名：只有其他有量时仍点名全部六区', () {
      expect(untrainedRegions({'其他': 1.0}),
          ['胸', '肩', '背', '手臂', '腿', '核心']);
    });
  });

  group('planMuscleShare（计划静态命中预览）', () {
    test('空计划 → 全零（键覆盖全部分区）', () {
      final share = planMuscleShare([], {});
      expect(share.keys.toSet(), kMuscleRegions.toSet());
      expect(share.values.every((v) => v == 0), isTrue);
    });

    test('主/次肌群 1:0.5 权重 + 归一化和为 1', () {
      final metas = {
        '测试卧推': const ExerciseMeta(
            '测试卧推', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true),
      };
      // unit = 4 组 × 中位 7.5 次 = 30；主 30，次各 15 → 总 60
      final share = planMuscleShare([ex('测试卧推', sets: 4, repsMin: 5, repsMax: 10)], metas);
      expect(share['胸'], closeTo(0.5, 1e-9));
      expect(share['肩'], closeTo(0.25, 1e-9));
      expect(share['手臂'], closeTo(0.25, 1e-9));
      expect(share.values.fold(0.0, (a, b) => a + b), closeTo(1.0, 1e-9));
    });

    test('多动作混合：按 sets × 中位次数加权归一化', () {
      final metas = {
        '测试卧推': const ExerciseMeta(
            '测试卧推', MuscleGroups(main: '胸', secondary: []), true),
        '测试划船': const ExerciseMeta(
            '测试划船', MuscleGroups(main: '背', secondary: ['手臂']), true),
      };
      // 卧推 3×10=30 全记胸；划船 4×7.5=30 主记背 + 手臂 15 → 总 75
      final share = planMuscleShare([
        ex('测试卧推', sets: 3, repsMin: 10, repsMax: 10),
        ex('测试划船', sets: 4, repsMin: 5, repsMax: 10),
      ], metas);
      expect(share['胸'], closeTo(30 / 75, 1e-9));
      expect(share['背'], closeTo(30 / 75, 1e-9));
      expect(share['手臂'], closeTo(15 / 75, 1e-9));
      expect(share.values.fold(0.0, (a, b) => a + b), closeTo(1.0, 1e-9));
    });

    test('查不到 meta 的动作归入「其他」', () {
      final share = planMuscleShare([ex('神秘动作')], {});
      expect(share['其他'], closeTo(1.0, 1e-9));
      expect(share['胸'], 0.0);
    });

    test('改组数/次数会改变占比（编辑器实时重算的依据）', () {
      final metas = {
        '测试卧推': const ExerciseMeta(
            '测试卧推', MuscleGroups(main: '胸', secondary: []), true),
        '测试划船': const ExerciseMeta(
            '测试划船', MuscleGroups(main: '背', secondary: []), true),
      };
      final before = planMuscleShare([
        ex('测试卧推', sets: 3),
        ex('测试划船', sets: 3),
      ], metas);
      final after = planMuscleShare([
        ex('测试卧推', sets: 6), // 组数翻倍 → 胸占比升高
        ex('测试划船', sets: 3),
      ], metas);
      expect(after['胸']!, greaterThan(before['胸']!));
      expect(after['背']!, lessThan(before['背']!));
    });
  });
}
