// 数据与备份页的自动备份入口回归：最近备份时间可见、「从最近自动备份恢复」
// 先弹预览（训练/计划/身体数据条数）再确认，确认前不改动数据。
import 'dart:io';

import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/models/models.dart';
import 'package:baoji_timer/services/backup_service.dart';
import 'package:baoji_timer/ui/settings_page.dart';
import 'package:baoji_timer/ui/settings_subpages.dart';
import 'package:baoji_timer/ui/stats_page.dart';
import 'package:flutter/material.dart';
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
  late Database rawDb;
  late String dbPath;
  late Directory tempRoot;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = await databaseFactory.getDatabasesPath();
    dbPath =
        '$dir/test_auto_backup_page_${DateTime.now().microsecondsSinceEpoch}.db';
    rawDb = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(rawDb);
    final db = Db.forTesting(rawDb);
    tempRoot = await Directory.systemTemp.createTemp('leanlift_backup_page_');
    final backup = AutoBackupService(
      db,
      directoryProvider: () async => tempRoot,
    );
    container = AppContainer(prefs: prefs, db: db, backupOverride: backup);
    await container.db.wipeAll();

    final ses = await container.db.insertSession(
      Session(
        date: '2026-10-17',
        planDayTitle: '推日',
        startedAt: DateTime(2026, 10, 17, 10).millisecondsSinceEpoch,
        endedAt: DateTime(2026, 10, 17, 11).millisecondsSinceEpoch,
        status: 'done',
      ),
    );
    final seId = await container.db.insertSessionExercise(
      SessionExercise(
        sessionId: ses.id!,
        name: '卧推',
        orderIdx: 0,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      ),
    );
    await container.db.insertSet(
      SetEntry(
        sessionExerciseId: seId,
        weightKg: 60,
        reps: 8,
        kind: SetKind.working,
        doneAt: DateTime(2026, 10, 17, 10, 30).millisecondsSinceEpoch,
      ),
    );
    await container.autoBackup.snapshotNow(at: DateTime(2026, 10, 17, 12, 0));
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

  Future<void> pumpPage(WidgetTester tester) async {
    Lang.setResolved(false);
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: const MaterialApp(home: DataBackupPage()),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('显示最近自动备份时间，恢复前有预览确认', (tester) async {
    await pumpPage(tester);

    expect(find.text('最近自动备份: 2026-10-17 12:00'), findsOneWidget);
    expect(find.text('从最近自动备份恢复'), findsOneWidget);
    expect(find.textContaining('还没有手动导出过备份'), findsOneWidget);

    await tester.tap(find.text('从最近自动备份恢复'));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('从最近自动备份恢复？'), findsOneWidget);
    expect(find.textContaining('包含 1 次训练'), findsOneWidget);
    expect(find.textContaining('备份时间：2026-10-17 12:00'), findsOneWidget);

    // 取消：数据保持原样。
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final sessions = await tester.runAsync(
      () => container.db.recentSessions(limit: 10),
    );
    expect(sessions!.length, 1);
  });

  testWidgets('确认后会真正恢复备份数据', (tester) async {
    await tester.runAsync(() => container.db.wipeAll());
    expect(
      await tester.runAsync(() => container.db.recentSessions(limit: 10)),
      isEmpty,
    );

    await pumpPage(tester);
    await tester.tap(find.text('从最近自动备份恢复'));
    await settle(tester);
    expect(find.text('从最近自动备份恢复？'), findsOneWidget);

    await tester.tap(find.text('恢复'));
    await settle(tester, rounds: 12);
    final sessions = await tester.runAsync(
      () => container.db.recentSessions(limit: 10),
    );
    expect(sessions!.length, 1, reason: '确认后应把备份里的训练写回数据库');
  });

  testWidgets('清空全部数据会同时删除自动备份文件', (tester) async {
    await pumpPage(tester);
    await tester.ensureVisible(find.text('清空全部数据'));
    await tester.pump();
    await tester.tap(find.text('清空全部数据'));
    await settle(tester, rounds: 4);
    expect(find.text('清空全部数据？'), findsOneWidget);

    await tester.tap(find.text('全部删除'));

    // 清空是「删文件 → 删库 → 存设置 → 刷计划」的异步链，轮询到收敛，
    // 避免固定 pump 次数在慢机器上提前断言。
    var backups = <BackupInfo>[];
    var sessions = <Session>[];
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      backups = (await tester.runAsync(
        () => container.autoBackup.listBackups(),
      ))!;
      sessions = (await tester.runAsync(
        () => container.db.recentSessions(limit: 10),
      ))!;
      if (backups.isEmpty && sessions.isEmpty) break;
    }
    expect(backups, isEmpty, reason: '清空后不能留下可恢复的自动备份');
    expect(sessions, isEmpty);
    expect(container.settings.lastExportJsonAt, 0);
  });

  testWidgets('自动备份失败提示出现，成功快照后消失', (tester) async {
    await pumpPage(tester);
    expect(find.textContaining('上次自动备份失败'), findsNothing);

    container.autoBackup.recordError('disk full');
    await settle(tester, rounds: 2);
    expect(find.textContaining('上次自动备份失败'), findsOneWidget);

    await tester.runAsync(() => container.autoBackup.snapshotNow());
    await settle(tester, rounds: 4);
    expect(find.textContaining('上次自动备份失败'), findsNothing);
  });

  testWidgets('自动备份开关关闭后会持久化', (tester) async {
    await pumpPage(tester);
    expect(container.settings.autoBackupEnabled, isTrue);

    await tester.tap(find.byType(Switch));
    await settle(tester, rounds: 3);
    expect(container.settings.autoBackupEnabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('set.autoBackupEnabled'), isFalse);
  });

  testWidgets('没有进行中训练时，数据页显示非打断式备份提醒', (tester) async {
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: const MaterialApp(home: StatsPage()),
      ),
    );
    await settle(tester, rounds: 6);
    expect(find.textContaining('还没有手动导出过备份'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('有进行中的训练时，数据页与数据与备份页都不显示备份提醒', (tester) async {
    await tester.runAsync(() async {
      final plan = await container.db.insertPlan(
        const Plan(name: '进行中计划', source: 'manual', createdAt: '2026-10-17'),
      );
      final dayId = await container.db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 6, title: '推日'),
      );
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
      final peId = await container.db.insertPlanExercise(pe);
      await container.session.startFromDay(
        day: PlanDay(id: dayId, planId: plan.id!, weekday: 6, title: '推日'),
        planExercises: [pe.copyWith(id: peId)],
      );
    });
    expect(container.session.hasActive, isTrue);
    // 失败提示也属于备份提醒，训练中不显示。
    container.autoBackup.recordError('disk full');

    await pumpPage(tester);
    expect(find.textContaining('还没有手动导出过备份'), findsNothing);
    expect(find.textContaining('上次自动备份失败'), findsNothing);

    await tester.pumpWidget(
      AppScope(
        container: container,
        child: const MaterialApp(home: StatsPage()),
      ),
    );
    await settle(tester, rounds: 6);
    expect(find.textContaining('还没有手动导出过备份'), findsNothing);

    // 设置主页的「建议备份」角标同样不能在训练中亮。
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('建议备份'), findsNothing);

    await tester.runAsync(() => container.session.quit());
    container.autoBackup.cancelScheduled();
    await tester.pumpWidget(const SizedBox());
  });
}
