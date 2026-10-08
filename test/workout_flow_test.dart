// 调研条目 8：一屏一组的页面流状态机（lib/engine/workout_flow.dart）。
// 覆盖：自动当前页推导（与 SessionController 推进语义对齐——只有正式组推进、
// 热身/力竭不推进、练满转加练、休息挂下一组）、全程完成比例（底部 3px
// 进度条）、跳页面板清单与划线标记、FlowPage 判等（UI 换页动画依据）。
// 纯 Dart 状态机：直接构造模型，不过 DB。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/engine/workout_flow.dart';
import 'package:baoji_timer/models/models.dart';

SessionExercise _ex(
  int id,
  String name,
  int order, {
  int workingSets = 3,
}) =>
    SessionExercise(
      sessionId: 1,
      id: id,
      name: name,
      orderIdx: order,
      kind: 'compound',
      rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: workingSets),
    );

SetEntry _set(int seId, {String kind = SetKind.working}) => SetEntry(
      sessionExerciseId: seId,
      weightKg: 60,
      reps: 8,
      kind: kind,
      doneAt: 0,
    );

/// 2 动作 × 各 3 计划组的典型会话。
WorkoutFlow _twoExercises() {
  final a = _ex(11, '动作甲', 0);
  final b = _ex(12, '动作乙', 1);
  return WorkoutFlow(
    exercises: [a, b],
    setsByEx: {
      11: <SetEntry>[],
      12: <SetEntry>[],
    },
  );
}

