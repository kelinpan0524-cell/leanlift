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
  /// 造一条正式组（默认 working；kind 可改为热身/力竭验证过滤）。
  SetEntry set({String kind = SetKind.working}) => SetEntry(
        sessionExerciseId: 1,
        weightKg: 20,
        reps: 10,
        kind: kind,
        doneAt: 0,
      );

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

  group('weeklyWorkingSetsByMuscle（每周组数计数）', () {
    const bench = ExerciseMeta(
        '测试卧推', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true);

    test('空数据 → 全零，键覆盖全部分区（含「其他」）', () {
      final sets = weeklyWorkingSetsByMuscle([], {});
      expect(sets.keys.toSet(), kMuscleRegions.toSet());
      expect(sets.values.every((v) => v == 0), isTrue);
    });

    test('主肌群计 1 组、次肌群计 0.5 组', () {
      // 系数本身锁死：主 1 / 次 0.5（改系数必须同步改测试与注释）
      expect(kSecondaryMuscleSetWeight, 0.5);
      final sets = weeklyWorkingSetsByMuscle([
        MapEntry('测试卧推', [set(), set(), set()]),
      ], {'测试卧推': bench});
      expect(sets['胸'], 3); // 主肌群：3 组 × 1
      expect(sets['肩'], 1.5); // 次肌群：3 组 × 0.5
      expect(sets['手臂'], 1.5);
      expect(sets['背'], 0);
    });

    test('只计正式组：热身组与力竭组都不计（与概览容量同口径）', () {
      final sets = weeklyWorkingSetsByMuscle([
        MapEntry('测试卧推', [
          set(kind: SetKind.warmup),
          set(),
          set(),
          set(kind: SetKind.failure),
        ]),
      ], {'测试卧推': bench});
      expect(sets['胸'], 2,
          reason: '2 组 working；热身组与力竭组都不计（docs/progression-rules.md §6）');
      expect(sets['肩'], 1.0);
    });

    test('多动作累加：同一肌群跨动作叠加，未知动作归「其他」', () {
      const row = ExerciseMeta(
          '测试划船', MuscleGroups(main: '背', secondary: ['手臂']), true);
      final sets = weeklyWorkingSetsByMuscle([
        MapEntry('测试卧推', [set(), set()]), // 胸 2，肩/手臂 1
        MapEntry('测试划船', [set()]), // 背 1，手臂 0.5
        MapEntry('神秘动作', [set(), set()]), // 查不到 meta → 其他 2
      ], {'测试卧推': bench, '测试划船': row});
      expect(sets['胸'], 2);
      expect(sets['背'], 1);
      expect(sets['肩'], 1);
      expect(sets['手臂'], 1.5);
      expect(sets['其他'], 2);
    });

    test('空组列表的动作不产出剂量', () {
      final sets = weeklyWorkingSetsByMuscle([
        MapEntry('测试卧推', const <SetEntry>[]),
      ], {'测试卧推': bench});
      expect(sets.values.every((v) => v == 0), isTrue);
    });
  });

  group('planWeeklyWorkingSetsByMuscle（按计划推算每周组数）', () {
    const bench = ExerciseMeta(
        '测试卧推', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true);

    test('空计划 → 全零（键覆盖全部分区）', () {
      final sets = planWeeklyWorkingSetsByMuscle([], {});
      expect(sets.keys.toSet(), kMuscleRegions.toSet());
      expect(sets.values.every((v) => v == 0), isTrue);
    });

    test('主 1 / 次 0.5：4 组卧推 → 胸 4、肩/手臂各 2', () {
      final sets = planWeeklyWorkingSetsByMuscle(
          [ex('测试卧推', sets: 4)], {'测试卧推': bench});
      expect(sets['胸'], 4);
      expect(sets['肩'], 2);
      expect(sets['手臂'], 2);
    });

    test('多动作累加：组数直接相加，不按次数加权', () {
      const row = ExerciseMeta(
          '测试划船', MuscleGroups(main: '背', secondary: ['手臂']), true);
      final sets = planWeeklyWorkingSetsByMuscle([
        ex('测试卧推', sets: 3),
        ex('测试划船', sets: 4),
      ], {'测试卧推': bench, '测试划船': row});
      expect(sets['胸'], 3);
      expect(sets['背'], 4);
      expect(sets['手臂'], 1.5 + 2);
    });

    test('weeklyFactor 只做纯缩放（循环系数由 cycleWeeklyFactor 计算）', () {
      final sets = planWeeklyWorkingSetsByMuscle(
          [ex('测试卧推', sets: 3)],
          {'测试卧推': bench},
          weeklyFactor: 7 / 3);
      expect(sets['胸'], closeTo(7, 1e-9));
      expect(sets['肩'], closeTo(3.5, 1e-9));
    });

    test('0 组动作不产出剂量', () {
      final sets = planWeeklyWorkingSetsByMuscle(
          [ex('测试卧推', sets: 0)], {'测试卧推': bench});
      expect(sets.values.every((v) => v == 0), isTrue);
    });
  });

  group('cycleWeeklyFactor（循环折算到每周）', () {
    const bench = ExerciseMeta(
        '测试卧推', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true);

    test('训练日数 = 连练数时退化为 7/(N+M)', () {
      // 2 个训练日 + 练2休1：每个周期恰好把两个模板日各练一遍
      expect(cycleWeeklyFactor(train: 2, rest: 1, trainableDays: 2),
          closeTo(7 / 3, 1e-9));
    });

    test('模板日多于连练数：每个模板日平均每周期只轮到 N/trainableDays 次', () {
      // 6 个训练日 + 练2休1：一个 3 天周期只练 2 次 → 7×2/(3×6) = 7/9
      expect(cycleWeeklyFactor(train: 2, rest: 1, trainableDays: 6),
          closeTo(7 / 9, 1e-9));
      // 4 个训练日 + 练2休1 → 7×2/(3×4) = 7/6
      expect(cycleWeeklyFactor(train: 2, rest: 1, trainableDays: 4),
          closeTo(7 / 6, 1e-9));
    });

    test('无休息日：天天练，7 天转完一轮', () {
      expect(cycleWeeklyFactor(train: 3, rest: 0, trainableDays: 3),
          closeTo(7 / 3, 1e-9));
      expect(cycleWeeklyFactor(train: 2, rest: 0, trainableDays: 4),
          closeTo(7 / 4, 1e-9));
    });

    test('参数无效 → 0（无连练天数 / 无模板日）', () {
      expect(cycleWeeklyFactor(train: 0, rest: 1, trainableDays: 3), 0);
      expect(cycleWeeklyFactor(train: 2, rest: 1, trainableDays: 0), 0);
    });

    test('整份计划组数：6 个训练日各 3 组、练2休1 → 每周胸 14 组', () {
      final sets = planWeeklyWorkingSetsByMuscle(
        [for (var i = 0; i < 6; i++) ex('测试卧推', sets: 3)],
        {'测试卧推': bench},
        weeklyFactor:
            cycleWeeklyFactor(train: 2, rest: 1, trainableDays: 6),
      );
      // 旧口径（直接 ×7/(2+1)）会得到 42 组，超出目标上限 20 → 误报过量
      expect(sets['胸'], closeTo(14, 1e-9));
      expect(sets['肩'], closeTo(7, 1e-9));
      expect(weeklySetStatusOf('胸', sets['胸']!), WeeklySetStatus.onTarget);
    });
  });

  group('每周组数目标区间与状态', () {
    test('目标区间：胸/背/腿 10-20，肩/手臂 8-16，核心 6-12', () {
      expect(kWeeklySetTargets['胸']!.min, 10);
      expect(kWeeklySetTargets['胸']!.max, 20);
      expect(kWeeklySetTargets['背']!.min, 10);
      expect(kWeeklySetTargets['背']!.max, 20);
      expect(kWeeklySetTargets['腿']!.min, 10);
      expect(kWeeklySetTargets['腿']!.max, 20);
      expect(kWeeklySetTargets['肩']!.min, 8);
      expect(kWeeklySetTargets['肩']!.max, 16);
      expect(kWeeklySetTargets['手臂']!.min, 8);
      expect(kWeeklySetTargets['手臂']!.max, 16);
      expect(kWeeklySetTargets['核心']!.min, 6);
      expect(kWeeklySetTargets['核心']!.max, 12);
      expect(kWeeklySetTargets.containsKey('其他'), isFalse,
          reason: '「其他」不是真实肌群，不设目标');
    });

    test('状态：低于下限不足、区间内（含边界）达标、高于上限过量', () {
      expect(weeklySetStatusOf('胸', 9.5), WeeklySetStatus.low);
      expect(weeklySetStatusOf('胸', 10), WeeklySetStatus.onTarget);
      expect(weeklySetStatusOf('胸', 20), WeeklySetStatus.onTarget);
      expect(weeklySetStatusOf('胸', 20.5), WeeklySetStatus.high);
      expect(weeklySetStatusOf('核心', 5.5), WeeklySetStatus.low);
      expect(weeklySetStatusOf('核心', 12), WeeklySetStatus.onTarget);
      expect(weeklySetStatusOf('核心', 12.5), WeeklySetStatus.high);
    });

    test('无目标分区（其他）→ null', () {
      expect(weeklySetStatusOf('其他', 100), isNull);
      expect(weeklySetStatusOf('不存在的肌群', 5), isNull);
    });

    test('空数据：各肌群 0 组 → 全部不足', () {
      final sets = weeklyWorkingSetsByMuscle([], {});
      for (final r in kWeeklySetTargets.keys) {
        expect(weeklySetStatusOf(r, sets[r]!), WeeklySetStatus.low,
            reason: '$r 空数据应为不足');
      }
    });
  });
}
