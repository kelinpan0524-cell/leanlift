// 今日页「今天已练完」状态回归测试（2026-09-27 Arono 反馈）：
// 今天该练的内容已经练完时，今日卡不再摆「开始训练」引导重练同一份
// 计划，而是完成态（✓ 标题）+「今天加练」入口；没练完时行为不变。
// 基建同 workout_flow_widget_test：真库（ffi）+ AppContainer 注入，
// DB 操作包 tester.runAsync，加载态用真实延时 ↔ pump 交替推进。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/ui/home_page.dart';
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
    await container.db.wipeAll();
    container.dispose();
  });

  /// 建一个「今天」恰好排上训练日「推日」的计划（weekday=今天的星期），
  /// 并可选插入一条今天已完成的 session（planDayTitle 同名）。
  /// [extra] = 额外加几个辅助动作（20 分钟入口的跳过文案用）。
  Future<void> seed({required bool doneToday, int extra = 0}) async {
    final now = DateTime.now();
    final plan = await container.db.insertPlan(Plan(
        name: '测试计划-完成态',
        source: 'manual',
        createdAt: '2026-09-27',
        isActive: 1));
    final dayId = await container.db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: now.weekday, title: '推日'));
    await container.db.insertPlanExercise(PlanExercise(
      dayId: dayId,
      name: '卧推',
      orderIdx: 0,
      sets: 3,
      repsMin: 5,
      repsMax: 8,
      restSec: 120,
      kind: 'compound',
      rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
    ));
    for (var i = 1; i <= extra; i++) {
      await container.db.insertPlanExercise(PlanExercise(
        dayId: dayId,
        name: '辅助$i',
        orderIdx: i,
        sets: 3,
        repsMin: 8,
        repsMax: 12,
        restSec: 90,
        kind: 'assistance',
        rule: ProgressionRule(repsMin: 8, repsMax: 12, workingSets: 3),
      ));
    }
    if (doneToday) {
      await container.db.insertSession(Session(
        date: fmtDate(now),
        planDayId: dayId,
        planDayTitle: '推日',
        startedAt: now.millisecondsSinceEpoch - 3600000,
        endedAt: now.millisecondsSinceEpoch,
        status: 'done',
      ));
    }
  }

  /// pump 首页并等加载完成（首页 FutureBuilder 走 ffi 后台 isolate，
  /// 用真实延时 ↔ pump 交替推进到「今天」卡出现）。
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

  testWidgets('今天已练完：完成态卡 + 加练入口，无「开始训练」', (tester) async {
    await tester.runAsync(() => seed(doneToday: true));
    await pumpHome(tester);

    expect(find.text('今天已练完'), findsOneWidget, reason: '完成态卡片标题');
    expect(find.text('推日'), findsNWidgets(2),
        reason: '完成态卡 + 「上次训练」卡（今天的 session）各一次');
    expect(find.text('开始训练'), findsNothing, reason: '不再引导重练同一份计划');
    expect(find.text('今天加练'), findsOneWidget, reason: '想再动一动的加练入口');
  });

  testWidgets('今天没练：原「今天该练 + 开始训练」不变', (tester) async {
    await tester.runAsync(() => seed(doneToday: false));
    await pumpHome(tester);

    expect(find.text('今天该练'), findsOneWidget);
    expect(find.text('开始训练'), findsOneWidget);
    expect(find.text('只有 20 分钟'), findsOneWidget, reason: '20 分钟精简入口');
    expect(find.text('今天已练完'), findsNothing);
  });

  testWidgets('只有 20 分钟：入口文案说明保留规则、跳过的动作与多余组数', (tester) async {
    // 卧推（复合）+ 辅助1/2/3：复合优先留 3 个 → 辅助3 被跳过
    await tester.runAsync(() => seed(doneToday: false, extra: 3));
    await pumpHome(tester);

    expect(find.text('只有 20 分钟'), findsOneWidget);
    expect(find.textContaining('复合优先保留 3 个动作'),
        findsOneWidget, reason: '说明复合优先与动作上限');
    expect(find.text('跳过：辅助3；多出的组数不练'),
        findsOneWidget, reason: '点名被删掉的动作，并说明组数压缩');
  });
}
