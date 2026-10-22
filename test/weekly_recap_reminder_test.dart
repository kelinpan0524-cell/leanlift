// 每周复盘提醒（P1-E2）：
// - nextWeeklyRecapFires 纯函数：默认周日 20:00、当天已过点顺延下周、
//   未来工作日当天照排、跨周/跨月递增；
// - 调度：payload 固定 weekly_recap，id 40-47，启动后排未来 8 周；
// - 设置变更：先取消旧 id 段，再按新星期/时刻重排；
// - 训练中抑制：开始训练取消 40-47，收工后补排；
// - 点击通知：payload 命中时向 UI 发一次打开周复盘请求。
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/services/notify_service.dart';
import 'package:baoji_timer/ui/settings_subpages.dart';
import 'package:baoji_timer/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/src/platform_flutter_local_notifications.dart'
    show AndroidFlutterLocalNotificationsPlugin;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const notifChannel =
      MethodChannel('dexterous.com/flutter/local_notifications');
  final notifCalls = <MethodCall>[];

  setUpAll(() {
    sqfliteFfiInit();
    // 测试环境无宿主插件：手动挂 Android 平台实现（NotifyService.init
    // 经 resolvePlatformSpecificImplementation 强转 Android 子类）。
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    final binding = TestWidgetsFlutterBinding.instance;
    // wakelock_plus 的 pigeon 通道：void 方法的合法回包是 [null]。
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
  });

  late Database rawDb;
  late String dbPath;
  late AppContainer c;

  setUp(() async {
    notifCalls.clear();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifChannel, (call) async {
      notifCalls.add(call);
      if (call.method == 'getNotificationAppLaunchDetails') return null;
      // initialize 的回包是非空 bool；cancel/zonedSchedule 是 void。
      return false;
    });
    // 关自动备份：测试不碰 path_provider，也不让收工后的快照干扰断言。
    SharedPreferences.setMockInitialValues({'set.autoBackupEnabled': false});
    final prefs = await SharedPreferences.getInstance();
    final dir = await databaseFactory.getDatabasesPath();
    dbPath = '$dir/test_weekly_recap_reminder_'
        '${DateTime.now().microsecondsSinceEpoch}.db';
    rawDb = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(rawDb);
    c = AppContainer(prefs: prefs, db: Db.forTesting(rawDb));
    await c.init();
    // notify.init / rescheduleWeeklyRecap 都是 fire-and-forget 异步链：
    // 等它们落地再断言。
    await Future<void>.delayed(const Duration(milliseconds: 120));
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

  List<Map<String, dynamic>> weeklyScheduled() => [
        for (final call in notifCalls)
          if (call.method == 'zonedSchedule' &&
              (call.arguments as Map)['payload'] ==
                  NotifyService.weeklyRecapPayload)
            (call.arguments as Map).cast<String, dynamic>(),
      ];

  List<int> weeklyCancelled() => [
        for (final call in notifCalls)
          if (call.method == 'cancel')
            (call.arguments as Map)['id'] as int,
      ];

  test('nextWeeklyRecapFires：周日 20:00 默认，当天未到点排当天、之后每 7 天', () {
    // 2026-10-18 是周日。
    final now = DateTime(2026, 10, 18, 19, 30);
    final fires = nextWeeklyRecapFires(
      now: now,
      weekday: DateTime.sunday,
      minutesOfDay: 20 * 60,
    );
    expect(fires, hasLength(NotifyService.weeklyRecapHorizon));
    expect(fires.first, DateTime(2026, 10, 18, 20, 0));
    expect(fires[1], DateTime(2026, 10, 25, 20, 0));
    expect(fires.last, DateTime(2026, 12, 6, 20, 0));
  });

  test('nextWeeklyRecapFires：当天已过点（含正好到点）顺延下周', () {
    final after = nextWeeklyRecapFires(
      now: DateTime(2026, 10, 18, 21, 0),
      weekday: DateTime.sunday,
      minutesOfDay: 20 * 60,
    );
    expect(after.first, DateTime(2026, 10, 25, 20, 0));

    final exactly = nextWeeklyRecapFires(
      now: DateTime(2026, 10, 18, 20, 0),
      weekday: DateTime.sunday,
      minutesOfDay: 20 * 60,
    );
    expect(exactly.first, DateTime(2026, 10, 25, 20, 0),
        reason: '正好到点不能再排一个过去/当下的闹钟');
  });

  test('nextWeeklyRecapFires：未来工作日当天照排，跨月日期正确', () {
    final monday = nextWeeklyRecapFires(
      now: DateTime(2026, 10, 19, 8, 0), // 周一早上
      weekday: DateTime.monday,
      minutesOfDay: 7 * 60,
    );
    expect(monday.first, DateTime(2026, 10, 26, 7, 0),
        reason: '当天 7:00 已过 → 顺延到下周一');
    // 同一天但时刻还没到 → 当天照排
    final mondayEvening = nextWeeklyRecapFires(
      now: DateTime(2026, 10, 19, 8, 0),
      weekday: DateTime.monday,
      minutesOfDay: 20 * 60,
    );
    expect(mondayEvening.first, DateTime(2026, 10, 19, 20, 0));
    // 从 12 月中旬看下一年 1 月：DateTime 自动进位
    final crossYear = nextWeeklyRecapFires(
      now: DateTime(2026, 12, 31, 10, 0),
      weekday: DateTime.sunday,
      minutesOfDay: 20 * 60,
    );
    expect(crossYear.first, DateTime(2027, 1, 3, 20, 0));
  });

  test('启动即排 8 周：payload=weekly_recap、id 40-47、周日本地 20:00', () async {
    final weekly = weeklyScheduled();
    expect(weekly, hasLength(NotifyService.weeklyRecapHorizon));
    expect(
      [for (final a in weekly) a['id']],
      [for (var i = 0; i < NotifyService.weeklyRecapHorizon; i++) 40 + i],
    );
    for (final args in weekly) {
      expect(args['payload'], NotifyService.weeklyRecapPayload);
      final when =
          DateTime.parse(args['scheduledDateTimeISO8601'] as String).toLocal();
      expect(when.weekday, DateTime.sunday);
      expect(when.hour, 20);
      expect(when.minute, 0);
    }
  });

  test('设置变更：取消旧 id 段并按新星期/时刻重排', () async {
    c.settings.weeklyRecapWeekday = DateTime.monday;
    c.settings.weeklyRecapMinOfDay = 7 * 60;
    await c.settings.save();

    notifCalls.clear();
    await c.rescheduleWeeklyRecap();

    expect(
      weeklyCancelled(),
      containsAll([
        for (var i = 0; i < NotifyService.weeklyRecapHorizon; i++) 40 + i,
      ]),
      reason: '重排前必须先取消旧星期/时刻的通知',
    );
    final weekly = weeklyScheduled();
    expect(weekly, hasLength(NotifyService.weeklyRecapHorizon));
    for (final args in weekly) {
      final when =
          DateTime.parse(args['scheduledDateTimeISO8601'] as String).toLocal();
      expect(when.weekday, DateTime.monday);
      expect(when.hour, 7);
    }
  });

  test('关闭开关：取消全部周复盘通知且不再排', () async {
    c.settings.weeklyRecapReminderOn = false;
    await c.settings.save();
    notifCalls.clear();
    await c.rescheduleWeeklyRecap();

    expect(
      weeklyCancelled(),
      containsAll([
        for (var i = 0; i < NotifyService.weeklyRecapHorizon; i++) 40 + i,
      ]),
    );
    expect(weeklyScheduled(), isEmpty);
  });

  test('训练中抑制：开始训练取消 40-47，收工后补排 8 周', () async {
    final today = DateTime.now();
    final plan = await c.db.insertPlan(Plan(
      name: '周复盘提醒测试',
      source: 'manual',
      createdAt: fmtDate(today),
      isActive: 1,
    ));
    final dayId = await c.db.insertPlanDay(PlanDay(
      planId: plan.id!,
      weekday: today.weekday,
      title: '推日',
    ));
    final day = PlanDay(
      id: dayId,
      planId: plan.id!,
      weekday: today.weekday,
      title: '推日',
    );
    final pe = PlanExercise(
      dayId: dayId,
      name: '杠铃卧推',
      orderIdx: 0,
      sets: 1,
      repsMin: 5,
      repsMax: 8,
      restSec: 120,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 1),
    );
    final ex = pe.copyWith(id: await c.db.insertPlanExercise(pe));

    notifCalls.clear();
    await c.session.startFromDay(day: day, planExercises: [ex]);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(c.session.hasActive, isTrue);
    expect(
      weeklyCancelled(),
      containsAll([
        for (var i = 0; i < NotifyService.weeklyRecapHorizon; i++) 40 + i,
      ]),
      reason: '训练进行中必须撤掉周复盘通知，避免到点打断训练',
    );
    expect(weeklyScheduled(), isEmpty,
        reason: '训练进行中不允许重新排周复盘通知');

    notifCalls.clear();
    await c.session.finish();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(c.session.hasActive, isFalse);
    expect(weeklyScheduled(), hasLength(NotifyService.weeklyRecapHorizon),
        reason: '收工后补排下一次（及后续 7 周）');
  });

  testWidgets('设置页：关开关取消，重开/改星期/改时刻都重排', (tester) async {
    tester.view.physicalSize = const Size(412, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final ids = [
      for (var i = 0; i < NotifyService.weeklyRecapHorizon; i++) 40 + i,
    ];
    Future<void> settle([int ms = 150]) async {
      await tester
          .runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
      await tester.pump();
    }

    await tester.pumpWidget(AppScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const TrainingPrefsPage(),
      ),
    ));
    await tester.pump();
    await settle(60);

    // 关：取消 40-47，且不再排
    notifCalls.clear();
    await tester.tap(find.text('每周复盘提醒'));
    await settle();
    expect(weeklyCancelled(), containsAll(ids));
    expect(weeklyScheduled(), isEmpty);

    // 重开：按当前星期/时刻重排 8 周
    notifCalls.clear();
    await tester.tap(find.text('每周复盘提醒'));
    await settle();
    expect(weeklyScheduled(), hasLength(NotifyService.weeklyRecapHorizon));

    // 改星期：周日 → 周一
    notifCalls.clear();
    await tester.tap(find.text('周日'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('周一').last);
    await tester.pump();
    await settle();
    final afterWeekday = weeklyScheduled();
    expect(afterWeekday, hasLength(NotifyService.weeklyRecapHorizon));
    for (final args in afterWeekday) {
      final when =
          DateTime.parse(args['scheduledDateTimeISO8601'] as String).toLocal();
      expect(when.weekday, DateTime.monday);
    }

    // 改时刻：打开时间选择器直接确定（默认 20:00）也会触发取消+重排
    notifCalls.clear();
    final card = find
        .ancestor(of: find.text('每周复盘提醒'), matching: find.byType(Card))
        .first;
    await tester.tap(
      find.descendant(of: card, matching: find.text('提醒时刻')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('OK'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pump();
    await settle();
    expect(weeklyCancelled(), containsAll(ids));
    expect(weeklyScheduled(), hasLength(NotifyService.weeklyRecapHorizon));
  });

  test('点击周复盘通知：payload 命中才请求打开周复盘页', () async {
    final codec = const StandardMethodCodec();
    Future<void> tap(String? payload) async {
      await TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        notifChannel.name,
        codec.encodeMethodCall(MethodCall(
          'didReceiveNotificationResponse',
          <String, Object?>{
            'notificationId': 40,
            'actionId': null,
            'input': null,
            'payload': payload,
            'notificationResponseType': 0,
          },
        )),
        (_) {},
      );
    }

    expect(c.takePendingWeeklyRecap(), isFalse);
    await tap('other_payload');
    expect(c.takePendingWeeklyRecap(), isFalse,
        reason: '别的通知（休息/练前提醒）不能打开周复盘');
    await tap(NotifyService.weeklyRecapPayload);
    expect(c.takePendingWeeklyRecap(), isTrue);
    expect(c.takePendingWeeklyRecap(), isFalse, reason: '请求只消费一次');
  });

  test('冷启动由周复盘通知拉起：init 读 launch details 并请求打开', () async {
    // 覆盖 notify_service 的冷启动分支：App 被通知拉起时不会走
    // onDidReceiveNotificationResponse，只能靠 getNotificationAppLaunchDetails。
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifChannel, (call) async {
      notifCalls.add(call);
      if (call.method == 'getNotificationAppLaunchDetails') {
        return <String, Object?>{
          'notificationLaunchedApp': true,
          'notificationResponse': <String, Object?>{
            'notificationId': 40,
            'actionId': null,
            'input': null,
            'payload': NotifyService.weeklyRecapPayload,
            'notificationResponseType': 0,
          },
        };
      }
      return false;
    });

    var opened = 0;
    final svc = NotifyService()..onWeeklyRecapTap = () => opened++;
    addTearDown(() {
      // 恢复本用例改过的通道 mock，避免影响后续用例的容器初始化
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notifChannel, (call) async {
        notifCalls.add(call);
        if (call.method == 'getNotificationAppLaunchDetails') return null;
        return false;
      });
    });
    await svc.init();
    expect(opened, 1);
  });

  test('冷启动通知 payload 不匹配：不请求打开周复盘页', () async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifChannel, (call) async {
      notifCalls.add(call);
      if (call.method == 'getNotificationAppLaunchDetails') {
        return <String, Object?>{
          'notificationLaunchedApp': true,
          'notificationResponse': <String, Object?>{
            'notificationId': 2,
            'actionId': null,
            'input': null,
            'payload': 'rest_timer',
            'notificationResponseType': 0,
          },
        };
      }
      return false;
    });

    var opened = 0;
    final svc = NotifyService()..onWeeklyRecapTap = () => opened++;
    addTearDown(() {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notifChannel, (call) async {
        notifCalls.add(call);
        if (call.method == 'getNotificationAppLaunchDetails') return null;
        return false;
      });
    });
    await svc.init();
    expect(opened, 0);
  });
}
