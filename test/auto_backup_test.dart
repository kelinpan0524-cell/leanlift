// P0-A 自动备份回归：全量快照、轮转口径（7 日内 + 4 周内）、
// 启动 24 小时补档、以及「从最近自动备份恢复」的预览计数与恢复结果。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/models/models.dart';
import 'package:baoji_timer/services/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 导出可被闸门卡住的测试库：模拟「全库导出耗时较长」，
/// 让 deleteAll/预约快照能精确地插进补档的导出中途。
class _GatedDb extends Db {
  _GatedDb(super.rawDb) : super.forTesting();

  /// 非 null 时 exportAllJson 先等它完成，再真正读库。
  Completer<void>? exportGate;

  @override
  Future<Map<String, dynamic>> exportAllJson() async {
    final gate = exportGate;
    if (gate != null) await gate.future;
    return super.exportAllJson();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Db db;
  late Database rawDb;
  late String dbPath;
  late Directory tempRoot;
  late AutoBackupService service;

  setUp(() async {
    final dir = await databaseFactory.getDatabasesPath();
    dbPath =
        '$dir/test_auto_backup_${DateTime.now().microsecondsSinceEpoch}.db';
    rawDb = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(rawDb);
    db = Db.forTesting(rawDb);
    tempRoot = await Directory.systemTemp.createTemp('leanlift_auto_backup_');
    service = AutoBackupService(db, directoryProvider: () async => tempRoot);
  });

  tearDown(() async {
    try {
      await rawDb.close();
    } catch (_) {}
    try {
      await databaseFactory.deleteDatabase(dbPath);
    } catch (_) {}
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Future<void> seedWorkout() async {
    final plan = await db.insertPlan(
      const Plan(name: '测试计划', source: 'manual', createdAt: '2026-10-17'),
    );
    final dayId = await db.insertPlanDay(
      PlanDay(planId: plan.id!, weekday: 6, title: '推日'),
    );
    final ses = await db.insertSession(
      Session(
        date: '2026-10-17',
        planDayId: dayId,
        planDayTitle: '推日',
        startedAt: DateTime(2026, 10, 17, 10).millisecondsSinceEpoch,
        endedAt: DateTime(2026, 10, 17, 11).millisecondsSinceEpoch,
        status: 'done',
      ),
    );
    final seId = await db.insertSessionExercise(
      SessionExercise(
        sessionId: ses.id!,
        name: '卧推',
        orderIdx: 0,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      ),
    );
    for (final weight in [60.0, 62.5]) {
      await db.insertSet(
        SetEntry(
          sessionExerciseId: seId,
          weightKg: weight,
          reps: 8,
          kind: SetKind.working,
          doneAt: DateTime(2026, 10, 17, 10, 30).millisecondsSinceEpoch,
        ),
      );
    }
  }

  int ms(int y, int m, int d, [int h = 0, int min = 0]) =>
      DateTime(y, m, d, h, min).millisecondsSinceEpoch;

  test('快照是全量 JSON；预览计数正确；可从最近自动备份恢复', () async {
    await seedWorkout();
    // 追加一条放弃的会话：它会进全量 JSON，但预览里的「训练次数」不算它。
    await db.insertSession(
      Session(
        date: '2026-10-16',
        planDayTitle: '未完成',
        startedAt: DateTime(2026, 10, 16, 10).millisecondsSinceEpoch,
        endedAt: DateTime(2026, 10, 16, 10, 20).millisecondsSinceEpoch,
        status: 'quit',
      ),
    );
    final fixed = DateTime(2026, 10, 17, 12, 0);
    final info = await service.snapshotNow(at: fixed);

    expect(await info.file.exists(), isTrue);
    expect(info.createdAt, fixed);
    final text = await info.file.readAsString();
    final raw = jsonDecode(text) as Map<String, dynamic>;
    expect(text, jsonEncode(raw), reason: '自动快照用紧凑 JSON（无换行缩进）');
    expect((raw['plans'] as List).length, 1);
    expect((raw['sessions'] as List).length, 2);
    expect((raw['sets'] as List).length, 2);

    // 模拟误清/换数据后从最近自动备份恢复。
    await db.wipeAll();
    expect(await db.recentSessions(limit: 10), isEmpty);

    final latest = await service.latestBackup();
    expect(latest, isNotNull);
    expect(latest!.file.path, info.file.path);

    final preview = await service.preview(latest);
    expect(preview.sessions, 1);
    expect(preview.plans, 1);
    expect(preview.sets, 2);
    expect(preview.bodyMetrics, 0);

    final n = await service.restore(latest);
    expect(n, 2, reason: '恢复返回全部会话数（含 quit）');
    final sessions = await db.recentSessions(limit: 10);
    expect(sessions.length, 1, reason: '历史只展示 done 会话');
    final exercises = await db.sessionExercises(sessions.first.id!);
    final sets = await db.setsOfSession(sessions.first.id!);
    expect(sets[exercises.first.id!]!.length, 2);

    final restored = await db.exportAllJson();
    expect((restored['plans'] as List).length, 1);
  });

  test('轮转保留最近 7 个日内最新 + 4 个周内最新（去重后 9 份）', () async {
    // 2026-10-17 是周六。先放 5 个更早的周快照（-5 ~ -1 周），
    // 再放最近 10 天每天 2 份，最后补一份当天中午的最新快照。
    for (var w = 5; w >= 1; w--) {
      await service.snapshotNow(at: DateTime(2026, 10, 17 - 7 * w, 9, 0));
    }
    for (var d = 9; d >= 0; d--) {
      for (var h = 10; h <= 11; h++) {
        await service.snapshotNow(at: DateTime(2026, 10, 17 - d, h, 0));
      }
    }
    await service.snapshotNow(at: DateTime(2026, 10, 17, 12, 0));

    final kept = (await service.listBackups())
        .map((b) => b.createdAt.millisecondsSinceEpoch)
        .toSet();
    expect(kept, {
      ms(2026, 10, 17, 12), // 当天最新（日内 + 本周）
      ms(2026, 10, 16, 11),
      ms(2026, 10, 15, 11),
      ms(2026, 10, 14, 11),
      ms(2026, 10, 13, 11),
      ms(2026, 10, 12, 11),
      ms(2026, 10, 11, 11), // 第 7 个日桶
      ms(2026, 10, 3, 9), // 上一周的最新一份
      ms(2026, 9, 26, 9), // 再上一周的最新一份
    });
    // 第 5 个更早周的备份（9/19）与同周更旧的文件都应被删掉。
    expect(kept, isNot(contains(ms(2026, 9, 19, 9))));
    expect(kept, isNot(contains(ms(2026, 10, 10, 11))));
  });

  test('空库启动不写无意义的空快照', () async {
    final r = await service.maybeSnapshotOnLaunch(
      at: DateTime(2026, 10, 17, 8),
    );
    expect(r, isNull);
    expect(await service.listBackups(), isEmpty);
  });

  test('启动补档：无备份立即写；24 小时内跳过；满 24 小时再写', () async {
    await seedWorkout();
    final t0 = DateTime(2026, 10, 17, 8);
    final first = await service.maybeSnapshotOnLaunch(at: t0);
    expect(first, isNotNull);
    expect((await service.listBackups()).length, 1);

    final second = await service.maybeSnapshotOnLaunch(
      at: t0.add(const Duration(hours: 23)),
    );
    expect(second, isNull);
    expect((await service.listBackups()).length, 1);

    final third = await service.maybeSnapshotOnLaunch(
      at: t0.add(const Duration(hours: 24)),
    );
    expect(third, isNotNull);
    expect((await service.listBackups()).length, 2);
  });

  test('清空全部自动备份（含尚未触发的预约快照）', () async {
    await seedWorkout();
    await service.snapshotNow(at: DateTime(2026, 10, 16, 12, 0));
    await service.snapshotNow(at: DateTime(2026, 10, 17, 13, 0));
    service.scheduleSnapshot(delay: const Duration(milliseconds: 100));
    final dir = await service.backupDir();
    final tmp = File('${dir.path}/leanlift_backup_9999999999999.json.tmp');
    await tmp.writeAsString('{"sessions":[]}');
    expect((await service.listBackups()).length, 2);

    await service.deleteAll();
    expect(await tmp.exists(), isFalse, reason: '中断写入的 .tmp 也可能含数据');
    // 预约中的那份不能在删完后自己冒出来。
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(await service.listBackups(), isEmpty);
  });

  test('deleteAll 会等已在执行的快照落盘后一起删除', () async {
    await seedWorkout();
    final snap = service.snapshotNow(at: DateTime(2026, 10, 17, 12, 0));
    final del = service.deleteAll();
    await Future.wait([snap, del]);
    expect(
      await service.listBackups(),
      isEmpty,
      reason: 'in-flight 快照不能落在清空之后',
    );
  });

  test('deleteAll 会放弃已在等待前置写入的预约快照', () async {
    await seedWorkout();
    final gate = Completer<void>();
    service.scheduleSnapshot(delay: Duration.zero, waitFor: gate.future);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    // 此时 Timer 已触发，_runScheduled 正卡在 waitFor 上。
    await service.deleteAll();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(
      await service.listBackups(),
      isEmpty,
      reason: '清空后等待中的预约任务必须作废，不能补写一份',
    );
  });

  test('启动补档导出中途执行 deleteAll，该次快照不得写回', () async {
    await seedWorkout();
    final gdb = _GatedDb(rawDb);
    final svc = AutoBackupService(gdb, directoryProvider: () async => tempRoot);

    // 启动补档已判定「该补一份」，正卡在全库导出上。
    final exportGate = Completer<void>();
    gdb.exportGate = exportGate;
    final launch = svc.maybeSnapshotOnLaunch(at: DateTime(2026, 10, 17, 8));
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // 导出中途清空全部数据。
    final del = svc.deleteAll();
    exportGate.complete(); // 放行导出，旧数据随后写盘
    final info = await launch;
    await del;

    expect(info, isNotNull, reason: '补档确实写出过一份（竞态场景成立）');
    expect(await info!.file.exists(), isFalse,
        reason: '写出的快照必须被排在其后的 deleteAll 一并删除');
    expect(
      await svc.listBackups(),
      isEmpty,
      reason: '清空完成后 backups/ 不能再出现该次快照',
    );
  });

  test('补档占用队列时 deleteAll 排在其后，已触发的预约快照仍被作废', () async {
    await seedWorkout();
    final gdb = _GatedDb(rawDb);
    final svc = AutoBackupService(gdb, directoryProvider: () async => tempRoot);

    // 1) 启动补档卡在导出上，占住串行队列。
    final exportGate = Completer<void>();
    gdb.exportGate = exportGate;
    final launch = svc.maybeSnapshotOnLaunch(at: DateTime(2026, 10, 17, 8));

    // 2) 预约一份快照并立刻触发，卡在 waitFor 上（模拟心率落库）。
    final waitGate = Completer<void>();
    svc.scheduleSnapshot(delay: Duration.zero, waitFor: waitGate.future);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // 3) 清空：只能排在补档后面执行；补档先落盘，清空把它删掉。
    final del = svc.deleteAll();
    exportGate.complete();
    await Future.wait([launch, del]);
    expect(await svc.listBackups(), isEmpty, reason: '补档写出的快照被清空一并删除');

    // 4) 放行预约任务的前置写入：cancelScheduled 已在清空时把代次 +1，必须作废。
    waitGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(
      await svc.listBackups(),
      isEmpty,
      reason: '清空后触发的预约快照不能补写一份',
    );
  });

  test('预约快照会等前置写入完成后再落盘（心率落库）', () async {
    await seedWorkout();
    final gate = Completer<void>();
    service.scheduleSnapshot(delay: Duration.zero, waitFor: gate.future);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await service.listBackups(), isEmpty, reason: '前置写入未完成前不应先写快照');

    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect((await service.listBackups()).length, 1);
  });

  test('lastError 上报会通知监听者，清空后清除', () async {
    var notifications = 0;
    service.addListener(() => notifications++);
    service.recordError('disk full');
    expect(service.lastError, 'disk full');
    expect(notifications, 1);

    await service.deleteAll();
    expect(service.lastError, isNull);
    expect(notifications, greaterThan(1));
  });

  test('损坏的备份不会被误当成可恢复数据', () async {
    final dir = await service.backupDir();
    final broken = File('${dir.path}/leanlift_backup_1729000000000.json');
    await broken.writeAsString('{"plans": []}');
    final info = BackupInfo(
      file: broken,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1729000000000),
      sizeBytes: await broken.length(),
    );
    expect(() => service.preview(info), throwsFormatException);
    expect(() => service.restore(info), throwsFormatException);
  });

  test('快照带上减载/停练标记与训练块锚点；恢复时写回本机偏好', () async {
    // 挂上偏好（App 启动同款接线）：导出/恢复把训练统计回溯的标记一起带走
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db.attachSessionPrefs(prefs);
    addTearDown(() => db.attachSessionPrefs(null));

    await seedWorkout();
    // 减载周/停练回归标记 + 训练块锚点（含来源会话指纹）
    await prefs.setString(
        'block.deloadSessionIds', jsonEncode(['9|2026-10-01|123']));
    await prefs.setString(
      'block.anchor.1',
      jsonEncode({
        'date': '2026-10-01',
        'plan': '2026-09-01',
        'session': '9|2026-10-01|123',
      }),
    );

    final info = await service.snapshotNow(at: DateTime(2026, 10, 17, 12));
    final raw = jsonDecode(await info.file.readAsString()) as Map<String, dynamic>;
    final prefsSection = raw['prefs'] as Map<String, dynamic>;
    expect(prefsSection['deload_sessions'], contains('9|2026-10-01|123'),
        reason: '减载/停练标记随快照带走');
    final anchors = prefsSection['block_anchors'] as Map;
    expect(anchors.keys, contains('block.anchor.1'), reason: '训练块锚点随快照带走');

    // 恢复 = 回到备份时点：清掉本机标记与库，再从快照恢复
    await prefs.remove('block.deloadSessionIds');
    await prefs.remove('block.anchor.1');
    await db.wipeAll();
    final n = await service.restore(info);
    expect(n, 1);
    expect(prefs.getString('block.deloadSessionIds') ?? '',
        contains('9|2026-10-01|123'),
        reason: '恢复后标记写回：统计回溯不因换机/误清错位');
    final anchor =
        jsonDecode(prefs.getString('block.anchor.1') ?? '{}') as Map;
    expect(anchor['date'], '2026-10-01');
    expect(anchor['session'], contains('9|'), reason: '来源会话指纹一并带回');

    // 老备份（无 prefs 段）：恢复时不动本机标记——两类标记都自带指纹校验，
    // 宁可少排除、不误排除真实训练。
    db.attachSessionPrefs(null);
    final oldInfo = await service.snapshotNow(at: DateTime(2026, 10, 17, 13));
    final oldRaw =
        jsonDecode(await oldInfo.file.readAsString()) as Map<String, dynamic>;
    expect(oldRaw['prefs'], isNull, reason: '未挂偏好的导出没有标记段');
    await prefs.setString('block.anchor.1', 'keep-me');
    await service.restore(oldInfo);
    expect(prefs.getString('block.anchor.1'), 'keep-me',
        reason: '老备份恢复不改本机标记');
  });
}
