import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/presets/baoji_plan.dart';
import 'package:baoji_timer/presets/exercise_library.dart';

/// 内置动作库与计划模板的数据完整性。
void main() {
  group('动作库完整性', () {
    test('数量充足（≥60）且无重名', () {
      expect(kExerciseLibrary.length, greaterThanOrEqualTo(60));
      final names = kExerciseLibrary.map((m) => m.name).toSet();
      expect(names.length, kExerciseLibrary.length, reason: '动作名不能重复');
    });

    test('每个动作：肌群合法、场景合法、名称非空', () {
      for (final m in kExerciseLibrary) {
        expect(m.name.trim(), isNotEmpty, reason: '${m.name} 名称非空');
        expect(kMuscleRegions, contains(m.muscles.main),
            reason: '${m.name} 主肌群 ${m.muscles.main} 必须在区域内');
        expect(['gym', 'home', 'both'], contains(m.equipment),
            reason: '${m.name} 场景 ${m.equipment} 非法');
        for (final sec in m.muscles.secondary) {
          expect(kMuscleRegions, contains(sec),
              reason: '${m.name} 次肌群 $sec 非法');
        }
      }
    });

    test('居家与健身房两个场景都有充足选择', () {
      final home =
          kExerciseLibrary.where((m) => m.equipment != 'gym').length;
      final gym =
          kExerciseLibrary.where((m) => m.equipment != 'home').length;
      expect(home, greaterThan(20), reason: '居家可选动作充足');
      expect(gym, greaterThan(20), reason: '健身房可选动作充足');
      // 每个大肌群在两个场景都至少有 2 个动作
      for (final region in ['胸', '背', '肩', '手臂', '腿', '核心']) {
        final homeN = kExerciseLibrary
            .where((m) => m.muscles.main == region && m.equipment != 'gym')
            .length;
        final gymN = kExerciseLibrary
            .where((m) => m.muscles.main == region && m.equipment != 'home')
            .length;
        expect(homeN, greaterThanOrEqualTo(2),
            reason: '$region 居家动作不足');
        expect(gymN, greaterThanOrEqualTo(2),
            reason: '$region 健身房动作不足');
      }
    });
  });

  group('计划模板完整性', () {
    test('模板数量与命名', () {
      expect(kPlanTemplates.length, 4);
      final names = kPlanTemplates.map((t) => t.name).toSet();
      expect(names.length, 4, reason: '模板名不重复');
      expect(names, contains('三分化（推·拉·腿）'));
      expect(names, contains('五分化（胸·背·肩·臂·腿）'));
      expect(names, contains('功能性训练（全身）'));
      expect(names, contains('居家哑铃全身'));
    });

    test('每个模板：天数合法、动作都在词表、数值在合理区间', () {
      final libNames = kExerciseLibrary.map((m) => m.name).toSet();
      for (final t in kPlanTemplates) {
        expect(t.byWeekday.keys.every((wd) => wd >= 1 && wd <= 7), isTrue,
            reason: '${t.name} weekday 越界');
        expect(t.byWeekday.length, greaterThanOrEqualTo(3),
            reason: '${t.name} 至少 3 个训练日');
        for (final entry in t.byWeekday.entries) {
          expect(entry.value.length, greaterThanOrEqualTo(4),
              reason: '${t.name} 周${entry.key} 动作过少');
          for (final ex in entry.value) {
            expect(libNames, contains(ex.name),
                reason: '${t.name} 的「${ex.name}」不在动作库中');
            expect(ex.sets, inInclusiveRange(1, 20));
            expect(ex.repsMin, inInclusiveRange(1, 60));
            expect(ex.repsMax, inInclusiveRange(ex.repsMin, 60),
                reason: '${ex.name} reps 倒挂（计时类动作上限 60 秒）');
            expect(ex.restSec, inInclusiveRange(15, 600));
            expect(['compound', 'assistance'], contains(ex.kind));
          }
        }
      }
    });

    test('薄肌计划模板（内置）动作也都在词表', () {
      final libNames = kExerciseLibrary.map((m) => m.name).toSet();
      for (final list in kBaojiExercisesByWeekday.values) {
        for (final ex in list) {
          expect(libNames, contains(ex.name),
              reason: '薄肌计划的「${ex.name}」不在动作库');
        }
      }
    });
  });

  group('负荷类型推断（P2-E）', () {
    test('defaultLoadTypeFor：自重动作 bodyweight，其余 weighted', () {
      expect(defaultLoadTypeFor('俯卧撑'), LoadMode.bodyweight);
      expect(defaultLoadTypeFor('引体向上'), LoadMode.bodyweight);
      expect(defaultLoadTypeFor('双杠臂屈伸（挺胸）'), LoadMode.bodyweight);
      expect(defaultLoadTypeFor('臀桥'), LoadMode.bodyweight);
      expect(defaultLoadTypeFor('push up'), LoadMode.bodyweight,
          reason: '别名归一后同样识别');
      expect(defaultLoadTypeFor('杠铃卧推'), LoadMode.weighted);
      expect(defaultLoadTypeFor('词表外动作'), LoadMode.weighted);
      // 自重器械 + 外加载重的变体必须仍是 weighted，否则训练页没有重量列
      expect(defaultLoadTypeFor('负重引体向上'), LoadMode.weighted);
      expect(defaultLoadTypeFor('负重双杠臂屈伸'), LoadMode.weighted);
    });

    test('模板/内置计划安装：自重动作落 bodyweight，负重动作不变', () {
      // 内置薄肌计划里的引体向上
      final pull =
          kBaojiExercisesByWeekday[3]!.firstWhere((e) => e.name == '引体向上');
      expect(pull.toPlanExercise(1, 0).loadType, LoadMode.bodyweight);
      // 居家模板里的俯卧撑 / 臀桥
      final pushUp =
          kHomeTemplate.byWeekday[3]!.firstWhere((e) => e.name == '俯卧撑');
      expect(pushUp.toPlanExercise(1, 0).loadType, LoadMode.bodyweight);
      final bridge =
          kHomeTemplate.byWeekday[5]!.firstWhere((e) => e.name == '臀桥');
      expect(bridge.toPlanExercise(1, 0).loadType, LoadMode.bodyweight);
      // 负重动作不受影响
      final bench =
          kPplTemplate.byWeekday[1]!.firstWhere((e) => e.name == '杠铃卧推');
      expect(bench.toPlanExercise(1, 0).loadType, LoadMode.weighted);
    });
  });

  group('起始重量启发式（P2-A）', () {
    double startOf(String name) {
      final meta = libraryMetaByName(name);
      expect(meta, isNotNull, reason: '$name 应在动作库');
      return defaultStartWeightOf(meta!);
    }

    test('杠铃：复合含杆 40 / 单关节 20', () {
      expect(startOf('杠铃卧推'), 40);
      expect(startOf('杠铃深蹲'), 40);
      expect(startOf('杠铃弯举'), 20);
      expect(startOf('杠铃耸肩'), 20);
    });

    test('哑铃/壶铃：复合 10 / 单关节 6（每只）', () {
      expect(startOf('哑铃卧推'), 10);
      expect(startOf('哑铃侧平举'), 6);
      expect(startOf('壶铃摆荡'), 10);
    });

    test('器械 20 / 绳索 10 / 自重与弹力带 0', () {
      expect(startOf('腿举（倒蹬机）'), 20);
      expect(startOf('绳索夹胸'), 10);
      expect(startOf('俯卧撑'), 0);
      expect(startOf('弹力带面拉'), 0);
    });

    test('全部动作推导值非负且不超出常见起始上限', () {
      for (final m in kExerciseLibrary) {
        final w = defaultStartWeightOf(m);
        expect(w, greaterThanOrEqualTo(0), reason: '${m.name} 起始重量不能为负');
        expect(w, lessThanOrEqualTo(40), reason: '${m.name} 首次训练不应上来就大重量');
      }
    });

    test('高频显式覆盖只收词表内动作', () {
      for (final name in kStartWeightOverrides.keys) {
        expect(libraryMetaByName(name), isNotNull, reason: '$name 不在动作库');
      }
    });

    test('器械未标注时按场景兜底（equipment 维度）', () {
      const gym =
          ExerciseMeta('自定义器械动作', MuscleGroups(main: '胸'), true, 'gym');
      const home =
          ExerciseMeta('自定义居家动作', MuscleGroups(main: '胸'), true, 'home');
      const both = ExerciseMeta('自定义通用动作', MuscleGroups(main: '胸'), true);
      expect(defaultStartWeightOf(gym), 20);
      expect(defaultStartWeightOf(home), 0);
      expect(defaultStartWeightOf(both), 10);
    });

    test('别名归一再查库（起始重量/器械口径）', () {
      expect(libraryMetaForLift('平板卧推')?.name, '杠铃卧推');
      expect(libraryMetaForLift('背阔肌下拉')?.gear, '龙门架绳索');
      expect(libraryMetaForLift('上斜杠铃卧推(轻)')?.name, '上斜杠铃卧推（轻）');
      expect(libraryMetaForLift('词表外动作'), isNull);
    });
  });
}
