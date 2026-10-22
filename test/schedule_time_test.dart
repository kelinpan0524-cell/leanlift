// 日期化排程 + 训练/休息时长统计 回归：
// 循环练休推导、覆盖行优先、拖拉改期（移动/互换/墓碑）、
// 星期回退、飞书规格按日期、会话时长落库、AI 分析包含休息数据。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/services/export_service.dart';
import 'package:baoji_timer/services/plan_repository.dart';
import 'package:baoji_timer/services/session_controller.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    final binding = TestWidgetsFlutterBinding.instance;
    final pigeonNullReply = ByteData(3)
      ..setUint8(0, 12)
      ..setUint8(1, 1)
      ..setUint8(2, 0);
    binding.defaultBinaryMessenger.setMockMessageHandler(
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
        (data) async => pigeonNullReply);
  });

  late Db db;
  late SharedPreferences prefs;
  final controllers = <SessionController>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final dir = await databaseFactory.getDatabasesPath();
    final path =
        '$dir/test_sched_${DateTime.now().microsecondsSinceEpoch}.db';
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

  /// 建一个循环计划：2 个模板日（练1/练2），练 N 休 M，起始 [start]。
  Future<Plan> makeCyclePlan(
      {required int train, required int rest, required DateTime start}) async {
    final plan = await db.insertPlan(Plan(
        name: '循环计划',
        source: 'manual',
        createdAt: '2026-09-24',
        isActive: 1,
        pattern: 'cycle',
        patternStart: fmtDate(start),
        cycleTrain: train,
        cycleRest: rest));
    for (var i = 1; i <= 2; i++) {
      final dayId = await db.insertPlanDay(PlanDay(
          planId: plan.id!,
          weekday: i,
          title: '练$i'));
      await db.insertPlanExercise(PlanExercise(
        dayId: dayId,
        name: '动作$i',
        orderIdx: 0,
        sets: 3,
        repsMin: 5,
        repsMax: 8,
        restSec: 120,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      ));
    }
    return plan;
  }

  test('S1：循环练2休1按起始日纯数学推导，无需预生成排程行', () async {
    final plan = await makeCyclePlan(
        train: 2, rest: 1, start: DateTime(2026, 9, 21)); // 周一起
    final repo = PlanRepository(db, Settings(prefs));

    // 第 0/1 天 = 练1/练2，第 2 天 = 休，第 3 天回到练1
    final day0 = await repo.dayForDateOn(plan, DateTime(2026, 9, 21));
    final day1 = await repo.dayForDateOn(plan, DateTime(2026, 9, 22));
    final day2 = await repo.dayForDateOn(plan, DateTime(2026, 9, 23));
    final day3 = await repo.dayForDateOn(plan, DateTime(2026, 9, 24));
    expect(day0?.title, '练1');
    expect(day1?.title, '练2');
    expect(day2, isNull, reason: '循环休息日');
    expect(day3?.title, '练1', reason: '周期 3 天，回到第 0 个模板');
  });

  test('S2：覆盖行优先于推导；显式休息墓碑挡住推导；清除后回归规则', () async {
    final plan = await makeCyclePlan(
        train: 2, rest: 1, start: DateTime(2026, 9, 21));
    final repo = PlanRepository(db, Settings(prefs));
    final rest = repo;

    // 推导：9/22 = 练2；覆盖成 练1 后以覆盖为准
    final d22 = DateTime(2026, 9, 22);
    await rest.setOverride(plan, d22,
        (await rest.dayForDateOn(plan, DateTime(2026, 9, 21)))!.id);
    expect((await rest.dayForDateOn(plan, d22))?.title, '练1');

    // 覆盖为显式休息：推导本该练，但用户手动改休 → 休
    await rest.setOverride(plan, d22, null);
    expect(await rest.dayForDateOn(plan, d22), isNull);

    // 清除覆盖：回到循环推导
    await rest.clearOverride(plan, d22);
    expect((await rest.dayForDateOn(plan, d22))?.title, '练2');
  });

  test('S3：moveScheduleDay 移动落墓碑；目标已有训练则互换；起点无训练不动', () async {
    final plan = await makeCyclePlan(
        train: 2, rest: 1, start: DateTime(2026, 9, 21));
    final repo = PlanRepository(db, Settings(prefs));

    // 把 9/21（练1）挪到 9/23（循环休息日）：9/23=练1，9/21 落显式休息墓碑
    await repo.moveScheduleDay(
        plan, DateTime(2026, 9, 21), DateTime(2026, 9, 23));
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 23)))?.title, '练1');
    expect(await repo.dayForDateOn(plan, DateTime(2026, 9, 21)), isNull,
        reason: '挪走后显式休息，推导不回填');

    // 互换：9/23（练1）与 9/22（练2）对调
    await repo.moveScheduleDay(
        plan, DateTime(2026, 9, 23), DateTime(2026, 9, 22));
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 22)))?.title, '练1');
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 23)))?.title, '练2');

    // 起点是无训练的循环休息日（9/26，无覆盖行）：no-op 不落行
    await repo.moveScheduleDay(
        plan, DateTime(2026, 9, 26), DateTime(2026, 9, 24));
    final rows = await db.allScheduleEntries(plan.id!);
    expect(rows.where((e) => e.date == '2026-09-26'), isEmpty);
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 24)))?.title, '练1',
        reason: 'no-op：终点内容未被误改');
  });

  test('S4：按星期计划保留旧行为（weekday 回退），单日覆盖可用', () async {
    final plan = await db.insertPlan(Plan(
        name: '周计划',
        source: 'manual',
        createdAt: '2026-09-24',
        isActive: 1));
    final dayId = await db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 3, title: '周三练'));
    await db.insertPlanExercise(PlanExercise(
      dayId: dayId,
      name: '卧推',
      orderIdx: 0,
      sets: 3,
      repsMin: 5,
      repsMax: 8,
      restSec: 120,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
    ));
    final repo = PlanRepository(db, Settings(prefs));

    final wed = DateTime(2026, 9, 23); // 周三
    expect((await repo.dayForDateOn(plan, wed))?.title, '周三练');
    final thu = wed.add(const Duration(days: 1));
    expect(await repo.dayForDateOn(plan, thu), isNull);

    // 把周四临时变成训练日（今天练前天/后天的训练场景）
    await repo.setOverride(plan, thu, dayId);
    expect((await repo.dayForDateOn(plan, thu))?.title, '周三练');
  });

  test('S5：飞书同步规格带具体日期（循环计划 14 天窗口数量正确）', () async {
    final start = DateTime(2026, 9, 21);
    final plan = await makeCyclePlan(train: 2, rest: 1, start: start);
    final repo = PlanRepository(db, Settings(prefs));
    final specs = await repo.larkSpecsForPlan(plan.id!);
    // 期望数 = 未来 14 天里落在"练"段位的天数（按与实现相同的推导算）
    final today = DateTime.now();
    final offset0 = DateTime(today.year, today.month, today.day)
        .difference(DateTime(start.year, start.month, start.day))
        .inDays;
    var expected = 0;
    for (var i = 0; i < 14; i++) {
      if ((offset0 + i) % 3 < 2) expected++;
    }
    expect(specs.length, expected);
    // 每条都有具体日期且日期不重复
    final dates = specs.map((s) => s.date).toList();
    expect(dates.toSet().length, dates.length, reason: '一天最多一条');
    for (final d in dates) {
      expect(d, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    }
  });

  test('S6：finish 落库训练/休息净时长，Session 反序列化带回', () async {
    final plan = await db.insertPlan(Plan(
        name: '日', source: 'manual', createdAt: '2026-09-24', isActive: 1));
    final dayId = await db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 1, title: '推日'));
    final pe = PlanExercise(
      dayId: dayId,
      name: '卧推',
      orderIdx: 0,
      sets: 1,
      repsMin: 5,
      repsMax: 8,
      restSec: 120,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 1),
    );
    await db.insertPlanExercise(pe);

    final c = SessionController(db, Settings(prefs), prefs, null);
    controllers.add(c);
    await c.startFromDay(
        day: PlanDay(planId: plan.id!, weekday: 1, title: '推日'),
        planExercises: [pe]);
    // 直接注入分桶值（真实累计依赖墙钟，测试里不稳定）；重点验证落库与回读链路
    c.restMs = 65000; // ~1 分钟
    c.activeMs = 240000; // ~4 分钟
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    expect(c.hasActive, isFalse, reason: '唯一正式组完成自动结束');

    final stored = await db.sessionById(c.session!.id!);
    expect(stored!.restMs, 65000);
    expect(stored.activeMs, 240000);
    expect(stored.restMs ~/ 60000, 1);
    expect(stored.activeMs ~/ 60000, 4);
  });

  test('S7：AI 分析包带休息数据（训练/休息分桶 + 计划休 vs 实际均休）', () async {
    final s = await db.insertSession(Session(
        date: '2026-09-20',
        planDayTitle: '推日',
        startedAt: 1,
        endedAt: 2,
        status: 'done',
        restMs: 900000,
        activeMs: 1500000));
    final se = await db.insertSessionExercise(SessionExercise(
        sessionId: s.id!,
        name: '卧推',
        orderIdx: 0,
        kind: 'compound',
        restSec: 120,
        rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3)));
    final base = DateTime(2026, 9, 20, 10).millisecondsSinceEpoch;
    await db.insertSet(SetEntry(
        sessionExerciseId: se,
        weightKg: 60,
        reps: 8,
        kind: SetKind.working,
        doneAt: base));
    await db.insertSet(SetEntry(
        sessionExerciseId: se,
        weightKg: 60,
        reps: 8,
        kind: SetKind.working,
        doneAt: base + 150000)); // 组间 150s
    final pack = await ExportService(db).buildAiPack();
    expect(pack, contains('训练 25 分 · 休息 15 分'));
    expect(pack, contains('计划休 120s'));
    expect(pack, contains('实际均休 ~150s'));
    expect(pack, contains('休息过长或过短'));
  });

  test('S8（评审拉齐口径）：AI 分析包传体重时自重动作按系数×体重计入容量', () async {
    final s = await db.insertSession(Session(
        date: '2026-09-20',
        planDayTitle: '背日',
        startedAt: 1,
        endedAt: 2,
        status: 'done'));
    final se = await db.insertSessionExercise(SessionExercise(
        sessionId: s.id!,
        name: '引体向上',
        orderIdx: 0,
        kind: 'compound',
        restSec: 150,
        rule: const ProgressionRule(repsMin: 5, repsMax: 10, workingSets: 3)));
    await db.insertSet(SetEntry(
        sessionExerciseId: se,
        weightKg: 0, // 自重：旧口径记 0
        reps: 10,
        kind: SetKind.working,
        doneAt: DateTime(2026, 9, 20, 10).millisecondsSinceEpoch));

    // 传体重：0.70 × 70 × 10 = 490
    final withBw = await ExportService(db).buildAiPack(bodyWeightKg: 70);
    expect(withBw, contains('总容量 490kg'));
    expect(withBw, contains('- 引体向上: 490'));

    // 不传（旧口径）：自重仍记 0
    final withoutBw = await ExportService(db).buildAiPack();
    expect(withoutBw, contains('总容量 0kg'));
  });
}
