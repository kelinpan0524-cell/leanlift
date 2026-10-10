// 评审修复验证：提醒双通道互斥（人在屏上不挂系统闹钟）的容器级行为测试。
// mock flutter_local_notifications 的插件通道，捕获 zonedSchedule/cancel 调用，
// 验证 _onRestAlarmChanged 的前台/后台分支与生命周期切换语义闭环。
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/services/session_controller.dart';
// 主入口文件 hide 了 MethodChannel 实现类，测试需要手动挂平台实例，走 src 路径
import 'package:flutter_local_notifications/src/platform_flutter_local_notifications.dart'
    show AndroidFlutterLocalNotificationsPlugin;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_local_notifications 18 的 Android MethodChannel 名（实查源码
  // platform_flutter_local_notifications.dart:32）
  const notifChannel =
      MethodChannel('dexterous.com/flutter/local_notifications');
  const focusChannel = MethodChannel('baoji/focus');
  final notifCalls = <MethodCall>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // 测试环境无宿主插件注册流程：手动挂 Android 平台实现（容器初始化经
    // resolvePlatformSpecificImplementation 强转 Android 子类，必须挂它），
    // 让 NotifyService.init/_ready 走通（所有调用落在我们 mock 的通道上）
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    // 测试环境无宿主插件：wakelock_plus 的 pigeon toggle 通道挂 mock 回包
    final binding = TestWidgetsFlutterBinding.instance;
    final pigeonNullReply = ByteData(3)
      ..setUint8(0, 12)
      ..setUint8(1, 1)
      ..setUint8(2, 0);
    binding.defaultBinaryMessenger.setMockMessageHandler(
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
        (data) async => pigeonNullReply);
    // 原生辅助通道：bool 回包需显式 mock（否则 invokeMethod 抛 MissingPluginException）
    binding.defaultBinaryMessenger.setMockMethodCallHandler(focusChannel,
        (call) async {
      switch (call.method) {
        case 'dndGranted':
          return false;
        case 'canExactAlarm':
          return true;
        case 'ignoringBattery':
          return true;
        default:
          return null;
      }
    });
  });

  late Database rawDb;
  late String dbPath;
  late AppContainer c;

  setUp(() async {
    notifCalls.clear();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifChannel, (call) async {
      notifCalls.add(call);
      // initialize 的回包是非空 bool（platform_flutter_local_notifications.dart:148），
      // 统一回 false；void 回包的 cancel/zonedSchedule 对 false 同样兼容
      return false;
    });
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = await databaseFactory.getDatabasesPath();
    dbPath = '$dir/test_dual_${DateTime.now().microsecondsSinceEpoch}.db';
    rawDb = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(rawDb);
    c = AppContainer(prefs: prefs, db: Db.forTesting(rawDb));
    await c.init();
    // notify.init() 是 unawaited 异步：等它落地，_ready=true 后
    // zonedSchedule/cancel 才会真正打到插件通道上
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  tearDown(() async {
    c.dispose();
    await rawDb.close();
    await databaseFactory.deleteDatabase(dbPath);
  });

  List<String> methods(String name) => [
        for (final call in notifCalls)
          if (call.method == name) name,
      ];

  Future<PlanDay> makePlanDay(String title) async {
    final plan = await c.db.insertPlan(Plan(
        name: '计划-$title', source: 'manual', createdAt: '2026-09-25', isActive: 1));
    final dayId =
        await c.db.insertPlanDay(PlanDay(planId: plan.id!, weekday: 3, title: title));
    return PlanDay(id: dayId, planId: plan.id!, weekday: 3, title: title);
  }

  Future<PlanExercise> addPlanEx(PlanDay day, String name, int order,
      {int restSec = 120}) async {
    final pe = PlanExercise(
      dayId: day.id!,
      name: name,
      orderIdx: order,
      sets: 3,
      repsMin: 5,
      repsMax: 8,
      restSec: restSec,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
    );
    final id = await c.db.insertPlanExercise(pe);
    return pe.copyWith(id: id);
  }

  Future<void> enterRest(PlanDay day, PlanExercise e) async {
    await c.session.startFromDay(day: day, planExercises: [e]);
    await c.session
        .completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    // 排空微任务/短延时：onRestAlarmChanged 是 fire-and-forget 的异步链，
    // 不等它落地就断言 notifCalls 会漏记
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.session.phase, WorkoutPhase.resting);
    expect(c.session.inForeground, isTrue, reason: 'App 启动即前台');
  }

  test('D1 人在屏上：进休息不预约系统提醒（评审 major：最常见路径的双触发）',
      () async {
    final day = await makePlanDay('推日');
    final e = await addPlanEx(day, '卧推', 0);
    await enterRest(day, e);

    expect(methods('zonedSchedule'), isEmpty,
        reason: '前台挂钟请求必须被跳过，否则休息页等到自然到点时'
            ' heads-up 系统通知先于屏内提示到达，两通道同时触发');
    expect(methods('cancel'), isNotEmpty,
        reason: '顺带幂等清掉可能残留的已预约闹钟');
  });

  test('D2 离开前台重挂系统提醒；回前台取消并只走屏内提示', () async {
    final day = await makePlanDay('推日');
    final e = await addPlanEx(day, '卧推', 0);
    await enterRest(day, e);

    c.onAppLifecycleChanged(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.session.inForeground, isFalse,
        reason: '前台标记传导到会话层（后台到点不再屏内震动/提示音）');
    expect(methods('zonedSchedule'), isNotEmpty, reason: '离开前台交回系统提醒');

    final scheduled = methods('zonedSchedule').length;
    c.onAppLifecycleChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(methods('zonedSchedule').length, scheduled,
        reason: '回前台不再新增预约');
    expect(methods('cancel'), isNotEmpty, reason: '回前台取消系统提醒');
  });

  test('D3 通知栏「继续」按钮（App 在后台）正确挂上系统提醒', () async {
    final day = await makePlanDay('推日');
    final e = await addPlanEx(day, '卧推', 0);
    await enterRest(day, e);
    c.onAppLifecycleChanged(AppLifecycleState.paused); // 人在别的 App 点通知按钮

    final before = methods('zonedSchedule').length;
    c.session.pauseRest(); // 后台暂停：先取消
    await Future<void>.delayed(const Duration(milliseconds: 50));
    c.session.resumeRest(); // 后台点继续：重挂
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.session.phase, WorkoutPhase.resting);
    expect(methods('zonedSchedule').length, greaterThan(before),
        reason: '后台暂停后点继续：系统提醒照挂（人不在屏上）');
  });

  test('D4 后台自然到点：系统提醒已在屏，屏内不再叠加提示（前台标记传导）',
      () async {
    final day = await makePlanDay('推日');
    final e = await addPlanEx(day, '卧推', 0);
    await enterRest(day, e);
    c.onAppLifecycleChanged(AppLifecycleState.paused);
    expect(c.session.inForeground, isFalse);

    // 模拟后台到点：_onRestFinished 的震动/提示音分支按 inForeground 跳过
    // （震动本身无观测点，这里验证标记与到点流程走通、相位回动作态）
    c.session.restEndAt -= 121000;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.session.phase, WorkoutPhase.lifting);
  });

  /// zonedSchedule 预约的通知 id 列表（Android 平台实现发 Map，见
  /// platform_flutter_local_notifications.dart:211）。
  List<int> scheduledIds() => [
        for (final call in notifCalls)
          if (call.method == 'zonedSchedule') (call.arguments as Map)['id'] as int,
      ];

  /// cancel 携带的通知 id 列表。
  List<int> cancelledIds() => [
        for (final call in notifCalls)
          if (call.method == 'cancel') (call.arguments as Map)['id'] as int,
      ];

  test('D5 离开前台：除休息结束提醒外，同时预约「剩 30 秒」预警', () async {
    final day = await makePlanDay('推日');
    final e = await addPlanEx(day, '卧推', 0, restSec: 120);
    await enterRest(day, e);

    c.onAppLifecycleChanged(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(scheduledIds(), containsAll([2, 3]),
        reason: '后台休息必须双提醒：剩 30 秒预警（id=3）把刷别的 App 的人'
            '提前拉回，结束提醒（id=2）兜底到点');

    // 回前台：预警与结束提醒一并取消（屏内提示接管，不残留系统闹钟）
    notifCalls.clear();
    c.onAppLifecycleChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(cancelledIds(), containsAll([2, 3]),
        reason: '回前台后休息提醒族（结束+预警）都要清，否则到点双响');
  });

  test('D6 短休息（< 30 秒）：离开前台只挂结束提醒，不预约预警', () async {
    final day = await makePlanDay('推日');
    final e = await addPlanEx(day, '卧推', 0, restSec: 20);
    await enterRest(day, e);

    c.onAppLifecycleChanged(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(scheduledIds(), contains(2), reason: '结束提醒照挂');
    expect(scheduledIds(), isNot(contains(3)),
        reason: '预警时点已过：预约过去时间插件直接抛异常，'
            '守卫必须静默跳过（20 秒休息只剩一条结束提醒）');
  });
}
