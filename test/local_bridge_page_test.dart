// 局域网连接页与设置页入口的 widget 测试。
// 服务本身的协议/安全边界在 local_bridge_test.dart 里用真 socket 覆盖；
// 这里只管 UI：入口行在不在、两种状态渲染是否正常、换码/断开这些操作
// 能不能真把状态改掉。
//
// 两个坑（踩过）：
//  1) testWidgets 默认跑在假异步区，真 socket / 真 HTTP 永远不会完成 →
//     凡涉及真实 I/O 的步骤一律包在 tester.runAsync() 里；
//  2) 服务跑起来后页面每秒 setState（"剩余 X 分钟自动关闭"要走字），
//     pumpAndSettle 会一直等不到静止 → 用固定时长的 pump 代替。
import 'dart:io';

import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/services/local_bridge.dart';
import 'package:baoji_timer/ui/local_bridge_page.dart';
import 'package:baoji_timer/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // 本页开着窗会真起 socket；测试里用真实现才测得到"启动成功"这条路径。
    HttpOverrides.global = null;
  });

  late AppContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // 注入自定义桥：固定 IP + 系统分配端口，不碰跑测机器的真实网卡
    container = AppContainer(
      prefs: prefs,
      bridgeOverride: LocalBridgeService(
        db: Db.instance,
        prefs: prefs,
        port: 0,
        ipProbe: () async => const ['10.0.0.5'],
      ),
    );
    await container.db.wipeAll();
    Lang.setResolved(false);
  });

  tearDown(() async {
    // tearDown 在假异步区之外跑，真 I/O 在这里能正常完成
    await container.bridge.stop();
    await container.db.wipeAll();
    container.dispose();
  });

  /// 加高测试画布：设置页是懒加载列表，矮屏上更靠下的行不会构建出来。
  void tallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpPage(WidgetTester tester) async {
    tallSurface(tester);
    await tester.pumpWidget(AppScope(
      container: container,
      child: const MaterialApp(home: LocalBridgePage()),
    ));
    await tester.pump();
  }

  /// 在假异步区之外把服务真启起来（真 socket 需要 runAsync 才走得动）。
  Future<void> startReal(WidgetTester tester) async {
    await tester.runAsync(() async {
      expect(await container.bridge.start(), isTrue);
    });
    await tester.pump();
  }

  /// 页面上现在有两个开关（主开关 + 常驻开关），按文字定位各自那颗。
  Finder switchOf(String title) => find.descendant(
        of: find.widgetWithText(SwitchListTile, title),
        matching: find.byType(Switch),
      );

  testWidgets('设置页有「局域网连接」入口，点开进本页', (tester) async {
    tallSurface(tester);
    await tester.pumpWidget(AppScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SettingsPage())),
    ));
    await tester.pump();
    expect(find.text('局域网连接'), findsOneWidget);
    expect(find.text('未开启'), findsWidgets);
    await tester.tap(find.text('局域网连接'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LocalBridgePage), findsOneWidget);
  });

  testWidgets('关闭态：只显示说明与开关，不显示地址/配对码', (tester) async {
    await pumpPage(tester);
    expect(find.text('这台手机当作数据源'), findsOneWidget);
    expect(find.text('开启局域网连接'), findsOneWidget);
    expect(find.text('关闭中'), findsOneWidget);
    expect(find.text('配对码'), findsNothing);
    expect(find.text('已配对的设备'), findsNothing);
  });

  testWidgets('运行态：显示地址、6 位配对码、电脑端操作指引', (tester) async {
    await pumpPage(tester);
    await startReal(tester);

    expect(find.text('配对码'), findsOneWidget);
    expect(find.textContaining('运行中'), findsOneWidget);
    expect(find.textContaining('http://10.0.0.5:'), findsOneWidget);
    expect(find.text('电脑端怎么接'), findsOneWidget);
    // 倒计时文案（"无请求 N 分钟后自动关闭"）确实在走字
    expect(find.textContaining('后自动关闭'), findsOneWidget);

    // 配对码是 6 位数字，且确实渲染在页面上
    final code = container.bridge.pairingCode;
    expect(code.length, 6);
    expect(int.tryParse(code), isNotNull);
    expect(find.text(code), findsOneWidget);

    // 还没设备接入 → 空态文案
    expect(
        find.text('还没有设备接入。配对成功后这里会列出来，且下次开开关不用重配；可随时断开。'),
        findsOneWidget);
    // 教程入口在页面上（小白就是靠它走完剩下的步骤）
    expect(find.textContaining('查看完整图文教程'), findsOneWidget);
    expect(find.textContaining('docs/MCP_GUIDE.md'), findsOneWidget);
  });

  testWidgets('换一个 → 配对码刷新（旧码作废）', (tester) async {
    await pumpPage(tester);
    await startReal(tester);
    final before = container.bridge.pairingCode;

    await tester.tap(find.text('换一个'));
    await tester.pump();
    expect(container.bridge.pairingCode, isNot(equals(before)));
    expect(find.text(container.bridge.pairingCode), findsOneWidget);
  });

  testWidgets('关开关要先确认：取消则继续跑，确认才停', (tester) async {
    await pumpPage(tester);
    await startReal(tester);
    expect(container.bridge.running, isTrue);

    await tester.tap(switchOf('开启局域网连接'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('关闭局域网连接？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.bridge.running, isTrue, reason: '取消不该关掉服务');
    expect(find.text('配对码'), findsOneWidget);

    await tester.tap(switchOf('开启局域网连接'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // 点确认只负责关掉对话框；真正的关服务是真 I/O，交给 runAsync 走完
    await tester.tap(find.text('确认'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(container.bridge.running, isFalse);
    expect(find.text('配对码'), findsNothing);
  });

  testWidgets('已配对设备列出来并能一键断开', (tester) async {
    await pumpPage(tester);
    await startReal(tester);
    final b = container.bridge;

    // 用真 HTTP 配一次对，等价于电脑已完成配对后的状态
    await tester.runAsync(() async {
      final client = HttpClient();
      final req = await client
          .postUrl(Uri.parse('http://127.0.0.1:${b.actualPort}/v1/pair'));
      req.headers.contentType = ContentType.json;
      req.write('{"code":"${b.pairingCode}"}');
      final res = await req.close();
      await res.drain<void>();
      client.close(force: true);
    });
    await tester.pump();

    expect(b.pairedDevices.length, 1);
    expect(find.text('断开'), findsOneWidget);
    // 设备行：自报名字 + 来源 IP + 摘要前缀。名字取自客户端自报的 User-Agent
    //（Dart 的 HttpClient 会带 Dart/x.y），所以按模型算出来的 label 断言，
    // 而不是写死某个字符串——换客户端实现也不会误报。
    expect(find.text(b.pairedDevices.first.label), findsOneWidget);
    expect(find.textContaining('127.0.0.1'), findsWidgets);
    expect(find.textContaining(RegExp(r'最近请求 \d\d:\d\d · [0-9a-f]{8}')),
        findsOneWidget);
    // 摘要前缀确实渲染出来了（长度 8 的 hex）
    expect(
        find.textContaining(RegExp(r'· [0-9a-f]{8}$')), findsOneWidget);

    await tester.tap(find.text('断开'));
    await tester.pump();
    expect(b.pairedDevices, isEmpty);
    expect(
        find.text('还没有设备接入。配对成功后这里会列出来，且下次开开关不用重配；可随时断开。'),
        findsOneWidget);
  });

  testWidgets('断开是持久的：关掉开关再打开，设备不会自己回来', (tester) async {
    await pumpPage(tester);
    await startReal(tester);
    final b = container.bridge;

    await tester.runAsync(() async {
      final client = HttpClient();
      final req = await client
          .postUrl(Uri.parse('http://127.0.0.1:${b.actualPort}/v1/pair'));
      req.headers.contentType = ContentType.json;
      req.write('{"code":"${b.pairingCode}"}');
      await (await req.close()).drain<void>();
      client.close(force: true);
    });
    await tester.pump();
    expect(b.pairedDevices.length, 1);

    await tester.tap(find.text('断开'));
    await tester.pump();
    expect(b.pairedDevices, isEmpty);

    // 重开服务：落盘里已删，设备不该复活
    await tester.runAsync(() async {
      await b.stop();
      await b.start();
    });
    await tester.pump();
    expect(b.pairedDevices, isEmpty);
  });

  testWidgets('常驻开关：先过风险提示，确认后记住当前局域网并顺手拉起服务', (tester) async {
    await pumpPage(tester);
    final b = container.bridge;
    expect(find.text('常驻模式'), findsOneWidget);
    expect(find.text('关闭 · 开启后在这个局域网内自动连接、不自动关'), findsOneWidget);

    await tester.tap(switchOf('常驻模式'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // 风险提示必须先过目：仅建议家用 Wi-Fi
    expect(find.text('在这个局域网开启常驻？'), findsOneWidget);
    expect(find.textContaining('仅建议在自家的 Wi-Fi'), findsWidgets);

    await tester.tap(find.text('确认'));
    await tester.pump();
    // 确认链路里有真 socket（顺手把服务拉起），交给 runAsync 走完
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    expect(b.persistentEnabled, isTrue);
    expect(b.rememberedLan, '10.0.0', reason: '注入的 ipProbe 是 10.0.0.5，取前三段');
    expect(b.running, isTrue, reason: '开常驻时用户多半当下就要用，顺手拉起');
    expect(find.text('已记住这个局域网（10.0.0.x）'), findsOneWidget);
    expect(find.text('常驻生效中：不会自动关闭（App 划掉即停）'), findsOneWidget);

    // start 是在 tap 链（假异步区）里执行的，它武装的周期 Timer 会让
    // widget 测试的"无悬挂 Timer"断言翻脸——结束前在真异步区里停掉。
    await tester.runAsync(() => b.stop());
    await tester.pump();
  });

  testWidgets('关闭常驻：只清常驻两项，不动正在跑的服务', (tester) async {
    await pumpPage(tester);
    final b = container.bridge;
    await tester.runAsync(() async {
      expect(await b.enablePersistent(), isTrue);
      expect(await b.start(), isTrue);
    });
    await tester.pump();
    expect(find.text('已记住这个局域网（10.0.0.x）'), findsOneWidget);

    await tester.tap(switchOf('常驻模式'));
    await tester.pump();
    // 关常驻是降风险操作，无确认弹窗，直接生效
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(b.persistentEnabled, isFalse);
    expect(b.rememberedLan, isNull);
    expect(b.running, isTrue, reason: '关常驻不该顺手关掉正在跑的服务');
  });
}
