// P0-A 接线回归：AppContainer 的 finish/quit/自评 → 自动快照，
// 以及 init 的 24 小时启动补档。这里跑真容器 + 临时备份目录，
// 平台通道按其它 widget 测试同款打桩。
import 'dart:convert';
import 'dart:io';

import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/models/models.dart';
import 'package:baoji_timer/services/backup_service.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
      const MethodChannel('baoji/focus'),
      (call) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter_local_notifications'),
      (call) async => null,
    );
  });

  late AppContainer container;
  late AutoBackupService backup;
  late Database rawDb;
  late Db db;
  late String dbPath;
  late Directory tempRoot;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = await databaseFactory.getDatabasesPath();
    dbPath =
        '$dir/test_auto_backup_wiring_${DateTime.now().microsecondsSinceEpoch}.db';
    rawDb = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(rawDb);
    db = Db.forTesting(rawDb);
    tempRoot = await Directory.systemTemp.createTemp('leanlift_backup_wiring_');
    backup = AutoBackupService(db, directoryProvider: () async => tempRoot);
    container = AppContainer(prefs: prefs, db: db, backupOverride: backup);
    await container.db.wipeAll();
  });

  tearDown(() async {
    container.dispose();
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

  Future<(PlanDay, PlanExercise)> seedPlan() async {
    final plan = await db.insertPlan(
      const Plan(name: '接线测试', source: 'manual', createdAt: '2026-10-17'),
    );
    final dayId = await db.insertPlanDay(
      PlanDay(planId: plan.id!, weekday: 6, title: '推日'),
    );
    final day = PlanDay(id: dayId, planId: plan.id!, weekday: 6, title: '推日');
    final pe = PlanExercise(
      dayId: dayId,
      name: '卧推',
      orderIdx: 0,
      sets: 1,
      repsMin: 5,
      repsMax: 8,
      restSec: 120,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 1),
    );
    final peId = await db.insertPlanExercise(pe);
    return (day, pe.copyWith(id: peId));
  }

  Future<BackupInfo?> waitForBackup(
    AutoBackupService service, {
    int atLeast = 1,
    DateTime? newerThan,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final all = await service.listBackups();
      final hit = all.where(
        (b) => newerThan == null || b.createdAt.isAfter(newerThan),
      );
      if (hit.length >= atLeast) return hit.first;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  test('finish、自评、quit 都会写出自动快照（自评与 quit 内容进备份）', () async {
    final (day, exercise) = await seedPlan();
    await container.session.startFromDay(day: day, planExercises: [exercise]);
    await container.session.finish();

    final first = await waitForBackup(backup);
    expect(first, isNotNull, reason: 'finish 后应写出首份自动快照');
    final firstJson =
        jsonDecode(await first!.file.readAsString()) as Map<String, dynamic>;
    expect((firstJson['sessions'] as List).single['status'], 'done');

    await container.session.setImpression(3);
    final second = await waitForBackup(backup, newerThan: first.createdAt);
    expect(second, isNotNull, reason: '自评写入后应补一份带自评的快照');
    final secondJson =
        jsonDecode(await second!.file.readAsString()) as Map<String, dynamic>;
    expect((secondJson['sessions'] as List).single['impression'], 3);

    await container.session.startFromDay(day: day, planExercises: [exercise]);
    await container.session.quit();
    final third = await waitForBackup(backup, newerThan: second.createdAt);
    expect(third, isNotNull, reason: 'quit 也是会话结束，不能漏快照');
    final thirdJson =
        jsonDecode(await third!.file.readAsString()) as Map<String, dynamic>;
    expect(
      (thirdJson['sessions'] as List).any((s) => s['status'] == 'quit'),
      isTrue,
    );
  });

  test('init 在启动时补一份（有数据才写）', () async {
    await db.insertSession(
      Session(
        date: '2026-10-17',
        planDayTitle: '推日',
        startedAt: DateTime(2026, 10, 17, 10).millisecondsSinceEpoch,
        endedAt: DateTime(2026, 10, 17, 11).millisecondsSinceEpoch,
        status: 'done',
      ),
    );
    await container.init();
    final info = await waitForBackup(backup);
    expect(info, isNotNull, reason: 'init 应触发 maybeSnapshotOnLaunch');
  });

  test('自动备份开关关闭后不再预约快照', () async {
    final (day, exercise) = await seedPlan();
    container.settings.autoBackupEnabled = false;
    await container.settings.save();
    await container.session.startFromDay(day: day, planExercises: [exercise]);
    await container.session.finish();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(await backup.listBackups(), isEmpty);

    // 打开开关后恢复工作。
    container.settings.autoBackupEnabled = true;
    await container.settings.save();
    await container.session.setImpression(2);
    final info = await waitForBackup(backup);
    expect(info, isNotNull);
  });

  test('Settings.autoBackupEnabled 默认开且可持久化', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = Settings(prefs);
    expect(settings.autoBackupEnabled, isTrue);
    settings.autoBackupEnabled = false;
    await settings.save();
    expect(Settings(prefs).autoBackupEnabled, isFalse);
  });
}
