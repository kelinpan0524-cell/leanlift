// 周复盘页测试：
//  - 空数据：360dp 窄屏下五张 SectionCard 正常渲染、无计划空态、英文模式不溢出
//  - 真数据路径：计划解析、sessionRowsBetween 明细解析、计划日精确匹配
//  - 计划 createdAt / activatedAt 截止：启用前的日子不算假缺勤
//  - 自动顺延：按顺延后的排程只计一次，不把同一内容算两遍
//  - 手动休息/清空/改期：墓碑不当作缺勤，改期只算目的地
//  - 计划外训练与计划内加组：实际总量主展示、计划外组数单独说明
//  - 减载标记接线：减载场不参与 1RM 进步/停滞判断
import 'dart:convert';

import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/services/ai_service.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:baoji_timer/ui/theme.dart';
import 'package:baoji_timer/ui/weekly_recap_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 固定「今天」= 2026-10-11（周日），本周 = 10-05 .. 10-11。
final _now = DateTime(2026, 10, 11, 20);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppContainer container;
  late Database rawDb;
  late String dbPath;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = await databaseFactory.getDatabasesPath();
    dbPath =
        '$dir/test_weekly_recap_page_${DateTime.now().microsecondsSinceEpoch}.db';
    rawDb = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(rawDb);
    container = AppContainer(prefs: prefs, db: Db.forTesting(rawDb));
    await container.db.wipeAll();
  });

  tearDown(() async {
    container.dispose();
    try {
      await rawDb.close();
    } catch (_) {}
    try {
      await databaseFactory.deleteDatabase(dbPath);
    } catch (_) {}
  });

  Future<int> addPlanDay({
    required int planId,
    required int weekday,
    int sets = 3,
  }) async {
    final dayId = await container.db.insertPlanDay(
      PlanDay(planId: planId, weekday: weekday, title: '周$weekday'),
    );
    await container.db.insertPlanExercise(
      PlanExercise(
        dayId: dayId,
        name: '杠铃卧推',
        orderIdx: 0,
        sets: sets,
        repsMin: 8,
        repsMax: 12,
        restSec: 90,
        kind: 'assistance',
        rule: const ProgressionRule(repsMin: 8, repsMax: 12, workingSets: 3),
      ),
    );
    return dayId;
  }

  Future<int> addSession({
    required DateTime date,
    int? planDayId,
    int sets = 3,
    String name = '杠铃卧推',
    double weight = 60,
    int reps = 10,
  }) async {
    final (session, exercises) = await container.db.insertSessionWithExercises(
      Session(
        date: fmtDate(date),
        planDayId: planDayId,
        planDayTitle: '训练',
        startedAt: date.millisecondsSinceEpoch,
        endedAt: date.millisecondsSinceEpoch + 3600000,
        status: 'done',
      ),
      [
        SessionExercise(
          sessionId: 0,
          name: name,
          orderIdx: 0,
          kind: 'assistance',
          rule: const ProgressionRule(repsMin: 8, repsMax: 12, workingSets: 3),
          targetSets: sets,
        ),
      ],
    );
    for (var i = 0; i < sets; i++) {
      await container.db.insertSet(
        SetEntry(
          sessionExerciseId: exercises.single.id!,
          weightKg: weight,
          reps: reps,
          kind: SetKind.working,
          doneAt: date.millisecondsSinceEpoch + i * 1000,
        ),
      );
    }
    return session.id!;
  }

  /// 重新创建 AppContainer，让 SessionController 从新 prefs 读减载标记。
  Future<void> rebindWithPrefs(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final prefs = await SharedPreferences.getInstance();
    container.dispose();
    container = AppContainer(prefs: prefs, db: Db.forTesting(rawDb));
  }

  /// 配好 AI（测试用 MockClient，无真实网络）+ 打开 AI 自动写周报。
  Future<void> rebindWithAi(
    http.Client client, {
    bool aiWeeklyOn = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      'set.aiBaseUrl': 'http://127.0.0.1:1',
      'set.aiApiKey': 'sk-test',
      'set.aiModel': 'test-model',
      'set.aiWeeklyRecapOn': aiWeeklyOn,
    });
    final prefs = await SharedPreferences.getInstance();
    container.dispose();
    container = AppContainer(
      prefs: prefs,
      db: Db.forTesting(rawDb),
      aiOverride: AiService(Settings(prefs), httpClient: client),
    );
  }

  http.Response aiReply(String text) => http.Response.bytes(
        utf8.encode(jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': text}
            }
          ]
        })),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        AppScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark,
            home: WeeklyRecapPage(now: _now),
          ),
        ),
      );
      await tester.pump();
      // 真实 DB 查询走异步，给页面加载留出时间
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
  }

  /// 带路由观察者的宿主：验证 didPopNext（返回页面补算）必须注册
  /// [weeklyRecapRouteObserver]，否则 RouteAware 收不到事件。
  Widget observerHost(Widget home) => AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          navigatorObservers: [weeklyRecapRouteObserver],
          home: home,
        ),
      );

  String valueOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  testWidgets('空数据：周复盘页正常渲染、无计划空态、不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    await pumpPage(tester);

    expect(find.text('周复盘'), findsOneWidget);
    expect(find.text('本周完成度'), findsOneWidget);
    expect(find.text('下周行动'), findsOneWidget);
    expect(find.text('进步与停滞'), findsOneWidget);
    expect(find.textContaining('没有安排训练'), findsOneWidget);
    // 无计划时展示实际总量，不再出现「0/—」
    expect(valueOf(tester, 'recap-total-sessions'), '0');
    expect(valueOf(tester, 'recap-total-sets'), '0');
    expect(find.byKey(const ValueKey('recap-plan-sessions')), findsNothing);
    expect(find.text('0/—'), findsNothing);
    expect(find.textContaining('本周没有可对照的计划训练'), findsOneWidget);
    // 后两张卡在 360×800 首屏之外：滚动到它们可见，确认能正常构建
    await tester.scrollUntilVisible(
      find.text('肌群周组数'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('肌群周组数'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('7 天体重趋势'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('近 7 天还没有体重记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('英文模式：360 宽渲染不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(true);
    addTearDown(() => Lang.setResolved(false));

    await pumpPage(tester);

    expect(find.text('Weekly Recap'), findsOneWidget);
    expect(find.text('This Week'), findsOneWidget);
    expect(find.text('Next Action'), findsOneWidget);
    expect(find.text('Progress & Stalls'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Weekly Sets by Muscle'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Weekly Sets by Muscle'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('7-Day Weight Trend'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('7-Day Weight Trend'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('真数据：实际总量主展示，计划进度 1/1 与 3/3', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    await tester.runAsync(() async {
      final plan = await container.db.insertPlan(
        Plan(
          name: '测试计划',
          source: 'manual',
          createdAt: '2026-10-05',
          isActive: 1,
        ),
      );
      final dayId = await addPlanDay(planId: plan.id!, weekday: 1, sets: 3);
      await addSession(date: DateTime(2026, 10, 5), planDayId: dayId, sets: 3);
    });
    await pumpPage(tester);

    expect(valueOf(tester, 'recap-total-sessions'), '1');
    expect(valueOf(tester, 'recap-total-sets'), '3');
    expect(valueOf(tester, 'recap-plan-sessions'), '1/1');
    expect(valueOf(tester, 'recap-plan-sets'), '3/3');
    expect(find.textContaining('加量'), findsOneWidget);
    expect(find.textContaining('近期还没有可对比的动作'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('计划创建于周中：只算创建后的计划日，周一不算假缺勤', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    await tester.runAsync(() async {
      final plan = await container.db.insertPlan(
        Plan(
          name: '周三新建',
          source: 'manual',
          createdAt: '2026-10-07',
          isActive: 1,
        ),
      );
      // 周一在创建之前，周五在创建之后：只应算周五
      await addPlanDay(planId: plan.id!, weekday: 1, sets: 3);
      await addPlanDay(planId: plan.id!, weekday: 5, sets: 3);
    });
    await pumpPage(tester);

    expect(valueOf(tester, 'recap-plan-sessions'), '0/1');
    expect(valueOf(tester, 'recap-plan-sets'), '0/3');
    expect(tester.takeException(), isNull);
  });

  testWidgets('计划启用晚于创建：启用前的日子不算假缺勤', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    await tester.runAsync(() async {
      final plan = await container.db.insertPlan(
        Plan(
          name: '老计划周中启用',
          source: 'manual',
          createdAt: '2026-09-01',
          activatedAt: '2026-10-07',
          isActive: 1,
        ),
      );
      await addPlanDay(planId: plan.id!, weekday: 1, sets: 3);
      await addPlanDay(planId: plan.id!, weekday: 5, sets: 3);
    });
    await pumpPage(tester);

    expect(valueOf(tester, 'recap-plan-sessions'), '0/1');
    expect(valueOf(tester, 'recap-plan-sets'), '0/3');
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动顺延：按顺延后的排程只计一次，不重复相加', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    await tester.runAsync(() async {
      final plan = await container.db.insertPlan(
        Plan(
          name: '顺延计划',
          source: 'manual',
          createdAt: '2026-10-05',
          isActive: 1,
          shiftDays: 1,
          shiftFrom: '2026-10-05',
        ),
      );
      final mon = await addPlanDay(planId: plan.id!, weekday: 1, sets: 3);
      final wed = await addPlanDay(planId: plan.id!, weekday: 3, sets: 3);
      final fri = await addPlanDay(planId: plan.id!, weekday: 5, sets: 3);
      // 周一漏练后自动顺延：原日期落休息墓碑，之后整体后移一天
      await container.db.upsertScheduleEntry(
        PlanScheduleEntry(planId: plan.id!, date: '2026-10-05', dayId: null),
      );
      await addSession(date: DateTime(2026, 10, 6), planDayId: mon, sets: 3);
      await addSession(date: DateTime(2026, 10, 8), planDayId: wed, sets: 3);
      await addSession(date: DateTime(2026, 10, 10), planDayId: fri, sets: 3);
    });
    await pumpPage(tester);

    // 顺延后只有周二/周四/周六三个计划日；三场都练了 → 3/3，不是 3/4
    expect(valueOf(tester, 'recap-total-sessions'), '3');
    expect(valueOf(tester, 'recap-total-sets'), '9');
    expect(valueOf(tester, 'recap-plan-sessions'), '3/3');
    expect(valueOf(tester, 'recap-plan-sets'), '9/9');
    expect(find.textContaining('差 1 次'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手动休息/清空：墓碑不当作缺勤', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    await tester.runAsync(() async {
      final plan = await container.db.insertPlan(
        Plan(
          name: '手动休息',
          source: 'manual',
          createdAt: '2026-10-05',
          isActive: 1,
        ),
      );
      await addPlanDay(planId: plan.id!, weekday: 1, sets: 3);
      await addPlanDay(planId: plan.id!, weekday: 5, sets: 3);
      await container.db.upsertScheduleEntry(
        PlanScheduleEntry(planId: plan.id!, date: '2026-10-05', dayId: null),
      );
    });
    await pumpPage(tester);

    // 只在周五有 1 个计划日；周一的显式休息不算缺勤
    expect(valueOf(tester, 'recap-plan-sessions'), '0/1');
    expect(valueOf(tester, 'recap-plan-sets'), '0/3');
    expect(tester.takeException(), isNull);
  });

  testWidgets('手动改期：只算目的地，原日期不算缺勤', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    await tester.runAsync(() async {
      final plan = await container.db.insertPlan(
        Plan(
          name: '手动改期',
          source: 'manual',
          createdAt: '2026-10-05',
          isActive: 1,
        ),
      );
      final mon = await addPlanDay(planId: plan.id!, weekday: 1, sets: 3);
      await addPlanDay(planId: plan.id!, weekday: 5, sets: 3);
      // 周一挪到周二：原日期休息墓碑，周二覆盖为周一内容
      await container.db.upsertScheduleEntry(
        PlanScheduleEntry(planId: plan.id!, date: '2026-10-05', dayId: null),
      );
      await container.db.upsertScheduleEntry(
        PlanScheduleEntry(planId: plan.id!, date: '2026-10-06', dayId: mon),
      );
      await addSession(date: DateTime(2026, 10, 6), planDayId: mon, sets: 3);
    });
    await pumpPage(tester);

    // 周二 + 周五 = 2 个计划日；完成后计划进度 1/2，不是 1/3
    expect(valueOf(tester, 'recap-plan-sessions'), '1/2');
    expect(valueOf(tester, 'recap-plan-sets'), '3/6');
    expect(valueOf(tester, 'recap-total-sessions'), '1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('计划外训练与计划内加组：实际总量主展示、计划外组数单独说明', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    await tester.runAsync(() async {
      final plan = await container.db.insertPlan(
        Plan(
          name: '加组计划',
          source: 'manual',
          createdAt: '2026-10-05',
          isActive: 1,
        ),
      );
      final dayId = await addPlanDay(planId: plan.id!, weekday: 1, sets: 3);
      // 计划日做了 5 组（多 2 组）
      await addSession(date: DateTime(2026, 10, 5), planDayId: dayId, sets: 5);
      // 另外两场计划外训练各 2 组
      await addSession(date: DateTime(2026, 10, 6), sets: 2);
      await addSession(date: DateTime(2026, 10, 7), sets: 2);
    });
    await pumpPage(tester);

    expect(valueOf(tester, 'recap-total-sessions'), '3');
    expect(valueOf(tester, 'recap-total-sets'), '9');
    // 计划完成按当日计划组数封顶：3/3，不是 5/3
    expect(valueOf(tester, 'recap-plan-sessions'), '1/1');
    expect(valueOf(tester, 'recap-plan-sets'), '3/3');
    expect(find.textContaining('计划外训练'), findsOneWidget);
    expect(find.textContaining('含计划内加组'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自定义动作：肌群卡显示「其他」组数，不假装没练', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    await tester.runAsync(() async {
      // 词表外动作没有肌群映射 → 全部计入「其他」
      await addSession(date: DateTime(2026, 10, 5), sets: 3, name: '我的自创动作');
    });
    await pumpPage(tester);

    await tester.scrollUntilVisible(
      find.textContaining('未归类动作'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('未归类动作'), findsOneWidget);
    expect(find.textContaining('3 组'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('减载标记接线：减载场不参与 1RM 进步/停滞判断', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    late int deloadSessionId;
    await tester.runAsync(() async {
      final plan = await container.db.insertPlan(
        Plan(
          name: '减载计划',
          source: 'manual',
          createdAt: '2026-10-05',
          isActive: 1,
        ),
      );
      final dayId = await addPlanDay(planId: plan.id!, weekday: 1, sets: 3);
      // 上周正常 60×8；本周减载 55×8（标记后不参与进步/停滞）
      await addSession(
        date: DateTime(2026, 9, 29),
        sets: 3,
        weight: 60,
        reps: 8,
      );
      deloadSessionId = await addSession(
        date: DateTime(2026, 10, 5),
        planDayId: dayId,
        sets: 3,
        weight: 55,
        reps: 8,
      );
      await rebindWithPrefs({
        'block.deloadSessionIds': jsonEncode([
          '$deloadSessionId|2026-10-05|${DateTime(2026, 10, 5).millisecondsSinceEpoch}',
        ]),
      });
    });
    await pumpPage(tester);

    expect(
      find.textContaining('近期还没有可对比的动作'),
      findsOneWidget,
      reason: '减载场被排除后没有可对比的 1RM',
    );
    expect(find.textContaining('没超过上周'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 周报：配置 AI 且开关打开时，页面打开后调用一次并展示叙事',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    var calls = 0;
    await tester.runAsync(() async {
      await rebindWithAi(MockClient((req) async {
        calls++;
        return aiReply('这周练得不错，下周卧推加到 62.5kg。');
      }));
    });

    await pumpPage(tester);
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 150)));
    await tester.pump();

    expect(find.text('AI 周报'), findsOneWidget);
    expect(find.byKey(const ValueKey('recap-ai-text')), findsOneWidget);
    expect(find.text('这周练得不错，下周卧推加到 62.5kg。'), findsOneWidget);
    expect(calls, 1, reason: '页面打开只生成一次，不重复请求');
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 周报：开关关闭时不请求 AI', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    var calls = 0;
    await tester.runAsync(() async {
      await rebindWithAi(
        MockClient((req) async {
          calls++;
          return aiReply('不该出现');
        }),
        aiWeeklyOn: false,
      );
    });

    await pumpPage(tester);
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 150)));
    await tester.pump();

    expect(find.text('AI 周报'), findsNothing);
    expect(calls, 0, reason: '默认关；用户没打开就不允许联网');
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 未配置：即使旧开关为开也不显示 AI 卡、不请求', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    await tester.runAsync(() async {
      // 只有持久化的开关、没有 AI 配置：授权不成立
      await rebindWithPrefs({'set.aiWeeklyRecapOn': true});
    });

    await pumpPage(tester);
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 150)));
    await tester.pump();

    expect(find.text('AI 周报'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('前台门控：App 非前台不请求 AI，回前台补一次', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    var calls = 0;
    await tester.runAsync(() async {
      await rebindWithAi(MockClient((req) async {
        calls++;
        return aiReply('回到前台生成的周报');
      }));
    });

    final binding = tester.binding;
    // 用 inactive（非前台但不冻结帧）：验证 lifecycle 门控本身；
    // paused 会禁用测试帧，页面根本不会布局，不适合做 UI 断言。
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(WidgetsBinding.instance.lifecycleState, AppLifecycleState.inactive);
    addTearDown(() {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    await pumpPage(tester);
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 150)));
    await tester.pump();
    expect(find.byType(WeeklyRecapPage), findsOneWidget);
    expect(calls, 0, reason: 'App 非前台时页面打开不得发起 AI 请求');

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(WidgetsBinding.instance.lifecycleState, AppLifecycleState.resumed);
    // 后台/非前台期间页面首帧的加载与 AI 请求要等回前台才跑：
    // 多给一点真实时间让 DB 查询 + MockClient 落地。
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 600)));
    await tester.pump();
    await tester.pump();

    expect(calls, 1, reason: '回到前台且本页仍是当前路由，补一次');
    expect(find.byKey(const ValueKey('recap-ai-text')), findsOneWidget);
    expect(find.text('回到前台生成的周报'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 周报失败：回退本地版并提示可重试，重试成功后展示', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    var calls = 0;
    await tester.runAsync(() async {
      await rebindWithAi(MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            '{"error":{"message":"upstream boom"}}',
            500,
            headers: {'content-type': 'application/json'},
          );
        }
        return aiReply('重试成功：下周先把背补上。');
      }));
    });

    await pumpPage(tester);
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 150)));
    await tester.pump();

    expect(find.byKey(const ValueKey('recap-ai-fallback')), findsOneWidget);
    expect(find.textContaining('已显示下面的本地版'), findsOneWidget);
    // 本地版内容照常可见（AI 失败不遮挡复盘）
    expect(find.text('本周完成度'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 150)));
    await tester.pump();

    expect(calls, 2);
    expect(find.byKey(const ValueKey('recap-ai-text')), findsOneWidget);
    expect(find.text('重试成功：下周先把背补上。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未请求过且没在加载：AI 卡显示手动生成入口，不显示假加载',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    var calls = 0;
    await tester.runAsync(() async {
      await rebindWithAi(MockClient((req) async {
        calls++;
        return aiReply('手动触发生成的周报');
      }));
    });

    final binding = tester.binding;
    // 打开页面时 App 非前台 → 首载不请求（_aiRequested 保持 false）。
    // 修改前这里会显示永远转下去的「AI 正在写这周总结…」假加载。
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    addTearDown(() {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    await pumpPage(tester);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    expect(calls, 0, reason: '非前台不自动请求');
    expect(find.byKey(const ValueKey('recap-ai-pending')), findsOneWidget,
        reason: '没请求过且没在加载 → 明确的待生成态');
    expect(find.textContaining('AI 正在写这周总结'), findsNothing,
        reason: '没有在途请求就不能显示加载行（不再永久转圈）');
    expect(find.text('生成 AI 周报'), findsOneWidget);

    // 回前台后手动点生成 → 请求一次并展示
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.tap(find.text('生成 AI 周报'));
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    expect(calls, 1);
    expect(find.byKey(const ValueKey('recap-ai-text')), findsOneWidget);
    expect(find.text('手动触发生成的周报'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('didPopNext：被盖住时首载没请求，返回页面补算一次', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    var calls = 0;
    await tester.runAsync(() async {
      await rebindWithAi(MockClient((req) async {
        calls++;
        return aiReply('返回页面补算的周报');
      }));
    });

    await tester.pumpWidget(observerHost(const Scaffold(
      body: Center(child: Text('root')),
    )));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));

    // 打开复盘页并**立刻盖上另一页**：复盘页的本地数据加载（真实异步，
    // 约几百毫秒）在覆盖期间完成，路由已不是 current，前台+当前路由的
    // 门控挡住请求，_aiRequested 保持 false。
    // 注意不能 pumpAndSettle：首帧全页 loading 转圈是无限动画，永不 settle。
    await tester.runAsync(() async {
      nav.push(MaterialPageRoute(builder: (_) => WeeklyRecapPage(now: _now)));
      await tester.pump(); // recap 首帧（postFrame 里开始 _load）
      nav.push(MaterialPageRoute(
          builder: (_) =>
              const Scaffold(body: Center(child: Text('盖住的页')))));
      await tester.pump(); // cover 进场
      // _load 的真实 DB 查询在 runAsync 窗口内推进，于覆盖期间完成
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump();

    expect(find.text('盖住的页'), findsOneWidget, reason: '覆盖页确实在顶层');
    expect(calls, 0, reason: '页面被盖住时不联网');

    // pop 回复盘页：didPopNext 随 pop 触发 → 补算。用固定帧序列走完
    // 退场动画（AI 转圈开始后 pumpAndSettle 同样会超时）。
    nav.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pump();

    expect(calls, 1, reason: 'didPopNext 返回页面时补发一次生成');
    expect(find.byKey(const ValueKey('recap-ai-text')), findsOneWidget);
    expect(find.text('返回页面补算的周报'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('下拉刷新：已生成过 AI 时不重复请求（不重复烧 Token）',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Lang.setResolved(false);

    var calls = 0;
    await tester.runAsync(() async {
      await rebindWithAi(MockClient((req) async {
        calls++;
        return aiReply('只生成一次的周报');
      }));
    });

    await pumpPage(tester);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    expect(calls, 1);

    // 下拉刷新本地数据：AI 已生成过（_aiRequested=true）→ 门控拦住
    await tester.runAsync(() async {
      await tester.drag(find.byType(ListView).first, const Offset(0, 200));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    expect(calls, 1, reason: '刷新本地数据不为 AI 重复联网');
    expect(find.byKey(const ValueKey('recap-ai-text')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
