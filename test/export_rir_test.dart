// P0-C RIR 真实性：导出链路必须带上 rir_recorded，外部工具/AI 才能
// 区分「用户点过的余力」与「计划默认填充值」。
//  - CSV：末列 rir_recorded（不挤动既有 11 列顺序）
//  - 全量 JSON：sets 表原有列直出
//  - AI 数据包：原始 JSON 段每组带 rir_recorded
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/services/export_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Db db;

  setUp(() async {
    // 微秒时间戳唯一路径 = 每个测试独立数据库（ffi 对同路径会复用连接）
    final dir = await databaseFactory.getDatabasesPath();
    final path =
        '$dir/test_export_rir_${DateTime.now().microsecondsSinceEpoch}.db';
    final rawDb = await databaseFactory.openDatabase(path);
    await Db.instance.createSchema(rawDb);
    db = Db.forTesting(rawDb);
  });

  tearDown(() async {
    await db.wipeAll();
  });

  Future<void> seed() async {
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
    // 第一组：用户真的点过余力（RIR 1）；第二组：没点，按计划默认 RIR 2。
    await db.insertSet(SetEntry(
      sessionExerciseId: se,
      weightKg: 60,
      reps: 8,
      rir: 1,
      kind: SetKind.working,
      doneAt: now.millisecondsSinceEpoch - 600000,
    ));
    await db.insertSet(SetEntry(
      sessionExerciseId: se,
      weightKg: 60,
      reps: 8,
      rir: 2,
      kind: SetKind.working,
      doneAt: now.millisecondsSinceEpoch - 300000,
      rirRecorded: false,
    ));
  }

  test('AI 数据包：同义名的累计容量按稳定键合并成一行', () async {
    Future<void> addSession(String date, String name) async {
      final s = await db.insertSession(Session(
        date: date,
        planDayTitle: '推日',
        startedAt: 1000,
        endedAt: 2000,
        status: 'done',
      ));
      final se = await db.insertSessionExercise(SessionExercise(
        sessionId: s.id!,
        name: name,
        orderIdx: 0,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8),
      ));
      await db.insertSet(SetEntry(
        sessionExerciseId: se,
        weightKg: 60,
        reps: 8,
        kind: SetKind.working,
        doneAt: 1500,
      ));
    }

    await addSession('2026-10-17', '杠铃卧推');
    await addSession('2026-10-18', '平板卧推');
    final ai = await ExportService(db).buildAiData();
    final section = ai
        .split('## 各动作累计容量（kg）')
        .last
        .split('## 身体数据')
        .first;
    final bullets =
        section.split('\n').where((l) => l.startsWith('- ')).toList();
    expect(bullets, hasLength(1), reason: '两个同义名合并成一个动作');
    expect(bullets.single, contains('杠铃卧推'));
    expect(bullets.single, isNot(contains('平板卧推')));
    expect(bullets.single, contains('960'), reason: '两场 60×8 容量相加');
  });

  test('AI 数据包：不同身份共用展示名时不被并成一桶', () async {
    Future<void> add(String date, String key) async {
      final s = await db.insertSession(Session(
        date: date,
        planDayTitle: '推日',
        startedAt: 1000,
        endedAt: 2000,
        status: 'done',
      ));
      final se = await db.insertSessionExercise(SessionExercise(
        sessionId: s.id!,
        name: '杠铃卧推',
        orderIdx: 0,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8),
        exerciseKey: key,
      ));
      await db.insertSet(SetEntry(
        sessionExerciseId: se,
        weightKg: 60,
        reps: 8,
        kind: SetKind.working,
        doneAt: 1500,
      ));
    }

    await add('2026-10-17', '杠铃卧推');
    await add('2026-10-18', 'barbell_bench_press');
    final ai = await ExportService(db).buildAiData();
    final section = ai
        .split('## 各动作累计容量（kg）')
        .last
        .split('## 身体数据')
        .first;
    final bullets =
        section.split('\n').where((l) => l.startsWith('- ')).toList();
    expect(bullets, hasLength(2),
        reason: '两个身份键不能因为展示名相同而合并');
    expect(bullets.any((l) => l.contains('杠铃卧推·barbell_bench_press')),
        isTrue,
        reason: '展示名冲突时用键后缀区分');
  });

  test('CSV / 全量 JSON / AI 数据包都带 rir_recorded', () async {
    await seed();
    final svc = ExportService(db);

    final csv = await svc.buildCsv();
    final lines = csv.trim().split('\n');
    final cols = lines.first.split(',');
    expect(cols, contains('rir_recorded'), reason: 'CSV 带 rir_recorded 列');
    // P2-B 起疼痛两列追加在 rir_recorded 之后（不挤动既有列序）
    expect(lines.first, endsWith(',rir_recorded,pain_level,pain_area'));
    final rirIdx = cols.indexOf('rir_recorded');
    final rows = lines.skip(1).toList();
    expect(rows, hasLength(2));
    expect(rows[0].split(',')[rirIdx], '1', reason: '第一组已记录');
    expect(rows[1].split(',')[rirIdx], '0', reason: '第二组未记录');

    final json = await svc.buildJson();
    expect(json, contains('"rir_recorded": 1'));
    expect(json, contains('"rir_recorded": 0'));

    final ai = await svc.buildAiData();
    expect(ai, contains('"rir_recorded":1'));
    expect(ai, contains('"rir_recorded":0'));
  });
}
