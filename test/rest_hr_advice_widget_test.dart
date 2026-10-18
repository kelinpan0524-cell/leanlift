// P2-F 心率自适应休息建议：休息页集成回归。
// - 已连接 + 心率偏高 → 出现「心率仍高，建议多休 30 秒」与手动 +30 秒；
// - 不点按钮绝不自动加时（心率只提示）；
// - 心率正常时不打扰；未连接时零占位，休息流程照旧；
// - 全程无弹窗。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/services/heart_rate_service.dart';
import 'package:baoji_timer/ui/workout_page.dart';
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

  Widget host(Widget home) => AppScope(
        container: container,
        child: MaterialApp(home: home),
      );

  /// 建一个 3 组、组间 120 秒的动作并开会话，然后直接完成一组进休息态。
  Future<void> enterRest(WidgetTester tester) async {
    await tester.runAsync(() async {
      final plan = await container.db.insertPlan(Plan(
          name: '心率测试计划',
          source: 'manual',
          createdAt: '2026-10-18',
          isActive: 1));
      final dayId = await container.db.insertPlanDay(
          PlanDay(planId: plan.id!, weekday: 3, title: '推日'));
      final day = PlanDay(
          id: dayId, planId: plan.id!, weekday: 3, title: '推日');
      final pe = PlanExercise(
        dayId: dayId,
        name: '卧推',
        orderIdx: 0,
        sets: 3,
        repsMin: 5,
        repsMax: 8,
        restSec: 120,
        kind: 'compound',
        rule: const ProgressionRule(
            repsMin: 5, repsMax: 8, workingSets: 3),
      );
      final id = await container.db.insertPlanExercise(pe);
      await container.session
          .startFromDay(day: day, planExercises: [pe.copyWith(id: id)]);
      await container.session.completeSet(
          weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    });
    await tester.pumpWidget(host(const WorkoutPage()));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('高心率：显示建议与 +30 秒按钮，未点击不自动加时', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await enterRest(tester);
    expect(find.text('组间休息'), findsOneWidget, reason: '确实在休息页');

    container.hr.debugSetReading(bpm: 130);
    await tester.pump();

    expect(find.byKey(const Key('restHrAdvice')), findsOneWidget);
    expect(find.text('心率仍高，建议多休 30 秒'), findsOneWidget);
    expect(find.byKey(const Key('restHrAdviceExtend')), findsOneWidget);

    // 只提示：心率偏高不会自动加时，剩余时间照常递减
    final beforeWait = container.session.restRemainingMs.value;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    final afterWait = container.session.restRemainingMs.value;
    expect(afterWait, lessThan(beforeWait), reason: '心率高只提示，不自动加时');

    // 用户主动点 +30 秒才加时
    await tester.tap(find.byKey(const Key('restHrAdviceExtend')));
    await tester.pump();
    final afterTap = container.session.restRemainingMs.value;
    expect(afterTap - afterWait, greaterThan(25000),
        reason: '点按钮后多休 30 秒');
    expect(find.byType(AlertDialog), findsNothing, reason: '休息中绝不弹窗');
    expect(tester.takeException(), isNull, reason: '建议行在 360 宽不溢出');
  });

  testWidgets('英文界面：建议行不溢出、文案走 en 译法', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Lang.setResolved(true);
    addTearDown(() => Lang.setResolved(false));

    await enterRest(tester);
    container.hr.debugSetReading(bpm: 130);
    await tester.pump();

    expect(find.text('Heart rate still high — consider 30s more rest'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('正常心率不打扰；低心率提示可提前但需手动点', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await enterRest(tester);

    // 95 - 60 = 35，低于高心率阈值 → 不出现任何建议
    container.hr.debugSetReading(bpm: 95);
    await tester.pump();
    expect(find.byKey(const Key('restHrAdvice')), findsNothing);

    // 70 - 60 = 10，已恢复 + 剩余 120 秒 → 提示可提前，但不自动减时
    container.hr.debugSetReading(bpm: 70);
    await tester.pump();
    expect(find.text('心率已恢复，可提前 30 秒开练'), findsOneWidget);
    final beforeTap = container.session.restRemainingMs.value;
    await tester.pump(const Duration(milliseconds: 50));
    expect(container.session.restRemainingMs.value, lessThanOrEqualTo(beforeTap),
        reason: '不点按钮不提前');

    await tester.tap(find.byKey(const Key('restHrAdviceShorten')));
    await tester.pump();
    expect(container.session.restRemainingMs.value, lessThan(beforeTap - 20000),
        reason: '手动点 -30 秒才提前');
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未连接心率：无建议、无占位，休息流程照旧', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await enterRest(tester);
    container.hr.debugSetReading(link: HrLink.idle, bpm: null);
    await tester.pump();

    expect(find.byKey(const Key('restHrAdvice')), findsNothing);
    expect(find.byKey(const Key('restHrAdviceExtend')), findsNothing);
    expect(find.text('组间休息'), findsOneWidget);
    expect(find.text('跳过休息，直接开练'), findsOneWidget,
        reason: '原有休息流程不受影响');
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('矮屏（高<480）：战报收起，但心率建议仍以紧凑布局显示',
      (tester) async {
    tester.view.physicalSize = const Size(360, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await enterRest(tester);
    expect(find.text('组间休息'), findsOneWidget, reason: '确实在休息页');
    expect(find.textContaining('本次战报'), findsNothing,
        reason: '矮屏战报保持收起（showBrief<480 不渲染）');

    container.hr.debugSetReading(bpm: 130);
    await tester.pump();

    expect(find.byKey(const Key('restHrAdvice')), findsOneWidget,
        reason: '恢复与否直接影响训练决策，矮屏也要能显示建议');
    expect(find.text('心率仍高，建议多休 30 秒'), findsOneWidget);
    expect(find.byKey(const Key('restHrAdviceExtend')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '紧凑布局在 360×400 不溢出');

    // 紧凑按钮也能点：手动 +30 秒
    await tester.tap(find.byKey(const Key('restHrAdviceExtend')));
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing, reason: '休息中绝不弹窗');
  });

  testWidgets('旧读数（超过 10 秒未更新）：不作为建议依据', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await enterRest(tester);

    // 高心率但读数已旧（15 秒前）：不能拿旧值建议多休
    container.hr.debugSetReading(
      bpm: 130,
      atMs: DateTime.now().millisecondsSinceEpoch - 15000,
    );
    await tester.pump();
    expect(find.byKey(const Key('restHrAdvice')), findsNothing,
        reason: '超过新鲜度窗口的读数不进建议判定');
    expect(find.byKey(const Key('restHrAdviceExtend')), findsNothing);

    // 新读数立刻恢复建议
    container.hr.debugSetReading(bpm: 130);
    await tester.pump();
    expect(find.byKey(const Key('restHrAdvice')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点心率小标：底部面板显示本次已消耗卡路里（2026-10-18）',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await enterRest(tester);
    // 模拟已练 20 分钟、平均 ~140bpm 的采样（1 分钟 1 个点）
    final now = DateTime.now().millisecondsSinceEpoch;
    container.hr.debugSeedSamples([
      for (var i = 0; i < 20; i++)
        HrPoint(now - (20 - i) * 60000, 135 + (i % 5) * 3),
    ]);
    container.hr.debugSetReading(bpm: 145);
    await tester.pump();

    await tester.tap(find.byKey(const Key('hrRestChip')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('本次训练消耗'), findsOneWidget);
    expect(find.textContaining('千卡'), findsOneWidget,
        reason: '大字卡路里可见（有采样就能算）');
    expect(find.textContaining('练后恢复'), findsOneWidget,
        reason: 'EPOC 拆分小字');
    expect(find.textContaining('平均'), findsOneWidget,
        reason: '平均/峰值一行');
    expect(find.textContaining('仅供参考'), findsOneWidget,
        reason: '估算口径免责说明');

    // 「查看心率曲线」关面板进曲线页
    await tester.tap(find.byKey(const Key('hrSheetOpenCurve')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('心率'), findsWidgets,
        reason: '已进入心率曲线页（原入口保留）');
  });

  testWidgets('点心率但没有采样：面板给引导文案，不崩、不显示 0 千卡',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await enterRest(tester);
    container.hr.debugSetReading(bpm: 120);
    await tester.pump();

    await tester.tap(find.byKey(const Key('hrRestChip')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.textContaining('还没有采到心率数据'), findsOneWidget);
    expect(find.textContaining('千卡'), findsNothing,
        reason: '没数据不给「约 0 千卡」的假数字');
    expect(tester.takeException(), isNull);
  });
}
