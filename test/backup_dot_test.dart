// 「数据与备份」14 天未手动导出 JSON 提醒回归锁（P0-A 自动备份配套）：
// backupNeedsAttention 纯函数 + 设置主页角标两态 + 导出后时戳落 prefs。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:baoji_timer/ui/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/baoji_timer.db');
  });

  group('backupNeedsAttention', () {
    final now = DateTime(2026, 9, 28).millisecondsSinceEpoch;
    const day = Duration(days: 14);

    test('从未导出 → 提醒', () {
      expect(Settings.backupNeedsAttention(0, nowMs: now), isTrue);
    });

    test('两周内导出过 → 不提醒；恰好第 14 天不提醒；超 14 天提醒', () {
      expect(
        Settings.backupNeedsAttention(now - const Duration(days: 3).inMilliseconds,
            nowMs: now),
        isFalse,
      );
      expect(Settings.backupNeedsAttention(now - day.inMilliseconds, nowMs: now),
          isFalse);
      expect(
        Settings.backupNeedsAttention(now - day.inMilliseconds - 1, nowMs: now),
        isTrue,
      );
    });
  });

  group('设置页备份角标与导出时戳', () {
    late AppContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      container = AppContainer(prefs: prefs);
      await container.db.wipeAll();
    });

    tearDown(() async {
      await container.db.wipeAll();
      container.dispose();
    });

    Future<void> pumpSettings(WidgetTester tester) async {
      Lang.setResolved(false);
      await tester.pumpWidget(AppScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('从未导出 → 数据与备份行亮「建议备份」', (tester) async {
      await pumpSettings(tester);
      expect(find.text('建议备份'), findsOneWidget);
    });

    testWidgets('两周内导出过 → 角标消失', (tester) async {
      container.settings.lastExportJsonAt =
          DateTime.now().millisecondsSinceEpoch;
      await container.settings.save();
      await pumpSettings(tester);
      expect(find.text('建议备份'), findsNothing);
    });

    test('导出时戳持久化（save → prefs 可读）', () async {
      container.settings.lastExportJsonAt = 1727500000000;
      await container.settings.save();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('set.lastExportJsonAt'), 1727500000000);
    });
  });

}
