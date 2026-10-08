// 加练组标注（v12，2026-10-08）：训练后看得出哪组是加练——
// 历史页「N（加练）/含加练 X 组」与总结页『本次组数』的数据源真值。
// 覆盖：计划内组不标 / 超计划正式组标（内存 + DB 往返一致）/
// 计划满后的热身·力竭组不标（kind 限定判据：加练态下 kind chips 仍可选，
// 不限定会把热身/力竭误标、含加练计数虚高）/ 撤销加练组后重记仍正确 /
// 加练组照旧全额计入容量（回归护栏：isExtra 不改统计口径）。
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
    // 测试环境没有宿主插件：wakelock_plus 的 pigeon toggle 通道挂 mock 回包
    //（编码后的 [null]，与 session_controller_test 同一套）。
    final binding = TestWidgetsFlutterBinding.instance;
    final pigeonNullReply = ByteData(3)
      ..setUint8(0, 12)
      ..setUint8(1, 1)
      ..setUint8(2, 0);
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (data) async => pigeonNullReply,
    );
  });

  late Db db;
  late SharedPreferences prefs;
  final controllers = <SessionController>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final dir = await databaseFactory.getDatabasesPath();
    final path = '$dir/test_extra_${DateTime.now().microsecondsSinceEpoch}.db';
    final rawDb = await databaseFactory.openDatabase(path);
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

  SessionController makeController() {
    final c = SessionController(db, Settings(prefs), prefs, null);
    controllers.add(c);
    return c;
  }

  Future<PlanDay> makePlanDay(String title) async {
    final plan = await db.insertPlan(Plan(
        name: '测试计划-$title',
        source: 'manual',
        createdAt: '2026-10-08',
        isActive: 1));
    final dayId = await db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 3, title: title));
    return PlanDay(id: dayId, planId: plan.id!, weekday: 3, title: title);
  }

  Future<PlanExercise> addPlanEx(
    PlanDay day,
    String name,
    int order, {
    int workingSets = 3,
  }) async {
    final pe = PlanExercise(
      dayId: day.id!,
      name: name,
      orderIdx: order,
      sets: workingSets,
      repsMin: 5,
      repsMax: 8,
      restSec: 60,
      kind: 'compound',
      rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: workingSets),
    );
    final id = await db.insertPlanExercise(pe);
    return pe.copyWith(id: id);
  }

  test('计划内组不标；超计划正式组标 true，内存与 DB 往返一致', () async {
    final day = await makePlanDay('腿日');
    final e = await addPlanEx(day, '深蹲', 0, workingSets: 2);
    final c = makeController();
    // 收尾确认回答「继续训练」：练满不清场，才有加练组可标（修复①管线）
    c.confirmAutoFinish = () async => false;
    await c.startFromDay(day: day, planExercises: [e]);

    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    var mem = c.setsByEx[c.currentEx!.id]!;
    expect(mem.where((s) => s.isExtra), isEmpty, reason: '计划内两组都不是加练');

    // 计划满后再记正式组（休息页「再来一组」同链路）
    await c.completeSet(weight: 62.5, reps: 8, rir: 2, kind: SetKind.working);
    mem = c.setsByEx[c.currentEx!.id]!;
    expect(mem.last.isExtra, isTrue, reason: '第 3 组正式组 = 加练');
    expect(mem.take(2).every((s) => !s.isExtra), isTrue);

    // DB 往返：历史页读回同一真值
    final fromDb = await db.setsOfSession(c.session!.id!);
    final all =
        fromDb.values.expand((l) => l).toList()
          ..sort((a, b) => a.doneAt.compareTo(b.doneAt));
    expect(all.length, 3);
    expect([for (final s in all) s.isExtra], [false, false, true],
        reason: '落库与内存一致（setsOfSession 历史数据源）');
  });

  test('计划满后再记热身/力竭组：不标（kind 限定判据）', () async {
    final day = await makePlanDay('推日');
    final e = await addPlanEx(day, '卧推', 0, workingSets: 1);
    final c = makeController();
    c.confirmAutoFinish = () async => false;
    await c.startFromDay(day: day, planExercises: [e]);

    // 计划满（1/1）→ 确认「继续训练」→ 同动作继续记热身/力竭
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    await c.completeSet(weight: 40, reps: 8, rir: 5, kind: SetKind.warmup);
    await c.completeSet(weight: 60, reps: 6, rir: 0, kind: SetKind.failure);
    // 再来一个超计划正式组：要标
    await c.completeSet(weight: 62.5, reps: 8, rir: 2, kind: SetKind.working);

    final mem = c.setsByEx[c.currentEx!.id]!;
    expect([for (final s in mem) s.kind],
        [SetKind.working, SetKind.warmup, SetKind.failure, SetKind.working]);
    expect([for (final s in mem) s.isExtra], [false, false, false, true],
        reason: '只有 kind=working 且超计划的组标加练，热身/力竭不误标');
  });

  test('撤销加练组后重记：标注仍正确（undo 组合场景）', () async {
    final day = await makePlanDay('日');
    final e = await addPlanEx(day, '划船', 0, workingSets: 1);
    final c = makeController();
    c.confirmAutoFinish = () async => false;
    await c.startFromDay(day: day, planExercises: [e]);

    await c.completeSet(weight: 50, reps: 8, rir: 2, kind: SetKind.working);
    await c.completeSet(weight: 50, reps: 8, rir: 2, kind: SetKind.working);
    expect(c.setCount, 2);
    expect(c.setsByEx[c.currentEx!.id]!.last.isExtra, isTrue);

    // 撤销：目标 = 全会话最新一组 = 刚才的加练组
    await c.undoLastSet();
    expect(c.setCount, 1);
    expect(c.workingSetsDone, 1, reason: '按剩余正式组重算');
    expect(c.setsByEx[c.currentEx!.id]!.single.isExtra, isFalse);

    // 重记这组：仍是加练
    await c.completeSet(weight: 52.5, reps: 8, rir: 2, kind: SetKind.working);
    final mem = c.setsByEx[c.currentEx!.id]!;
    expect([for (final s in mem) s.isExtra], [false, true],
        reason: '撤销后重记，加练标注不串行');

    final fromDb = await db.setsOfSession(c.session!.id!);
    final all = fromDb.values.expand((l) => l).toList();
    expect(all.length, 2);
    expect([for (final s in all) s.isExtra], contains(true));
  });

  test('加练组照旧全额计入容量（回归护栏：isExtra 不改统计口径）', () async {
    final day = await makePlanDay('日');
    final e = await addPlanEx(day, '卧推', 0, workingSets: 1);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: [e]);

    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    // 第 2 组（加练）走自动结束路径也要先标好再落库
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);

    final mem = c.setsByEx[c.currentEx!.id]!;
    expect([for (final s in mem) s.isExtra], [false, true]);

    // sessionStatsFrom 口径不变：加练组全额计入正式组数与容量（60×8×2=960）
    final stats = sessionStatsFrom(c.setsByEx, c.exercises);
    expect(stats.workingSets, 2);
    expect(stats.volume, 960);
    expect(c.session!.status, 'done', reason: '未挂确认回调时练满仍自动结束');
  });
}
