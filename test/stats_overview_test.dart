// 数据页概览重设计回归测试（2026-09-27 Arono「数据页乱七八糟」反馈）：
//  - 筛选控件统一为下拉：不再出现 ChoiceChip / SegmentedButton 混排
//  - 指标下拉可切换（容量 → 组数），说明文案随之变化
//  - 1RM 动作下拉打开带搜索的弹层：搜索过滤、可选非主力动作、空结果提示
// 基建同 home_done_today_test：真库（ffi）+ AppContainer 注入，
// DB 操作包 tester.runAsync，加载态用真实延时 ↔ pump 交替推进。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/l10n/names.dart';
import 'package:baoji_timer/ui/stats_page.dart';
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

  /// 两条已完成 session（间隔 9 天，必落在不同的周桶）：
  /// 10 天前只练卧推；昨天练卧推 + 深蹲（卧推容量更高 = 主力，深蹲次之）。
  /// 每条带 restMs 让组间休息趋势也有两个点。
  Future<void> seed() async {
    Future<void> day(DateTime when, List<(String, List<(double, int)>)> exs,
        int restMs) async {
      final ses = await container.db.insertSession(Session(
        date: fmtDate(when),
        planDayTitle: '推日',
        startedAt: when.millisecondsSinceEpoch - 3600000,
        endedAt: when.millisecondsSinceEpoch,
        status: 'done',
        restMs: restMs,
      ));
      final sid = ses.id!;
      for (var i = 0; i < exs.length; i++) {
        final (name, sets) = exs[i];
        final seId = await container.db.insertSessionExercise(SessionExercise(
          sessionId: sid,
          name: name,
          orderIdx: i,
          kind: 'compound',
          rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
        ));
        for (final (w, r) in sets) {
          await container.db.insertSet(SetEntry(
            sessionExerciseId: seId,
            weightKg: w,
            reps: r,
            rir: 2,
            kind: SetKind.working,
            doneAt: when.millisecondsSinceEpoch,
          ));
        }
      }
    }

    final now = DateTime.now();
    await day(now.subtract(const Duration(days: 10)), [('卧推', [(60, 8)])],
        10 * 60 * 1000);
    await day(now.subtract(const Duration(days: 1)), [
      ('卧推', [(65, 8), (65, 8)]),
      ('深蹲', [(80, 5)]),
    ], 20 * 60 * 1000);
  }

  Future<void> pumpStats(WidgetTester tester) async {
    await tester.pumpWidget(AppScope(
        container: container,
        child: const MaterialApp(home: StatsPage())));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 菜单 / 弹层动画推进到稳定（不用 pumpAndSettle：防图表等无限动画）
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('筛选统一为下拉：无 chips / 分段按钮混排', (tester) async {
    await tester.runAsync(seed);
    await pumpStats(tester);

    expect(find.text('训练趋势'), findsOneWidget, reason: '趋势卡标题不再带括号后缀');
    expect(find.text('按周'), findsOneWidget, reason: '粒度下拉（卡片标题行右侧）');
    expect(find.text('容量'), findsOneWidget, reason: '指标下拉');
    expect(find.byType(ChoiceChip), findsNothing,
        reason: '原 chip 混排在窄屏上折行错位，已全部改为下拉');
    expect(find.byType(SegmentedButton<String>), findsNothing,
        reason: 'M3 蓝色分段按钮与绿色主题违和，已移除');
  });

  testWidgets('指标下拉切换：容量 → 组数，说明文案跟随', (tester) async {
    await tester.runAsync(seed);
    await pumpStats(tester);

    expect(find.textContaining('正式组总容量'), findsOneWidget);
    await tester.tap(find.text('容量'));
    await settle(tester);
    await tester.tap(find.text('组数'));
    await settle(tester);
    expect(find.text('组数'), findsOneWidget, reason: '下拉按钮 label 已切换');
    expect(find.text('正式组组数'), findsOneWidget, reason: '指标说明随之更新');
  });

  testWidgets('1RM 动作下拉：搜索过滤 + 可选非主力动作', (tester) async {
    await tester.runAsync(seed);
    await pumpStats(tester);

    // 打开动作选单（卧推容量最高 = 默认选中）
    expect(find.text(exname('卧推')), findsOneWidget);
    await tester.tap(find.byIcon(Icons.fitness_center));
    await settle(tester);
    expect(find.text('选择动作'), findsOneWidget);
    expect(find.text('搜索动作'), findsOneWidget, reason: '动作库全量大，必须有搜索');
    expect(find.text(exname('深蹲')), findsOneWidget, reason: '非主力动作也在列表里');

    // 搜索无匹配
    await tester.enterText(find.byType(TextField), '不存在的动作xyz');
    await tester.pump();
    expect(find.text('没有匹配的动作'), findsOneWidget);

    // 清空搜索，选中深蹲（只有 1 天数据 → 1RM 空态文案）
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    await tester.tap(find.text(exname('深蹲')).last);
    await settle(tester);
    expect(find.text('${exname('深蹲')}：已记 1 天'), findsOneWidget,
        reason: '选中动作的 1RM 空态（第二个动作也能看，不再锁死前 4）');
  });

  /// 切到「肌肉」Tab 并等肌群占比加载完成（同 pumpStats 的真实延时节奏）
  Future<void> openMuscleTab(WidgetTester tester) async {
    await tester.tap(find.text('肌肉'));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 肌群卡很长：800×600 测试视口下未练点名行在折 fold 之下，
  /// Lazy ListView 未物化就找不到——滚到卡尾（以下一张卡出现为准）
  Future<void> scrollToMuscleCardEnd(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      if (find.text('上下肢分布').evaluate().isNotEmpty) return;
      await tester.drag(find.byType(ListView).first, const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('肌群卡未练点名：有漏练肌群时出现', (tester) async {
    await tester.runAsync(seed); // 只练卧推+深蹲（词表外 → 全归「其他」）
    await pumpStats(tester);
    await openMuscleTab(tester);
    await scrollToMuscleCardEnd(tester);
    expect(find.textContaining('未练到'), findsOneWidget,
        reason: '统计期内肩/背/手臂/核心等近零占比 → 一行点名');
  });

  testWidgets('肌群卡未练点名：六大肌群全命中时不出现', (tester) async {
    // 一个 session 覆盖全部六区（词表内动作，主肌群各占 1/6 ≥ 2%）。
    // DB 操作必须包 runAsync：flutter_test 的 FakeAsync 区里真异步不会推进
    await tester.runAsync(() async {
      final now = DateTime.now();
      final ses = await container.db.insertSession(Session(
        date: fmtDate(now),
        planDayTitle: '全身日',
        startedAt: now.millisecondsSinceEpoch - 3600000,
        endedAt: now.millisecondsSinceEpoch,
        status: 'done',
      ));
      final covers = [
        '杠铃卧推', // 胸
        '坐姿哑铃推举', // 肩
        '引体向上', // 背
        '哑铃弯举', // 手臂
        '杠铃深蹲', // 腿
        '卷腹', // 核心
      ];
      for (var i = 0; i < covers.length; i++) {
        final seId = await container.db.insertSessionExercise(SessionExercise(
          sessionId: ses.id!,
          name: covers[i],
          orderIdx: i,
          kind: 'compound',
          rule: ProgressionRule(repsMin: 8, repsMax: 12, workingSets: 1),
        ));
        await container.db.insertSet(SetEntry(
          sessionExerciseId: seId,
          weightKg: 20,
          reps: 10,
          rir: 2,
          kind: SetKind.working,
          doneAt: now.millisecondsSinceEpoch,
        ));
      }
    });
    await pumpStats(tester);
    await openMuscleTab(tester);
    await scrollToMuscleCardEnd(tester);
    expect(find.text('上下肢分布'), findsOneWidget,
        reason: '确认已滚过整张肌群卡（否则「不出现」断言不可信）');
    expect(find.textContaining('未练到'), findsNothing,
        reason: '每区都有足量容量 → 不点名、不占版面');
  });
}
