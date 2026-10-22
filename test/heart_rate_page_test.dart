// 心率设备页布局稳定性回归（2026-10-17 Arono：连 WHOOP 时页面漂移）：
//  - 未连接时 bpm 行/重连/忘记按钮就已占位，连接成功不新增行
//  - 未保存设备时重连/忘记置灰但仍在版面上
//  - 设置页长设备名只省略、不挤压标题、不溢出
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/services/heart_rate_service.dart';
import 'package:baoji_timer/ui/heart_rate_page.dart';
import 'package:baoji_timer/ui/settings_page.dart';
import 'package:baoji_timer/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/baoji_timer.db');
  });

  late AppContainer container;

  Future<void> boot({Map<String, Object> prefsSeed = const {}}) async {
    SharedPreferences.setMockInitialValues(prefsSeed);
    final prefs = await SharedPreferences.getInstance();
    container = AppContainer(prefs: prefs);
    await container.db.wipeAll();
  }

  tearDown(() async {
    await container.db.wipeAll();
    container.dispose();
  });

  Widget host(Widget home) => AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(body: home),
        ),
      );

  testWidgets('未连接/未保存：bpm 占位与两枚按钮已在版面上（不日后长出来）',
      (tester) async {
    // testWidgets 的 FakeAsync 区里真实 DB/prefs 异步不会自行推进，
    // 必须包 runAsync（与 stats_overview_test 的 seed 同口径）
    await tester.runAsync(boot);
    Lang.setResolved(false);
    await tester.pumpWidget(host(const HeartRatePage()));
    await tester.pump();

    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('--'), findsOneWidget, reason: 'bpm 槽位始终存在');
    expect(find.text('未选择设备'), findsOneWidget);
    expect(find.text('扫描心率设备'), findsOneWidget);

    // 两枚按钮始终存在，只是无保存设备时不可按——布局不随连接成功跳变
    final reconnect = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '重连已保存设备'));
    final forget = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '忘记设备'));
    expect(reconnect.onPressed, isNull);
    expect(forget.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已保存设备：重连/忘记可点，设备名显示', (tester) async {
    await tester.runAsync(() => boot(prefsSeed: {
          'set.hrId': 'AA:BB:CC:DD:EE:FF',
          'set.hrName': 'WHOOP 4.0',
        }));
    Lang.setResolved(false);
    await tester.pumpWidget(host(const HeartRatePage()));
    await tester.pump();

    expect(find.text('WHOOP 4.0'), findsOneWidget);
    final reconnect = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '重连已保存设备'));
    final forget = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '忘记设备'));
    expect(reconnect.onPressed, isNotNull);
    expect(forget.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('掉线自动重连：状态与主按钮显示「重连中…」，不掉回未连接',
      (tester) async {
    await tester.runAsync(() => boot(prefsSeed: {
          'set.hrId': 'AA:BB:CC:DD:EE:FF',
          'set.hrName': 'WHOOP 4.0',
        }));
    Lang.setResolved(false);
    container.hr.debugSetReading(link: HrLink.reconnecting);
    await tester.pumpWidget(host(const HeartRatePage()));
    await tester.pump();

    expect(find.text('未连接'), findsNothing);
    expect(find.text('重连中…'), findsNWidgets(2),
        reason: '状态行 + 主按钮都明确显示正在重连');
    // 自动重连期间仍可手动「重连已保存设备」立即再试
    final reconnect = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '重连已保存设备'));
    expect(reconnect.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置页：超长设备名省略显示，360 宽不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => boot(prefsSeed: {
          'set.hrId': 'AA:BB:CC:DD:EE:FF',
          'set.hrName': 'WHOOP 4.0 BLE Heart Rate Monitor Very Long Name',
        }));
    Lang.setResolved(false);
    await tester.pumpWidget(host(const SettingsPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('WHOOP 4.0'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: '限宽 + ellipsis 后长设备名不能把行挤溢出');
  });
}
