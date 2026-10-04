// 错过训练日自动顺延（2026-10-04 Arono：「今天没练，计划自动顺延一日」）：
// 排了训练却整天没有会话的日子，每错一个训练日 shift 一天（链式）；
// 今天永不参与、显式休息墓碑/空模板日不算错过、done/quit 会话都算练过。
// 检查点（AutoShiftService）：首次见某计划从今天起算不追历史、换激活计划
// 重置、关开关不推进检查点。基建同 shift_schedule_test：ffi 真库。
// 固定日期锚点：2026-09-28 周一、09-29 周二、09-30 周三、10-04 周日、
// 10-05 周一、10-06 周二。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/models/models.dart';
import 'package:baoji_timer/services/auto_shift.dart';
import 'package:baoji_timer/services/plan_repository.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Db db;
  late PlanRepository repo;
  late SharedPreferences prefs;
  late AutoShiftService svc;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final dir = await databaseFactory.getDatabasesPath();
    final path =
        '$dir/test_autoshift_${DateTime.now().microsecondsSinceEpoch}.db';
    final rawDb = await databaseFactory.openDatabase(path);
    await Db.instance.createSchema(rawDb);
    db = Db.forTesting(rawDb);
    repo = PlanRepository(db, Settings(prefs));
    svc = AutoShiftService(repo, prefs);
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

  Future<Plan> refetch(Plan p) async =>
      (await db.allPlans()).where((x) => x.id == p.id).first;

  Future<String?> titleOn(Plan plan, String date) async =>
      (await repo.dayForDateOn(plan, d(date)))?.title;

  Future<void> trainOn(String date, {String status = 'done'}) async =>
      db.insertSession(Session(
        date: date,
        planDayTitle: '测试日',
        startedAt: 0,
        status: status,
      ));

  group('autoShiftMissedDays 扫描（repo 层）', () {
    test('周一没练：顺延一天，推日挪周二、拉日挪周四', () async {
      final plan = await buildWeeklyPlan();
      final missed = await repo
          .autoShiftMissedDays(plan, d('2026-09-27'), d('2026-09-29'));
      expect(missed, [d('2026-09-28')]);
      final fresh = await refetch(plan);
      expect(fresh.shiftDays, 1);
      expect(fresh.shiftFrom, '2026-09-28');
      expect(await titleOn(fresh, '2026-09-28'), null); // 墓碑：显式休息
      expect(await titleOn(fresh, '2026-09-29'), '推日');
      expect(await titleOn(fresh, '2026-09-30'), null); // 周三推到周四
      expect(await titleOn(fresh, '2026-10-01'), '拉日');
    });

    test('练过（done 会话）：不顺延', () async {
      final plan = await buildWeeklyPlan();
      await trainOn('2026-09-28');
      final missed = await repo
          .autoShiftMissedDays(plan, d('2026-09-27'), d('2026-09-29'));
      expect(missed, isEmpty);
      expect((await refetch(plan)).shiftDays, 0);
    });

    test('quit 会话也算练过：不顺延', () async {
      final plan = await buildWeeklyPlan();
      await trainOn('2026-09-28', status: 'quit');
      final missed = await repo
          .autoShiftMissedDays(plan, d('2026-09-27'), d('2026-09-29'));
      expect(missed, isEmpty);
    });

    test('连续错过链式顺延：周一+周二都没练 → 顺延两天', () async {
      final plan = await buildWeeklyPlan();
      final missed = await repo
          .autoShiftMissedDays(plan, d('2026-09-27'), d('2026-09-30'));
      expect(missed, [d('2026-09-28'), d('2026-09-29')]);
      final fresh = await refetch(plan);
      expect(fresh.shiftDays, 2);
      // 顺延 2 天后整条节奏后移：周三(09-30)推周一槽位→推日，
      // 周四(10-01)推周二槽位→休息，周五(10-02)推周三槽位→拉日
      expect(await titleOn(fresh, '2026-09-30'), '推日');
      expect(await titleOn(fresh, '2026-10-01'), null);
      expect(await titleOn(fresh, '2026-10-02'), '拉日');
    });

    test('显式休息墓碑（手动钉死休息）不触发顺延', () async {
      final plan = await buildWeeklyPlan();
      await repo.setOverride(plan, d('2026-09-28'), null);
      final missed = await repo
          .autoShiftMissedDays(plan, d('2026-09-27'), d('2026-09-29'));
      expect(missed, isEmpty);
      expect((await refetch(plan)).shiftDays, 0);
    });

    test('今天永不参与（还没过完）', () async {
      final plan = await buildWeeklyPlan();
      final missed = await repo
          .autoShiftMissedDays(plan, d('2026-09-27'), d('2026-09-28'));
      expect(missed, isEmpty);
      expect((await refetch(plan)).shiftDays, 0);
    });

    test('空模板日（无动作）不算错过', () async {
      final plan = await db.insertPlan(Plan(
        name: '空日计划',
        source: 'manual',
        createdAt: '2026-09-25',
      ));
      await db.insertPlanDay(
          PlanDay(planId: plan.id!, weekday: 1, title: '空壳日'));
      final missed = await repo
          .autoShiftMissedDays(plan, d('2026-09-27'), d('2026-09-29'));
      expect(missed, isEmpty);
      expect((await refetch(plan)).shiftDays, 0);
    });
  });

  group('AutoShiftService 检查点（服务层）', () {
    setUp(() async {
      final plan = await buildWeeklyPlan();
      await db.setActivePlan(plan.id!);
      await repo.reload();
    });

    test('首次运行不追历史；次日起开始盯', () async {
      // 周日(10-04)首次打开：即使之前有错过也不补
      expect(await svc.run(enabled: true, now: d('2026-10-04')), isEmpty);
      // 周二(10-06)再打开：扫周一(10-05) → 顺延一天
      final missed = await svc.run(enabled: true, now: d('2026-10-06'));
      expect(missed, [d('2026-10-05')]);
      final fresh = repo.activePlan!;
      expect(fresh.shiftDays, 1);
      expect(await titleOn(fresh, '2026-10-06'), '推日');
    });

    test('同一天重复运行不重复顺延', () async {
      await svc.run(enabled: true, now: d('2026-10-04'));
      expect(await svc.run(enabled: true, now: d('2026-10-06')), isNotEmpty);
      expect(await svc.run(enabled: true, now: d('2026-10-06')), isEmpty);
      expect(repo.activePlan!.shiftDays, 1);
    });

    test('关闭开关：不扫不推进；重开后续扫错过窗口', () async {
      await svc.run(enabled: true, now: d('2026-10-04'));
      await svc.run(enabled: false, now: d('2026-10-06')); // 周一错过但不扫
      expect(repo.activePlan!.shiftDays, 0);
      final missed = await svc.run(enabled: true, now: d('2026-10-07'));
      expect(missed, [d('2026-10-05'), d('2026-10-06')]);
      expect(repo.activePlan!.shiftDays, 2);
    });

    test('换激活计划：从当天起算，不追旧账', () async {
      await svc.run(enabled: true, now: d('2026-10-04'));
      // 新建并切换到计划 B（周一/周三模板，创建于过去）
      final planB = await buildWeeklyPlan();
      await db.renamePlan(planB.id!, '周计划B');
      await db.setActivePlan(planB.id!);
      await repo.reload();
      // 周二打开：B 虽然周一(10-05)该练没练，但刚切换 → 从今天起算
      expect(await svc.run(enabled: true, now: d('2026-10-06')), isEmpty);
      expect(repo.activePlan!.shiftDays, 0);
      // 周三再打开：盯到了周二…周二本就不是 B 的训练日 → 仍无顺延；
      // 周四打开才补扫周三
      expect(await svc.run(enabled: true, now: d('2026-10-07')), isEmpty);
      final missed = await svc.run(enabled: true, now: d('2026-10-08'));
      expect(missed, [d('2026-10-07')]);
      expect(repo.activePlan!.shiftDays, 1);
    });
  });
}
