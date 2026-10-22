// AI 教练上下文增强：「当前计划与日程」段（buildPlanContextSection 纯函数 +
// buildAiData(planRepo:) 集成）。集成部分基建同 plan_repository_test.dart：
// ffi 真库 + Settings(prefs) + PlanRepository(db, settings)。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/services/export_service.dart';
import 'package:baoji_timer/services/plan_repository.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _wd = '一二三四五六日';

String _weekdayCn(DateTime d) => _wd[d.weekday - 1];

PlanExercise _ex(int dayId, String name, int orderIdx) => PlanExercise(
      dayId: dayId,
      name: name,
      orderIdx: orderIdx,
      sets: 4,
      repsMin: 6,
      repsMax: 8,
      restSec: 180,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 6, repsMax: 8, workingSets: 4),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildPlanContextSection（纯函数，无 DB）', () {
    test('① 训练日今天：日期+周几+标题+动作行', () {
      final s = PlanContextSnapshot(
        today: '2026-09-26',
        planName: '薄肌计划',
        scheduleDesc: '按星期（周六=推日）',
        todayDay: PlanDayLine(
          date: '2026-09-26',
          title: '推日',
          exCount: 2,
          exLines: ['杠铃卧推 4×6-8', '上斜哑铃卧推 3×8-12'],
        ),
        tomorrowDay: null,
        next7: const [],
        activeSessionNote: null,
      );
      final out = buildPlanContextSection(s);
      // 2026-09-26 实为周六（date -j 验证）
      expect(out, contains('今天 2026-09-26（周六）：推日'));
      expect(out, contains('- 杠铃卧推 4×6-8'));
      expect(out, contains('- 上斜哑铃卧推 3×8-12'));
      expect(out, contains('动作清单（组×次）'));
    });

    test('② 休息日今天：「今天是休息日」且省略动作清单块', () {
      final s = PlanContextSnapshot(
        today: '2026-09-26',
        planName: '薄肌计划',
        scheduleDesc: '按星期（周日=推日）',
        todayDay: const PlanDayLine(date: '2026-09-26', title: ''),
        tomorrowDay: null,
        next7: const [],
        activeSessionNote: null,
      );
      final out = buildPlanContextSection(s);
      expect(out, contains('今天是休息日（按计划无训练安排）'));
      expect(out.contains('动作清单'), isFalse);
    });

    test('③ 明天行与 7 天概览：行数=7、休息日行正确渲染', () {
      final s = PlanContextSnapshot(
        today: '2026-09-26',
        planName: '薄肌计划',
        scheduleDesc: '',
        todayDay: const PlanDayLine(date: '2026-09-26', title: ''),
        tomorrowDay: const PlanDayLine(date: '2026-09-27', title: '拉日', exCount: 6),
        next7: [
          const PlanDayLine(date: '2026-09-26', title: ''),
          const PlanDayLine(date: '2026-09-27', title: '拉日', exCount: 6),
          const PlanDayLine(date: '2026-09-28', title: ''),
          const PlanDayLine(date: '2026-09-29', title: ''),
          const PlanDayLine(date: '2026-09-30', title: ''),
          const PlanDayLine(date: '2026-10-01', title: ''),
          const PlanDayLine(date: '2026-10-02', title: ''),
        ],
        activeSessionNote: null,
      );
      final out = buildPlanContextSection(s);
      // 2026-09-27 实为周日、2026-10-01 实为周四（date -j 验证）
      expect(out, contains('明天 2026-09-27（周日）：拉日（6 个动作）'));
      expect(out, contains('未来 7 天日程'));
      expect(RegExp(r'^  - \d{4}-\d{2}-\d{2}', multiLine: true)
          .allMatches(out)
          .length, 7);
      expect(out, contains('2026-09-28 周一：休息日'));
      expect(out, contains('2026-10-01 周四：休息日'));
    });

    test('④ 有进行中会话注记：含「进行中」与标题', () {
      final s = PlanContextSnapshot(
        today: '2026-09-26',
        planName: '薄肌计划',
        scheduleDesc: '',
        todayDay: null,
        tomorrowDay: null,
        next7: const [],
        activeSessionNote: '拉日（2026-09-26 19:02 开始，尚未结束）',
      );
      final out = buildPlanContextSection(s);
      expect(out, contains('进行中的训练会话'));
      expect(out, contains('「拉日（2026-09-26 19:02 开始，尚未结束）」'));
    });

    test('⑤ 无计划：含「无」且不含日程行', () {
      final out = buildPlanContextSection(const PlanContextSnapshot(
        today: '2026-09-26',
        planName: '',
        scheduleDesc: '',
        todayDay: null,
        tomorrowDay: null,
        next7: [],
        activeSessionNote: null,
      ));
      expect(out, contains('使用中计划：无（未启用任何训练计划）'));
      expect(out.contains('未来 7 天日程'), isFalse);
      expect(out.contains('排程方式'), isFalse);
    });

    test('⑥ 排程方式两种文案：按星期 / 练2休1+起始日', () {
      final weekly = buildPlanContextSection(PlanContextSnapshot(
        today: '2026-09-26',
        planName: '薄肌计划',
        scheduleDesc: '按星期（周一=推日；周三=拉日；周五=腿日）',
        todayDay: null,
        tomorrowDay: null,
        next7: const [],
        activeSessionNote: null,
      ));
      expect(weekly, contains('排程方式：按星期（周一=推日；周三=拉日；周五=腿日）'));

      final cycle = buildPlanContextSection(PlanContextSnapshot(
        today: '2026-09-26',
        planName: '薄肌计划',
        scheduleDesc: '循环 练2休1，起始日 2026-09-01（周二）',
        todayDay: null,
        tomorrowDay: null,
        next7: const [],
        activeSessionNote: null,
      ));
      expect(cycle, contains('循环 练2休1，起始日 2026-09-01（周二）'));
    });
  });

  group('buildAiData(planRepo:) 集成（ffi 真库）', () {
    setUpAll(() {
      sqfliteFfiInit();
    });

    late Db db;
    late SharedPreferences prefs;
    late PlanRepository repo;
    late DateTime today;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      // 微秒时间戳唯一路径 = 每个测试独立数据库（ffi 对同路径会复用连接）
      final dir = await databaseFactory.getDatabasesPath();
      final path =
          '$dir/test_plan_ctx_${DateTime.now().microsecondsSinceEpoch}.db';
      final rawDb = await databaseFactory.openDatabase(path);
      await Db.instance.createSchema(rawDb);
      db = Db.forTesting(rawDb);
      repo = PlanRepository(db, Settings(prefs));
      final now = DateTime.now();
      today = DateTime(now.year, now.month, now.day);
    });

    tearDown(() async {
      await db.wipeAll();
    });

    /// 建 weekly 计划：今天一个「推日」（杠铃卧推），明天一个「拉日」（无动作）。
    Future<Plan> seedWeeklyPlan() async {
      final plan = await db.insertPlan(Plan(
          name: '测试周计划', source: 'manual', createdAt: '2026-01-01'));
      final pushId = await db.insertPlanDay(PlanDay(
          planId: plan.id!, weekday: today.weekday, title: '推日'));
      await db.insertPlanExercise(_ex(pushId, '杠铃卧推', 0));
      await db.insertPlanExercise(_ex(pushId, '上斜哑铃卧推', 1));
      final pullId = await db.insertPlanDay(PlanDay(
          planId: plan.id!,
          weekday: today.add(const Duration(days: 1)).weekday,
          title: '拉日'));
      await db.insertPlanExercise(_ex(pullId, '引体向上', 0));
      await db.setActivePlan(plan.id!);
      return plan;
    }

    test('① weekly 计划：段头/计划名/今天动作行齐备，且排在「训练概要」之前', () async {
      await seedWeeklyPlan();
      final out = await ExportService(db).buildAiData(planRepo: repo);
      expect(out, contains('## 当前计划与日程'));
      expect(out, contains('使用中计划：测试周计划'));
      expect(out,
          contains('今天 ${fmtDate(today)}（周${_weekdayCn(today)}）：推日'));
      expect(out, contains('- 杠铃卧推 4×6-8'));
      expect(out.indexOf('## 当前计划与日程'), lessThan(out.indexOf('## 训练概要')));
    });

    test('② cycle 计划：排程方式行含「练2休1」与起始日绝对日期', () async {
      final plan = await db.insertPlan(Plan(
          name: '循环计划',
          source: 'manual',
          createdAt: '2026-01-01',
          pattern: 'cycle',
          patternStart: '2026-09-01',
          cycleTrain: 2,
          cycleRest: 1));
      final d1 = await db.insertPlanDay(
          PlanDay(planId: plan.id!, weekday: 1, title: '推日'));
      final d2 = await db.insertPlanDay(
          PlanDay(planId: plan.id!, weekday: 2, title: '拉日'));
      await db.insertPlanExercise(_ex(d1, '杠铃卧推', 0));
      await db.insertPlanExercise(_ex(d2, '引体向上', 0));
      await db.setActivePlan(plan.id!);

      final out = await ExportService(db).buildAiData(planRepo: repo);
      // 2026-09-01 实为周二（date -j 验证）
      expect(out, contains('排程方式：循环 练2休1，起始日 2026-09-01（周二）'));
    });

    test('③ 覆盖行优先：今天显式休息墓碑（dayId=null）→ 今天行是「今天是休息日」', () async {
      final plan = await seedWeeklyPlan();
      await repo.setOverride(plan, today, null);
      final out = await ExportService(db).buildAiData(planRepo: repo);
      expect(out,
          contains('今天 ${fmtDate(today)}（周${_weekdayCn(today)}）：'
              '今天是休息日（按计划无训练安排）'));
      expect(out.contains('今天 ${fmtDate(today)}（周${_weekdayCn(today)}）：推日'),
          isFalse);
    });

    test('④ active 会话：数据包含「进行中的训练会话」与训练日标题', () async {
      await seedWeeklyPlan();
      await db.insertSession(Session(
          date: fmtDate(today),
          planDayTitle: '推日',
          startedAt: DateTime.now().millisecondsSinceEpoch,
          status: 'active'));
      final out = await ExportService(db).buildAiData(planRepo: repo);
      expect(out, contains('进行中的训练会话'));
      expect(out, contains('「推日（'));
      expect(out, contains('开始，尚未结束）'));
    });

    test('⑤ 回归保护：不传 planRepo → 数据包不含「当前计划与日程」段', () async {
      await seedWeeklyPlan();
      final out = await ExportService(db).buildAiData();
      expect(out.contains('当前计划与日程'), isFalse);
      expect(out, contains('## 训练概要'));
    });
  });
}
