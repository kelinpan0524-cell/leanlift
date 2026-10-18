// 本地周复盘（P1-E1）纯函数测试：
//  - 数据齐全：计划/完成次数与组数、1RM 进步/停滞、肌群缺口、体重趋势、行动建议
//  - 空数据：全零、全部肌群低于目标、无体重、行动建议指向先排计划
//  - 只有一次训练：没有上周对比 → 不判进步/停滞；体重只有一条 → Δ 为 null
//  - 边界：中周零训练、计划组数不足、加练不顶替计划日、别名合并、
//    减载会话排除、滚动 7 天体重、英文行动文案
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/l10n/lang.dart';

Session _session(DateTime day, {int? id, int? planDayId}) => Session(
  id: id,
  date: fmtDate(day),
  planDayId: planDayId,
  planDayTitle: '推日',
  startedAt: day.millisecondsSinceEpoch,
  endedAt: day.millisecondsSinceEpoch + 3600000,
  status: 'done',
);

RecapSetRow _set(
  String name,
  DateTime day,
  double weight,
  int reps, {
  String kind = SetKind.working,
  int? sessionId,
}) => RecapSetRow(
  name: name,
  weightKg: weight,
  reps: reps,
  kind: kind,
  date: day,
  sessionId: sessionId,
);

RecapPlannedDay _day(int dayId, int sets) =>
    RecapPlannedDay(dayId: dayId, workingSets: sets);

// 六大肌群各给满目标下限，用于验证「全部达标」之后的行动分支。
const _bench = ExerciseMeta(
  '杠铃卧推',
  MuscleGroups(main: '胸', secondary: ['肩', '手臂']),
  true,
);
const _row = ExerciseMeta(
  '杠铃划船',
  MuscleGroups(main: '背', secondary: ['手臂']),
  true,
);
const _squat = ExerciseMeta('杠铃深蹲', MuscleGroups(main: '腿'), true);
const _press = ExerciseMeta(
  '站姿推举',
  MuscleGroups(main: '肩', secondary: ['手臂']),
  true,
);
const _curl = ExerciseMeta('杠铃弯举', MuscleGroups(main: '手臂'), true);
const _crunch = ExerciseMeta('卷腹', MuscleGroups(main: '核心'), true);
const _allMeta = {
  '杠铃卧推': _bench,
  '杠铃划船': _row,
  '杠铃深蹲': _squat,
  '站姿推举': _press,
  '杠铃弯举': _curl,
  '卷腹': _crunch,
};

/// 本周 52 个正式组，覆盖六个目标肌群并刚好达到下限：
/// 胸 10 / 背 10 / 腿 10 / 肩 13 / 手臂 23 / 核心 6。
List<RecapSetRow> _coverAllMuscles({
  required DateTime day,
  required int sessionId,
  double benchWeight = 60,
}) {
  final rows = <RecapSetRow>[];
  for (var i = 0; i < 10; i++) {
    rows.add(_set('杠铃卧推', day, benchWeight, 10, sessionId: sessionId));
  }
  for (var i = 0; i < 10; i++) {
    rows.add(_set('杠铃划船', day, 60, 10, sessionId: sessionId));
  }
  for (var i = 0; i < 10; i++) {
    rows.add(_set('杠铃深蹲', day, 100, 5, sessionId: sessionId));
  }
  for (var i = 0; i < 8; i++) {
    rows.add(_set('站姿推举', day, 40, 8, sessionId: sessionId));
  }
  for (var i = 0; i < 8; i++) {
    rows.add(_set('杠铃弯举', day, 20, 10, sessionId: sessionId));
  }
  for (var i = 0; i < 6; i++) {
    rows.add(_set('卷腹', day, 0, 15, sessionId: sessionId));
  }
  return rows;
}

