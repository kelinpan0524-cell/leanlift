import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart' show fmtDate;
import 'package:baoji_timer/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Db db;

  setUp(() async {
    // 唯一文件路径 = 每个测试独立数据库（ffi 对同路径会复用连接）
    final dir = await databaseFactory.getDatabasesPath();
    final path =
        '$dir/test_${DateTime.now().microsecondsSinceEpoch}.db';
    final database = await databaseFactory.openDatabase(path);
    await Db.instance.createSchema(database);
    db = Db.forTesting(database);
  });

  tearDown(() async {
    await db.wipeAll();
  });

  Future<Plan> makePlan(String name,
      {String source = 'manual', int isActive = 0}) async {
    final p = await db.insertPlan(Plan(
        name: name,
        source: source,
        createdAt: '2026-09-23',
        isActive: isActive));
    return Plan.fromMap({...p.toMap(), 'id': p.id});
  }

  Future<int> addDay(int planId, int weekday, String title) =>
      db.insertPlanDay(PlanDay(planId: planId, weekday: weekday, title: title));

  Future<int> addExercise(int dayId, String name,
      {int order = 0, int restSec = 120}) async {
    return db.insertPlanExercise(PlanExercise(
      dayId: dayId,
      name: name,
      orderIdx: order,
      sets: 3,
      repsMin: 5,
      repsMax: 8,
      restSec: restSec,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8),
    ));
  }

  group('多计划 CRUD', () {
    test('创建多个计划并可切换启用；切换后原计划失活', () async {
      final a = await makePlan('A');
      await db.setActivePlan(a.id!);
      final b = await makePlan('B');
      await db.setActivePlan(b.id!);

      final active = await db.activePlan();
      expect(active!.id, b.id);
      final all = await db.allPlans();
      expect(all.length, 2);
      expect(all.first.id, b.id, reason: '启用的排最前');
      final aRow = all.where((p) => p.id == a.id).first;
      expect(aRow.isActive, 0);
    });

    test('切换启用记录 activated_at；重复启用同一个计划不刷新', () async {
      final a = await makePlan('A', isActive: 1);
      final b = await makePlan('B');
      await db.setActivePlan(b.id!);
      final b1 = (await db.allPlans()).firstWhere((p) => p.id == b.id);
      expect(b1.activatedAt, fmtDate(DateTime.now()));

      await db.setActivePlan(b.id!);
      final b2 = (await db.allPlans()).firstWhere((p) => p.id == b.id);
      expect(b2.activatedAt, b1.activatedAt, reason: '重复点已启用计划不能把启用日刷新到今天');

      await db.setActivePlan(a.id!);
      final a1 = (await db.allPlans()).firstWhere((p) => p.id == a.id);
      expect(a1.activatedAt, fmtDate(DateTime.now()));
    });

    test('切换再切回：activated_at 保留最早启用日，不把计划起点推后', () async {
      // 语义（2026-10-18）：activated_at = 最早一次启用日。计划 A 曾在
      // 2026-09-01 启用过，切到 B 再切回 A，起点仍是 09-01——周复盘的
      // 回溯窗口不因切换器的来回操作被推后。
      final a = await makePlan('A');
      final b = await makePlan('B');
      await db.setActivePlan(a.id!);
      // 手工把 A 的启用日拨回过去（模拟它实际是更早启用过的老计划）
      await db.updatePlanFields(a.id!, {'activated_at': '2026-09-01'});

      // 切走（B 启用，A 失活）再切回 A
      await db.setActivePlan(b.id!);
      expect((await db.allPlans()).firstWhere((p) => p.id == a.id).isActive, 0);
      await db.setActivePlan(a.id!);

      final back = (await db.allPlans()).firstWhere((p) => p.id == a.id);
      expect(back.activatedAt, '2026-09-01',
          reason: '重激活不刷新启用日：最早启用日就是计划起点');
      expect(back.isActive, 1);
      expect((await db.allPlans()).firstWhere((p) => p.id == b.id).isActive, 0);
    });

    test('重命名与删除（级联删除日与动作）', () async {
      final p = await makePlan('旧名');
      final dayId = await addDay(p.id!, 1, '推');
      await addExercise(dayId, '卧推');

      await db.renamePlan(p.id!, '新名');
      final renamed = await db.allPlans();
      expect(renamed.first.name, '新名');

      await db.deletePlan(p.id!);
      expect((await db.allPlans()).isEmpty, isTrue);
      expect((await db.planDays(p.id!)).isEmpty, isTrue);
    });

    test('计数聚合：每个计划的训练日/动作数', () async {
      final p = await makePlan('P');
      final d1 = await addDay(p.id!, 1, 'A日');
      addDay(p.id!, 3, 'B日');
      await addExercise(d1, '卧推');
      await addExercise(d1, '划船', order: 1);

      final dayCounts = await db.planDayCounts();
      final exCounts = await db.planExerciseCounts();
      expect(dayCounts[p.id!], 2);
      expect(exCounts[p.id], 2);
    });
  });

  group('训练日/动作编辑', () {
    test('更新训练日标题与星期', () async {
      final p = await makePlan('P');
      final dayId = await addDay(p.id!, 1, '推');
      final day = (await db.planDays(p.id!)).first;
      await db.updatePlanDay(PlanDay(
          id: dayId, planId: p.id!, weekday: 5, title: '推力日'));
      final days = await db.planDays(p.id!);
      expect(days.first.weekday, 5);
      expect(days.first.title, '推力日');
      expect(day.id, dayId);
    });

    test('交换两个训练日的星期', () async {
      final p = await makePlan('P');
      final d1 = await addDay(p.id!, 1, '周一内容');
      final d2 = await addDay(p.id!, 3, '周三内容');
      final days = await db.planDays(p.id!);
      await db.swapPlanDayWeekdays(days[0], days[1]);
      final after = await db.planDays(p.id!);
      final day1 = after.where((d) => d.id == d1).first;
      final day3 = after.where((d) => d.id == d2).first;
      expect(day1.weekday, 3);
      expect(day3.weekday, 1);
    });

    test('更新与删除单个动作；重排 order_idx', () async {
      final p = await makePlan('P');
      final dayId = await addDay(p.id!, 1, '日');
      final e1 = await addExercise(dayId, '动作1', order: 0);
      final e2 = await addExercise(dayId, '动作2', order: 1);
      final e3 = await addExercise(dayId, '动作3', order: 2);

      final exs = await db.dayExercises(dayId);
      final updated = exs[0].copyWith(name: '改名', sets: 5, restSec: 90);
      await db.updatePlanExercise(updated);
      final after1 = await db.dayExercises(dayId);
      expect(after1[0].name, '改名');
      expect(after1[0].sets, 5);
      expect(after1[0].restSec, 90);

      // 重排为 3,1,2
      await db.reorderPlanExercises(dayId, [e3, e1, e2]);
      final after2 = await db.dayExercises(dayId);
      expect(after2.map((e) => e.name).toList(), ['动作3', '改名', '动作2']);
      expect(after2[0].orderIdx, 0);

      await db.deletePlanExercise(e2);
      final after3 = await db.dayExercises(dayId);
      expect(after3.length, 2);
    });

    test('删除训练日级联删除其动作', () async {
      final p = await makePlan('P');
      final dayId = await addDay(p.id!, 1, '日');
      await addExercise(dayId, '卧推');
      await db.deletePlanDay(dayId);
      // 级联删除后该日无动作
      expect(await db.dayExercises(dayId), isEmpty);
    });
  });

  group('lastWorkingSets 按 session 分组（回归）', () {
    test('返回最近一次训练的全部正式组，而非毫秒相等的最后一组', () async {
      final p = await makePlan('P');
      final dayId = await addDay(p.id!, 1, '推力日');
      assert(dayId > 0);

      // 训练 1：卧推 3 组
      final s1 = await db.insertSession(Session(
          date: '2026-09-01',
          planDayTitle: 't1',
          startedAt: 1000,
          endedAt: 2000,
          status: 'done'));
      final se1 = await db.insertSessionExercise(SessionExercise(
          sessionId: s1.id!,
          name: '卧推',
          orderIdx: 0,
          kind: 'compound',
          rule: const ProgressionRule(repsMin: 5, repsMax: 8)));
      await db.insertSet(SetEntry(
          sessionExerciseId: se1,
          weightKg: 60,
          reps: 8,
          kind: 'working',
          doneAt: 1100));
      await db.insertSet(SetEntry(
          sessionExerciseId: se1,
          weightKg: 60,
          reps: 7,
          kind: 'working',
          doneAt: 1200));
      await db.insertSet(SetEntry(
          sessionExerciseId: se1,
          weightKg: 60,
          reps: 6,
          kind: 'working',
          doneAt: 1300));

      // 训练 2：卧推 1 组（更晚）
      final s2 = await db.insertSession(Session(
          date: '2026-09-08',
          planDayTitle: 't2',
          startedAt: 5000,
          endedAt: 6000,
          status: 'done'));
      final se2 = await db.insertSessionExercise(SessionExercise(
          sessionId: s2.id!,
          name: '卧推',
          orderIdx: 0,
          kind: 'compound',
          rule: const ProgressionRule(repsMin: 5, repsMax: 8)));
      await db.insertSet(SetEntry(
          sessionExerciseId: se2,
          weightKg: 62.5,
          reps: 8,
          kind: 'working',
          doneAt: 5100));

      // 训练 2 的 active 之前的会话不影响（status=done 才算）
      final last = await db.lastWorkingSets('卧推');
      expect(last.length, 1, reason: '最近一次训练只有 1 组');
      expect(last.first.weightKg, 62.5);

      // 历史最大重量（PR 用）
      expect(await db.maxWeightOf('卧推'), 62.5);
    });
  });

  group('身体数据部分更新', () {
    test('同日二次录入只覆盖填写的字段', () async {
      await db.upsertBodyMetric(
        const BodyMetric(date: '2026-09-23', weightKg: 80, waistCm: 85),
      );
      await db.upsertBodyMetric(
        const BodyMetric(date: '2026-09-23', waistCm: 84),
      );

      final rows = await db.bodyMetrics();
      expect(rows.length, 1, reason: '同日期只有一行');
      expect(rows.first.weightKg, 80, reason: '体重不被清空');
      expect(rows.first.waistCm, 84);
      expect(rows.first.bodyFatPct, isNull);
    });

    test('bodyMetricOn 按日期查询：有则返回、无则 null', () async {
      await db.upsertBodyMetric(
          const BodyMetric(date: '2026-10-16', weightKg: 78));
      final hit = await db.bodyMetricOn('2026-10-16');
      expect(hit?.weightKg, 78);
      expect(await db.bodyMetricOn('2026-10-17'), isNull);
    });
  });

  group('记录形态与负荷类型（v14）', () {
    test('logging/load_type 保存与读回；老数据缺键回落默认', () async {
      final p = await makePlan('P');
      final dayId = await addDay(p.id!, 1, '日');
      await db.insertPlanExercise(PlanExercise(
        dayId: dayId,
        name: '平板支撑',
        orderIdx: 0,
        sets: 3,
        repsMin: 30,
        repsMax: 45,
        restSec: 60,
        kind: 'assistance',
        rule: const ProgressionRule(repsMin: 30, repsMax: 45),
        logging: LoggingMode.time,
        loadType: LoadMode.bodyweight,
      ));
      await db.insertPlanExercise(PlanExercise(
        dayId: dayId,
        name: '卧推',
        orderIdx: 1,
        sets: 3,
        repsMin: 5,
        repsMax: 8,
        restSec: 180,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8),
      ));

      final exs = await db.dayExercises(dayId);
      expect(exs[0].logging, LoggingMode.time);
      expect(exs[0].loadType, LoadMode.bodyweight);
      expect(exs[1].logging, LoggingMode.reps, reason: '未指定时落默认按次数');
      expect(exs[1].loadType, LoadMode.weighted, reason: '未指定时落默认负重');

      // 编辑改形态：copyWith 更新后再读回
      await db.updatePlanExercise(
          exs[0].copyWith(logging: LoggingMode.repsPerSide));
      final after = await db.dayExercises(dayId);
      expect(after[0].logging, LoggingMode.repsPerSide);
      expect(after[0].loadType, LoadMode.bodyweight,
          reason: '未改的负荷类型保持原值');
    });
  });
}
