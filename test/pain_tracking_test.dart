// P2-B 疼痛与不适标记：安全底线的回归锁。
// 覆盖：
//  - DB round-trip：pain_level/pain_area 写入读出；老行/缺键回默认 0/''；
//  - 控制器接线：completeSet 把疼痛随组落库（0 级时部位一并清空）；
//  - 导出链路：CSV / 全量 JSON / AI 数据包都带疼痛字段；
//  - 历史页：有标记的动作多一列 + 疼痛摘要，没标记的动作不加列。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/services/export_service.dart';
import 'package:baoji_timer/services/session_controller.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:baoji_timer/ui/history_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('baoji/focus'), (call) async => null);
  });

  late Db db;

  setUp(() async {
    // 微秒时间戳唯一路径 = 每个测试独立数据库（ffi 对同路径会复用连接）
    final dir = await databaseFactory.getDatabasesPath();
    final path =
        '$dir/test_pain_${DateTime.now().microsecondsSinceEpoch}.db';
    final rawDb = await databaseFactory.openDatabase(path);
    await Db.instance.createSchema(rawDb);
    db = Db.forTesting(rawDb);
  });

  tearDown(() async {
    await db.wipeAll();
  });

  Future<(Session, int)> seedSession() async {
    final now = DateTime.now();
    final s = await db.insertSession(Session(
      date: fmtDate(now),
      planDayTitle: '推日',
      startedAt: now.millisecondsSinceEpoch - 3600000,
      endedAt: now.millisecondsSinceEpoch,
      status: 'done',
    ));
    final se = await db.insertSessionExercise(SessionExercise(
      sessionId: s.id!,
      name: '杠铃卧推',
      orderIdx: 0,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8),
    ));
    return (s, se);
  }

  group('DB round-trip', () {
    test('疼痛等级/部位写入后原样读出；hasPain 随等级变化', () async {
      final (_, se) = await seedSession();
      await db.insertSet(SetEntry(
        sessionExerciseId: se,
        weightKg: 60,
        reps: 8,
        rir: 2,
        kind: SetKind.working,
        doneAt: 1000,
        painLevel: 2,
        painArea: PainArea.shoulder,
      ));
      final sets = await db.setsOfExercise(se);
      expect(sets, hasLength(1));
      expect(sets.single.painLevel, 2);
      expect(sets.single.painArea, '肩');
      expect(sets.single.hasPain, isTrue);
    });

    test('未填疼痛默认 0/空串（老行、老备份缺键同口径）', () async {
      final (_, se) = await seedSession();
      await db.insertSet(SetEntry(
        sessionExerciseId: se,
        weightKg: 60,
        reps: 8,
        rir: 2,
        kind: SetKind.working,
        doneAt: 1000,
      ));
      final sets = await db.setsOfExercise(se);
      expect(sets.single.painLevel, 0);
      expect(sets.single.painArea, '');
      expect(sets.single.hasPain, isFalse);

      // 老备份缺两列：fromMap 回默认，不抛
      final old = SetEntry.fromMap({
        'session_exercise_id': se,
        'weight_kg': 60,
        'reps': 8,
        'rir': 2,
        'kind': SetKind.working,
        'done_at': 1000,
      });
      expect(old.painLevel, 0);
      expect(old.painArea, '');
    });
  });

  test('SessionController.completeSet 把疼痛随组落库；0 级时部位一并清空',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = SessionController(db, Settings(prefs), prefs, null);
    addTearDown(c.dispose);

    final plan = await db.insertPlan(Plan(
      name: '疼痛测试',
      source: 'manual',
      createdAt: fmtDate(DateTime.now()),
      isActive: 1,
    ));
    final dayId = await db.insertPlanDay(PlanDay(
      planId: plan.id!,
      weekday: DateTime.now().weekday,
      title: '推日',
    ));
    final day = PlanDay(
      id: dayId,
      planId: plan.id!,
      weekday: DateTime.now().weekday,
      title: '推日',
    );
    final pe = PlanExercise(
      dayId: dayId,
      name: '杠铃卧推',
      orderIdx: 0,
      sets: 3,
      repsMin: 5,
      repsMax: 8,
      restSec: 120,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
    );
    final saved = pe.copyWith(id: await db.insertPlanExercise(pe));
    await c.startFromDay(day: day, planExercises: [saved]);
    expect(c.hasActive, isTrue);

    await c.completeSet(
      weight: 60,
      reps: 8,
      rir: 2,
      kind: SetKind.working,
      painLevel: 3,
      painArea: PainArea.knee,
    );
    // 0 级不该带部位（脏数据防线）
    await c.completeSet(
      weight: 60,
      reps: 8,
      rir: 2,
      kind: SetKind.working,
      painLevel: 0,
      painArea: PainArea.knee,
    );

    final sets = await db.setsOfExercise(c.exercises.first.id!);
    expect(sets, hasLength(2));
    expect(sets[0].painLevel, 3);
    expect(sets[0].painArea, '膝');
    expect(sets[1].painLevel, 0);
    expect(sets[1].painArea, '');
  });

  test('CSV / 全量 JSON / AI 数据包都带疼痛字段', () async {
    final (_, se) = await seedSession();
    await db.insertSet(SetEntry(
      sessionExerciseId: se,
      weightKg: 60,
      reps: 8,
      rir: 2,
      kind: SetKind.working,
      doneAt: 1000,
      painLevel: 2,
      painArea: PainArea.shoulder,
    ));
    await db.insertSet(SetEntry(
      sessionExerciseId: se,
      weightKg: 60,
      reps: 8,
      rir: 2,
      kind: SetKind.working,
      doneAt: 2000,
    ));
    final svc = ExportService(db);

    // CSV：表头两列在 rir_recorded 之后；行里等级与部位（部位带引号转义）
    final csv = await svc.buildCsv();
    final lines = csv.trim().split('\n');
    expect(lines.first, endsWith(',rir_recorded,pain_level,pain_area'));
    final cols = lines.first.split(',');
    final levelIdx = cols.indexOf('pain_level');
    final areaIdx = cols.indexOf('pain_area');
    final rows = lines.skip(1).toList();
    expect(rows, hasLength(2));
    expect(rows[0].split(',')[levelIdx], '2');
    expect(rows[0].split(',')[areaIdx], '"肩"');
    expect(rows[1].split(',')[levelIdx], '0');
    expect(rows[1].split(',')[areaIdx], '""');

    // 全量 JSON：sets 表原列直出
    final json = await svc.buildJson();
    expect(json, contains('"pain_level": 2'));
    expect(json, contains('"pain_area": "肩"'));

    // AI 数据包：明细里能看到、单列疼痛汇总段、原始 JSON 段带字段
    final ai = await svc.buildAiData();
    expect(ai, contains('·痛肩2级'));
    expect(ai, contains('## 疼痛记录'));
    expect(ai, contains('肩 2 级 ×1 组'));
    expect(ai, contains('"pain_level":2'));
    expect(ai, contains('"pain_area":"肩"'));
  });

  testWidgets('历史页：有疼痛的动作多一列并带摘要，无疼痛动作不加列',
      (tester) async {
    final withPain = SessionExercise(
      sessionId: 1,
      name: '杠铃卧推',
      orderIdx: 0,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
    ).copyWithId(7);
    final noPain = SessionExercise(
      sessionId: 1,
      name: '杠铃划船',
      orderIdx: 1,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
    ).copyWithId(8);
    const s = Session(
      id: 1,
      date: '2026-10-18',
      planDayTitle: '推日',
      startedAt: 1000,
      endedAt: 2000,
      status: 'done',
    );
    final rows = buildSessionDetailRows(s, [withPain, noPain], {
      7: const [
        SetEntry(
          sessionExerciseId: 7,
          weightKg: 60,
          reps: 8,
          rir: 2,
          kind: SetKind.working,
          doneAt: 1100,
          painLevel: 2,
          painArea: PainArea.shoulder,
        ),
        SetEntry(
          sessionExerciseId: 7,
          weightKg: 60,
          reps: 8,
          rir: 2,
          kind: SetKind.working,
          doneAt: 1200,
        ),
      ],
      8: const [
        SetEntry(
          sessionExerciseId: 8,
          weightKg: 50,
          reps: 8,
          rir: 2,
          kind: SetKind.working,
          doneAt: 1300,
        ),
      ],
    }, bodyWeightKg: 70);

    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ListView(children: rows)),
    ));
    await tester.pump();

    // 摘要一行：部位 + 等级 + 组数
    expect(find.textContaining('疼痛：肩 2 级 ×1 组'), findsOneWidget);
    // 表头：疼痛列只出现在有标记的动作表里
    expect(find.text('疼痛'), findsOneWidget);
    expect(find.text('肩 2 级'), findsOneWidget);
    final tables = tester.widgetList<Table>(find.byType(Table)).toList();
    expect(tables, hasLength(2));
    expect(tables[0].columnWidths!.length, 5, reason: '有疼痛：组/重量/次数/余力/疼痛');
    expect(tables[1].columnWidths!.length, 4, reason: '无疼痛：保持原四列');
  });
}
