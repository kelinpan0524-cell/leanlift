// 计划模板快照接线测试（调研条目 14）：开始训练时模板目标参数
// （组数 / 次数区间）整套快照进 session_exercises 行；总结建议文案
// 携带快照目标。引擎侧规则链判定见 test/progression_chain_test.dart。
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
    // 测试环境没有宿主插件：wakelock_plus 的 pigeon toggle 通道挂 mock 回包。
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
    final path = '$dir/snap_${DateTime.now().microsecondsSinceEpoch}.db';
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

  Future<(PlanDay, List<PlanExercise>)> makeDay() async {
    final plan = await db.insertPlan(Plan(
      name: '快照计划',
      source: 'manual',
      createdAt: '2026-09-25',
      isActive: 1,
    ));
    final dayId = await db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 3, title: '推日'));
    final day = PlanDay(id: dayId, planId: plan.id!, weekday: 3, title: '推日');
    final ex = PlanExercise(
      id: await db.insertPlanExercise(PlanExercise(
        dayId: dayId,
        name: '杠铃卧推',
        orderIdx: 0,
        sets: 4,
        repsMin: 6,
        repsMax: 10,
        restSec: 150,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 6, repsMax: 10, workingSets: 4),
      )),
      dayId: dayId,
      name: '杠铃卧推',
      orderIdx: 0,
      sets: 4,
      repsMin: 6,
      repsMax: 10,
      restSec: 150,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 6, repsMax: 10, workingSets: 4),
    );
    return (day, [ex]);
  }

  test('startFromDay 把模板目标参数全套快照进训练记录', () async {
    final (day, exs) = await makeDay();
    final c = SessionController(db, Settings(prefs), prefs, null);
    controllers.add(c);
    await c.startFromDay(day: day, planExercises: exs);

    expect(c.exercises, hasLength(1));
    final se = c.exercises.first;
    expect(se.targetSets, 4); // 模板组数
    expect(se.targetRepsMin, 6); // 模板次数区间
    expect(se.targetRepsMax, 10);
    expect(se.restSec, 150);
    expect(se.name, '杠铃卧推');

    // 落库读回一致（不只内存态）
    final rows = await db.sessionExercises(c.session!.id!);
    expect(rows.first.targetSets, 4);
    expect(rows.first.targetRepsMin, 6);
    expect(rows.first.targetRepsMax, 10);
  });

  test('模板日后修改不影响已快照的老记录', () async {
    final (day, exs) = await makeDay();
    final c = SessionController(db, Settings(prefs), prefs, null);
    controllers.add(c);
    await c.startFromDay(day: day, planExercises: exs);
    final seId = c.exercises.first.id!;

    // 模板被改成 2×12-15
    final pe = exs.first;
    await db.updatePlanExercise(pe.copyWith(sets: 2, repsMin: 12, repsMax: 15));

    // 老记录的快照原样保留
    final rows = await db.sessionExercises(c.session!.id!);
    final old = rows.firstWhere((r) => r.id == seId);
    expect(old.targetSets, 4);
    expect(old.targetRepsMin, 6);
    expect(old.targetRepsMax, 10);
  });

  test('verdicts 文案携带快照目标（无快照回退规则参数）', () async {
    final (day, exs) = await makeDay();
    final c = SessionController(db, Settings(prefs), prefs, null);
    controllers.add(c);
    await c.startFromDay(day: day, planExercises: exs);
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);

    final vs = await c.verdicts();
    expect(vs, hasLength(1));
    expect(vs.single, contains('计划目标 4×6-10'));
  });

  test('训练中替换动作后快照仍在（整行覆写不丢 target 列）', () async {
    final (day, exs) = await makeDay();
    final c = SessionController(db, Settings(prefs), prefs, null);
    controllers.add(c);
    await c.startFromDay(day: day, planExercises: exs);

    final ok = await c.replaceCurrentExercise(const ExerciseMeta(
      '上斜哑铃卧推',
      MuscleGroups(main: '胸'),
      false,
    ));
    expect(ok, isTrue);

    expect(c.exercises.first.targetSets, 4);
    expect(c.exercises.first.targetRepsMin, 6);
    expect(c.exercises.first.targetRepsMax, 10);
    expect(c.exercises.first.trace, '替换自：杠铃卧推');

    // 落库读回一致（updateSessionExercise 整行覆写路径）
    final rows = await db.sessionExercises(c.session!.id!);
    expect(rows.first.targetSets, 4);
    expect(rows.first.targetRepsMin, 6);
    expect(rows.first.targetRepsMax, 10);
  });

  test('自重历史（0kg）动作的建议重量走链判定而非回退预设 20kg', () async {
    // 历史：done 会话里 "单杠悬垂举腿" 0kg×6×3，末组余力 0（不满足 RIR 门槛）
    // → 规则链 hold → 建议重量保持 0；修复前这里会把 0 误判为「无历史」，
    // 回退 presetStartOf 的默认 20kg。
    // 历史日期用**相对 2 天前**（2026-10-18）：固定日期离测试运行日一远
    // （≥14 天）就会触发 P1-D 停练降档，让本测试的「链 hold」断言碰巧
    // 由停练路径兜住——测试意图失真。这里显式断言不在停练态。
    final histDate = fmtDate(DateTime.now().subtract(const Duration(days: 2)));
    final rule = ProgressionRule(repsMin: 5, repsMax: 8);
    final (hist, histEx) = await db.insertSessionWithExercises(
      Session(
        date: histDate,
        planDayTitle: '核心日',
        startedAt: 1000,
        endedAt: 2000,
        status: 'done',
      ),
      [
        SessionExercise(
          sessionId: 0,
          name: '单杠悬垂举腿',
          orderIdx: 0,
          kind: 'assistance',
          rule: rule,
        ),
      ],
    );
    for (var i = 0; i < 3; i++) {
      await db.insertSet(SetEntry(
        sessionExerciseId: histEx.first.id!,
        weightKg: 0,
        reps: 6,
        rir: 0,
        kind: SetKind.working,
        doneAt: 1100 + i,
      ));
    }

    final plan = await db.insertPlan(Plan(
      name: '自重计划',
      source: 'manual',
      createdAt: '2026-09-25',
      isActive: 1,
    ));
    final dayId = await db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 4, title: '核心日'));
    final ex = PlanExercise(
      id: await db.insertPlanExercise(PlanExercise(
        dayId: dayId,
        name: '单杠悬垂举腿',
        orderIdx: 0,
        sets: 3,
        repsMin: 5,
        repsMax: 8,
        restSec: 90,
        kind: 'assistance',
        rule: rule,
      )),
      dayId: dayId,
      name: '单杠悬垂举腿',
      orderIdx: 0,
      sets: 3,
      repsMin: 5,
      repsMax: 8,
      restSec: 90,
      kind: 'assistance',
      rule: rule,
    );
    final c = SessionController(db, Settings(prefs), prefs, null);
    controllers.add(c);
    await c.startFromDay(
      day: PlanDay(id: dayId, planId: plan.id!, weekday: 4, title: '核心日'),
      planExercises: [ex],
    );

    // 显式断言（2026-10-18）：2 天前有正式组的 done 训练 → 不触发停练降档；
    // 本测试的 0kg 建议重量只来自规则链 hold，与停练路径无关。
    expect(c.inLayoff, isFalse);

    // hold：0kg 保持 0（presetStartOf 对词表外动作返回 20）
    expect(c.weightDraft, 0);
  });
}
