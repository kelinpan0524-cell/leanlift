// 批次2 修复回归：计划域（A2-5 模板「第 N 练」序号 / A2-4 模板查重带来源校验 /
// A3-1 saveAiPlan 不全量覆盖用户动作标注）。
// 基建同批次1 session_controller_test：ffi 真库 + Db.forTesting + wipeAll。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/models/models.dart';
import 'package:baoji_timer/presets/exercise_library.dart';
import 'package:baoji_timer/services/ai_service.dart';
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
  late SharedPreferences prefs;
  late PlanRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // 微秒时间戳唯一路径 = 每个测试独立数据库（ffi 对同路径会复用连接）
    final dir = await databaseFactory.getDatabasesPath();
    final path =
        '$dir/test_plan_${DateTime.now().microsecondsSinceEpoch}.db';
    final rawDb = await databaseFactory.openDatabase(path);
    await Db.instance.createSchema(rawDb);
    db = Db.forTesting(rawDb);
    repo = PlanRepository(db, Settings(prefs));
  });

  tearDown(() async {
    await db.wipeAll();
  });

  test('A2-5：非连练模板安装后「第 N 练」按模板内序号递增，不再等于星期数', () async {
    final (plan, created) = await repo.installTemplate(kHomeTemplate);
    expect(created, isTrue);
    final days = await db.planDays(plan.id!);
    expect(days.length, 3, reason: '居家哑铃全身为 1/3/5 三练');
    final titleByWeekday = {for (final d in days) d.weekday: d.title};
    // 全 App 星期格式为汉字「周一」（wd='一二三四五六日'，plan_page 同款），
    // ask 断言里的「周1」是笔误——核心断言是序号按模板内递增、不等于星期数
    expect(titleByWeekday[1], '周一 · 第 1 练');
    expect(titleByWeekday[3], '周三 · 第 2 练', reason: '第 2 练，不再是「第 3 练」');
    expect(titleByWeekday[5], '周五 · 第 3 练', reason: '第 3 练，不再是「第 5 练」');
  });

  test('A2-4：用户自建同名计划不拦截模板安装；重复安装同模板不重复建', () async {
    // 用户先自建了一个恰好同名的空白计划（source='manual'，7 个空训练日）
    final manual = await db.insertPlan(Plan(
        name: kHomeTemplate.name,
        source: 'manual',
        createdAt: '2026-09-24'));
    for (var wd = 1; wd <= 7; wd++) {
      await db.insertPlanDay(
          PlanDay(planId: manual.id!, weekday: wd, title: '训练日'));
    }

    // 装同名模板：不被 manual 同名计划误判为已安装，模板内容真实写入
    final (plan, created) = await repo.installTemplate(kHomeTemplate);
    expect(created, isTrue, reason: 'manual 同名计划不算已安装');
    expect(plan.source, 'preset');

    final active = await db.activePlan();
    expect(active, isNotNull);
    expect(active!.id, plan.id, reason: '模板计划成为使用中');
    expect(active.source, 'preset');

    final days = await db.planDays(plan.id!);
    expect(days.length, 3);
    final exMap = await db.daysExercisesMap(days.map((d) => d.id!).toList());
    final total = exMap.values.fold<int>(0, (n, list) => n + list.length);
    expect(total, 15, reason: '3 练 × 5 动作真实写入，不是空计划被直接启用');

    // 再装一次同模板：命中同名同源 preset → 不重复建
    final (same, createdAgain) = await repo.installTemplate(kHomeTemplate);
    expect(createdAgain, isFalse);
    expect(same.id, plan.id);
    final sameNameCount =
        (await db.allPlans()).where((p) => p.name == kHomeTemplate.name).length;
    expect(sameNameCount, 2, reason: 'manual 那份仍在，模板本身只有一份');
  });

  test('A3-1：saveAiPlan 不再把内置词表全量 REPLACE，覆盖用户改过的标注', () async {
    // 用户在编辑器里把「杠铃卧推」的主肌群改成了「肩」（词表内动作默认是「胸」）
    await db.upsertExerciseMeta(
        const ExerciseMeta('杠铃卧推', MuscleGroups(main: '肩'), true, 'gym'));

    final ai = AiService(Settings(prefs));
    await repo.saveAiPlan(
      name: 'AI 计划',
      specs: const [
        AiDaySpec(1, '推日', [
          AiExerciseSpec(
              name: '杠铃卧推',
              sets: 3,
              repsMin: 5,
              repsMax: 8,
              kind: 'compound'),
        ]),
      ],
      metaMap: ai.metaMap(),
    );

    final meta = await db.exerciseMeta('杠铃卧推');
    expect(meta, isNotNull);
    expect(meta!.muscles.main, '肩',
        reason: '修复前：saveAiPlan 尾部全量落库会把标注静默重置回内置默认「胸」');
  });

  test('v9：AI 超级组链落库为同 tag 相邻行（配对/三连/悬挂不落）', () async {
    final specs = [
      AiDaySpec(1, '超级组日', [
        AiExerciseSpec(name: '杠铃卧推', sets: 3, repsMin: 5, repsMax: 8,
            startsSuperset: true),
        AiExerciseSpec(name: '杠铃划船', sets: 3, repsMin: 5, repsMax: 8),
        AiExerciseSpec(name: '杠铃弯举', sets: 3, repsMin: 8, repsMax: 12,
            startsSuperset: true),
        AiExerciseSpec(name: '哑铃颈后臂屈伸', sets: 3, repsMin: 8, repsMax: 12),
        AiExerciseSpec(name: '卷腹', sets: 3, repsMin: 8, repsMax: 12,
            startsSuperset: true), // 悬挂：无下一个，不落标记
      ]),
    ];
    final plan = await repo.saveAiPlan(
        name: '超级组计划', specs: specs, metaMap: const {});
    final days = await db.planDays(plan.id!);
    final exs = await db.dayExercises(days.first.id!);
    expect(exs.length, 5);
    // 卧推+划船 一组；弯举+臂屈伸 一组（悬挂的卷腹不带 tag）
    expect(exs[0].supersetTag, isNotEmpty);
    expect(exs[1].supersetTag, exs[0].supersetTag);
    expect(exs[2].supersetTag, isNotEmpty);
    expect(exs[3].supersetTag, exs[2].supersetTag);
    expect(exs[2].supersetTag, isNot(exs[0].supersetTag), reason: '两组标记不同');
    expect(exs[4].supersetTag, '', reason: '末位悬挂标记不落库');
  });

  test('v15：duplicatePlan 复制动作保留 exerciseKey', () async {
    final plan = await db.insertPlan(Plan(
        name: '原计划', source: 'manual', createdAt: '2026-10-17', isActive: 1));
    final dayId = await db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 1, title: '推日'));
    await db.insertPlanExercise(PlanExercise(
      dayId: dayId,
      name: '杠铃卧推',
      orderIdx: 0,
      sets: 3,
      repsMin: 5,
      repsMax: 8,
      restSec: 120,
      kind: 'compound',
      rule: ProgressionRule.fallback,
      exerciseKey: 'barbell_bench_press',
    ));

    final newId = await repo.duplicatePlan(plan.id!, '原计划副本');
    final newDays = await db.planDays(newId);
    expect(newDays.length, 1);
    final copied = await db.dayExercises(newDays.single.id!);
    expect(copied.single.exerciseKey, 'barbell_bench_press',
        reason: 'v15：副本保留源动作稳定键');
    // 源计划行不受影响
    expect((await db.dayExercises(dayId)).single.exerciseKey,
        'barbell_bench_press');
  });

  test('refreshRecommendations 用计划行自带的 key 查历史', () async {
    // 历史挂在旧键 bench_key 上；计划行显示名已改成哑铃飞鸟，但键仍是
    // bench_key——推荐必须沿这个键找到 3×8 的历史并推进 2.5kg。
    final s = await db.insertSession(Session(
      date: '2026-10-18',
      planDayTitle: '旧训练',
      startedAt: 1000,
      endedAt: 2000,
      status: 'done',
    ));
    final seId = await db.insertSessionExercise(SessionExercise(
      sessionId: s.id!,
      name: '杠铃卧推',
      orderIdx: 0,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      exerciseKey: 'bench_key',
    ));
    for (var i = 0; i < 3; i++) {
      await db.insertSet(SetEntry(
        sessionExerciseId: seId,
        weightKg: 60,
        reps: 8,
        kind: SetKind.working,
        doneAt: 1100 + i,
      ));
    }

    const rule = ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3);
    await repo.refreshRecommendations([
      const PlanExercise(
        dayId: 0,
        name: '哑铃飞鸟',
        orderIdx: 0,
        sets: 3,
        repsMin: 5,
        repsMax: 8,
        restSec: 120,
        kind: 'compound',
        rule: rule,
        exerciseKey: 'bench_key',
      ),
    ]);
    expect(repo.recommendedWeight('哑铃飞鸟'), 62.5,
        reason: '按稳定键查到旧历史，3×8 达标推进 2.5kg');
  });

  test('无历史时按动作库启发式给起始重量（P2-A）', () {
    expect(repo.recommendedWeight('哑铃弯举'), 6, reason: '哑铃单关节');
    expect(repo.recommendedWeight('俯卧撑'), 0, reason: '自重不猜重量');
    expect(repo.recommendedWeight('词表外动作'), 20, reason: '词表外保持旧兜底');
  });
}
