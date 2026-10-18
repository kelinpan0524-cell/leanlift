// P1-D 停练回归接线测试：开练时按「全库上一场 done 训练」判定 ≥14 天；
// 处方 0.85×、组数 -1；与减载周取更低的 0.85 不叠加；回归场次不计入
// 下次处方，间隔 <14 天的下一场自动回到停练前档位。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/services/session_controller.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // finish() 会调 WakelockPlus.disable：测试环境没有宿主插件，
    // 按 void 方法回 [null]（与 training_block_controller_test.dart 同口径）。
    final pigeonNullReply = ByteData(3)
      ..setUint8(0, 12)
      ..setUint8(1, 1)
      ..setUint8(2, 0);
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (data) async => pigeonNullReply,
    );
  });

  late Db db;
  late Database rawDb;
  late SharedPreferences prefs;
  final controllers = <SessionController>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final dir = await databaseFactory.getDatabasesPath();
    final path =
        '$dir/test_layoff_${DateTime.now().microsecondsSinceEpoch}.db';
    rawDb = await databaseFactory.openDatabase(path);
    await Db.instance.createSchema(rawDb);
    db = Db.forTesting(rawDb);
  });

  tearDown(() async {
    for (final c in controllers) {
      c.dispose();
    }
    controllers.clear();
    await db.wipeAll();
  });

  Future<(PlanDay, List<PlanExercise>)> makePlan() async {
    final plan = await db.insertPlan(
      Plan(
        name: '停练测试计划',
        source: 'manual',
        createdAt: '2026-10-01',
        isActive: 1,
      ),
    );
    final dayId = await db.insertPlanDay(
      PlanDay(planId: plan.id!, weekday: 1, title: '推日'),
    );
    final pe = PlanExercise(
      dayId: dayId,
      name: '杠铃卧推',
      orderIdx: 0,
      sets: 3,
      repsMin: 5,
      repsMax: 8,
      restSec: 120,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
    );
    await db.insertPlanExercise(pe);
    final day =
        PlanDay(id: dayId, planId: plan.id!, weekday: 1, title: '推日');
    return (day, await db.dayExercises(dayId));
  }

  /// 往 [daysAgo] 天前写一场已完成训练（60kg × [reps] × 3）。
  Future<int> addDoneSession(
    PlanDay day,
    int daysAgo, {
    int reps = 6,
    int setCount = 3,
    double weight = 60,
  }) async {
    final when = DateTime.now().subtract(Duration(days: daysAgo));
    final base = when.millisecondsSinceEpoch;
    final s = await db.insertSession(Session(
      date: fmtDate(when),
      planDayId: day.id,
      planDayTitle: day.title,
      startedAt: 1,
      status: 'done',
    ));
    final se = await db.insertSessionExercise(SessionExercise(
      sessionId: s.id!,
      name: '杠铃卧推',
      orderIdx: 0,
      kind: 'compound',
      restSec: 120,
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      targetSets: 3,
      targetRepsMin: 5,
      targetRepsMax: 8,
    ));
    for (var i = 0; i < setCount; i++) {
      await db.insertSet(SetEntry(
        sessionExerciseId: se,
        weightKg: weight,
        reps: reps,
        kind: SetKind.working,
        doneAt: base + i,
      ));
    }
    return s.id!;
  }

  SessionController makeController({int blockWeeks = 0}) {
    final c = SessionController(db, Settings(prefs), prefs, null);
    controllers.add(c);
    c.settings.trainingBlockWeeks = blockWeeks;
    return c;
  }

  test('14 天边界：第 14 天触发 85% + 组数 -1；第 13 天回到正常处方', () async {
    final (day, exs) = await makePlan();
    final sid = await addDoneSession(day, 14, reps: 6);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);

    expect(c.inLayoff, isTrue);
    expect(c.layoffDays, 14);
    expect(c.weightDraft, 51, reason: '60 × 0.85 = 51');
    expect(c.exercises.first.targetSets, 2, reason: '3 组 -1');
    expect(c.targetWhyOf(0), contains('停练 14 天'));
    expect(c.targetWhyOf(0), contains('85%'));
    expect(await c.verdicts(), everyElement(isNot(contains('继续加重'))));
    await c.quit();

    // 把上一场挪到 13 天前：下一场不再触发，处方回到 60kg / 3 组
    await rawDb.update(
      'sessions',
      {
        'date': fmtDate(DateTime.now().subtract(const Duration(days: 13))),
      },
      where: 'id = ?',
      whereArgs: [sid],
    );
    final c2 = makeController();
    await c2.startFromDay(day: day, planExercises: exs);
    expect(c2.inLayoff, isFalse);
    expect(c2.layoffDays, 0);
    expect(c2.weightDraft, 60, reason: '60×6 未到上限 → 保持 60');
    expect(c2.exercises.first.targetSets, 3);
  });

  test('与减载周叠加：取更低的 85% 一档，组数只减一次', () async {
    final (day, exs) = await makePlan();
    await addDoneSession(day, 28, reps: 6);
    final c = makeController(blockWeeks: kDefaultTrainingBlockWeeks);
    await c.startFromDay(day: day, planExercises: exs);

    expect(c.inDeloadWeek, isTrue, reason: '28 天 = 5 周一块的第 5 周');
    expect(c.inLayoff, isTrue);
    expect(c.layoffDays, 28);
    // 不叠加：60×0.85 = 51，而不是 60×0.9 再×0.85 = 45.9
    expect(c.weightDraft, 51);
    expect(c.exercises.first.targetSets, 2, reason: '组数只减 1 次，不能 3→1');
    final why = c.targetWhyOf(0);
    expect(why, contains('85%'));
    expect(why, contains('不重复打折'));
    expect(why, isNot(contains('90%')));

    final verdicts = await c.verdicts();
    expect(verdicts.first, contains('停练 28 天回归'));
    expect(verdicts.first, contains('85%'));
    expect(verdicts.first, contains('不重复打折'));
    expect(verdicts.first, isNot(contains('本周减载')));
  });

  test('回归场次不计入处方：下一次间隔 <14 天自动恢复正常', () async {
    final (day, exs) = await makePlan();
    await addDoneSession(day, 20, reps: 8); // 停练前已顶格，正常下一场 62.5
    final c1 = makeController();
    await c1.startFromDay(day: day, planExercises: exs);
    expect(c1.inLayoff, isTrue);
    expect(c1.weightDraft, 51);

    c1.confirmAutoFinish = () async => false;
    await c1.completeSet(weight: 51, reps: 8, rir: 2, kind: SetKind.working);
    c1.skipRest();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await c1.finish();
    expect(c1.session!.status, 'done');

    // 同一天再开：上一场是刚完成的回归场，间隔 0 天 → 自动恢复正常
    final c2 = makeController();
    await c2.startFromDay(day: day, planExercises: exs);
    expect(c2.inLayoff, isFalse, reason: '间隔 <14 天不再降档');
    expect(c2.layoffDays, 0);
    expect(c2.exercises.first.targetSets, 3);
    expect(c2.weightDraft, 62.5,
        reason: '回归场不计入处方回溯，按停练前 60×8 顶格加重');
    expect(c2.lastPerformance('杠铃卧推')!.weightKg, 51,
        reason: '「上次成绩」仍显示真实的回归场');
  });

  test('杀进程恢复：沿用开练时的停练快照，不随日期重算', () async {
    final (day, exs) = await makePlan();
    await addDoneSession(day, 14, reps: 6);
    final c1 = makeController();
    await c1.startFromDay(day: day, planExercises: exs);
    expect(c1.inLayoff, isTrue);

    final c2 = makeController();
    await c2.restore();
    expect(c2.hasActive, isTrue);
    expect(c2.inLayoff, isTrue);
    expect(c2.layoffDays, 14);
    expect(c2.weightDraft, 51);
    expect(c2.exercises.first.targetSets, 2);
  });
}
