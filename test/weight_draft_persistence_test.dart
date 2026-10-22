// 手调重量跨进程保留（2026-10-22 Arono 报障）：深蹲处方 60kg，用户手改
// 30kg 记了一组；切到别的 App 再回来（进程被杀 → restore）下一组弹回 60kg。
// 覆盖：草稿落盘/防抖、恢复优先级、记组同步、多动作隔离、撤销回落、
// 热身组同规则、会话结束清理。
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
    final path =
        '$dir/test_draft_${DateTime.now().microsecondsSinceEpoch}.db';
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

  /// 模拟 Android 回收进程：旧控制器释放，数据库里的 active 会话还在。
  void kill(SessionController c) {
    controllers.remove(c);
    c.dispose();
  }

  String draftKeyOf(SessionController c) {
    final ex = c.currentEx!;
    return 'sess.draft.${exerciseIdentityKeyOf(ex.name, ex.exerciseKey)}';
  }

  Future<PlanDay> makePlanDay(String title) async {
    final plan = await db.insertPlan(
      Plan(
        name: '测试计划-$title',
        source: 'manual',
        createdAt: '2026-10-22',
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
    int workingSets = 3,
  }) async {
    final pe = PlanExercise(
      dayId: day.id!,
      name: name,
      orderIdx: order,
      sets: workingSets,
      repsMin: 5,
      repsMax: 8,
      restSec: 120,
      kind: 'compound',
      rule: ProgressionRule(
        repsMin: 5,
        repsMax: 8,
        workingSets: workingSets,
      ),
    );
    final id = await db.insertPlanExercise(pe);
    return pe.copyWith(id: id);
  }

  /// 前置历史：昨天深蹲 60kg×7×3 组（区间内未顶格 → 下次处方仍是 60kg）。
  Future<void> seedHistory(String name) async {
    final s = await db.insertSession(
      Session(
        date: fmtDate(DateTime.now().subtract(const Duration(days: 1))),
        planDayTitle: '旧训练',
        startedAt: 1,
        endedAt: 2,
        status: 'done',
      ),
    );
    final seId = await db.insertSessionExercise(
      SessionExercise(
        sessionId: s.id!,
        name: name,
        orderIdx: 0,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await db.insertSet(
        SetEntry(
          sessionExerciseId: seId,
          weightKg: 60,
          reps: 7,
          rir: 2,
          kind: SetKind.working,
          doneAt: 1000 + i,
        ),
      );
    }
  }

  test('手改 30kg 切后台（进程被杀）后 restore 仍是 30，不弹回处方 60', () async {
    await seedHistory('深蹲');
    final day = await makePlanDay('腿日');
    final e = await addPlanEx(day, '深蹲', 0);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: [e]);
    expect(c.weightDraft, 60, reason: '历史 60kg×7 的处方仍是 60kg');

    c.setWeightDraft(30);
    // 用户没记组就切到别的 App：生命周期回调立即落盘，不等 300ms 防抖。
    c.setForeground(false);
    expect(prefs.getDouble(draftKeyOf(c)), 30);

    kill(c);
    final c2 = makeController();
    await c2.restore();
    expect(c2.hasActive, isTrue);
    expect(c2.weightDraft, 30, reason: '手改草稿优先于处方 60kg');
  });

  test('连续点按合并落盘：首个改动立即写，尾值切后台补写', () async {
    await seedHistory('深蹲');
    final day = await makePlanDay('腿日');
    final e = await addPlanEx(day, '深蹲', 0);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: [e]);

    c.setWeightDraft(30);
    expect(prefs.getDouble(draftKeyOf(c)), 30, reason: '首个改动立即落盘');
    c.setWeightDraft(32.5);
    c.setWeightDraft(35);
    expect(
      prefs.getDouble(draftKeyOf(c)),
      30,
      reason: '300ms 内的连续点按合并，不逐次写盘',
    );
    c.setForeground(false);
    expect(prefs.getDouble(draftKeyOf(c)), 35, reason: '切后台补写最终值');

    kill(c);
    final c2 = makeController();
    await c2.restore();
    expect(c2.weightDraft, 35);
  });

  test('记一组 30kg 后草稿同步 30；进程被杀恢复下一组仍是 30', () async {
    await seedHistory('深蹲');
    final day = await makePlanDay('腿日');
    final e = await addPlanEx(day, '深蹲', 0);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: [e]);

    c.setWeightDraft(30);
    await c.completeSet(weight: 30, reps: 8, rir: 2, kind: SetKind.working);
    expect(c.weightDraft, 30, reason: '休息页下一组接刚记的 30kg');
    expect(prefs.getDouble(draftKeyOf(c)), 30, reason: '记组后草稿立即落盘');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    kill(c);
    final c2 = makeController();
    await c2.restore();
    expect(c2.weightDraft, 30, reason: '恢复后下一组仍是 30kg，不弹回 60');
    c2.skipRest();
    expect(c2.weightDraft, 30);
  });

  test('两个动作的草稿互不污染，恢复/切换各取各的', () async {
    final day = await makePlanDay('日');
    final a = await addPlanEx(day, '动作甲', 0, workingSets: 2);
    final b = await addPlanEx(day, '动作乙', 1, workingSets: 2);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: [a, b]);
    expect(c.weightDraft, presetStartOf('动作甲'));

    c.setWeightDraft(30);
    c.setForeground(false);
    await c.skipExercise();
    expect(c.curExIdx, 1);
    expect(
      c.weightDraft,
      presetStartOf('动作乙'),
      reason: 'B 不继承 A 手改的 30kg',
    );

    c.setWeightDraft(45);
    c.setForeground(false);
    await c.jumpToExercise(0);
    expect(c.weightDraft, 30, reason: '回到 A 用 A 自己的草稿');
    await c.jumpToExercise(1);
    expect(c.weightDraft, 45, reason: '回到 B 用 B 自己的草稿');

    // 进程被杀：无任何已记录组，恢复落在第一个动作 A。
    kill(c);
    final c2 = makeController();
    await c2.restore();
    expect(c2.curExIdx, 0);
    expect(c2.weightDraft, 30);
    await c2.jumpToExercise(1);
    expect(c2.weightDraft, 45, reason: 'B 的草稿独立保留');
  });

  test('撤销组后草稿回落到剩余最后一组；全撤完回推荐值', () async {
    await seedHistory('深蹲');
    final day = await makePlanDay('腿日');
    final e = await addPlanEx(day, '深蹲', 0, workingSets: 4);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: [e]);

    c.setWeightDraft(30);
    await c.completeSet(weight: 30, reps: 8, rir: 2, kind: SetKind.working);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    c.skipRest();
    c.setWeightDraft(50);
    await c.completeSet(weight: 50, reps: 8, rir: 2, kind: SetKind.working);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(prefs.getDouble(draftKeyOf(c)), 50);

    await c.undoLastSet();
    expect(c.currentSets.length, 1);
    expect(c.weightDraft, 30, reason: '回落到剩余最后一组的 30kg');
    expect(
      prefs.getDouble(draftKeyOf(c)),
      30,
      reason: '草稿一起回落，重启不会复活被撤销的 50kg',
    );

    await c.undoLastSet();
    expect(c.currentSets, isEmpty);
    expect(c.weightDraft, 60, reason: '没有剩余组时回推荐值');
    expect(prefs.getDouble(draftKeyOf(c)), 60);
  });

  test('热身组同样同步草稿，恢复后仍是热身重量', () async {
    await seedHistory('深蹲');
    final day = await makePlanDay('腿日');
    final e = await addPlanEx(day, '深蹲', 0);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: [e]);

    c.setWeightDraft(25);
    await c.completeSet(weight: 25, reps: 10, rir: 4, kind: SetKind.warmup);
    expect(c.phase, WorkoutPhase.lifting, reason: '热身组不触发休息');
    expect(c.weightDraft, 25);
    expect(prefs.getDouble(draftKeyOf(c)), 25);

    kill(c);
    final c2 = makeController();
    await c2.restore();
    expect(c2.weightDraft, 25);
  });

  test('会话结束清理草稿，下一场不继承', () async {
    await seedHistory('深蹲');
    final day = await makePlanDay('腿日');
    final e = await addPlanEx(day, '深蹲', 0);
    final c = makeController();
    await c.startFromDay(day: day, planExercises: [e]);

    c.setWeightDraft(30);
    c.setForeground(false);
    expect(prefs.getDouble(draftKeyOf(c)), 30);

    await c.finish();
    expect(
      prefs.getKeys().where((k) => k.startsWith('sess.draft.')),
      isEmpty,
      reason: '会话结束清空本场草稿',
    );

    final c2 = makeController();
    await c2.startFromDay(day: day, planExercises: [e]);
    expect(
      c2.weightDraft,
      presetStartOf('深蹲'),
      reason: '下一场不继承 30kg（本场没记组，回到内置起始重量）',
    );
  });
}
