// 全计划顺延一天（2026-09-29 Arono：「今天休息，之后所有训练推一天」）：
// 这天落显式休息墓碑，shiftFrom 起的规则推导整体回退 shiftDays 天——
// 明天排今天的内容、依此类推，weekly / cycle 通用；覆盖行（手动改期）不动。
// 基建同 cycle_schedule_test：ffi 真库。
// 固定日期锚点：2026-09-28 是周一、09-30 周三、10-05 下周一。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/models/models.dart';
import 'package:baoji_timer/services/plan_repository.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
  });

  late Db db;
  late PlanRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = await databaseFactory.getDatabasesPath();
    final path =
        '$dir/test_shift_${DateTime.now().microsecondsSinceEpoch}.db';
    final rawDb = await databaseFactory.openDatabase(path);
    await Db.instance.createSchema(rawDb);
    db = Db.forTesting(rawDb);
    repo = PlanRepository(db, Settings(prefs));
  });

  tearDown(() async {
    await db.wipeAll();
  });

  DateTime d(String s) => DateTime.parse(s);

  /// weekly 计划：周一=推日、周三=拉日（各 1 个动作）。
  Future<Plan> buildWeeklyPlan() async {
    final plan = await db.insertPlan(Plan(
      name: '周计划',
      source: 'manual',
      createdAt: '2026-09-25',
    ));
    for (final (wd, title) in [(1, '推日'), (3, '拉日')]) {
      final dayId = await db.insertPlanDay(
          PlanDay(planId: plan.id!, weekday: wd, title: title));
      await db.insertPlanExercise(PlanExercise(
        dayId: dayId,
        name: '动作$wd',
        orderIdx: 0,
        sets: 3,
        repsMin: 5,
        repsMax: 8,
        restSec: 120,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8),
      ));
    }
    return plan;
  }

  /// cycle 计划：练2休1，锚点 2026-09-28（周一），模板 [胸, 腿]。
  Future<Plan> buildCyclePlan() async {
    final plan = await db.insertPlan(Plan(
      name: '循环计划',
      source: 'manual',
      createdAt: '2026-09-25',
      pattern: 'cycle',
      patternStart: '2026-09-28',
      cycleTrain: 2,
      cycleRest: 1,
    ));
    for (final (i, title) in [(1, '胸'), (2, '腿')]) {
      final dayId = await db.insertPlanDay(
          PlanDay(planId: plan.id!, weekday: i, title: title));
      await db.insertPlanExercise(PlanExercise(
        dayId: dayId,
        name: '动作$i',
        orderIdx: 0,
        sets: 3,
        repsMin: 5,
        repsMax: 8,
        restSec: 120,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8),
      ));
    }
    return plan;
  }

  Future<String?> titleOn(Plan plan, String date) async =>
      (await repo.dayForDateOn(plan, d(date)))?.title;

  /// 顺延写的是库里最新行；推导读的是传入对象——测试里每次顺延后
  /// 重取（真实 App 走 repo.reload() 刷新，等价）。
  Future<Plan> refetch(Plan p) async =>
      (await db.allPlans()).where((x) => x.id == p.id).first;

  group('effectiveScheduleDate 纯函数', () {
    test('未顺延 / 起点前：原样返回', () {
      const base = Plan(name: 'p', source: 'manual', createdAt: '2026-01-01');
      expect(base.effectiveScheduleDate(d('2026-09-28')), d('2026-09-28'));

      const shifted = Plan(
          name: 'p',
          source: 'manual',
          createdAt: '2026-01-01',
          shiftDays: 2,
          shiftFrom: '2026-09-30');
      // 09-29 在起点 09-30 之前：不动
      expect(shifted.effectiveScheduleDate(d('2026-09-29')), d('2026-09-29'));
      // 起点当天（含）：回退
      expect(shifted.effectiveScheduleDate(d('2026-09-30')), d('2026-09-28'));
      expect(shifted.effectiveScheduleDate(d('2026-10-05')), d('2026-10-03'));
    });
  });

  group('weekly 顺延', () {
    test('周一顺延：当天休息，推日挪到周二、拉日到周四，长期有效', () async {
      var plan = await buildWeeklyPlan();
      expect(await titleOn(plan, '2026-09-28'), '推日'); // 周一
      expect(await titleOn(plan, '2026-09-29'), null); // 周二
      expect(await titleOn(plan, '2026-09-30'), '拉日'); // 周三

      final snap = await repo.shiftScheduleOneDay(plan, d('2026-09-28'));
      expect(snap, (0, '', false, null), reason: '撤销快照=未顺延且无覆盖行');
      plan = await refetch(plan);

      expect(await titleOn(plan, '2026-09-28'), null, reason: '当天显式休息');
      expect(await titleOn(plan, '2026-09-29'), '推日', reason: '明天排今天的内容');
      expect(await titleOn(plan, '2026-09-30'), null, reason: '原周三空出来');
      expect(await titleOn(plan, '2026-10-01'), '拉日', reason: '拉日推到周四');
      expect(await titleOn(plan, '2026-10-05'), null, reason: '下周一也顺延（长期）');
      expect(await titleOn(plan, '2026-10-06'), '推日');

      final fresh =
          (await db.allPlans()).where((p) => p.id == plan.id).first;
      expect(fresh.shiftDays, 1);
      expect(fresh.shiftFrom, '2026-09-28');
    });

    test('shiftFrom 之前的日期不受影响', () async {
      var plan = await buildWeeklyPlan();
      // 从周三（09-30）顺延
      await repo.shiftScheduleOneDay(plan, d('2026-09-30'));
      plan = await refetch(plan);
      expect(await titleOn(plan, '2026-09-28'), '推日', reason: '起点前维持原推导');
      expect(await titleOn(plan, '2026-09-29'), null);
      expect(await titleOn(plan, '2026-09-30'), null, reason: '当天休息');
      expect(await titleOn(plan, '2026-10-01'), '拉日', reason: '拉日推到周四');
    });

    test('手动改期（覆盖行）不受顺延影响', () async {
      var plan = await buildWeeklyPlan();
      final pull = (await db.planDays(plan.id!)).firstWhere((x) => x.weekday == 3);
      // 用户手动把拉日钉在周五（10-02）
      await repo.setOverride(plan, d('2026-10-02'), pull.id);
      await repo.shiftScheduleOneDay(plan, d('2026-09-28'));
      plan = await refetch(plan);
      expect(await titleOn(plan, '2026-10-02'), '拉日',
          reason: '覆盖行按真实日期命中，顺延不动它');
    });
  });

  group('cycle 顺延', () {
    test('练2休1 周一顺延：序列整体后移一天', () async {
      var plan = await buildCyclePlan();
      // 原序列：周一胸 周二腿 周三休 周四胸 周五腿
      expect(await titleOn(plan, '2026-09-28'), '胸');
      expect(await titleOn(plan, '2026-09-29'), '腿');
      expect(await titleOn(plan, '2026-09-30'), null);
      expect(await titleOn(plan, '2026-10-01'), '胸');

      await repo.shiftScheduleOneDay(plan, d('2026-09-28'));
      plan = await refetch(plan);

      expect(await titleOn(plan, '2026-09-28'), null, reason: '当天休息');
      expect(await titleOn(plan, '2026-09-29'), '胸');
      expect(await titleOn(plan, '2026-09-30'), '腿');
      expect(await titleOn(plan, '2026-10-01'), null, reason: '休息也跟着推');
      expect(await titleOn(plan, '2026-10-02'), '胸');
    });

    test('叠加顺延：连点两天，shiftFrom 保留最早', () async {
      var plan = await buildCyclePlan();
      await repo.shiftScheduleOneDay(plan, d('2026-09-28'));
      // 第二天再顺延（用旧 plan 对象调，验证内部重读最新行）
      await repo.shiftScheduleOneDay(plan, d('2026-09-29'));
      plan = await refetch(plan);

      final fresh = (await db.allPlans()).where((p) => p.id == plan.id).first;
      expect(fresh.shiftDays, 2);
      expect(fresh.shiftFrom, '2026-09-28', reason: '保留最早起点');

      // 10-01 回退 2 天 = 09-29 → 腿；10-02 回退 2 天 = 09-30 → 休
      expect(await titleOn(plan, '2026-10-01'), '腿');
      expect(await titleOn(plan, '2026-10-02'), null);
    });
  });

  group('撤销', () {
    test('撤销无覆盖行的顺延：推导与墓碑都还原', () async {
      var plan = await buildWeeklyPlan();
      final snap = await repo.shiftScheduleOneDay(plan, d('2026-09-28'));
      plan = await refetch(plan);
      expect(await titleOn(plan, '2026-09-29'), '推日');

      await repo.undoShiftScheduleOneDay(plan, d('2026-09-28'), snap);
      plan = await refetch(plan);

      expect(await titleOn(plan, '2026-09-28'), '推日', reason: '墓碑已删');
      expect(await titleOn(plan, '2026-09-29'), null, reason: '推导回到原样');
      final fresh = (await db.allPlans()).where((p) => p.id == plan.id).first;
      expect(fresh.shiftDays, 0);
      expect(fresh.shiftFrom, '');
    });

    test('撤销原有手动训练覆盖的顺延：覆盖行原样写回', () async {
      var plan = await buildWeeklyPlan();
      final pull = (await db.planDays(plan.id!)).firstWhere((x) => x.weekday == 3);
      // 周一原本被手动钉成拉日，再顺延
      await repo.setOverride(plan, d('2026-09-28'), pull.id);
      final snap = await repo.shiftScheduleOneDay(plan, d('2026-09-28'));
      plan = await refetch(plan);
      expect(await titleOn(plan, '2026-09-28'), null, reason: '顺延盖成休息');

      await repo.undoShiftScheduleOneDay(plan, d('2026-09-28'), snap);
      expect(await titleOn(plan, '2026-09-28'), '拉日', reason: '手动覆盖还原');
    });
  });

  group('复制计划带顺延状态', () {
    test('duplicatePlan 复制 shiftDays/shiftFrom', () async {
      var plan = await buildWeeklyPlan();
      await repo.shiftScheduleOneDay(plan, d('2026-09-28'));
      final newId = await repo.duplicatePlan(plan.id!, '副本');
      final copy = (await db.allPlans()).where((p) => p.id == newId).first;
      expect(copy.shiftDays, 1);
      expect(copy.shiftFrom, '2026-09-28');
    });
  });
}