/// 一周全达标场景：1 个计划日 52 组；本周全部练满。
/// [benchLastWeek] 非空时补上周 10 组卧推，用于对比进步/停滞。
WeeklyRecap _fullWeek({
  required DateTime now,
  required DateTime weekStart,
  double benchThisWeek = 60,
  double? benchLastWeek,
}) {
  final planned = {fmtDate(weekStart): _day(1, 52)};
  final sets = _coverAllMuscles(
    day: weekStart,
    sessionId: 101,
    benchWeight: benchThisWeek,
  );
  if (benchLastWeek != null) {
    final prevDay = weekStart.subtract(const Duration(days: 2));
    for (var i = 0; i < 10; i++) {
      sets.add(_set('杠铃卧推', prevDay, benchLastWeek, 10, sessionId: 201));
    }
  }
  return weeklyRecap(
    now: now,
    weekStart: weekStart,
    plannedByDate: planned,
    sessions: [_session(weekStart, id: 101, planDayId: 1)],
    sets: sets,
    metaByName: _allMeta,
  );
}

void main() {
  // 2026-10-05 是周一；本周 = 10-05 .. 10-11，上周 = 09-28 .. 10-04。
  final weekStart = DateTime(2026, 10, 5);
  final sunday = DateTime(2026, 10, 11, 20);

  const bench = ExerciseMeta(
    '杠铃卧推',
    MuscleGroups(main: '胸', secondary: ['肩', '手臂']),
    true,
  );
  const squat = ExerciseMeta('杠铃深蹲', MuscleGroups(main: '腿'), true);
  final meta = {bench.name: bench, squat.name: squat};

  group('weeklyRecap 数据齐全', () {
    late WeeklyRecap r;
    setUp(() {
      r = weeklyRecap(
        now: sunday,
        weekStart: weekStart,
        plannedByDate: {
          '2026-10-05': _day(1, 9),
          '2026-10-07': _day(2, 9),
          '2026-10-09': _day(3, 9),
        },
        sessions: [
          _session(DateTime(2026, 10, 5), id: 101, planDayId: 1),
          _session(DateTime(2026, 10, 7), id: 102, planDayId: 2),
        ],
        sets: [
          // 上周：卧推 80×8、深蹲 100×5（热身不计）
          _set('杠铃卧推', DateTime(2026, 9, 29), 80, 8, sessionId: 201),
          _set(
            '杠铃卧推',
            DateTime(2026, 9, 29),
            40,
            10,
            kind: SetKind.warmup,
            sessionId: 201,
          ),
          _set('杠铃深蹲', DateTime(2026, 9, 30), 100, 5, sessionId: 202),
          // 本周：卧推第二练加重到 82.5×8（进步）；深蹲同重量（停滞）
          _set('杠铃卧推', DateTime(2026, 10, 5), 80, 8, sessionId: 101),
          _set('杠铃卧推', DateTime(2026, 10, 5), 80, 8, sessionId: 101),
          _set('杠铃卧推', DateTime(2026, 10, 5), 80, 8, sessionId: 101),
          _set('杠铃卧推', DateTime(2026, 10, 7), 82.5, 8, sessionId: 102),
          _set('杠铃卧推', DateTime(2026, 10, 7), 82.5, 8, sessionId: 102),
          _set('杠铃卧推', DateTime(2026, 10, 7), 82.5, 8, sessionId: 102),
          _set(
            '杠铃卧推',
            DateTime(2026, 10, 5),
            40,
            10,
            kind: SetKind.warmup,
            sessionId: 101,
          ),
          _set('杠铃深蹲', DateTime(2026, 10, 5), 100, 5, sessionId: 101),
          _set('杠铃深蹲', DateTime(2026, 10, 5), 100, 5, sessionId: 101),
          _set('杠铃深蹲', DateTime(2026, 10, 5), 100, 5, sessionId: 101),
        ],
        metaByName: meta,
        bodyMetrics: [
          BodyMetric(date: '2026-10-05', weightKg: 72.0),
          BodyMetric(date: '2026-10-08', weightKg: 71.6),
          BodyMetric(date: '2026-10-11', weightKg: 71.4),
        ],
      );
    });

    test('计划训练数 / 实际完成数、计划正式组 / 实际完成组', () {
      expect(r.plannedSessions, 3);
      expect(r.completedSessions, 2);
      expect(r.completedPlannedSessions, 2);
      expect(r.plannedWorkingSets, 27);
      // 9 个正式组已记，但热身组不计 → 9 组；全部属于计划日
      expect(r.completedWorkingSets, 9);
      expect(r.completedPlannedWorkingSets, 9);
      expect(r.extraSessions, 0);
      expect(r.extraWorkingSets, 0);
      expect(r.remainingPlannedSessions, 0);
    });

    test('进步动作：本周 1RM 超过上周（按动作身份合并）', () {
      expect(r.improvedExercises.length, 1);
      final e = r.improvedExercises.single;
      expect(e.name, '杠铃卧推');
      expect(e.best1Rm, greaterThan(e.previousBest1Rm));
      expect(e.deltaKg, closeTo(3.13, 0.02));
    });

    test('停滞动作：本周 1RM 没超过上周', () {
      expect(r.stalledExercises.length, 1);
      final e = r.stalledExercises.single;
      expect(e.name, '杠铃深蹲');
      expect(e.deltaKg.abs(), lessThan(0.01));
    });

    test('低于周组数目标的肌群：按缺口从大到小', () {
      // 本周：卧推 6 组 → 胸 6 / 肩 3 / 手臂 3；深蹲 3 组 → 腿 3；
      // 背、核心为 0。目标下限：胸/背/腿 10、肩/手臂 8、核心 6。
      expect(r.weeklySetsByMuscle['胸'], 6);
      expect(r.weeklySetsByMuscle['肩'], 3);
      expect(r.weeklySetsByMuscle['手臂'], 3);
      expect(r.weeklySetsByMuscle['腿'], 3);
      expect(r.weeklySetsByMuscle['背'], 0);
      expect(r.weeklySetsByMuscle['核心'], 0);

      final first = r.underTargetMuscles.first;
      expect(first.muscle, '背'); // 缺口 10 组，最大
      expect(first.sets, 0);
      expect(first.targetMin, 10);
      expect(first.targetMax, 20);
      expect(r.underTargetMuscles.map((e) => e.muscle).toSet(), {
        '胸',
        '肩',
        '背',
        '手臂',
        '腿',
        '核心',
      });
    });

    test('7 天体重趋势：首条 → 末条 + 差值', () {
      final t = r.weightTrend;
      expect(t.hasData, isTrue);
      expect(t.points.length, 3);
      expect(t.startKg, 72.0);
      expect(t.endKg, 71.4);
      expect(t.deltaKg, closeTo(-0.6, 1e-9));
    });

    test('行动建议：少练 1 次时优先补训练次数', () {
      expect(r.action, contains('2/3'));
      expect(r.action, contains('差 1 次'));
      expect(r.action, contains('下周'));
    });
  });

  group('weeklyRecap 空数据', () {
    test('没有计划、没有训练、没有体重也能给出完整空结果', () {
      final r = weeklyRecap(
        now: sunday,
        weekStart: weekStart,
        plannedByDate: const {},
        sessions: const [],
        sets: const [],
      );
      expect(r.plannedSessions, 0);
      expect(r.completedSessions, 0);
      expect(r.completedPlannedSessions, 0);
      expect(r.plannedWorkingSets, 0);
      expect(r.completedWorkingSets, 0);
      expect(r.completedPlannedWorkingSets, 0);
      expect(r.remainingPlannedSessions, 0);
      expect(r.improvedExercises, isEmpty);
      expect(r.stalledExercises, isEmpty);
      // 六大肌群全部低于目标下限
      expect(r.underTargetMuscles.length, 6);
      expect(r.weeklySetsByMuscle.values.every((v) => v == 0), isTrue);
      expect(r.weightTrend.hasData, isFalse);
      expect(r.weightTrend.deltaKg, isNull);
      expect(r.action, contains('没有安排训练'));
    });

    test('有计划但一次没练：建议先练第一次', () {
      final r = weeklyRecap(
        now: sunday,
        weekStart: weekStart,
        plannedByDate: const {
          '2026-10-05': RecapPlannedDay(dayId: 1, workingSets: 9),
          '2026-10-07': RecapPlannedDay(dayId: 2, workingSets: 9),
        },
        sessions: const [],
        sets: const [],
      );
      expect(r.plannedSessions, 2);
      expect(r.completedSessions, 0);
      expect(r.action, contains('一次也没练'));
    });
  });

  group('weeklyRecap 只有一次训练', () {
    late WeeklyRecap r;
    setUp(() {
      r = weeklyRecap(
        now: sunday,
        weekStart: weekStart,
        plannedByDate: const {
          '2026-10-05': RecapPlannedDay(dayId: 1, workingSets: 9),
          '2026-10-07': RecapPlannedDay(dayId: 2, workingSets: 9),
        },
        sessions: [_session(DateTime(2026, 10, 5), id: 101, planDayId: 1)],
        sets: [
          _set('杠铃卧推', DateTime(2026, 10, 5), 60, 10, sessionId: 101),
          _set('杠铃卧推', DateTime(2026, 10, 5), 60, 10, sessionId: 101),
          _set('杠铃卧推', DateTime(2026, 10, 5), 60, 10, sessionId: 101),
        ],
        metaByName: meta,
        bodyMetrics: [BodyMetric(date: '2026-10-05', weightKg: 70.0)],
      );
    });

    test('没有上周对比：进步/停滞都为空', () {
      expect(r.completedSessions, 1);
      expect(r.completedPlannedSessions, 1);
      expect(r.completedWorkingSets, 3);
      expect(r.completedPlannedWorkingSets, 3);
      expect(r.improvedExercises, isEmpty);
      expect(r.stalledExercises, isEmpty);
      // 只练了胸 → 胸仍是低于目标的（3 组 < 10）
      expect(r.underTargetMuscles.any((e) => e.muscle == '胸'), isTrue);
    });

    test('体重只有一条：有数据但 Δ 为 null', () {
      expect(r.weightTrend.hasData, isTrue);
      expect(r.weightTrend.points.length, 1);
      expect(r.weightTrend.startKg, 70.0);
      expect(r.weightTrend.endKg, 70.0);
      expect(r.weightTrend.deltaKg, isNull);
    });

    test('行动建议：完成 1/2 次，指向补齐训练次数', () {
      expect(r.action, contains('1/2'));
      expect(r.action, contains('下周'));
    });
  });

  group('weeklyRecap 行动建议优先级', () {
    test('中周一次没练：先提示本周还剩几次，而不是让用户下周再开始', () {
      final r = weeklyRecap(
        now: DateTime(2026, 10, 6, 9), // 周二
        weekStart: weekStart,
        plannedByDate: const {
          '2026-10-05': RecapPlannedDay(dayId: 1, workingSets: 9),
          '2026-10-07': RecapPlannedDay(dayId: 2, workingSets: 9),
          '2026-10-09': RecapPlannedDay(dayId: 3, workingSets: 9),
        },
        sessions: const [],
        sets: const [],
      );
      // 周一已过；周三、周五还没到 → 剩 2 次
      expect(r.remainingPlannedSessions, 2);
      expect(r.action, contains('还剩 2 次'));
      expect(r.action, isNot(contains('一次也没练')));
    });

    test('本周还没过完时，先提示把剩下的计划训练练完', () {
      final r = weeklyRecap(
        now: DateTime(2026, 10, 6, 9), // 周二
        weekStart: weekStart,
        plannedByDate: const {
          '2026-10-05': RecapPlannedDay(dayId: 1, workingSets: 9),
          '2026-10-07': RecapPlannedDay(dayId: 2, workingSets: 9),
          '2026-10-09': RecapPlannedDay(dayId: 3, workingSets: 9),
        },
        sessions: [_session(DateTime(2026, 10, 5), id: 101, planDayId: 1)],
        sets: const [],
      );
      expect(r.remainingPlannedSessions, 2);
      expect(r.action, contains('还剩 2 次'));
    });

    test('次数练够但计划组数不足：先补组数，不说「全部完成」', () {
      final r = weeklyRecap(
        now: sunday,
        weekStart: weekStart,
        plannedByDate: const {
          '2026-10-05': RecapPlannedDay(dayId: 1, workingSets: 9),
        },
        sessions: [_session(DateTime(2026, 10, 5), id: 101, planDayId: 1)],
        sets: [
          for (var i = 0; i < 6; i++)
            _set('杠铃卧推', DateTime(2026, 10, 5), 60, 10, sessionId: 101),
        ],
        metaByName: meta,
      );
      expect(r.completedPlannedSessions, 1);
      expect(r.completedPlannedWorkingSets, 6);
      expect(r.action, contains('正式组只完成 6/9'));
      expect(r.action, contains('少 3 组'));
    });

    test('加练不顶替计划日：计划日漏练 + 其他日子加练仍提示补次数', () {
      final r = weeklyRecap(
        now: sunday,
        weekStart: weekStart,
        plannedByDate: const {
          '2026-10-05': RecapPlannedDay(dayId: 1, workingSets: 9),
        },
        sessions: [
          // 周一自由训练（planDayId=null），周二加练
          _session(DateTime(2026, 10, 5), id: 101),
          _session(DateTime(2026, 10, 6), id: 102),
        ],
        sets: [
          _set('杠铃卧推', DateTime(2026, 10, 5), 60, 10, sessionId: 101),
          _set('杠铃卧推', DateTime(2026, 10, 6), 60, 10, sessionId: 102),
        ],
      );
      expect(r.completedSessions, 2);
      expect(r.completedPlannedSessions, 0);
      expect(r.extraSessions, 2);
      expect(r.action, contains('没有一次对上计划的训练日'));
    });

    test('次数达标后，优先给缺口最大的肌群加量', () {
      final r = weeklyRecap(
        now: sunday,
        weekStart: weekStart,
        plannedByDate: const {
          '2026-10-05': RecapPlannedDay(dayId: 1, workingSets: 1),
        },
        sessions: [_session(DateTime(2026, 10, 5), id: 101, planDayId: 1)],
        sets: [_set('杠铃卧推', DateTime(2026, 10, 5), 60, 10, sessionId: 101)],
        metaByName: meta,
      );
      expect(r.completedPlannedSessions, r.plannedSessions);
      expect(r.action, contains('加量'));
      // 缺口最大的仍是背（0/10）
      expect(r.action, contains('背'));
    });

    test('全部达标且有进步：建议继续加重', () {
      final r = _fullWeek(
        now: sunday,
        weekStart: weekStart,
        benchThisWeek: 62.5,
        benchLastWeek: 60,
      );
      expect(r.underTargetMuscles, isEmpty);
      expect(r.improvedExercises.single.name, '杠铃卧推');
      expect(r.action, contains('提高了'));
      expect(r.action, contains('继续加重'));
    });

    test('全部达标但没进步：建议同重量多冲 1 次', () {
      final r = _fullWeek(
        now: sunday,
        weekStart: weekStart,
        benchThisWeek: 62.5,
        benchLastWeek: 62.5,
      );
      expect(r.underTargetMuscles, isEmpty);
      expect(r.stalledExercises.single.name, '杠铃卧推');
      expect(r.action, contains('没超过上周'));
      expect(r.action, contains('多冲 1 次'));
    });

    test('全部达标且没有对比动作：保持节奏', () {
      final r = _fullWeek(now: sunday, weekStart: weekStart);
      expect(r.underTargetMuscles, isEmpty);
      expect(r.improvedExercises, isEmpty);
      expect(r.stalledExercises, isEmpty);
      expect(r.action, contains('保持节奏'));
    });
  });

  group('weeklyRecap 口径边界', () {
    test('计时动作的秒数不参与 1RM 估算', () {
      final r = weeklyRecap(
        now: sunday,
        weekStart: weekStart,
        plannedByDate: const {
          '2026-10-05': RecapPlannedDay(dayId: 1, workingSets: 1),
        },
        sessions: [_session(DateTime(2026, 10, 5), id: 101, planDayId: 1)],
        sets: [
          _set('哑铃农夫行走', DateTime(2026, 9, 30), 20, 60, sessionId: 201),
          RecapSetRow(
            name: '哑铃农夫行走',
            weightKg: 20,
            reps: 60,
            date: DateTime(2026, 10, 5),
            sessionId: 101,
            logging: LoggingMode.time,
          ),
        ],
      );
      expect(r.improvedExercises, isEmpty);
      expect(r.stalledExercises, isEmpty);
      // 但计时组仍算正式组与肌群剂量
      expect(r.completedWorkingSets, 1);
    });

    test('本周范围外的组不计入完成组数', () {
      final r = weeklyRecap(
        now: sunday,
        weekStart: weekStart,
        plannedByDate: const {
          '2026-10-05': RecapPlannedDay(dayId: 1, workingSets: 1),
        },
        sessions: [_session(DateTime(2026, 10, 5), id: 101, planDayId: 1)],
        sets: [
          _set('杠铃卧推', DateTime(2026, 10, 5), 60, 10, sessionId: 101),
          _set('杠铃卧推', DateTime(2026, 10, 2), 60, 10, sessionId: 201),
          _set('杠铃卧推', DateTime(2026, 10, 13), 60, 10, sessionId: 301),
        ],
        metaByName: meta,
      );
      expect(r.completedWorkingSets, 1);
    });

    test('别名合并：上周「平板卧推」和本周「杠铃卧推」算同一动作', () {
      final r = weeklyRecap(
        now: sunday,
        weekStart: weekStart,
        plannedByDate: const {},
        sessions: [_session(DateTime(2026, 10, 5), id: 101)],
        sets: [
          _set('平板卧推', DateTime(2026, 9, 29), 60, 8, sessionId: 201),
          _set('杠铃卧推', DateTime(2026, 10, 5), 62.5, 8, sessionId: 101),
        ],
        metaByName: meta,
      );
      expect(r.improvedExercises.length, 1);
      expect(
        r.improvedExercises.single.name,
        '杠铃卧推',
        reason: '展示名用规范名，不能把别名拆成两个动作',
      );
      expect(r.weeklySetsByMuscle['胸'], 1);
      expect(r.weeklySetsByMuscle['肩'], 0.5);
    });

    test('减载/停练回归会话不参与 1RM 进步/停滞判断', () {
      final r = weeklyRecap(
        now: sunday,
        weekStart: weekStart,
        plannedByDate: const {
          '2026-10-05': RecapPlannedDay(dayId: 1, workingSets: 1),
        },
        sessions: [_session(DateTime(2026, 10, 5), id: 101, planDayId: 1)],
        sets: [
          // 上周正常 60×8，本周减载 55×8（session 101 被标记）
          _set('杠铃卧推', DateTime(2026, 9, 29), 60, 8, sessionId: 201),
          _set('杠铃卧推', DateTime(2026, 10, 5), 55, 8, sessionId: 101),
        ],
        excludeProgressSessionIds: const {101},
        metaByName: meta,
      );
      expect(r.improvedExercises, isEmpty);
      expect(r.stalledExercises, isEmpty, reason: '主动减载不是停滞，不能提示减载/换变式');
      // 减载组仍算实际完成量
      expect(r.completedWorkingSets, 1);
      expect(r.completedPlannedWorkingSets, 1);
    });

    test('滚动 7 天体重：中周查看时包含上周尾部的记录', () {
      final r = weeklyRecap(
        now: DateTime(2026, 10, 7, 20), // 周三
        weekStart: weekStart,
        plannedByDate: const {},
        sessions: const [],
        sets: const [],
        bodyMetrics: [
          BodyMetric(date: '2026-09-30', weightKg: 72.0), // 窗口外
          BodyMetric(date: '2026-10-01', weightKg: 71.8), // now-6，窗口内
          BodyMetric(date: '2026-10-07', weightKg: 71.5), // 今天
          BodyMetric(date: '2026-10-08', weightKg: 71.4), // 未来，窗口外
        ],
      );
      expect(r.weightTrend.points.map((e) => e.date).toList(), [
        '2026-10-01',
        '2026-10-07',
      ]);
      expect(r.weightTrend.startKg, 71.8);
      expect(r.weightTrend.endKg, 71.5);
      expect(r.weightTrend.deltaKg, closeTo(-0.3, 1e-9));
    });

    test('同一模板日只算一次：顺延后的日期有训练时保留新日期', () {
      final r = weeklyRecap(
        now: sunday,
        weekStart: weekStart,
        plannedByDate: {
          '2026-10-05': _day(1, 9), // 原周一（漏练）
          // 顺延后的周二（同一模板日，实际练了）；调用方显式声明承接关系
          '2026-10-06': const RecapPlannedDay(
            dayId: 1,
            workingSets: 9,
            postponedFrom: '2026-10-05',
          ),
          '2026-10-08': _day(2, 9),
          '2026-10-10': _day(3, 9),
        },
        sessions: [
          _session(DateTime(2026, 10, 6), id: 101, planDayId: 1),
          _session(DateTime(2026, 10, 8), id: 102, planDayId: 2),
          _session(DateTime(2026, 10, 10), id: 103, planDayId: 3),
        ],
        sets: const [],
      );
      // 周一被显式声明的顺延承接并入周二，只算一次；三场都练了 → 3/3
      expect(r.plannedSessions, 3);
      expect(r.completedPlannedSessions, 3);
      expect(r.plannedWorkingSets, 27);
    });

    test('循环计划漏练不并入后练的同模板日：第一次 occurrence 漏了也照算', () {
      // 练2休2 配 3 模板（真实链路：漏练未触发顺延 → 无休息墓碑）：
      // 9/1=胸（漏练）、9/2=背、9/5=腿、9/6=胸（练了）。两个胸 occurrence
      // 独立计数，不能把漏练的周一并进练了的周六造成「全勤」假象。
      final r = weeklyRecap(
        now: DateTime(2026, 9, 6, 20), // 周日
        weekStart: DateTime(2026, 8, 31), // 周一
        plannedByDate: {
          '2026-09-01': _day(1, 3), // 胸（漏练）
          '2026-09-02': _day(2, 3), // 背（漏练）
          '2026-09-05': _day(3, 3), // 腿（漏练）
          '2026-09-06': _day(1, 3), // 胸（练了）
        },
        sessions: [_session(DateTime(2026, 9, 6), id: 104, planDayId: 1)],
        sets: [
          for (var i = 0; i < 3; i++)
            _set('杠铃卧推', DateTime(2026, 9, 6), 62.5, 8, sessionId: 104),
        ],
      );
      // 计划 4 天 / 12 组，只对上 1 天 → 1/4，「补训练次数」必须触发
      expect(r.plannedSessions, 4);
      expect(r.plannedWorkingSets, 12);
      expect(r.completedPlannedSessions, 1);
      expect(r.remainingPlannedSessions, 0);
      expect(r.action, contains('1/4'));
    });

    test('循环计划同模板日多次 occurrence 全部未练：每天各算一个计划日', () {
      // 两个胸日都没练且未触发顺延 → 计划仍按 4 天 / 12 组算，
      // 漏练程度不能被低估成 3 天 / 9 组。
      final r = weeklyRecap(
        now: DateTime(2026, 9, 6, 20),
        weekStart: DateTime(2026, 8, 31),
        plannedByDate: {
          '2026-09-01': _day(1, 3), // 胸（漏练）
          '2026-09-02': _day(2, 3), // 背（漏练）
          '2026-09-05': _day(3, 3), // 腿（漏练）
          '2026-09-06': _day(1, 3), // 胸（还没过完）
        },
        sessions: const [],
        sets: const [],
      );
      expect(r.plannedSessions, 4);
      expect(r.plannedWorkingSets, 12);
      expect(r.completedPlannedSessions, 0);
      // 周日的胸日还没过完，算剩余；其余三天已过去
      expect(r.remainingPlannedSessions, 1);
    });

    test('循环计划同一周轮到同一模板日：每天各算一次（练2休2配3模板）', () {
      // 练2休2 配 3 个模板日（胸/背/腿），patternStart 9/1：全局轮转给出
      // 9/1=胸、9/2=背、9/5=腿、9/6=胸——同一模板日（胸）在本周出现两次，
      // 两天都练成 → 计划完成数各算一次、计划组数翻倍，不是「只算一次」。
      final r = weeklyRecap(
        now: DateTime(2026, 9, 6, 20), // 周日
        weekStart: DateTime(2026, 8, 31), // 周一
        plannedByDate: {
          '2026-09-01': _day(1, 3), // 胸
          '2026-09-02': _day(2, 3), // 背
          '2026-09-05': _day(3, 3), // 腿
          '2026-09-06': _day(1, 3), // 胸（循环第二次）
        },
        sessions: [
          _session(DateTime(2026, 9, 1), id: 101, planDayId: 1),
          _session(DateTime(2026, 9, 2), id: 102, planDayId: 2),
          _session(DateTime(2026, 9, 5), id: 103, planDayId: 3),
          _session(DateTime(2026, 9, 6), id: 104, planDayId: 1),
        ],
        sets: [
          for (var i = 0; i < 3; i++) ...[
            _set('杠铃卧推', DateTime(2026, 9, 1), 60, 8, sessionId: 101),
            _set('杠铃划船', DateTime(2026, 9, 2), 60, 8, sessionId: 102),
            _set('杠铃深蹲', DateTime(2026, 9, 5), 80, 8, sessionId: 103),
            _set('杠铃卧推', DateTime(2026, 9, 6), 62.5, 8, sessionId: 104),
          ],
        ],
      );
      // 两个胸日各算一次：计划 4 天 / 12 组；4 场全对上 → 4/4，无计划外
      expect(r.plannedSessions, 4);
      expect(r.completedPlannedSessions, 4);
      expect(r.plannedWorkingSets, 12);
      expect(r.completedPlannedWorkingSets, 12);
      expect(r.extraSessions, 0);
      expect(r.extraWorkingSets, 0);
    });

    test('循环计划：第二次 occurrence 还没练时仍算独立计划日（计入剩余）', () {
      // 周三晚回看：只练了周一的胸；周日的胸是循环的下一次 occurrence，
      // 不是被顺延顶掉的原日期，要保留成独立计划日并计入剩余。
      final r = weeklyRecap(
        now: DateTime(2026, 9, 2, 20), // 周三
        weekStart: DateTime(2026, 8, 31),
        plannedByDate: {
          '2026-09-01': _day(1, 3), // 胸（已练）
          '2026-09-02': _day(2, 3), // 背（今天，还没练）
          '2026-09-05': _day(3, 3), // 腿（还没到）
          '2026-09-06': _day(1, 3), // 胸（还没到）
        },
        sessions: [_session(DateTime(2026, 9, 1), id: 101, planDayId: 1)],
        sets: const [],
      );
      expect(r.plannedSessions, 4);
      expect(r.completedPlannedSessions, 1);
      // 周二背 / 周六腿 / 周日胸都还没练
      expect(r.remainingPlannedSessions, 3);
    });

    test('计划内加组按计划组数封顶，超出部分算计划外', () {
      final r = weeklyRecap(
        now: sunday,
        weekStart: weekStart,
        plannedByDate: const {
          '2026-10-05': RecapPlannedDay(dayId: 1, workingSets: 3),
        },
        sessions: [_session(DateTime(2026, 10, 5), id: 101, planDayId: 1)],
        sets: [
          for (var i = 0; i < 5; i++)
            _set('杠铃卧推', DateTime(2026, 10, 5), 60, 10, sessionId: 101),
        ],
      );
      expect(r.completedPlannedSessions, 1);
      expect(r.completedPlannedWorkingSets, 3, reason: '计划完成最多按 3 组计');
      expect(r.completedWorkingSets, 5);
      expect(r.extraWorkingSets, 2, reason: '多做的 2 组算计划外');
    });

    test('英文行动文案里的动作名走 exname 英译', () {
      Lang.setResolved(true);
      addTearDown(() => Lang.setResolved(false));
      final r = _fullWeek(
        now: sunday,
        weekStart: weekStart,
        benchThisWeek: 62.5,
        benchLastWeek: 60,
      );
      expect(r.action, contains('Barbell Bench Press'));
      expect(r.action, isNot(contains('杠铃卧推')));
    });
  });
}
