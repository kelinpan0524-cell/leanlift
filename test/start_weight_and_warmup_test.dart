import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/engine/weight_unit.dart';
import 'package:baoji_timer/presets/exercise_library.dart';
import 'package:baoji_timer/presets/start_weights.dart';
import 'package:baoji_timer/services/session_controller.dart';

/// P2-A：首次训练的起始重量兜底 + 热身阶梯。
void main() {
  group('presetStartOf 兜底（P2-A）', () {
    test('内置计划显式起始重量优先', () {
      expect(presetStartOf('杠铃卧推'), 45);
      expect(presetStartOf('上斜哑铃卧推'), 16);
      expect(presetStartOf('引体向上'), 0);
    });

    test('高频动作显式覆盖', () {
      expect(presetStartOf('高位下拉'), 30);
      expect(presetStartOf('窄距高位下拉'), 30);
    });

    test('按器械 + 复合/单关节推导', () {
      expect(presetStartOf('坐姿杠铃推举'), 40, reason: '杠铃复合');
      expect(presetStartOf('杠铃耸肩'), 20, reason: '杠铃单关节');
      expect(presetStartOf('哑铃卧推'), 10, reason: '哑铃复合（每只）');
      expect(presetStartOf('哑铃侧平举'), 6, reason: '哑铃单关节（每只）');
      expect(presetStartOf('腿屈伸（股四头）'), 20, reason: '固定器械');
      expect(presetStartOf('绳索夹胸'), 10, reason: '龙门架绳索');
      expect(presetStartOf('徒手深蹲'), 0, reason: '自重');
      expect(presetStartOf('弹力带面拉'), 0, reason: '弹力带');
    });

    test('动作别名先归一再查显式值/器械', () {
      expect(presetStartOf('平板卧推'), 45, reason: '别名归一到杠铃卧推');
      expect(presetStartOf('背阔肌下拉'), 30, reason: '别名归一到高位下拉的覆盖值');
    });

    test('半角括号的动作名也归一到全角库名', () {
      expect(presetStartOf('上斜杠铃卧推(轻)'), 32.5);
      expect(presetStartOf('曲杠弯举(EZ杠)'), 20, reason: '按杠铃单关节启发式');
    });

    test('词表外动作保持 20kg 旧兜底', () {
      expect(presetStartOf('动作乙'), 20);
    });
  });

  group('热身阶梯（P2-A）', () {
    test('杠铃大重量：空杆 → 40% / 60% / 80%', () {
      final plan = warmupPlanFor(targetWeightKg: 100, gear: '杠铃');
      expect(plan.mode, WarmupMode.standard);
      expect(plan.steps, const [
        WarmupStep(20, 5),
        WarmupStep(40, 5, percent: 40),
        WarmupStep(60, 3, percent: 60),
        WarmupStep(80, 1, percent: 80),
      ]);
    });

    test('杠铃 45kg：空杆 + 被空杆吞掉的 40% 档不重复', () {
      final plan = warmupPlanFor(targetWeightKg: 45, gear: '杠铃');
      expect(plan.mode, WarmupMode.standard);
      expect(plan.steps.map((s) => s.weightKg), [20, 27.5, 35]);
      expect(plan.steps.first.percent, isNull, reason: '第一步是空杆');
      expect(plan.steps.last.reps, 1, reason: '80% 做 1 次');
    });

    test('绳索/器械大重量：直接 40/60/80，不硬加空杆', () {
      final plan = warmupPlanFor(targetWeightKg: 100, gear: '龙门架绳索');
      expect(plan.mode, WarmupMode.standard);
      expect(plan.steps.length, 3);
      expect(plan.steps.first.percent, 40);
      expect(plan.steps.every((s) => s.percent != null), isTrue);
    });

    test('≤40kg：简化成 40% / 60% 两档', () {
      final plan = warmupPlanFor(targetWeightKg: 30, gear: '哑铃');
      expect(plan.mode, WarmupMode.light);
      expect(plan.steps, const [
        WarmupStep(12, 5, percent: 40),
        WarmupStep(18, 3, percent: 60),
      ]);
    });

    test('≤40kg 杠铃也至少给空杆步（20/30/40kg）', () {
      for (final target in [20.0, 30.0, 40.0]) {
        final plan = warmupPlanFor(targetWeightKg: target, gear: '杠铃');
        expect(plan.mode, WarmupMode.light, reason: '$target kg 走简化版');
        expect(plan.steps, isNotEmpty, reason: '$target kg 必须有热身建议');
        expect(plan.steps.first.percent, isNull, reason: '先做空杆');
        expect(plan.steps.first.weightKg, 20);
      }
      final p40 = warmupPlanFor(targetWeightKg: 40, gear: '杠铃');
      expect(p40.steps.length, 2, reason: '空杆 + 60%（40% 低于空杆被过滤）');
      expect(p40.steps.last.percent, 60);
    });

    test('40kg 边界：>40 才升到 80% 单次档', () {
      final light = warmupPlanFor(targetWeightKg: 40, gear: '杠铃');
      expect(light.mode, WarmupMode.light);
      expect(light.steps.last.percent, 60);
      final standard = warmupPlanFor(targetWeightKg: 40.5, gear: '杠铃');
      expect(standard.mode, WarmupMode.standard);
      expect(standard.steps.last.percent, 80);
    });

    test('lb 模式：空杆 45lb、杠铃百分比落 5lb 网格', () {
      final plan = warmupPlanFor(
        targetWeightKg: 100,
        gear: '杠铃',
        useLb: true,
      );
      final lbs = plan.steps.map((s) => kgToLb(s.weightKg)).toList();
      expect(lbs.length, 4);
      expect(lbs[0], closeTo(45, 1e-9), reason: '与挂片提示同源的空杆');
      expect(lbs[1], closeTo(90, 1e-9));
      expect(lbs[2], closeTo(130, 1e-9));
      expect(lbs[3], closeTo(175, 1e-9));
    });

    test('lb 模式下 20kg 杠铃目标仍有空杆步（44lb 与 45lb 的取整差）', () {
      final plan = warmupPlanFor(
        targetWeightKg: 20,
        gear: '杠铃',
        useLb: true,
      );
      expect(plan.mode, WarmupMode.light);
      expect(plan.steps, isNotEmpty, reason: '20kg 杠铃单关节也要有热身');
      expect(kgToLb(plan.steps.first.weightKg), closeTo(45, 1e-9));
    });

    test('lb 模式下所有正重量的内置动作也都有热身建议', () {
      for (final meta in kExerciseLibrary) {
        final start = defaultStartWeightOf(meta);
        if (start <= 0) continue;
        final plan = warmupPlanFor(
          targetWeightKg: start,
          gear: meta.gear,
          useLb: true,
        );
        expect(plan.steps, isNotEmpty,
            reason: '${meta.name}（${start}kg，lb 模式）热身阶梯为空');
      }
    });

    test('EZ 杠用 10kg/25lb 空杆，其余仍标准奥杆', () {
      expect(warmupBarKgFor('曲杠弯举（EZ杠）', useLb: false), 10);
      expect(
        kgToLb(warmupBarKgFor('曲杠弯举（EZ杠）', useLb: true)!),
        closeTo(25, 1e-9),
      );
      expect(warmupBarKgFor('杠铃卧推', useLb: false), isNull);
      final plan = warmupPlanFor(
        targetWeightKg: 20,
        gear: '杠铃',
        barKgOverride: 10,
      );
      expect(plan.steps.first.weightKg, 10, reason: 'EZ 杠空杆');
      expect(plan.steps.last.weightKg, 12.5, reason: '60% of 20 按 2.5kg 片重');
    });

    test('自重：不给重量阶梯，走一组慢速动作的简化版', () {
      final plan = warmupPlanFor(targetWeightKg: 0, gear: '自重');
      expect(plan.mode, WarmupMode.bodyweight);
      expect(plan.steps, isEmpty);
    });

    test('辅助配重（负值）不出热身建议', () {
      expect(
        warmupPlanFor(targetWeightKg: -30, gear: '固定器械').mode,
        WarmupMode.none,
      );
    });

    test('阶梯重量严格递增、都是正数，且重复重量会去重', () {
      for (final target in [2.5, 20.0, 40.0, 45.0, 60.0, 100.0, 120.0]) {
        for (final gear in ['杠铃', '哑铃', '龙门架绳索', '固定器械', '自重']) {
          final plan = warmupPlanFor(targetWeightKg: target, gear: gear);
          var prev = 0.0;
          for (final step in plan.steps) {
            expect(step.weightKg, greaterThan(prev),
                reason: '$gear $target 的阶梯必须递增');
            expect(step.reps, greaterThan(0));
            prev = step.weightKg;
          }
        }
      }
    });

    test('所有正重量的内置动作都至少有一条热身建议', () {
      for (final meta in kExerciseLibrary) {
        final start = defaultStartWeightOf(meta);
        if (start <= 0) continue;
        final plan = warmupPlanFor(targetWeightKg: start, gear: meta.gear);
        expect(plan.mode, isNot(WarmupMode.none),
            reason: '${meta.name}（${start}kg）没有热身档位');
        expect(plan.steps, isNotEmpty,
            reason: '${meta.name}（${start}kg）热身阶梯为空');
      }
    });
  });
}