void main() {
  group('全程完成比例（底部 3px 进度条）', () {
    test('空会话：total 0，ratio 0', () {
      final f = WorkoutFlow(exercises: const [], setsByEx: const {});
      expect(f.totalPlannedSets, 0);
      expect(f.ratioCompleted, 0);
    });

    test('2 动作 × 3 组：完成 1 组 ratio = 1/6，全满 = 1', () {
      final f = _twoExercises();
      expect(f.totalPlannedSets, 6);
      f.setsByEx[11]!.add(_set(11));
      expect(f.ratioCompleted, closeTo(1 / 6, 1e-9));

      for (var i = 0; i < 3; i++) {
        f.setsByEx[11]!.add(_set(11));
      }
      f.setsByEx[12]!.addAll([_set(12), _set(12), _set(12)]);
      expect(f.ratioCompleted, 1);
    });

    test('加练不涨全程进度：封顶在计划组数上', () {
      final f = _twoExercises();
      f.setsByEx[11]!.addAll([_set(11), _set(11), _set(11), _set(11)]);
      expect(f.donePlannedSets, 3, reason: '动作甲第 4 组是加练，不计入计划进度');
      expect(f.ratioCompleted, closeTo(0.5, 1e-9));
    });

    test('热身组不涨全程进度（只有正式组算完成）', () {
      final f = _twoExercises();
      f.setsByEx[11]!.addAll([_set(11, kind: SetKind.warmup), _set(11, kind: SetKind.warmup)]);
      expect(f.donePlannedSets, 0);
      expect(f.ratioCompleted, 0);
    });
  });

  group('自动当前页（保存一组 → 状态推进 → 页面顺延）', () {
    test('新会话：落在第 1 个动作第 1 组的记录页', () {
      final f = _twoExercises();
      final p = f.currentPage(resting: false, curExIdx: 0);
      expect(p.kind, FlowPageKind.record);
      expect(p.exerciseIndex, 0);
      expect(p.setNumber, 1);
      expect(p.plannedSets, 3);
      expect(p.extra, isFalse);
      expect(p.setLabel(), '第 1/3 组');
    });

    test('保存一组后自动翻到下一组页（不休息时的口径）', () {
      final f = _twoExercises();
      f.setsByEx[11]!.add(_set(11));
      expect(
        f.currentPage(resting: false, curExIdx: 0).setNumber,
        2,
        reason: '第 1 组已记，当前页是第 2 组',
      );
    });

    test('休息中：当前页是休息页，挂在下一组上（与训练卡同口径）', () {
      final f = _twoExercises();
      f.setsByEx[11]!.add(_set(11));
      final p = f.currentPage(resting: true, curExIdx: 0);
      expect(p.kind, FlowPageKind.rest);
      expect(p.exerciseIndex, 0);
      expect(p.setNumber, 2);
      expect(p.setLabel(), '第 2/3 组');
    });

    test('热身/力竭组不推进页面（与控制器 workingSetsDone 语义一致）', () {
      final f = _twoExercises();
      f.setsByEx[11]!.addAll([
        _set(11, kind: SetKind.warmup),
        _set(11, kind: SetKind.failure),
      ]);
      final p = f.currentPage(resting: false, curExIdx: 0);
      expect(p.setNumber, 1, reason: '只有正式组推进"下一组"');
    });

    test('动作记满：加练记录页（extra=true，组号继续涨不封顶）', () {
      final f = _twoExercises();
      f.setsByEx[11]!.addAll([_set(11), _set(11), _set(11)]);
      final p = f.currentPage(resting: false, curExIdx: 0);
      expect(p.extra, isTrue, reason: '计划 3 组已练满，继续记录即加练');
      expect(p.setNumber, 4, reason: '加练组号继续涨（第 4 组），不再夹回 3/3');
      expect(p.setLabel(), '第 4 组（加练）');
      // 练满转休息（加练后组间）同样是休息页
      expect(f.currentPage(resting: true, curExIdx: 0).kind, FlowPageKind.rest);
    });

    test('跨动作：第 1 动作记满推进后，当前页是第 2 动作第 1 组', () {
      final f = _twoExercises();
      f.setsByEx[11]!.addAll([_set(11), _set(11), _set(11)]);
      final p = f.currentPage(resting: false, curExIdx: 1);
      expect(p.exerciseIndex, 1);
      expect(p.setNumber, 1);
    });

    test('全部计划组记满：每页 done，exerciseDone 全真', () {
      final f = _twoExercises();
      f.setsByEx[11]!.addAll([_set(11), _set(11), _set(11)]);
      f.setsByEx[12]!.addAll([_set(12), _set(12), _set(12)]);
      expect(f.exerciseDone(0), isTrue);
      expect(f.exerciseDone(1), isTrue);
      expect(f.ratioCompleted, 1);
    });

    test('curExIdx 越界收敛到合法下标（脏数据不崩）', () {
      final f = _twoExercises();
      final p = f.currentPage(resting: false, curExIdx: 99);
      expect(p.exerciseIndex, 1);
    });
  });

  group('跳页面板清单（收起面板的划线标记与可跳性）', () {
    test('顺序 = 动作序 × 组序；已完成组带 done 标记', () {
      final f = _twoExercises();
      f.setsByEx[11]!.addAll([_set(11), _set(11)]);
      final refs = f.setRefs();
      expect(refs.length, 6);
      expect(refs[0].done, isTrue, reason: '动作甲第 1 组已记');
      expect(refs[1].done, isTrue);
      expect(refs[2].done, isFalse, reason: '动作甲第 3 组未记，可跳');
      expect(refs[3].exerciseIndex, 1);
      expect(refs[3].setNumber, 1);
      expect(refs[3].done, isFalse);
    });

    test('加练的组也列入清单：第 4 组带 extra 标记且已划线', () {
      final f = _twoExercises();
      f.setsByEx[11]!.addAll([_set(11), _set(11), _set(11), _set(11)]);
      final refs = f.setRefs();
      // 动作甲 3 个计划组 + 1 个加练组
      expect(refs.length, 7, reason: '加练的组要显示出来（2026-09-26 Arono）');
      final extra = refs[3];
      expect(extra.setNumber, 4);
      expect(extra.extra, isTrue, reason: '第 4 组超出计划，带加练标记');
      expect(extra.done, isTrue, reason: '加练组已记录，划线锁定');
      // 动作乙的计划组不受影响
      expect(refs[4].exerciseIndex, 1);
      expect(refs[4].extra, isFalse);
    });

    test('计划组完成度统计不含加练（面板头部 X/N 仍按计划数）', () {
      final f = _twoExercises();
      f.setsByEx[11]!.addAll([_set(11), _set(11), _set(11), _set(11)]);
      final refs = f.setRefs();
      final plannedDone = refs
          .where((r) => r.exerciseIndex == 0 && r.done && !r.extra)
          .length;
      expect(plannedDone, 3, reason: '头部 3/3 done 只数计划组');
    });
  });

  group('FlowPage 判等（AnimatedSwitcher 换页依据）', () {
    test('同页字段相同判等；换组/换动作/换相位不相等', () {
      const a = FlowPage.record(exerciseIndex: 0, setNumber: 1, plannedSets: 3);
      const b = FlowPage.record(exerciseIndex: 0, setNumber: 1, plannedSets: 3);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);

      expect(a, isNot(equals(a.copyWithLike(setNumber: 2))));
      expect(a, isNot(equals(a.copyWithLike(exerciseIndex: 1))));
      expect(
        a,
        isNot(equals(const FlowPage.rest(exerciseIndex: 0, setNumber: 1, plannedSets: 3))),
        reason: '同组记录页与休息页是两页（相位切换要翻页）',
      );
      expect(
        a,
        isNot(equals(const FlowPage.record(
          exerciseIndex: 0,
          setNumber: 3,
          plannedSets: 3,
          extra: true,
        ))),
        reason: '加练态是另一页',
      );
    });

    test('key 稳定且换页必不同', () {
      const r1 = FlowPage.record(exerciseIndex: 0, setNumber: 1, plannedSets: 3);
      const r2 = FlowPage.record(exerciseIndex: 0, setNumber: 2, plannedSets: 3);
      const s = FlowPage.start();
      const sum = FlowPage.summary();
      expect(r1.key, isNot(r2.key));
      expect(s.key, 'start');
      expect(sum.key, 'summary');
    });
  });
}

/// 测试辅助：按字段替换构造新页（FlowPage 本体是 const 不可变）。
extension _FlowPageCopy on FlowPage {
  FlowPage copyWithLike({int? setNumber, int? exerciseIndex}) =>
      FlowPage.record(
        exerciseIndex: exerciseIndex ?? this.exerciseIndex,
        setNumber: setNumber ?? this.setNumber,
        plannedSets: plannedSets,
        extra: extra,
      );
}
