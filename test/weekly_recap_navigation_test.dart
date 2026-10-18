// 周复盘通知点击 → 真正打开周复盘页（main.dart 的导航接线）：
// 容器只挂起请求；BaojiApp 首帧/收到回调后用 navigatorKey push 页面。
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/main.dart';
import 'package:baoji_timer/ui/weekly_recap_page.dart';
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
        const MethodChannel('baoji/focus'), (call) async => null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async {
        if (call.method == 'getNotificationAppLaunchDetails') return null;
        return false;
      },
    );
  });

  late Database rawDb;
  late String dbPath;
  late AppContainer c;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'onboarded': true,
      // 本文件只验证导航：关掉周复盘排期与自动备份，减少无关异步
      'set.weeklyRecapOn': false,
      'set.autoBackupEnabled': false,
    });
    final prefs = await SharedPreferences.getInstance();
    final dir = await databaseFactory.getDatabasesPath();
    dbPath =
        '$dir/test_weekly_recap_navigation_${DateTime.now().microsecondsSinceEpoch}.db';
    rawDb = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(rawDb);
    c = AppContainer(prefs: prefs, db: Db.forTesting(rawDb));
    await c.init();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    Lang.setResolved(false);
  });

  tearDown(() async {
    c.dispose();
    try {
      await rawDb.close();
    } catch (_) {}
    try {
      await databaseFactory.deleteDatabase(dbPath);
    } catch (_) {}
  });

  testWidgets('容器收到打开请求后，BaojiApp 真正 push 周复盘页', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(BaojiApp(container: c, onboarded: true));
    await tester.pump();
    // 跨过开机动画（1.2s）+ 380ms 交叉淡出
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(WeeklyRecapPage), findsNothing);

    c.requestWeeklyRecap();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(WeeklyRecapPage), findsOneWidget,
        reason: '通知点击必须真的打开周复盘页，而不只是挂一个 pending 标记');
    expect(find.text('周复盘'), findsOneWidget);

    // 首页的 post-frame _refresh 还在跑：等它落地再结束用例，
    // 否则 tearDown dispose 容器后它会撞上「PlanRepository used after dispose」。
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
