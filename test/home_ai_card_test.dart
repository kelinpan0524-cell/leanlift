// 首页 AI 教练入口按配置态分级（2026-09-29 Arono）：
// 未配置 Key = 一行灰字直达 AI 配置页（无紫底光晕）；配好 Key = 紫光晕大卡。
// 防「装好即用的首页给未配置用户常驻死路大卡」回归。
// 基建同 home_done_today_test：真库（ffi）+ AppContainer 注入。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/ui/home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    final binding = TestWidgetsFlutterBinding.instance;
    final pigeonNullReply = ByteData(3)
      ..setUint8(0, 12)
      ..setUint8(1, 1)
      ..setUint8(2, 0);
    binding.defaultBinaryMessenger.setMockMessageHandler(
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
        (data) async => pigeonNullReply);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('baoji/focus'), (call) async => null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter_local_notifications'),
        (call) async => null);
  });

  tearDownAll(() async {
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/baoji_timer.db');
  });

  late AppContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = AppContainer(prefs: prefs);
    await container.db.wipeAll();
    await container.planRepo.reload();
    await container.session.restore();
  });

  tearDown(() async {
    await container.db.wipeAll();
    container.dispose();
  });

  /// pump 首页并等加载完成（首页查询走 ffi 后台 isolate，
  /// 用真实延时 ↔ pump 交替推进到内容出现）。
  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(AppScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: HomePage()))));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('未配置 Key：一行灰字降级入口，无紫卡副标题', (tester) async {
    await pumpHome(tester);

    expect(container.settings.aiConfigured, isFalse);
    expect(find.text('AI 教练 · 未配置，点此设置'), findsOneWidget,
        reason: '降级为一行灰字入口');
    expect(find.text('问训练数据 · 一句话排计划，一键存入 App'), findsNothing,
        reason: '未配置时不摆紫光晕大卡');
  });

  testWidgets('配好 Key：升级成紫卡，降级入口消失', (tester) async {
    container.settings.set(() {
      container.settings.aiBaseUrl = 'https://api.example.com/v1';
      container.settings.aiApiKey = 'sk-test';
    });
    await pumpHome(tester);

    expect(container.settings.aiConfigured, isTrue);
    expect(find.text('问训练数据 · 一句话排计划，一键存入 App'), findsOneWidget,
        reason: '配好 Key 紫光晕大卡回归');
    expect(find.text('AI 教练 · 未配置，点此设置'), findsNothing,
        reason: '降级入口不再出现');
  });
}
