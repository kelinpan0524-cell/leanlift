// S4：排程拖拽互换的交互反馈（2026-09-24 Arono 反馈"换了没反应"）：
// - 拖到有训练的日子＝互换：放下后出现「已互换」确认 SnackBar（带撤销）；
// - 撤销后 DB 覆盖行还原。
// 真库（ffi）+ AppContainer 注入，DB/异步回包按仓库惯例包 tester.runAsync。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/ui/schedule_views.dart';
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
    container.session.skipRest();
    await container.db.wipeAll();
    container.dispose();
  });

  Widget host(Widget home) =>
      AppScope(container: container, child: MaterialApp(home: home));

  testWidgets('S4：拖拽互换出现「已互换」确认提示，撤销可还原', (tester) async {
    final d0 = DateTime.now();
    final today = DateTime(d0.year, d0.month, d0.day);
    final d2 = today.add(const Duration(days: 2));
    late Plan plan;
    late int dayAId, dayBId;

    await tester.runAsync(() async {
      plan = await container.db.insertPlan(Plan(
          name: '拖拽测试计划',
          source: 'manual',
          createdAt: '2026-09-24',
          isActive: 1));
      // weekday=0：真实日期 weekday 恒为 1..7，避免窗口内其他日期按规则推导出同名训练
      dayAId = await container.db
          .insertPlanDay(PlanDay(planId: plan.id!, weekday: 0, title: '推日'));
      dayBId = await container.db
          .insertPlanDay(PlanDay(planId: plan.id!, weekday: 0, title: '拉日'));
      await container.db.upsertScheduleEntry(PlanScheduleEntry(
          planId: plan.id!, date: fmtDate(today), dayId: dayAId));
      await container.db.upsertScheduleEntry(PlanScheduleEntry(
          planId: plan.id!, date: fmtDate(d2), dayId: dayBId));
    });

    await tester.pumpWidget(host(Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: ScheduleViews(plan: plan, onChanged: () {}),
        ),
      ),
    )));
    // 初始加载：ffi 在后台 isolate，真实延时等回包再渲染。
    // 轮询直到格子渲染出来（固定延时在慢机/满载机上不够，曾致假失败）
    for (var i = 0;
        i < 10 && find.text('推日').evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump();

    final src = find.text('推日');
    final wd = '一二三四五六日'[d2.weekday - 1];
    final dst = find.text('周$wd ${d2.month}/${d2.day}');
    expect(src, findsOneWidget, reason: '今天应有训练「推日」');
    expect(dst, findsOneWidget, reason: '今天+2 应有目标行');

    // 长按拖动（>120ms 延迟起拖）。起终点坐标先取好：
    // 起拖后跟随 Chip 上也有「推日」字样，再 find 会撞。
    final srcCenter = tester.getCenter(src);
    final dstCenter = tester.getCenter(dst);
    final gesture = await tester.startGesture(srcCenter);
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveBy(dstCenter - srcCenter);
    await tester.pump();
    await gesture.up();
    // accept 回调走真库异步：轮询直到确认提示出现（固定延时在慢机/
    // 满载机上不够，互换的 DB 写回未落就会假失败）
    for (var i = 0;
        i < 10 && find.textContaining('已互换').evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }

    expect(find.textContaining('已互换'), findsOneWidget,
        reason: '互换后应出现确认提示');
    expect(find.text('推日'), findsOneWidget, reason: '互换后「推日」仍在屏上');

    // 等提示条滑入动画完成再点按钮本体（动画中按钮位置未定，命中测试会落偏）
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(SnackBarAction));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();

    var restored = false;
    await tester.runAsync(() async {
      final e = await container.db.scheduleEntryOn(plan.id!, fmtDate(today));
      restored = e?.dayId == dayAId;
    });
    expect(restored, isTrue, reason: '撤销后今天的训练应还原为「推日」');

    // 收尾排水：accept/undo 触发的 _reload 仍在后台跑（真库 isolate），
    // 让它在 tearDown 关库前落地——否则「database already closed」异常
    // 会算到已完成的测试头上（b47 发布 run 与本地满载时的同款假失败）
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
  });
}
