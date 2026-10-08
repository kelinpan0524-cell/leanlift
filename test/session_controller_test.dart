// 批次1 修复回归：会话状态机（A1-1 撤销计数 / A1-2 零动作脏会话 / A1-5 双击竞态）、
// 休息时间源与闹钟回调（A1-4 controller 半边）、数据层正确性（A5-2 截断方向 / A5-3 导出）。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/services/export_service.dart';
import 'package:baoji_timer/services/rest_cue.dart';
import 'package:baoji_timer/services/session_controller.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // 测试环境没有宿主插件：wakelock_plus 的 pigeon toggle 通道挂 mock 回包。
    // pigeon 对 null 回包一律抛 channel-error，void 方法的合法回包是
    // 编码后的 [null]（StandardMessageCodec：list 头 0x0C + 长度 0x01 + null 0x00）。
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
  late Database rawDb; // 直查用（绕开 Db 封装断言库内真值）
  late SharedPreferences prefs;
  final controllers = <SessionController>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // 微秒时间戳唯一路径 = 每个测试独立数据库（ffi 对同路径会复用连接）
    final dir = await databaseFactory.getDatabasesPath();
    final path = '$dir/test_sess_${DateTime.now().microsecondsSinceEpoch}.db';
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

  SessionController makeController() {
    final c = SessionController(db, Settings(prefs), prefs, null);
    controllers.add(c);
    return c;
  }

  Future<PlanDay> makePlanDay(String title) async {
    final plan = await db.insertPlan(
      Plan(
        name: '测试计划-$title',
        source: 'manual',
        createdAt: '2026-09-24',
        isActive: 1,
      ),
    );
    final dayId = await db.insertPlanDay(
      PlanDay(planId: plan.id!, weekday: 3, title: title),
    );
    return PlanDay(id: dayId, planId: plan.id!, weekday: 3, title: title);
  }

  Future<PlanExercise> addPlanEx(
    PlanDay day,
    String name,
    int order, {
    int sets = 3,
    int restSec = 120,
    int workingSets = 3,
    String supersetTag = '',
  }) async {
    final pe = PlanExercise(
      dayId: day.id!,
      name: name,
      orderIdx: order,
      sets: sets,
      repsMin: 5,
      repsMax: 8,
      restSec: restSec,
      kind: 'compound',
      rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: workingSets),
      supersetTag: supersetTag,
    );
    final id = await db.insertPlanExercise(pe);
    return pe.copyWith(id: id);
  }

  test('A1-1：跨动作回退撤销后计数收敛到 DB 真值，剩余组仍是 PR 则保留标记', () async {
    // 前置历史：深蹲 在一次 done 会话里推过 60kg（62.5 即历史新高）
    final s0 = await db.insertSession(
      Session(
        date: '2026-09-01',
        planDayTitle: '旧训练',
        startedAt: 1,
        endedAt: 2,
        status: 'done',
      ),
    );
    final se0 = await db.insertSessionExercise(
      SessionExercise(
        sessionId: s0.id!,
        name: '深蹲',
        orderIdx: 0,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      ),
    );
    await db.insertSet(
      SetEntry(
        sessionExerciseId: se0,
        weightKg: 60,
        reps: 8,
        kind: SetKind.working,
        doneAt: 1000,
      ),
    );

    final day = await makePlanDay('腿日');
    final a = await addPlanEx(day, '深蹲', 0, workingSets: 3);
    final b = await addPlanEx(day, '腿举', 1, sets: 1, workingSets: 1);

    final c = makeController();
    await c.startFromDay(day: day, planExercises: [a, b]);
    expect(c.hasActive, isTrue);
    expect(c.curExIdx, 0);

    // 记满 A 的 3 个正式组 → 自动推进到 B 并进入休息
    for (var i = 0; i < 3; i++) {
      await c.completeSet(weight: 62.5, reps: 8, rir: 2, kind: SetKind.working);
    }
    expect(c.curExIdx, 1, reason: 'A 记满 3 组已推进到 B');
    expect(c.prHit, contains('深蹲'));

    // 休息态撤销：回退到 A 删最后一组
    await c.undoLastSet();
    expect(c.workingSetsDone, 2, reason: '按剩余正式组重算，不再出现 -1');
    expect(c.curExIdx, 0, reason: '回退到动作 A');
    expect(c.currentSets.length, 2, reason: 'A 只剩 2 组');
    expect(c.prHit, contains('深蹲'), reason: '剩余两组 62.5 仍高于历史 60，PR 标记保留');

    // 继续撤销直到 A 一个正式组不剩：已无任何"历史新高"组 → 标记清除
    await c.undoLastSet();
    expect(c.workingSetsDone, 1);
    await c.undoLastSet();
    expect(c.workingSetsDone, 0);
    expect(c.currentSets, isEmpty);
    expect(c.prHit, isNot(contains('深蹲')), reason: '剩余正式组全删后 PR 标记应清除');
  });

  test('A1-2：零动作 active 脏会话 restore 自动作废，不再锁死启动', () async {
    await db.insertSession(
      Session(
        date: '2026-09-24',
        planDayTitle: '脏会话',
        startedAt: 1,
        status: 'active',
      ),
    );
    final dirty = await db.activeSession();
    expect(dirty, isNotNull);

    final c = makeController();
    // 修复前：exercises 为空 → currentEx! 解引用抛
    // "Null check operator used on a null value"，启动即崩
    await c.restore();
    expect(c.hasActive, isFalse);
    expect(c.session, isNull);
    expect(c.phase, WorkoutPhase.idle);

    final after = await db.sessionById(dirty!.id!);
    expect(after!.status, 'quit', reason: '孤儿会话被自动作废');

    // 作废后可正常开新会话
    final day = await makePlanDay('推日');
    final e = await addPlanEx(day, '卧推', 0);
    await c.startFromDay(day: day, planExercises: [e]);
    expect(c.hasActive, isTrue);
    expect(c.exercises.length, 1);
    expect(c.phase, WorkoutPhase.lifting);
  });

  test('A5-2：historySets 超 2000 行时截掉最旧、保留最新且仍按时间升序', () async {
    final s = await db.insertSession(
      Session(
        date: '2026-09-01',
        planDayTitle: 't',
        startedAt: 1,
        endedAt: 2,
        status: 'done',
      ),
    );
    final se = await db.insertSessionExercise(
      SessionExercise(
        sessionId: s.id!,
        name: '卧推',
        orderIdx: 0,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8),
      ),
    );
    const base = 1700000000000;
    // 备数用单事务 batch：2001 次逐行 insertSet（每次 ffi isolate 往返）
    // 在 CI runner 上会撞 30 秒单测超时；被超时打断的残留循环还会撞上
    // tearDown 清库报外键错。被测对象是 historySets 的截断查询，不是
    // 逐行插入路径，batch 备数不削弱断言。
    final batch = rawDb.batch();
    for (var i = 0; i < 2001; i++) {
      batch.insert(
        'sets',
        SetEntry(
          sessionExerciseId: se,
          weightKg: 60,
          reps: 8,
          kind: SetKind.working,
          doneAt: base + i * 1000,
        ).toMap(),
      );
    }
    await batch.commit(noResult: true);
    final latest = base + 2000 * 1000;

    final list = await db.historySets('卧推');
    expect(list.length, 2000, reason: '封顶 2000 行');
    expect(list.first.doneAt < list.last.doneAt, isTrue, reason: '时间升序');
    expect(list.last.doneAt, latest, reason: '最后一条是最新的组（截掉的是最旧段）');
  });

  test('A5-3：exportAllJson 导出包含 exercise_meta', () async {
    await db.upsertExerciseMeta(
      const ExerciseMeta(
        '词表外动作',
        MuscleGroups(main: '胸', secondary: ['肩']),
        true,
        'gym',
      ),
    );

    final data = await db.exportAllJson();
    expect(data.containsKey('exercise_meta'), isTrue);
    final rows = data['exercise_meta'] as List<dynamic>;
    expect(rows, isNotEmpty);
    expect((rows.first as Map)['name'], '词表外动作');
  });

  test('A1-5（controller 侧）：已有 active 会话时再调 startFromDay 直接返回', () async {
    final day = await makePlanDay('日');
    final e = await addPlanEx(day, '卧推', 0);

    final c = makeController();
    await c.startFromDay(day: day, planExercises: [e]);
    final firstId = c.session!.id;
    await c.startFromDay(day: day, planExercises: [e]); // 模拟双击第二击
    expect(c.session!.id, firstId, reason: '内存态已 active，第二次调用直接返回');
    var rows = await rawDb.query('sessions', where: "status='active'");
    expect(rows.length, 1, reason: '不产生第二条 active 会话');

    // DB 层已有 active 而内存未加载（如恢复失败）时，插入前重查兜底同样拦截
    final c2 = makeController();
    await c2.startFromDay(day: day, planExercises: [e]);
    expect(c2.session, isNull, reason: 'DB 重查兜底拦截，未开新会话');
    rows = await rawDb.query('sessions', where: "status='active'");
    expect(rows.length, 1);
  });

  test('A1-4（controller 半边）：暂停态 +30 秒不被 resume 丢弃；闹钟回调跟随时间源', () async {
    final alarmCalls = <int?>[];
    final day = await makePlanDay('日');
    final e = await addPlanEx(day, '卧推', 0, workingSets: 3, restSec: 120);

    final c = makeController();
    c.onRestAlarmChanged = (endAtMs) async => alarmCalls.add(endAtMs);
    await c.startFromDay(day: day, planExercises: [e]);
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    expect(c.phase, WorkoutPhase.resting);
    final endAfterStart = c.restEndAt;
    expect(alarmCalls.last, endAfterStart, reason: '开始休息即挂精确闹钟');

    c.pauseRest();
    expect(c.isRestPaused, isTrue);
    expect(alarmCalls.last, isNull, reason: '暂停即取消精确闹钟');

    final remainingBefore = c.restRemainingMs.value;
    final prefsEndAtBefore = prefs.getInt('rest.endAt');
    c.extendRest(30);
    expect(
      c.restRemainingMs.value,
      remainingBefore + 30000,
      reason: '暂停态加时立即反映在剩余时间上',
    );
    expect(
      prefs.getInt('rest.endAt'),
      prefsEndAtBefore,
      reason: '暂停态加时不写 prefs',
    );
    expect(c.restEndAt, endAfterStart, reason: '暂停态不改动 restEndAt');

    c.resumeRest();
    expect(c.isRestPaused, isFalse);
    expect(
      c.restEndAt,
      greaterThan(endAfterStart),
      reason: '继续后按冻结剩余+加时重算结束时刻',
    );
    expect(prefs.getInt('rest.endAt'), c.restEndAt);
    expect(alarmCalls.last, c.restEndAt, reason: '恢复时重挂闹钟到新时刻');
    expect(
      c.restEndAt - DateTime.now().millisecondsSinceEpoch,
      closeTo(remainingBefore + 30000, 2000),
      reason: 'resume 保留暂停态加的 30 秒，不再被静默丢弃',
    );

    // 等 completeSet → _beginRestFor 的异步续体（预载下一动作上下文）跑完，
    // 避免它在 tearDown dispose 之后才 notifyListeners 报"used after dispose"。
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('B1：同一动作组间休息保留手动调过的重量，换动作才重新推荐', () async {
    final day = await makePlanDay('日');
    final a = await addPlanEx(day, '动作甲', 0, sets: 2, workingSets: 2);
    final b = await addPlanEx(day, '动作乙', 1, sets: 1, workingSets: 1);

    final c = makeController();
    await c.startFromDay(day: day, planExercises: [a, b]);
    // 推荐值是内置起始 20：手动加重后做一组
    c.setWeightDraft(62.5);
    await c.completeSet(weight: 62.5, reps: 8, rir: 2, kind: SetKind.working);
    expect(c.phase, WorkoutPhase.resting);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.weightDraft, 62.5, reason: '同动作继续：手动调过的重量不被推荐值冲掉');

    // 记满动作甲 → 推进到动作乙：换动作才刷新推荐重量
    await c.completeSet(
      weight: c.weightDraft,
      reps: 8,
      rir: 2,
      kind: SetKind.working,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.curExIdx, 1);
    expect(c.weightDraft, presetStartOf('动作乙'), reason: '无历史的动作用内置起始重量');
  });

  test('B2：动作练满进休息可回退加练一组，加练按正式组记录', () async {
    final day = await makePlanDay('日');
    final a = await addPlanEx(day, '动作甲', 0, sets: 1, workingSets: 1);
    final b = await addPlanEx(day, '动作乙', 1, sets: 1, workingSets: 1);

    final c = makeController();
    await c.startFromDay(day: day, planExercises: [a, b]);
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    expect(c.curExIdx, 1, reason: '动作甲练满已推进');
    expect(c.extraSetExerciseName, '动作甲', reason: '休息页应有加练入口');

    await c.startExtraSet();
    expect(c.phase, WorkoutPhase.lifting);
    expect(c.curExIdx, 0);
    expect(c.extraSetExerciseName, isNull);
    expect(c.workingSetsDone, 1);

    // 加练一组：作为正式组落库
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    final map = await db.setsOfSession(c.session!.id!);
    final working = (map[c.exercises[0].id] ?? [])
        .where((e) => e.kind == SetKind.working)
        .length;
    expect(working, 2, reason: '加练组按正式组记录');
    expect(c.curExIdx, 1, reason: '加练满后再次推进到下一动作');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('B6：组间（未练满）休息也有「再来一组」，重量继承最后一组实际值', () async {
    final day = await makePlanDay('日');
    final a = await addPlanEx(day, '动作甲', 0, sets: 3, workingSets: 3);

    final c = makeController();
    await c.startFromDay(day: day, planExercises: [a]);
    c.setWeightDraft(52.5); // 手调重量（推荐 20）
    await c.completeSet(weight: 52.5, reps: 8, rir: 2, kind: SetKind.working);
    expect(c.phase, WorkoutPhase.resting);
    expect(c.workingSetsDone, 1, reason: '只做了 1/3 组，未练满');
    expect(c.extraSetExerciseName, '动作甲', reason: '组间休息也提供「再来一组」回到本动作');

    await c.startExtraSet();
    expect(c.phase, WorkoutPhase.lifting);
    expect(c.weightDraft, 52.5, reason: '再来一组继承最后一组实际重量，不被推荐值冲回');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('B7：负重量（辅助器械配重）可记录、容量按 0 计、跨次渐进', () async {
    final day = await makePlanDay('日');
    final a = await addPlanEx(day, '引体向上', 0, sets: 1, workingSets: 1);

    final c = makeController();
    await c.startFromDay(day: day, planExercises: [a]);

    c.setWeightDraft(-30); // 辅助配重 30kg：从自重 0 往下减
    expect(c.weightDraft, -30, reason: '负值保留，不再被钳到 0');
    await c.completeSet(weight: -30, reps: 8, rir: 2, kind: SetKind.working);
    final stats = await c.stats();
    expect(stats.volume, 0, reason: '辅助配重按 0 容量计（不回减总容量）');

    // 下次训练该动作：历史 -30 达标 → 推荐 -27.5（辅助减少 = 进步）
    await c.finish();
    final c2 = makeController();
    await c2.startFromDay(day: day, planExercises: [a]);
    expect(c2.weightDraft, -27.5, reason: '负重量同样渐进，不再卡死在原配重');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('B8：toggleBodyweightDraft 对辅助配重态一键归零；下限 -300 防手抖', () async {
    final day = await makePlanDay('日');
    final a = await addPlanEx(day, '引体向上', 0, sets: 1, workingSets: 1);

    final c = makeController();
    await c.startFromDay(day: day, planExercises: [a]);
    c.setWeightDraft(-30);
    c.toggleBodyweightDraft();
    expect(c.weightDraft, 0, reason: '辅助态点一下切回纯自重');

    c.setWeightDraft(-5000);
    expect(c.weightDraft, -300, reason: '负值下限 -300kg');
  });

  test('B9：手动改重量并完成后，下次训练直接从实际重量开始（不回计划初始）', () async {
    final day = await makePlanDay('日');
    final a = await addPlanEx(day, '动作甲', 0, sets: 2, workingSets: 2);

    final c = makeController();
    await c.startFromDay(day: day, planExercises: [a]);
    final base = c.weightDraft; // 无历史：内置起始重量
    c.setWeightDraft(base + 40); // 手动加 40kg（换器械/个人偏好）
    await c.completeSet(
      weight: c.weightDraft,
      reps: 7,
      rir: 2,
      kind: SetKind.working,
    );
    await c.completeSet(
      weight: c.weightDraft,
      reps: 7,
      rir: 2,
      kind: SetKind.working,
    );
    await c.finish();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 下次训练：次数在区间内但未全达上限 → 渐进判 hold（+0），
    // 推荐重量 = 上次实际重量——手动调整无需每次重来
    final c2 = makeController();
    await c2.startFromDay(day: day, planExercises: [a]);
    expect(c2.weightDraft, base + 40, reason: '下次训练从上次实际重量开始，手动调整被记住');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('B3：训练中可追加动作、可替换未记组动作，已记组不可替换', () async {
    final day = await makePlanDay('日');
    final a = await addPlanEx(day, '动作甲', 0, sets: 3, workingSets: 3);

    final c = makeController();
    await c.startFromDay(day: day, planExercises: [a]);

    await c.appendExercises(const [
      ExerciseMeta('临时动作', MuscleGroups(main: '胸'), true),
    ]);
    expect(c.exercises.length, 2);
    expect(c.exercises.last.name, '临时动作');
    expect(c.exercises.last.orderIdx, 1, reason: '追加到队尾');
    final added = await rawDb.query(
      'session_exercises',
      where: "name = '临时动作'",
    );
    expect(added.length, 1, reason: '追加动作落库');
    expect(added.first['trace'], '追加于：动作甲',
        reason: '点名条目三：追加痕迹落库（追加在谁后面）');

    // 当前动作还没记组：可替换（沿用规则只换名）
    final ok = await c.replaceCurrentExercise(
      const ExerciseMeta('替换动作', MuscleGroups(main: '背'), false),
    );
    expect(ok, isTrue);
    expect(c.exercises[0].name, '替换动作');
    expect(c.exercises[0].trace, '替换自：动作甲',
        reason: '内存模型带替换痕迹');
    final renamed = await rawDb.query(
      'session_exercises',
      where: 'id = ?',
      whereArgs: [c.exercises[0].id],
    );
    expect(renamed.first['name'], '替换动作');
    expect(renamed.first['trace'], '替换自：动作甲',
        reason: '点名条目三：替换痕迹落库（原动作是什么）');

    // 已记组：不可替换（防把已记的组串到别的动作名下）
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    final ok2 = await c.replaceCurrentExercise(
      const ExerciseMeta('再换一个', MuscleGroups(main: '肩'), false),
    );
    expect(ok2, isFalse);
    expect(c.exercises[0].name, '替换动作');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('B3b：跳页——可跳到未练满动作并带上下文；练满/越界/原地不可跳；休息中跳页结束休息', () async {
    final day = await makePlanDay('日');
    final a = await addPlanEx(day, '动作甲', 0, sets: 2, workingSets: 2);
    final b = await addPlanEx(day, '动作乙', 1, sets: 2, workingSets: 2);
    final c2 = await addPlanEx(day, '动作丙', 2, sets: 1, workingSets: 1);

    final c = makeController();
    final alarmCalls = <int?>[];
    c.onRestAlarmChanged = (endAtMs) async => alarmCalls.add(endAtMs);
    await c.startFromDay(day: day, planExercises: [a, b, c2]);

    // 原地/越界：no-op
    expect(await c.jumpToExercise(0), isFalse);
    expect(await c.jumpToExercise(99), isFalse);
    expect(c.curExIdx, 0);

    // 动作甲记 1 组后跳到动作乙：上下文跟随（推荐重量/计数/相位）
    c.setWeightDraft(55);
    await c.completeSet(weight: 55, reps: 8, rir: 2, kind: SetKind.working);
    expect(c.phase, WorkoutPhase.resting);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(await c.jumpToExercise(1), isTrue, reason: '跳到未练满的动作乙');
    expect(c.phase, WorkoutPhase.lifting, reason: '休息中跳页先结束休息');
    expect(alarmCalls.last, isNull, reason: '跳页取消精确闹钟（跳过休息同口径）');
    expect(c.curExIdx, 1);
    expect(c.workingSetsDone, 0);
    expect(c.weightDraft, presetStartOf('动作乙'), reason: '无历史组用推荐值');
    // 甲的已记组原样保留
    final map = await db.setsOfSession(c.session!.id!);
    expect((map[c.exercises[0].id] ?? []).length, 1);

    // 动作乙记满后：不可再跳入（防打乱计数），但可跳到未练满的丙
    await c.completeSet(weight: 40, reps: 8, rir: 2, kind: SetKind.working);
    await c.completeSet(weight: 40, reps: 8, rir: 2, kind: SetKind.working);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.curExIdx, 2, reason: '乙练满已自动推进到丙');
    expect(await c.jumpToExercise(1), isFalse, reason: '练满的动作不可跳入');
    // 跳回甲（还有 1 个正式组没做）：带实际组重量
    expect(await c.jumpToExercise(0), isTrue);
    expect(c.curExIdx, 0);
    expect(c.workingSetsDone, 1);
    expect(c.weightDraft, 55, reason: '有实际组时重量继承最后一组实际值');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('B4：休息减时有 5 秒地板，不把剩余时间减穿（暂停态同理）', () async {
    final day = await makePlanDay('日');
    final a = await addPlanEx(
      day,
      '动作甲',
      0,
      sets: 3,
      workingSets: 3,
      restSec: 120,
    );

    final c = makeController();
    await c.startFromDay(day: day, planExercises: [a]);
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    expect(c.phase, WorkoutPhase.resting);

    c.extendRest(-118); // 120 - 118 ≈ 2s → 地板抬到 5s
    expect(
      c.restEndAt - DateTime.now().millisecondsSinceEpoch,
      closeTo(5000, 1500),
    );

    c.pauseRest();
    c.extendRest(-30); // 剩余 ≈5s，减 30 也被地板挡住
    expect(c.restRemainingMs.value, 5000);
    c.resumeRest();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('B5：restoreFromJson 清空恢复后外键关系完整，缺段报错且不动数据', () async {
    final plan = await db.insertPlan(
      Plan(name: '计划', source: 'manual', createdAt: '2026-09-24', isActive: 1),
    );
    final dayId = await db.insertPlanDay(
      PlanDay(planId: plan.id!, weekday: 1, title: '推日'),
    );
    await db.insertPlanExercise(
      PlanExercise(
        dayId: dayId,
        name: '卧推',
        orderIdx: 0,
        sets: 3,
        repsMin: 5,
        repsMax: 8,
        restSec: 120,
        kind: 'compound',
        rule: ProgressionRule.fallback,
      ),
    );
    final s = await db.insertSession(
      Session(
        date: '2026-09-20',
        planDayTitle: '推日',
        startedAt: 1,
        endedAt: 2,
        status: 'done',
      ),
    );
    final se = await db.insertSessionExercise(
      SessionExercise(
        sessionId: s.id!,
        name: '卧推',
        orderIdx: 0,
        kind: 'compound',
        rule: ProgressionRule.fallback,
      ),
    );
    await db.insertSet(
      SetEntry(
        sessionExerciseId: se,
        weightKg: 60,
        reps: 8,
        kind: SetKind.working,
        doneAt: 1000,
        note: '状态好',
      ),
    );
    await db.upsertBodyMetric(
      const BodyMetric(date: '2026-09-21', weightKg: 70.5),
    );

    final data = await db.exportAllJson();
    final svc = ExportService(db);
    final n = await svc.restoreFromJson(data);
    expect(n, 1);

    // 清空重灌后，会话→动作→组 的外键链与计划/身体数据完整
    final sessions = await db.recentSessions(limit: 100);
    expect(sessions.length, 1);
    final ses = await db.sessionExercises(sessions.first.id!);
    expect(ses.length, 1);
    final sets = await db.setsOfSession(sessions.first.id!);
    expect(sets[ses.first.id]!.length, 1);
    expect(sets[ses.first.id]!.first.note, '状态好');
    expect((await db.allPlans()).length, 1);
    expect((await db.bodyMetrics()).length, 1);

    // 缺关键段：抛 FormatException，且在清库之前校验（现有数据不动）
    expect(() => svc.restoreFromJson({'sessions': []}), throwsFormatException);
    expect((await db.recentSessions(limit: 100)).length, 1);
  });

  // ============ 训练态计时可靠化（调研条目 1：心跳恢复 + 训练卡） ============

  Future<int> seedActiveSession(PlanDay day, String name) async {
    final s = await db.insertSession(
      Session(
        date: '2026-09-25',
        planDayId: day.id,
        planDayTitle: day.title,
        startedAt: DateTime.now().millisecondsSinceEpoch,
        status: 'active',
      ),
    );
    await db.insertSessionExercise(
      SessionExercise(
        sessionId: s.id!,
        name: name,
        orderIdx: 0,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      ),
    );
    return s.id!;
  }

  test('T-N1：训练态被杀恢复——心跳按墙钟差值接续训练时长，不再清零', () async {
    final day = await makePlanDay('腿日');
    final sid = await seedActiveSession(day, '深蹲');
    final now = DateTime.now().millisecondsSinceEpoch;
    // 模拟被杀前的最后心跳：已入桶训练 120s / 休息 30s，当前段起点在 5 分钟前
    await prefs.setInt('sess.sid', sid);
    await prefs.setInt('sess.since', now - 5 * 60000);
    await prefs.setInt('sess.phase', 0);
    await prefs.setInt('sess.restMs', 30000);
    await prefs.setInt('sess.activeMs', 120000);

    final c = makeController();
    await c.restore();
    expect(c.hasActive, isTrue);
    expect(c.phase, WorkoutPhase.lifting, reason: '无 rest.endAt 时回动作态');
    // 120000 + (now - since)：被杀的 5 分钟按墙钟差值补回（±3 秒容差）
    expect(c.activeMs, inInclusiveRange(120000 + 297000, 120000 + 303000));
    expect(c.restMs, 30000);
    expect(c.phaseSinceMs, greaterThan(0));
  });

  test('T-N2：休息态被杀恢复——漏计时长接回休息桶，相位还原为休息', () async {
    final day = await makePlanDay('推日');
    final sid = await seedActiveSession(day, '卧推');
    final now = DateTime.now().millisecondsSinceEpoch;
    await prefs.setInt('sess.sid', sid);
    await prefs.setInt('sess.since', now - 2 * 60000);
    await prefs.setInt('sess.phase', 1);
    await prefs.setInt('sess.restMs', 30000);
    await prefs.setInt('sess.activeMs', 120000);
    await prefs.setInt('rest.endAt', now + 60000);
    await prefs.setInt('rest.sessionId', sid);

    final c = makeController();
    await c.restore();
    expect(c.hasActive, isTrue);
    expect(c.phase, WorkoutPhase.resting, reason: 'restEndAt 未到期，还原休息');
    expect(c.restMs, inInclusiveRange(30000 + 117000, 30000 + 123000));
    expect(c.activeMs, 120000);
  });

  test('T-N3：无心跳数据（老版本升级）维持旧行为从零起表', () async {
    final day = await makePlanDay('日');
    await seedActiveSession(day, '动作甲');
    final c = makeController();
    await c.restore();
    expect(c.hasActive, isTrue);
    expect(c.activeMs, 0);
    expect(c.restMs, 0);
  });

  test('T-N4：相位切换时心跳落盘，结束训练清空心跳并停训练卡', () async {
    final day = await makePlanDay('日');
    final e = await addPlanEx(
      day,
      '动作甲',
      0,
      sets: 3,
      workingSets: 3,
      restSec: 120,
    );
    final c = makeController();
    final cards = <TrainingCard>[];
    c.onCardChanged = cards.add;
    await c.startFromDay(day: day, planExercises: [e]);

    expect(prefs.getInt('sess.sid'), c.session!.id, reason: '开始训练即落心跳');
    expect(prefs.getInt('sess.phase'), 0);

    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    expect(prefs.getInt('sess.phase'), 1, reason: '进休息心跳相位更新');
    expect(prefs.getInt('rest.endAt'), greaterThan(0));

    await c.finish();
    expect(prefs.getInt('sess.sid'), 0, reason: '结束清空心跳');
    expect(cards.last.active, isFalse, reason: '结束后最后一张卡为 inactive（停前台服务）');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('T-N5：训练卡内容对齐三要素（动作/目标/剩余+进度/按钮语义）', () async {
    final day = await makePlanDay('日');
    final e = await addPlanEx(
      day,
      '动作甲',
      0,
      sets: 3,
      workingSets: 3,
      restSec: 120,
    );
    final c = makeController();
    final cards = <TrainingCard>[];
    c.onCardChanged = cards.add;
    await c.startFromDay(day: day, planExercises: [e]);
    var card = cards.last;
    expect(card.active, isTrue);
    expect(card.resting, isFalse);
    expect(card.title, '动作甲', reason: '三要素之当前动作');
    expect(card.text, contains('20kg×5-8 次'), reason: '三要素之本组目标');
    expect(
      card.chronoStartMs,
      c.session!.startedAt,
      reason: '动作态走系统 chronometer（从会话开始计时）',
    );

    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    card = cards.last;
    expect(card.resting, isTrue);
    expect(card.title, '组间休息中');
    expect(
      card.remaining,
      inInclusiveRange(115, 120),
      reason: '三要素之剩余时间（进度条当前值）',
    );
    expect(card.total, inInclusiveRange(118, 122));
    expect(card.paused, isFalse);

    c.pauseRest();
    card = cards.last;
    expect(card.paused, isTrue, reason: '暂停态通知按钮切「继续」');
    expect(card.text, startsWith('已暂停'));
    c.resumeRest();
    expect(cards.last.paused, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('T-N6：空闲提醒——训练态连续超阈值触发一次，休息中断，恢复重计，可关', () async {
    final day = await makePlanDay('日');
    final e = await addPlanEx(
      day,
      '动作甲',
      0,
      sets: 3,
      workingSets: 3,
      restSec: 120,
    );
    final settings = Settings(prefs)
      ..idleNudgeEnabled = true
      ..idleNudgeMinutes = 10;
    final c = SessionController(db, settings, prefs, null);
    controllers.add(c);
    final nudges = <int>[];
    c.onIdleNudge = (minutes) async => nudges.add(minutes);
    await c.startFromDay(day: day, planExercises: [e]);
    final start = DateTime.now().millisecondsSinceEpoch;

    c.checkIdleNudge(start + 9 * 60000);
    expect(nudges, isEmpty, reason: '未到阈值不提醒');
    c.checkIdleNudge(start + 10 * 60000 + 2000);
    expect(nudges, [10], reason: '超阈值触发一次，报实际连续分钟数');
    c.checkIdleNudge(start + 20 * 60000);
    expect(nudges, [10], reason: '每段只提醒一次');

    // 休息中断：完成一组进休息，空闲计时不再走
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    expect(c.phase, WorkoutPhase.resting);
    c.checkIdleNudge(start + 30 * 60000);
    expect(nudges, [10], reason: '休息/暂停/结束不触发空闲提醒');

    // 跳过休息回到 lifting：新一段重新起算（第二段的连续分钟含真实测试
    // 耗时的秒级偏差，放宽到 41-42）
    c.skipRest();
    expect(c.phase, WorkoutPhase.lifting);
    c.checkIdleNudge(start + 30 * 60000 + 12 * 60000);
    expect(nudges.length, 2, reason: '恢复后重新连续计时并再次提醒');
    expect(nudges[1], inInclusiveRange(41, 42));

    // 关闭开关：不再提醒
    nudges.clear();
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    c.skipRest();
    settings.idleNudgeEnabled = false;
    c.checkIdleNudge(start + 60 * 60000);
    expect(nudges, isEmpty, reason: '设置关闭后不提醒');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('T-N7：休息提前跳过会取消精确提醒；自然到点不取消（双通道不漏）', () async {
    final day = await makePlanDay('日');
    final e = await addPlanEx(
      day,
      '动作甲',
      0,
      sets: 3,
      workingSets: 3,
      restSec: 120,
    );
    // 关提示音：自然到点走 SystemSound 通道，测试环境无宿主插件
    final settings = Settings(prefs)..soundOn = false;
    final c = SessionController(db, settings, prefs, null);
    controllers.add(c);
    final alarmCalls = <int?>[];
    c.onRestAlarmChanged = (endAtMs) async => alarmCalls.add(endAtMs);
    await c.startFromDay(day: day, planExercises: [e]);
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    expect(alarmCalls.last, c.restEndAt);

    c.skipRest();
    expect(alarmCalls.last, isNull, reason: '提前跳过休息：取消精确提醒');

    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    final endAt = c.restEndAt;
    expect(alarmCalls.last, endAt);
    // 模拟自然到点（不走 skipRest）：把结束时刻拨到过去，等下一次 tick 触发
    c.restEndAt -= 121000;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.phase, WorkoutPhase.lifting, reason: '到点回动作态');
    expect(alarmCalls.last, endAt, reason: '自然到点不取消闹钟：人在后台时系统提醒是唯一通道');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('T-N8：暂停态被杀恢复——冻结倒计时还原，暂停不被静默吞掉', () async {
    final day = await makePlanDay('日');
    final e = await addPlanEx(
      day,
      '动作甲',
      0,
      sets: 3,
      workingSets: 3,
      restSec: 120,
    );
    final c1 = makeController();
    await c1.startFromDay(day: day, planExercises: [e]);
    await c1.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    c1.pauseRest();
    expect(c1.isRestPaused, isTrue);
    final frozen = c1.restRemainingMs.value;
    final sid = c1.session!.id!;
    // 手动补齐被杀前的最后心跳（pauseRest 已 force 落盘一次，这里固化场景）
    await prefs.setInt('sess.sid', sid);
    await prefs.setInt(
      'sess.since',
      DateTime.now().millisecondsSinceEpoch - 10000,
    );
    await prefs.setInt('sess.phase', 1);
    await prefs.setInt('sess.restMs', 5000);
    await prefs.setInt('sess.activeMs', 90000);
    // rest.paused / rest.remainingAtPause 已由 pauseRest 落盘

    final c2 = makeController();
    final alarm2 = <int?>[];
    c2.onRestAlarmChanged = (endAtMs) async => alarm2.add(endAtMs);
    await c2.restore();
    expect(c2.phase, WorkoutPhase.resting);
    expect(c2.isRestPaused, isTrue, reason: '暂停态被杀后还原暂停，不再静默吞掉');
    expect(
      c2.restRemainingMs.value,
      closeTo(frozen, 2000),
      reason: '冻结的剩余时间原样还原',
    );
    expect(alarm2, isEmpty, reason: '暂停态恢复不挂精确闹钟');

    c2.resumeRest();
    expect(c2.isRestPaused, isFalse);
    expect(alarm2, [c2.restEndAt], reason: '用户点继续后重挂闹钟');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('T-N9：最后一个动作练满——训练卡瞬时文案不越界（无「第 4/3 组」）', () async {
    final day = await makePlanDay('日');
    final e = await addPlanEx(
      day,
      '动作甲',
      0,
      sets: 3,
      workingSets: 3,
      restSec: 120,
    );
    final c = makeController();
    final cards = <TrainingCard>[];
    c.onCardChanged = cards.add;
    await c.startFromDay(day: day, planExercises: [e]);
    // 练满 3 组：最后一次 completeSet 触发自动结束（先推卡后 finish）
    for (var i = 0; i < 3; i++) {
      await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(c.hasActive, isFalse, reason: '唯一动作练满自动结束');
    for (final card in cards) {
      if (card.active && !card.resting) {
        expect(
          card.text,
          isNot(contains('第 4/3')),
          reason: '组数封顶在本动作组数上，finish 前的瞬时推卡不越界',
        );
      }
    }
    expect(cards.last.active, isFalse, reason: '结束后最后一张卡为 inactive');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  // ---------- 调研条目 6/7/10 ----------

  test('T-B1：常亮纯函数——训练/未暂停休息常亮，暂停与空闲灭屏（条目 6）', () {
    const lifting = WorkoutPhase.lifting;
    const resting = WorkoutPhase.resting;
    const idle = WorkoutPhase.idle;
    expect(
      SessionController.shouldKeepScreenOn(
        hasActive: true,
        phase: lifting,
        restPaused: false,
      ),
      isTrue,
    );
    expect(
      SessionController.shouldKeepScreenOn(
        hasActive: true,
        phase: resting,
        restPaused: false,
      ),
      isTrue,
    );
    expect(
      SessionController.shouldKeepScreenOn(
        hasActive: true,
        phase: resting,
        restPaused: true,
      ),
      isFalse,
      reason: '暂停即灭屏：只有真在计时才耗电',
    );
    expect(
      SessionController.shouldKeepScreenOn(
        hasActive: false,
        phase: idle,
        restPaused: false,
      ),
      isFalse,
    );
    expect(
      SessionController.shouldKeepScreenOn(
        hasActive: false,
        phase: lifting,
        restPaused: false,
      ),
      isFalse,
    );
  });

  test('T-B2：休息音效四层（条目 10）——完成组进休息播 start，'
      '加时重置后重新经过窗口重播，开关关闭整体静音', () async {
    final day = await makePlanDay('日');
    final e = await addPlanEx(
      day,
      '动作甲',
      0,
      sets: 3,
      workingSets: 3,
      restSec: 120,
    );
    final c = makeController();
    final cues = <RestCue>[];
    c.onRestCue = cues.add;
    await c.startFromDay(day: day, planExercises: [e]);
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    expect(c.phase, WorkoutPhase.resting);
    expect(cues, [RestCue.start], reason: '进入休息播开始音');

    // 减时保留已播状态：剩余仍落在 start 窗口（59.75s / total 59s 量级）
    // 也不重播（去重），跳过的层不补播——半程/倒数窗口由 rest_cue_test 覆盖
    c.extendRest(-60);
    expect(cues, [RestCue.start], reason: '减时不重置已播层');

    // 加时重新获得一段等待：清层，start 重新可触发
    c.extendRest(30);
    expect(cues, [
      RestCue.start,
      RestCue.start,
    ], reason: '加时 reset 后 start 重新播一声');

    // 开关关掉：不播（结束音走 _onRestFinished 原有通道，不经此回调）
    c.skipRest();
    cues.clear();
    c.settings.restCueEnabled = false;
    await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    expect(c.phase, WorkoutPhase.resting);
    expect(cues, isEmpty, reason: '整体开关关闭时四层都不触发');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('T-B3：上次成绩行数据源（条目 7）——取上次首个正式组，'
      '重量/次数/RIR 整套可带入', () async {
    // 前置历史：动作甲 上次训练第一组 60kg×8 R2、第二组 62.5kg×7 R1
    final s0 = await db.insertSession(
      Session(
        date: '2026-09-20',
        planDayTitle: '旧训练',
        startedAt: 1,
        endedAt: 2,
        status: 'done',
      ),
    );
    final se0 = await db.insertSessionExercise(
      SessionExercise(
        sessionId: s0.id!,
        name: '动作甲',
        orderIdx: 0,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      ),
    );
    await db.insertSet(
      SetEntry(
        sessionExerciseId: se0,
        weightKg: 60,
        reps: 8,
        rir: 2,
        kind: SetKind.working,
        doneAt: 1000,
      ),
    );
    await db.insertSet(
      SetEntry(
        sessionExerciseId: se0,
        weightKg: 62.5,
        reps: 7,
        rir: 1,
        kind: SetKind.working,
        doneAt: 2000,
      ),
    );

    final day = await makePlanDay('日');
    final e = await addPlanEx(day, '动作甲', 0, workingSets: 3);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: [e]);

    final last = c.lastPerformance('动作甲');
    expect(last, isNotNull);
    expect(last!.weightKg, 60, reason: '取首个正式组（重现起点），非最后一组');
    expect(last.reps, 8);
    expect(last.rir, 2, reason: 'RIR 一并带入');

    // 无历史动作返回 null（首次训练该动作不显示上次行）
    expect(c.lastPerformance('从没练过的动作'), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  group('休息规则细化（调研条目 9）', () {
    // completeSet → _beginRestFor 有 _loadContextForCurrent().then 的悬挂续体，
    // 测试末尾统一排干（与既有测试同模式）。
    Future<void> drainContinuations() =>
        Future<void>.delayed(const Duration(milliseconds: 120));

    test('热身组不触发休息计时：留在动作态、不写 rest.endAt', () async {
      final day = await makePlanDay('日');
      final e = await addPlanEx(day, '卧推', 0, restSec: 120);
      final c = makeController();
      await c.startFromDay(day: day, planExercises: [e]);

      await c.completeSet(weight: 20, reps: 10, rir: 3, kind: SetKind.warmup);
      expect(c.phase, WorkoutPhase.lifting,
          reason: '热身组不触发休息计时（Flexify 规则）');
      expect(c.restEndAt, 0);
      expect(prefs.getInt('rest.endAt'), isNull,
          reason: '不落休息时间戳');
      expect(c.extraSetExerciseName, isNull,
          reason: '热身组不提供再来一组回退');
      await drainContinuations();
    });

    test('达标正式组（末组达次数上限）给标准休息', () async {
      final day = await makePlanDay('日');
      final e = await addPlanEx(day, '卧推', 0, restSec: 120);
      final c = makeController();
      await c.startFromDay(day: day, planExercises: [e]);

      await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      expect(c.phase, WorkoutPhase.resting);
      // reps 8 ≥ repsMax 8 → 标准档 120 秒（不放大）
      final totalSec = c.restTotalMs ~/ 1000;
      expect(totalSec, 120, reason: '达标给标准休息（动作级覆盖 120）');
      await drainContinuations();
    });

    test('未达标正式组给更长休息（×1.5 → 180 秒）', () async {
      final day = await makePlanDay('日');
      final e = await addPlanEx(day, '卧推', 0, restSec: 120);
      final c = makeController();
      await c.startFromDay(day: day, planExercises: [e]);

      await c.completeSet(weight: 60, reps: 5, rir: 1, kind: SetKind.working);
      expect(c.phase, WorkoutPhase.resting);
      // reps 5 < repsMax 8 → 120 × 1.5 = 180
      final totalSec = c.restTotalMs ~/ 1000;
      expect(totalSec, 180, reason: '未达标给更长休息（LiftLog 分档）');
      await drainContinuations();
    });

    test('逐动作覆盖优先：计划里配置的 restSec 生效于全局偏好之上', () async {
      final day = await makePlanDay('日');
      // 全局偏好默认 180/120，动作覆盖 60
      final e = await addPlanEx(day, '卧推', 0, restSec: 60);
      final c = makeController();
      await c.startFromDay(day: day, planExercises: [e]);

      await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      final totalSec = c.restTotalMs ~/ 1000;
      expect(totalSec, 60, reason: '动作级 restSec=60 覆盖全局复合 180');
      await drainContinuations();
    });

    test('未配置动作级休息时（restSec=0）按全局偏好 + 分档', () async {
      final day = await makePlanDay('日');
      final e = await addPlanEx(day, '卧推', 0, restSec: 0);
      final c = makeController();
      await c.startFromDay(day: day, planExercises: [e]);

      await c.completeSet(weight: 60, reps: 5, rir: 1, kind: SetKind.working);
      // 全局复合 180，未达标 ×1.5 = 270
      final totalSec = c.restTotalMs ~/ 1000;
      // 墙钟差按毫秒整除：极偶然差 1 秒（CI 实发 269），给容差
      expect(totalSec, inInclusiveRange(269, 270));
      await drainContinuations();
    });
  });

  group('组数显示（2026-09-26 Arono：第几组帮人记好，加练组不封顶）', () {
    test('加练态训练卡显示「第 N 组（加练）」（绝对组号），不再夹回计划组数', () async {
      final day = await makePlanDay('日');
      final a = await addPlanEx(day, '动作甲', 0, sets: 1, workingSets: 1);
      final b = await addPlanEx(day, '动作乙', 1, sets: 1, workingSets: 1);

      final c = makeController();
      await c.startFromDay(day: day, planExercises: [a, b]);
      // 计划内第 1 组
      expect(c.buildCard().text, contains('第 1/1 组'));
      await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      await c.startExtraSet(); // 回到动作甲加练
      final card = c.buildCard();
      // 2026-10-08 口径统一：绝对组号 doneRaw+1（与跳页面板/总结页一个写法）
      expect(card.text, contains('第 2 组（加练）'), reason: '加练组按绝对组号显性计数');
      expect(card.text, isNot(contains('第 2/1 组')), reason: '不出现越界组号');

      await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      await c.startExtraSet();
      expect(c.buildCard().text, contains('第 3 组（加练）'),
          reason: '第二次加练组号继续涨');
    });
  });

  group('忘停表守护截断', () {
    // completeSet 的悬挂续体排干（与休息规则组同模式）
    Future<void> drainContinuations() =>
        Future<void>.delayed(const Duration(milliseconds: 120));

    test('截到最后一条记录 +2 分钟：ended_at 与时长桶只减不增', () async {
      final day = await makePlanDay('守护日');
      final e = await addPlanEx(day, '深蹲', 0);
      final c = makeController();
      await c.startFromDay(day: day, planExercises: [e]);
      await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      await drainContinuations();
      c.skipRest(); // 回到动作态：挂机超时发生在 lifting 相位，扣 active 桶

      // 模拟"练完挂着没停表"：把这条记录的 doneAt 拨回 3 小时前，
      // 时长桶灌成虚高值（挂机段全进了 active 桶）。
      final pastDoneAt = DateTime.now().millisecondsSinceEpoch - 3 * 3600000;
      final list = c.setsByEx[c.currentEx!.id]!;
      final old = list.removeLast();
      list.add(SetEntry(
        sessionExerciseId: old.sessionExerciseId,
        weightKg: old.weightKg,
        reps: old.reps,
        rir: old.rir,
        kind: old.kind,
        doneAt: pastDoneAt,
      ));
      expect(c.lastSetDoneAtMs, pastDoneAt);
      expect(c.setCount, 1);
      c.activeMs = 200 * 60000; // 3 小时挂机 + 40 分钟训练

      c.truncateDurationToLastSet();

      final cap = pastDoneAt + 2 * 60000;
      expect(c.truncatedEndAtMs, cap);
      // 挂机段（now - cap）从 active 桶扣掉（±5 秒容差）
      final excessMs = DateTime.now().millisecondsSinceEpoch - cap;
      expect(c.activeMs, closeTo(200 * 60000 - excessMs, 5000));

      await c.finish();
      expect(c.session!.endedAt, cap);
      // 总时长收敛到 cap - startedAt（分钟级 ≈ 3h 内的最后几段，不再是 3h+）
      expect(c.session!.durationMin, lessThan(180));
    });

    test('刚记完一组（未超时）不截断', () async {
      final day = await makePlanDay('正常日');
      final e = await addPlanEx(day, '卧推', 0);
      final c = makeController();
      await c.startFromDay(day: day, planExercises: [e]);
      await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      await drainContinuations();

      c.activeMs = 30 * 60000;
      c.truncateDurationToLastSet();
      expect(c.truncatedEndAtMs, isNull); // cap >= now，不动作
      expect(c.activeMs, 30 * 60000);
      await c.finish();
      expect(c.session!.durationMin, lessThan(5)); // 正常即时结束
    });
  });

  group('超级组（v9）', () {
    test('v9-1：全程轮转 A1→B1→A2→B2→出组→丙→自动结束；休息各按所属动作', () async {
      final day = await makePlanDay('超级组日');
      final a = await addPlanEx(day, '动作甲', 0,
          sets: 2, workingSets: 2, restSec: 15, supersetTag: 'ss');
      final b = await addPlanEx(day, '动作乙', 1,
          sets: 2, workingSets: 2, restSec: 120, supersetTag: 'ss');
      final c3 = await addPlanEx(day, '动作丙', 2,
          sets: 1, workingSets: 1, restSec: 90);

      final c = makeController();
      await c.startFromDay(day: day, planExercises: [a, b, c3]);
      expect(
          c.exercises.map((e) => e.supersetTag), ['ss', 'ss', ''],
          reason: '超级组标记快照进会话动作行');

      // A1：切到 B，休息按 A 的 15s（转换休息）
      await c.completeSet(weight: 50, reps: 8, rir: 2, kind: SetKind.working);
      expect(c.phase, WorkoutPhase.resting);
      expect(c.curExIdx, 1, reason: 'A1 后轮转到 B');
      expect(c.restTotalMs, closeTo(15000, 1500), reason: '转换休息用 A 的 restSec');
      c.skipRest();
      expect(c.phase, WorkoutPhase.lifting);

      // B1：切回 A，休息按 B 的 120s（轮末完整休息）
      await c.completeSet(weight: 80, reps: 8, rir: 2, kind: SetKind.working);
      expect(c.curExIdx, 0, reason: 'B1 后轮转回 A');
      expect(c.restTotalMs, closeTo(120000, 1500));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.weightDraft, 50,
          reason: 'A2 接 A1 的实际重量，不被 B 的上下文覆盖');
      c.skipRest();

      // A2：A 练满 → 轮转到还有剩余组的 B（不是线性进丙）
      await c.completeSet(weight: 50, reps: 8, rir: 2, kind: SetKind.working);
      expect(c.curExIdx, 1, reason: 'A 练满后仍在组内轮转到 B');
      c.skipRest();

      // B2：组内全满 → 出组到丙
      await c.completeSet(weight: 80, reps: 8, rir: 2, kind: SetKind.working);
      expect(c.curExIdx, 2, reason: '超级组完成出组到丙');
      c.skipRest();

      // 丙完成：全部结束
      await c.completeSet(weight: 40, reps: 8, rir: 2, kind: SetKind.working);
      expect(c.hasActive, isFalse, reason: '最后一个动作完成自动结束会话');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    test('v9-2：撤销删全局最后一组并切回所属动作（轮转下当前动作≠刚记录动作）', () async {
      final day = await makePlanDay('超级组日');
      final a = await addPlanEx(day, '动作甲', 0, workingSets: 3, supersetTag: 'ss');
      final b = await addPlanEx(day, '动作乙', 1, workingSets: 3, supersetTag: 'ss');

      final c = makeController();
      await c.startFromDay(day: day, planExercises: [a, b]);
      await c.completeSet(weight: 50, reps: 8, rir: 2, kind: SetKind.working);
      expect(c.curExIdx, 1, reason: 'A1 后已轮转到 B（休息中）');
      c.skipRest();

      // 当前动作是乙，但最后一组是甲的 → 撤销必须删甲的组并回到甲
      await c.undoLastSet();
      expect(c.curExIdx, 0, reason: '撤销 A1 回到动作甲');
      expect(c.workingSetsDone, 0);
      expect((c.setsByEx[c.exercises[0].id] ?? const []).length, 0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    test('v9-3：被杀恢复落在轮转序列的下一个动作', () async {
      final day = await makePlanDay('超级组日');
      final a = await addPlanEx(day, '动作甲', 0, workingSets: 3, supersetTag: 'ss');
      final b = await addPlanEx(day, '动作乙', 1, workingSets: 3, supersetTag: 'ss');

      final c = makeController();
      await c.startFromDay(day: day, planExercises: [a, b]);
      await c.completeSet(weight: 50, reps: 8, rir: 2, kind: SetKind.working);
      c.skipRest();
      await c.completeSet(weight: 80, reps: 8, rir: 2, kind: SetKind.working);
      c.skipRest();
      expect(c.curExIdx, 0, reason: 'A1B1 后轮到 A2');

      // 模拟进程重启：新控制器从库恢复
      final c2 = makeController();
      await c2.restore();
      expect(c2.hasActive, isTrue);
      expect(c2.curExIdx, 0, reason: '恢复落点 = 轮转序列的下一个（A2）');
      expect(c2.workingSetsDone, 1, reason: '动作甲已完成 1 组');
      expect(c2.exercises.map((e) => e.supersetTag), ['ss', 'ss']);
    });
  });

  group('临时训练 startAdHoc（2026-09-29 出差场景）', () {
    test('开临时会话：plan_day_id 落 null、标题带出、记组/自动结束全链路正常', () async {
      final day = await makePlanDay('正课日');
      final a = await addPlanEx(day, '动作甲', 0, workingSets: 1);

      final c = makeController();
      await c.startAdHoc(
        title: '酒店全身练',
        planExercises: [a.copyWith(supersetTag: '')],
      );
      expect(c.hasActive, isTrue);
      expect(c.session!.planDayId, isNull, reason: '临时训练不挂模板日');
      expect(c.session!.planDayTitle, '酒店全身练');
      expect(c.exercises.length, 1);

      // 记满自动结束（1 组计划）
      await c.completeSet(weight: 40, reps: 8, rir: 2, kind: SetKind.working);
      expect(c.hasActive, isFalse, reason: '临时训练照常自动结束');
      final raw = await rawDb.rawQuery(
          'SELECT plan_day_id, plan_day_title FROM sessions WHERE id = ?',
          [c.session!.id]);
      expect(raw.first['plan_day_id'], isNull);
      expect(raw.first['plan_day_title'], '酒店全身练');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    test('普通开练仍挂模板日（回归）', () async {
      final day = await makePlanDay('普通日');
      final a = await addPlanEx(day, '动作甲', 0, workingSets: 1);
      final c = makeController();
      await c.startFromDay(day: day, planExercises: [a]);
      expect(c.session!.planDayId, day.id, reason: '普通开练仍挂模板日');
      await c.completeSet(weight: 40, reps: 8, rir: 2, kind: SetKind.working);
      expect(c.hasActive, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });

  group('结束确认（2026-10-07：最后一组完成先问「现在结束吗」）', () {
    // completeSet → _beginRestFor 的悬挂续体排干（与休息规则组同模式）
    Future<void> drainContinuations() =>
        Future<void>.delayed(const Duration(milliseconds: 120));

    test('回调返回 false：唯一动作练满不自动结束，落加练态休息页；每组再问；改 true 后落库 done', () async {
      final day = await makePlanDay('日');
      final e = await addPlanEx(day, '动作甲', 0, workingSets: 2);
      final c = makeController();
      await c.startFromDay(day: day, planExercises: [e]);

      var calls = 0;
      var answer = false;
      c.confirmAutoFinish = () async {
        calls++;
        return answer;
      };

      // 计划内前 1 组：推进语义不变，不触发确认
      await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      expect(calls, 0, reason: '未到最后一组不问');
      // 第 2 组完成 = 唯一动作练满：回答「继续训练」→ 不结束，起休息页
      await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      expect(calls, 1);
      expect(c.hasActive, isTrue, reason: '回答「继续训练」不清场');
      expect(c.phase, WorkoutPhase.resting, reason: '按原推进语义起休息页');
      expect(c.extraSetExerciseName, '动作甲',
          reason: '休息页给出「再来一组」入口');

      // 加练 1 组（休息页「再来一组」路径）：再次触发确认（每组再问）
      await c.startExtraSet();
      await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      expect(calls, 2, reason: '加练组完成同样要问');
      expect(c.hasActive, isTrue);

      // 改回答「结束并保存」：下一组完成即按原收尾落库 done
      answer = true;
      await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      expect(calls, 3);
      expect(c.hasActive, isFalse);
      expect(c.session!.status, 'done');
      await drainContinuations();
    });

    test('跳着做：末位动作练满即触发确认，剩余组数 = 前面未做动作的组（WorkoutFlow 口径）', () async {
      final day = await makePlanDay('日');
      final a = await addPlanEx(day, '动作甲', 0, workingSets: 2);
      final b = await addPlanEx(day, '动作乙', 1, workingSets: 1);
      final c = makeController();
      await c.startFromDay(day: day, planExercises: [a, b]);

      var calls = 0;
      c.confirmAutoFinish = () async {
        calls++;
        return true;
      };

      // 跳过动作甲（页面流「跳过动作」的控制器入口），直接做末位动作
      final jumped = await c.jumpToExercise(1);
      expect(jumped, isTrue);
      await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      expect(calls, 1, reason: '末位动作练满即触发收尾确认（甲一组没做也问）');
      expect(c.hasActive, isFalse, reason: '回答结束 → 落库 done');
      expect(c.session!.status, 'done');

      // 『还剩 N 组』提示的数据源（UI 面板同口径）：甲 2 组未做
      final flow = WorkoutFlow(exercises: c.exercises, setsByEx: c.setsByEx);
      expect(flow.totalPlannedSets, 3);
      expect(flow.donePlannedSets, 1);
      expect(flow.totalPlannedSets - flow.donePlannedSets, 2);
      await drainContinuations();
    });

    test('回调 null（默认）保持原自动结束语义——回归锚点', () async {
      final day = await makePlanDay('日');
      final e = await addPlanEx(day, '动作甲', 0, workingSets: 1);
      final c = makeController();
      expect(c.confirmAutoFinish, isNull);
      await c.startFromDay(day: day, planExercises: [e]);
      await c.completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      expect(c.hasActive, isFalse, reason: '未接线时维持旧行为：练满即自动结束');
      expect(c.session!.status, 'done');
      await drainContinuations();
    });
  });
}
