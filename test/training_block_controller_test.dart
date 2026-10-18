// P1-C 训练块接线测试：块起点取当前计划第一次 done 训练；减载周把
// 「90% 重量 + 少 1 组」写进会话处方；块长 0 关闭；减载会话不计入
// 下次处方回溯（不把线性加重的档位带低）。
import 'dart:convert';
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
    // 按 void 方法回 [null]（与 session_controller_test.dart 同口径）。
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
        '$dir/test_block_${DateTime.now().microsecondsSinceEpoch}.db';
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

  Future<(PlanDay, List<PlanExercise>)> makePlan({
    int sets = 3,
    String loadType = LoadMode.weighted,
    String logging = LoggingMode.reps,
  }) async {
    final plan = await db.insertPlan(
      Plan(
        name: '块测试计划',
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
      sets: sets,
      repsMin: 5,
      repsMax: 8,
      restSec: 120,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      loadType: loadType,
      logging: logging,
    );
    await db.insertPlanExercise(pe);
    final day = PlanDay(
        id: dayId, planId: plan.id!, weekday: 1, title: '推日');
    return (day, await db.dayExercises(dayId));
  }

  /// 往 [daysAgo] 天前写一场已完成训练（60kg × [reps] × 3）。
  Future<void> addDoneSession(PlanDay day, int daysAgo,
      {int reps = 8,
      int setCount = 3,
      double weight = 60,
      String loadType = LoadMode.weighted,
      String logging = LoggingMode.reps}) async {
    final when = DateTime.now().subtract(Duration(days: daysAgo));
    final date = fmtDate(when);
    // done_at 必须按「场次」拉开：historySets 按 done_at 升序返回，
    // 同一场的组要相邻（plateauOf 按相邻 sessionExerciseId 分组）。
    final base = when.millisecondsSinceEpoch;
    final s = await db.insertSession(Session(
      date: date,
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
      loadType: loadType,
      logging: logging,
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
  }

  SessionController makeController() {
    final c = SessionController(db, Settings(prefs), prefs, null);
    controllers.add(c);
    return c;
  }

  test('块起点 = 当前计划第一次 done 训练：第 5 周自动减载', () async {
    final (day, exs) = await makePlan();
    // 28 天 = 5 周一块的第 5 周；最近一场 1 天前保持在 14 天内，
    // 避免触发 P1-D 停练回归（块起点仍取 MIN=28 天前）。
    await addDoneSession(day, 28);
    await addDoneSession(day, 1);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);

    expect(c.trainingBlockWeek, 5);
    expect(c.inDeloadWeek, isTrue);
    // 组数 -1（3 → 2），写进本场 target_sets 快照
    expect(c.exercises.first.targetSets, 2);
    // 减载以当前工作重量 60kg 为基准 ×0.9 = 54kg；
    // 不是按链建议的 62.5×0.9（那只比 60 低 6%，不算减载）。
    expect(c.weightDraft, 54);
    // 总结页不诱导「继续加重」，直接说明本周减载、不计入渐进判定。
    final verdicts = await c.verdicts();
    expect(verdicts.first, contains('减载周'));
    expect(verdicts.first, isNot(contains('加重')));
  });

  test('先放弃再首练：放弃日不写入块起点', () async {
    final (day, exs) = await makePlan();
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    expect(c.trainingBlockWeek, 1);
    await c.quit();
    // 计划还没有 done 记录：不能把「开练后放弃」的日期落成锚点
    expect(prefs.getString('block.anchor.${day.planId}'), isNull);

    final c2 = makeController();
    await c2.startFromDay(day: day, planExercises: exs);
    expect(c2.trainingBlockWeek, 1, reason: '没有 done 记录，仍是第 1 周');
    expect(c2.inDeloadWeek, isFalse);
  });

  test('旧版纯日期锚点 / 错误计划指纹都不被采信', () async {
    final (day, exs) = await makePlan();
    // 无 done 记录时读到旧版纯日期：忽略，按当天第 1 周
    await prefs.setString('block.anchor.${day.planId}', '2020-01-01');
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    expect(c.trainingBlockWeek, 1);
    expect(c.inDeloadWeek, isFalse);
    await c.quit();

    // 新格式但计划指纹对不上（恢复备份的同号计划）同样忽略
    await prefs.setString(
      'block.anchor.${day.planId}',
      jsonEncode({'date': '2020-01-01', 'plan': 'other-plan'}),
    );
    final c2 = makeController();
    await c2.startFromDay(day: day, planExercises: exs);
    expect(c2.trainingBlockWeek, 1);
  });

  test('平台期未顶格：verdict 文案给减载 10% 或换变式并带原因', () async {
    final (day, exs) = await makePlan();
    // 3 场同重量 60kg×6（reps_max=8 未顶格）→ plateauOf 判定停滞
    await addDoneSession(day, 14, reps: 6);
    await addDoneSession(day, 7, reps: 6);
    await addDoneSession(day, 2, reps: 6);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);

    // 协议建议的 54kg 要真的接到下一次处方（不是只改文案），
    // 且「为什么是这个数字」说同一件事
    expect(c.weightDraft, 54);
    expect(c.targetWhyOf(0), contains('减载 10%'));
    // 自重切换：切回负重要恢复本次处方 54，而不是上一场 60
    c.toggleBodyweightDraft();
    expect(c.weightDraft, 0);
    c.toggleBodyweightDraft();
    expect(c.weightDraft, 54);
    // 本场记录 3 组 60×6 后，verdict 才是「有记录」的停滞判定
    c.confirmAutoFinish = () async => false;
    for (var i = 0; i < 3; i++) {
      await c.completeSet(
          weight: 60, reps: 6, rir: 2, kind: SetKind.working);
      c.skipRest();
    }
    expect(c.targetWhyOf(0), contains('减载 10%'));
    final verdicts = await c.verdicts();
    expect(verdicts.first, contains('减载 10%'));
    expect(verdicts.first, contains('换一个变式'));
    // 本场 3 组也算进平台期链：3 场历史 + 本场 = 连续 4 次
    expect(verdicts.first, contains('连续 4 次'));
    expect(verdicts.first, contains('60kg'));
    expect(verdicts.first, isNot(contains('继续冲')));
  });

  test('本场顶格突破平台期：plateau 刷新为 add，verdict 保留链的加重', () async {
    final (day, exs) = await makePlan();
    for (final d in [14, 7, 2]) {
      await addDoneSession(day, d, reps: 6);
    }
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    // 开练时历史 3 场 60×6：协议是减载
    expect(
      plateauProtocolOf(c.plateauFor('杠铃卧推'), rule: exs.first.rule).action,
      'reduce',
    );
    c.confirmAutoFinish = () async => false;
    for (var i = 0; i < 3; i++) {
      await c.completeSet(
          weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      c.skipRest();
    }
    // 本场把次数做到上限：平台期状态刷新为 hitTop → add，不再劝减载
    final p =
        plateauProtocolOf(c.plateauFor('杠铃卧推'), rule: exs.first.rule);
    expect(p.action, 'add');
    expect(p.reason, contains('加重'));
    final verdicts = await c.verdicts();
    expect(verdicts.first, contains('加重'));
    expect(verdicts.first, contains('62.5kg'));
    expect(verdicts.first, isNot(contains('减载 10%')));
    // 「为什么是这个数字」随本场顶格即时刷新，不再是旧的减载文案
    expect(c.targetWhyOf(0), contains('加重'));
  });

  test('上一场少做：targetWhy 与 weightDraft 都不触发减载', () async {
    final (day, exs) = await makePlan();
    await addDoneSession(day, 14, reps: 6);
    await addDoneSession(day, 7, reps: 6);
    // 最近一场是平台期但只做了 1/3 组（P0-B：少做不推进）
    await addDoneSession(day, 1, reps: 6, setCount: 1);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);

    expect(c.weightDraft, 60, reason: '少做不触发平台期减载');
    expect(c.targetWhyOf(0), isNot(contains('减载 10%')));
  });

  test('平台期减载场内 target_weight_kg 快照不随本场组漂移', () async {
    final (day, exs) = await makePlan();
    await addDoneSession(day, 14, reps: 6);
    await addDoneSession(day, 7, reps: 6);
    await addDoneSession(day, 2, reps: 6);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    expect(c.weightDraft, 54);

    c.confirmAutoFinish = () async => false;
    // 按处方做 54×6：若无会话级快照，第一组后 60kg 平台期被打断，
    // 后续组的 target_weight_kg 会漂成链的 62.5。
    for (var i = 0; i < 3; i++) {
      await c.completeSet(
          weight: 54, reps: 6, rir: 2, kind: SetKind.working);
      c.skipRest();
    }
    final sets = await db.setsOfExercise(c.exercises.first.id!);
    expect(sets.map((s) => s.targetWeightKg).toSet(), {54},
        reason: '同一场的目标重量快照必须一致');
  });

  test('历史顶格但本场少做：verdict 保留「本次只完成 X/Y 组」', () async {
    final (day, exs) = await makePlan();
    for (final d in [14, 7, 2]) {
      await addDoneSession(day, d); // 60×8，hitTop
    }
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    await c.completeSet(
        weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    c.skipRest();
    final verdicts = await c.verdicts();
    expect(verdicts.first, contains('本次只完成 1/3 组'));
    expect(verdicts.first, isNot(contains('继续加重')));
  });

  test('会话中改块长后恢复：仍按开练时的减载处方', () async {
    final (day, exs) = await makePlan();
    await addDoneSession(day, 28);
    // 最近一场 1 天前：把「上一场 done」保持在 14 天内，让本测试只验证
    // 减载周，不触发 P1-D 停练回归（块起点仍取 MIN=28 天前）。
    await addDoneSession(day, 1);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    expect(c.inDeloadWeek, isTrue);
    c.settings.trainingBlockWeeks = 0;
    await c.settings.save();

    final c2 = makeController();
    await c2.restore();
    expect(c2.hasActive, isTrue);
    expect(c2.inDeloadWeek, isTrue, reason: '本场快照，不跟随改后的 0');
    expect(c2.trainingBlockWeek, 5);
    expect(c2.trainingBlockWeeks, 5, reason: '块长也按开练时快照');
    expect(c2.exercises.first.targetSets, 2);
  });

  test('杀进程恢复平台期减载场：weightDraft 仍是 54，不弹回 60', () async {
    final (day, exs) = await makePlan();
    // 3 场同重量 60×6（reps_max=8 未顶格）→ 开练即平台期减载处方 54；
    // 锚点 = 14 天前 → 第 3 周，本测试专验平台期减载（不走减载周快照）。
    await addDoneSession(day, 14, reps: 6);
    await addDoneSession(day, 7, reps: 6);
    await addDoneSession(day, 2, reps: 6);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    expect(c.weightDraft, 54);
    // 按处方做一组 54：本场处方落进组行 target_weight_kg
    await c.completeSet(weight: 54, reps: 6, rir: 2, kind: SetKind.working);

    // 模拟杀进程：内存全空的控制器从同一库/prefs 恢复。
    // 本场的 54kg 组会打断 60kg 平台期回溯，恢复时重算建议会弹回 60——
    // 必须优先沿用已落库的处方。
    final c2 = makeController();
    await c2.restore();
    expect(c2.hasActive, isTrue);
    expect(c2.weightDraft, 54,
        reason: '恢复后重量建议仍是减载后的 54kg，不弹回 60kg');
    expect(c2.targetWhyOf(0), contains('减载 10%'),
        reason: '目标解释与重量同口径，不再自相矛盾');
  });

  test('杀进程恢复减载周会话：记录 54 后恢复仍按 54', () async {
    final (day, exs) = await makePlan();
    await addDoneSession(day, 28);
    // 最近一场 1 天前，避免触发 P1-D 停练回归（与本文件其他测试同口径）。
    await addDoneSession(day, 1);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    expect(c.inDeloadWeek, isTrue);
    expect(c.weightDraft, 54);
    await c.completeSet(weight: 54, reps: 8, rir: 2, kind: SetKind.working);

    final c2 = makeController();
    await c2.restore();
    expect(c2.hasActive, isTrue);
    expect(c2.inDeloadWeek, isTrue, reason: '块周按本场快照');
    expect(c2.weightDraft, 54, reason: '恢复沿用本场已落库的减载处方');
  });

  test('删除/重建训练日后块起点锚点不重置', () async {
    final (day, exs) = await makePlan();
    await addDoneSession(day, 28);
    // 最近一场 1 天前：把「上一场 done」保持在 14 天内，让本测试只验证
    // 减载周，不触发 P1-D 停练回归（块起点仍取 MIN=28 天前）。
    await addDoneSession(day, 1);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    expect(c.inDeloadWeek, isTrue);
    await c.quit();

    // 模拟 replacePlanWithSpecs：先删光模板日/动作，再重建
    await db.deletePlanDaysOfPlan(day.planId);
    final newDayId = await db.insertPlanDay(
      PlanDay(planId: day.planId, weekday: 1, title: '推日'),
    );
    await db.insertPlanExercise(PlanExercise(
      dayId: newDayId,
      name: '杠铃卧推',
      orderIdx: 0,
      sets: 3,
      repsMin: 5,
      repsMax: 8,
      restSec: 120,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
    ));
    final newDay = PlanDay(
        id: newDayId, planId: day.planId, weekday: 1, title: '推日');
    final newExs = await db.dayExercises(newDayId);
    final c2 = makeController();
    await c2.startFromDay(day: newDay, planExercises: newExs);
    expect(c2.inDeloadWeek, isTrue, reason: '锚点缓存仍指向 28 天前');
    expect(c2.trainingBlockWeek, 5);
  });

  test('删除唯一 done 会话后锚点失效重算：回第 1 周，不再减载', () async {
    // 语义（2026-10-18）：锚点带来源会话指纹（id|date|startedAt）。指向的
    // done 会话被用户删掉后，锚点不能继续把块周钉在已不存在的旧日期上——
    // 失效重算，「今天 = 第 1 周」（与「还没有 done 记录」同口径，不落盘）。
    final (day, exs) = await makePlan();
    await addDoneSession(day, 28);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    expect(c.inDeloadWeek, isTrue, reason: '块起点 = 28 天前那场，第 5 周减载');
    await c.quit();

    // 锚点已带来源会话指纹
    final rawAnchor = prefs.getString('block.anchor.${day.planId}');
    expect(rawAnchor, isNotNull);
    expect(rawAnchor!, contains('session'));

    // 删掉那场唯一的 done 会话（历史页删除入口同款：级联清动作与组）
    final only = await db.recentSessions(limit: 10);
    expect(only, hasLength(1));
    await db.deleteSession(only.single.id!);

    final c2 = makeController();
    await c2.startFromDay(day: day, planExercises: exs);
    expect(c2.trainingBlockWeek, 1, reason: '来源会话已删：锚点失效，重算第 1 周');
    expect(c2.inDeloadWeek, isFalse, reason: '不再按旧块周进入减载');
    expect(c2.inLayoff, isFalse, reason: '没有带正式组的 done 会话，不触发停练');
    expect(c2.exercises.first.targetSets, 3, reason: '组数不再减 1');
  });

  test('减载场之后：上次成绩显示减载场，处方跳过它回到原档', () async {
    final (day, exs) = await makePlan();
    // 28 天前 60×8 = 减载前的工作档；最近一场 1 天前避免停练回归。
    await addDoneSession(day, 28);
    await addDoneSession(day, 1);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    expect(c.inDeloadWeek, isTrue);
    await c.completeSet(
        weight: 54, reps: 8, rir: 2, kind: SetKind.working);
    c.skipRest();
    await c.finish();

    c.settings.trainingBlockWeeks = 0;
    await c.settings.save();
    final c2 = makeController();
    await c2.startFromDay(day: day, planExercises: exs);
    expect(c2.lastPerformance('杠铃卧推')!.weightKg, 54,
        reason: '真实上一场是减载（上次成绩行）');
    expect(c2.weightDraft, 62.5,
        reason: '处方跳过减载场，按 60×8 顶格加重到 62.5');
  });

  test('自重动作减载文案不写「90% 重量」', () async {
    final (day, exs) =
        await makePlan(loadType: LoadMode.bodyweight);
    await addDoneSession(day, 28,
        weight: 0, loadType: LoadMode.bodyweight);
    await addDoneSession(day, 1,
        weight: 0, loadType: LoadMode.bodyweight);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    expect(c.inDeloadWeek, isTrue);
    final verdicts = await c.verdicts();
    expect(verdicts.first, contains('本次少做 1 组'));
    expect(verdicts.first, isNot(contains('90%')));
  });

  test('辅助配重减载写「配重增加 10%」，不写「90% 重量」', () async {
    final (day, exs) = await makePlan();
    await addDoneSession(day, 28, weight: -30);
    await addDoneSession(day, 1, weight: -30);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    expect(c.inDeloadWeek, isTrue);
    expect(c.weightDraft, -33, reason: '-30 配重再辅助 10% → -33');
    expect(c.targetWhyOf(0), contains('辅助配重增加约 10%'));
    final verdicts = await c.verdicts();
    expect(verdicts.first, contains('辅助配重增加约 10%'));
    expect(verdicts.first, isNot(contains('90% 重量')));
  });

  test('恢复会话的块周快照带会话指纹：同号不同场不套用', () async {
    final (day, exs) = await makePlan();
    await addDoneSession(day, 28);
    // 最近一场 1 天前：把「上一场 done」保持在 14 天内，让本测试只验证
    // 减载周，不触发 P1-D 停练回归（块起点仍取 MIN=28 天前）。
    await addDoneSession(day, 1);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    expect(c.inDeloadWeek, isTrue);
    final sid = c.session!.id!;

    // 模拟恢复另一台设备的备份：同 id 会话变成 14 天后的另一场训练
    await rawDb.update(
      'sessions',
      {
        'date': fmtDate(DateTime.now().add(const Duration(days: 14))),
        'started_at': 12345,
      },
      where: 'id = ?',
      whereArgs: [sid],
    );

    final c2 = makeController();
    await c2.restore();
    expect(c2.hasActive, isTrue);
    expect(c2.inDeloadWeek, isFalse, reason: '旧快照指纹不匹配，按新会话重算');
    expect(c2.trainingBlockWeek, 2, reason: '锚点 28 天前 + 14 天 = 第 2 周');
  });

  test('块长设为 0 = 关闭：不减组、不减重', () async {
    final (day, exs) = await makePlan();
    await addDoneSession(day, 28);
    // 最近一场 1 天前：把「上一场 done」保持在 14 天内，让本测试只验证
    // 减载周，不触发 P1-D 停练回归（块起点仍取 MIN=28 天前）。
    await addDoneSession(day, 1);
    final c = makeController();
    c.settings.trainingBlockWeeks = 0;
    await c.settings.save();
    await c.startFromDay(day: day, planExercises: exs);

    expect(c.inDeloadWeek, isFalse);
    expect(c.exercises.first.targetSets, 3);
    expect(c.weightDraft, 62.5);
  });

  test('计划的第一次训练（还没有 done 记录）= 第 1 周，不减载', () async {
    final (day, exs) = await makePlan();
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);

    expect(c.trainingBlockWeek, 1);
    expect(c.inDeloadWeek, isFalse);
    expect(c.exercises.first.targetSets, 3);
  });

  test('减载会话记录在本地偏好，且从下次处方回溯中排除', () async {
    final (day, exs) = await makePlan();
    await addDoneSession(day, 28);
    // 最近一场 1 天前：把「上一场 done」保持在 14 天内，让本测试只验证
    // 减载周，不触发 P1-D 停练回归（块起点仍取 MIN=28 天前）。
    await addDoneSession(day, 1);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    final deloadSessionId = c.session!.id!;

    // 直接补一条减载组（54kg），并把本场记录形态改成计时——
    // 这样三条纵向查询（重量/组数/形态）都能验证排除生效。
    final exId = c.exercises.first.id!;
    await db.insertSet(SetEntry(
      sessionExerciseId: exId,
      weightKg: 54,
      reps: 8,
      kind: SetKind.working,
      doneAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await rawDb.update(
      'session_exercises',
      {'logging': LoggingMode.time},
      where: 'id = ?',
      whereArgs: [exId],
    );
    await c.finish();

    final raw = prefs.getString('block.deloadSessionIds') ?? '';
    expect(raw, contains('$deloadSessionId'));

    final plain = await db.lastWorkingSets('杠铃卧推');
    expect(plain.first.weightKg, 54, reason: '不排除时最新一场是减载');
    final skipped = await db.lastWorkingSets('杠铃卧推',
        excludeSessionIds: {deloadSessionId});
    expect(skipped.first.weightKg, 60, reason: '排除减载后回到上一场正常训练');

    // 组数快照与记录形态同样跳过减载场：3 组（旧场）而不是 2 组（减载场）；
    // 形态回到 reps 而不是本场改成的 time。
    expect(await db.lastTargetSets('杠铃卧推'), 2);
    expect(
      await db.lastTargetSets('杠铃卧推', excludeSessionIds: {deloadSessionId}),
      3,
    );
    expect((await db.lastExerciseModes('杠铃卧推'))!.$1, LoggingMode.time);
    expect(
      (await db.lastExerciseModes('杠铃卧推',
              excludeSessionIds: {deloadSessionId}))!
          .$1,
      LoggingMode.reps,
    );

    // 平台期/PR 用的 historySets 同样排除减载组。
    final all = await db.historySets('杠铃卧推', kindFilter: SetKind.working);
    expect(all.where((e) => e.weightKg == 54), isNotEmpty);
    final noDeload = await db.historySets('杠铃卧推',
        kindFilter: SetKind.working, excludeSessionIds: {deloadSessionId});
    expect(noDeload.where((e) => e.weightKg == 54), isEmpty);
  });

  test('备份恢复后同号但不同场的减载标记会被剔除', () async {
    final (day, exs) = await makePlan();
    await addDoneSession(day, 28);
    // 最近一场 1 天前：把「上一场 done」保持在 14 天内，让本测试只验证
    // 减载周，不触发 P1-D 停练回归（块起点仍取 MIN=28 天前）。
    await addDoneSession(day, 1);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: exs);
    final sid = c.session!.id!;
    await c.finish();
    expect(prefs.getString('block.deloadSessionIds') ?? '', contains('$sid'));

    // 模拟恢复另一台设备的备份：同 id 会话变成日期/开始时间都不同的训练
    await rawDb.update(
      'sessions',
      {'date': '2020-01-01', 'started_at': 999999},
      where: 'id = ?',
      whereArgs: [sid],
    );

    final c2 = makeController();
    await c2.startFromDay(day: day, planExercises: exs);
    expect(prefs.getString('block.deloadSessionIds') ?? '',
        isNot(contains('$sid')),
        reason: '指纹对不上 → 不误排除真实训练');
  });

  test('恢复写回偏好后 reloadDeloadMarkers 重灌内存排除表', () async {
    // restoreAll 已把备份里的 block.deloadSessionIds 写回 prefs；控制器是
    // App 级单例（构造时读过一次），恢复路径必须调 reloadDeloadMarkers
    // 让内存排除表跟上，否则本进程内统计回溯仍用恢复前的旧标记。
    final (day, exs) = await makePlan();
    await addDoneSession(day, 28);
    final past = await db.recentSessions(limit: 10);
    final sid = past.single.id!;
    final date = fmtDate(DateTime.now().subtract(const Duration(days: 28)));
    final marker = jsonEncode(['$sid|$date|1']); // startedAt 与 addDoneSession 一致

    // 场景：控制器先构造（还没有标记），恢复把标记写回 prefs 后重灌
    final c = makeController();
    expect(c.deloadSessionIds, isEmpty);
    await prefs.setString('block.deloadSessionIds', marker);
    c.reloadDeloadMarkers();
    expect(c.deloadSessionIds, {sid}, reason: '内存排除表随恢复后的偏好重灌');

    // 指纹对不上库内会话的标记：重灌后由下次开练时的指纹校验剔除
    await prefs.setString(
        'block.deloadSessionIds', jsonEncode(['$sid|2000-01-01|1']));
    c.reloadDeloadMarkers();
    expect(c.deloadSessionIds, {sid},
        reason: '重灌只管装填，指纹校验在 _ensureDeloadMarkersValid');
    final c2 = makeController();
    await c2.startFromDay(day: day, planExercises: exs);
    expect(c2.deloadSessionIds, isEmpty, reason: '开练时的指纹校验剔除了对不上的标记');
  });
}
