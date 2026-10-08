// 调研条目 8：一屏一组的页面流 widget 测试。
// 覆盖：起始页（零记录先见计划文案）→ 顶部『第 N/M 组』→ 底部 3px 进度条
// 全程比例 → 保存一组「校验→写库→划线标记→自动翻页」全链 → 休息页插队 →
// 跳页面板（收起面板，已完成组划线锁定）→ 全程无 showDialog。
// 基建同 widget_layout_test.dart：真库（ffi）+ AppContainer 注入；
// DB/会话操作与"UI tap 触发 DB"的链路必须包进 tester.runAsync。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/services/session_controller.dart';
import 'package:baoji_timer/ui/workout_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final binding = TestWidgetsFlutterBinding.instance;
    // 测试环境没有宿主插件：给会碰到的平台通道挂空实现（同 widget_layout_test）
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
    // 若挂在休息态：取消 250ms tick 真实定时器，避免 pending timer
    container.session.skipRest();
    await container.db.wipeAll();
    container.dispose();
  });

  Widget host(AppContainer c, Widget home) =>
      AppScope(container: c, child: MaterialApp(home: home));

  void setSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  void expectNoLayoutError(WidgetTester tester) {
    final err = tester.takeException();
    if (err != null) fail('页面布局异常: $err');
  }

  Future<PlanDay> makeDay(String title) async {
    final plan = await container.db.insertPlan(Plan(
        name: '测试计划-$title',
        source: 'manual',
        createdAt: '2026-09-25',
        isActive: 1));
    final dayId = await container.db
        .insertPlanDay(PlanDay(planId: plan.id!, weekday: 3, title: title));
    return PlanDay(id: dayId, planId: plan.id!, weekday: 3, title: title);
  }

  Future<PlanExercise> addEx(PlanDay day, String name, int order,
      {int workingSets = 3, int restSec = 120}) async {
    final pe = PlanExercise(
      dayId: day.id!,
      name: name,
      orderIdx: order,
      sets: workingSets,
      repsMin: 5,
      repsMax: 8,
      restSec: restSec,
      kind: 'compound',
      rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: workingSets),
    );
    final id = await container.db.insertPlanExercise(pe);
    return pe.copyWith(id: id);
  }

  /// 造 2 动作 × 各 3 计划组并开会话。
  Future<void> startLifting(WidgetTester tester) async {
    await tester.runAsync(() async {
      final day = await makeDay('推日');
      final a = await addEx(day, '卧推', 0);
      final b = await addEx(day, '划船', 1);
      await container.session.startFromDay(day: day, planExercises: [a, b]);
    });
  }

  /// pump 训练页；零记录会话先落起始页，点「开始训练」进第一记录页。
  /// 末尾补一帧：AnimatedSwitcher 的 outgoing 子树在动画完成的下一帧才移除。
  Future<void> pumpWorkout(WidgetTester tester,
      {bool throughStart = true}) async {
    await tester.pumpWidget(host(container, const WorkoutPage()));
    await tester.pump(const Duration(milliseconds: 20));
    if (throughStart && find.text('开始训练').evaluate().isNotEmpty) {
      await tester.tap(find.text('开始训练'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  LinearProgressIndicator progressBar(WidgetTester tester) =>
      tester.widget<LinearProgressIndicator>(
          find.byKey(const Key('workoutFlowProgress')));

  /// 选余力 2（余力没填写提醒上线后，落库路径需先填余力；
  /// RIR chip 的 '2' 与次数格 3-10、页面指示 '1 / 2' 均不冲突）
  Future<void> pickRir2(WidgetTester tester) async {
    await tester.tap(find.text('2').first);
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('起始页（计划文案 + 大按钮进流程）', () {
    testWidgets('零记录新会话先见起始页：日标题/动作清单/开始训练；进度条 3px 起点为 0',
        (tester) async {
      setSurface(tester, const Size(360, 800));
      await startLifting(tester);
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.text('推日'), findsOneWidget, reason: '计划文案：日标题');
      expect(find.textContaining('2 个动作 · 6 个正式组'), findsOneWidget);
      expect(find.text('卧推'), findsOneWidget, reason: '动作清单');
      expect(find.text('划船'), findsOneWidget);
      expect(find.byKey(const Key('workoutCompleteSet')), findsNothing,
          reason: '起始页不是记录页');

      final bar = progressBar(tester);
      expect(bar.minHeight, 3.0, reason: 'wger 口径：3px 细进度条');
      expect(bar.value, 0);

      await tester.tap(find.text('开始训练'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('workoutCompleteSet')), findsOneWidget,
          reason: '开始后进入第一记录页');
    });

    testWidgets('已有记录时（恢复/返回）不经过起始页，直接落到当前记录页', (tester) async {
      setSurface(tester, const Size(360, 800));
      await startLifting(tester);
      await tester.runAsync(() async {
        await container.session
            .completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
        container.session.skipRest();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('开始训练'), findsNothing, reason: '有记录不显示起始页');
      expect(find.byKey(const Key('workoutCompleteSet')), findsOneWidget);
      expect(find.text('第 2/3 组'), findsOneWidget, reason: '顶部 N/M 对齐已记 1 组');
    });
  });

  group('保存一组：划线标记 → 自动翻页（核心链路）', () {
    testWidgets('完成本组 → 「已记录」划线章 → 自动翻到休息页 → 跳过休息到第 2 组',
        (tester) async {
      setSurface(tester, const Size(360, 800));
      await startLifting(tester);
      await pumpWorkout(tester);
      expect(find.text('第 1/3 组'), findsOneWidget);
      expect(progressBar(tester).value, 0);

      await tester.runAsync(() async {
        await pickRir2(tester);
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        // DB 写组 + 控制器进休息的链路在真实 isolate：给回包时间
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('已记录'), findsOneWidget, reason: '划线标记：盖「已记录」章');
      expect(find.textContaining('kg × '), findsOneWidget,
          reason: '刚存的组带划线展示（默认重量 20kg × 默认次数 5）');

      // 划线窗口（900ms 定时器在 runAsync 的真实区创建）：真实延时等它走完，
      // 再 pump 应用状态机算出的下一页（休息页插队）
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1000)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('组间休息'), findsOneWidget, reason: '自动翻到休息页');
      expect(find.text('已记录'), findsNothing);
      expect(find.text('第 2/3 组'), findsOneWidget, reason: '休息页顶部也是下一组 N/M');
      expect(progressBar(tester).value, closeTo(1 / 6, 1e-6),
          reason: '全程完成比例随保存推进');

      await tester.tap(find.text('跳过休息，直接开练'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('workoutCompleteSet')), findsOneWidget,
          reason: '跳过休息回到第 2 组记录页');
      expect(find.text('第 2/3 组'), findsOneWidget);
      expect(progressBar(tester).value, closeTo(1 / 6, 1e-6));
    });

    testWidgets('热身/力竭组不推进页面（与控制器语义一致）', (tester) async {
      setSurface(tester, const Size(360, 800));
      await startLifting(tester);
      await pumpWorkout(tester);

      await tester.tap(find.text('热身'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('已记录'), findsOneWidget, reason: '热身组也盖划线章');
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('组间休息'), findsNothing,
          reason: '热身组不触发休息计时（调研条目 9 规则）');
      expect(find.byKey(const Key('workoutCompleteSet')), findsOneWidget,
          reason: '仍停在原页（只有正式组推进"下一组"）');
      expect(find.text('第 1/3 组'), findsOneWidget);
      expect(progressBar(tester).value, 0, reason: '热身组不计入全程进度');
    });
  });

  group('跳页面板（收起面板，禁弹窗）', () {
    testWidgets('面板列出全程组页：已完成划线锁定、当前标记、可跳到另一动作', (tester) async {
      setSurface(tester, const Size(360, 800));
      await startLifting(tester);
      await pumpWorkout(tester);
      await tester.runAsync(() async {
        await container.session
            .completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
        container.session.skipRest();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('第 2/3 组'), findsOneWidget);

      // 顶部『第 N/M 组』chip 打开跳页面板（弹层动画：先 pump() 起帧再推进）
      await tester.tap(find.text('第 2/3 组'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('全程页面 · 点未完成组的行直接跳过去'), findsOneWidget);
      expect(find.text('第 1 组'), findsNWidgets(2), reason: '两动作各一个第 1 组');
      expect(find.text('当前'), findsOneWidget, reason: '卧推第 2 组是当前页');

      // 卧推第 1 组已完成（列表序在前）：划线 + 禁点，tap 不产生跳页
      await tester.tap(find.text('第 1 组').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('全程页面 · 点未完成组的行直接跳过去'), findsOneWidget,
          reason: '已完成组锁定：面板仍开着');

      // 划船第 1 组（列表序在后）：可跳。跳转的 DB 续体在真实 isolate，
      // 与 tap 一起包进 runAsync（本文件头部已知坑）
      await tester.runAsync(() async {
        await tester.tap(find.text('第 1 组').last);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('全程页面 · 点未完成组的行直接跳过去'), findsNothing,
          reason: '跳转后面板关闭');
      expect(find.text('划船'), findsOneWidget, reason: '已跳到划船的记录页');
      expect(find.text('第 1/3 组'), findsOneWidget);

      // 红线：全程没有弹窗（Dialog），菜单/跳页全走收起面板
      expect(find.byType(Dialog), findsNothing);
    });
  });

  group('总结页并入页面流', () {
    testWidgets('全程记满：最后一组 UI 保存 → 总结页就地展示，进度条到 1，收工回入口',
        (tester) async {
      setSurface(tester, const Size(360, 800));
      // 双路由宿主：收工 = popUntil 首个路由，能真正退出训练页
      await tester.pumpWidget(AppScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                      builder: (_) => const WorkoutPage())),
                  child: const Text('去训练'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.runAsync(() async {
        final day = await makeDay('推日');
        final a = await addEx(day, '卧推', 0);
        final b = await addEx(day, '划船', 1);
        await container.session.startFromDay(day: day, planExercises: [a, b]);
        final s = container.session;
        for (var i = 0; i < 5; i++) {
          await s.completeSet(
              weight: 60, reps: 8, rir: 2, kind: SetKind.working);
          if (s.phase == WorkoutPhase.resting) s.skipRest();
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.tap(find.text('去训练'));
      await tester.pumpAndSettle();
      expect(progressBar(tester).value, closeTo(5 / 6, 1e-6));

      // 测试闸门（2026-10-07 结束确认弹窗）：本用例验证「UI 最后一组 →
      // 自动结束 → 总结页」管线，确认面板行为由专测覆盖——置 null 放行
      // 原自动结束语义，否则最后一组会被确认面板挂住。
      container.session.confirmAutoFinish = null;
      await tester.runAsync(() async {
        container.session.setWeightDraft(60);
        await pickRir2(tester);
        await tester.tap(find.text('8'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pumpAndSettle();

      expect(find.text('训练完成 💪'), findsOneWidget, reason: '总结页是页面流最后一页');
      expect(progressBar(tester).value, 1.0, reason: '全程完成');
      expectNoLayoutError(tester);

      // 收工退出训练页（popUntil 首个路由）
      await tester.tap(find.text('收工'));
      await tester.pumpAndSettle();
      expect(find.text('去训练'), findsOneWidget, reason: '收工回到入口页');
      expect(find.text('训练完成 💪'), findsNothing);
    });
  });

  group('自定义次数直输（2026-09-26 Arono：轻重量高次数 12/15+）', () {
    testWidgets('点「自定义」键入 15 → chip 显示 15 → 完成组落库 reps=15',
        (tester) async {
      // 高屏（折叠屏展开态）：保证次数行完整可见可点
      setSurface(tester, const Size(360, 1200));
      await startLifting(tester);
      await pumpWorkout(tester);
      // 计划 5-8 次：点选范围 3-10，没有 15
      expect(find.text('15'), findsNothing);
      expect(find.text('自定义'), findsOneWidget);

      await pickRir2(tester);
      await tester.tap(find.text('自定义'));
      await tester.pump(); // 先起帧再推进动画，单次 pump(300) 弹层停在屏外
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField), '15');
      await tester.tap(find.text('确认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('自定义'), findsNothing,
          reason: '自定义值生效后 chip 直接显示次数');
      expect(find.text('15'), findsOneWidget, reason: '自定义次数以选中态显示');

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump(const Duration(milliseconds: 100));
      final sets = container.session.setsByEx[container.session.currentEx!.id]!;
      expect(sets.last.reps, 15, reason: '自定义次数落库为真实记录值');
    });

    testWidgets('超出 1-99 的输入被拦下，不关闭弹层', (tester) async {
      setSurface(tester, const Size(360, 1200));
      await startLifting(tester);
      await pumpWorkout(tester);

      await tester.tap(find.text('自定义'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 2 位上限输入 0：越界值，确认无效
      await tester.enterText(find.byType(TextField), '0');
      await tester.tap(find.text('确认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('输入次数'), findsOneWidget, reason: '弹层仍开着等改对');
      expect(find.text('请输入 1-99 的次数'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '12');
      await tester.tap(find.text('确认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('12'), findsOneWidget, reason: '改对后正常生效');
    });
  });

  group('组数+目标显示（2026-09-26 Arono：帮人数组防忘目标）', () {
    testWidgets('动作面板第一行显示「第 1/3 组 · 目标 5-8 次」', (tester) async {
      setSurface(tester, const Size(360, 1200));
      await startLifting(tester);
      await pumpWorkout(tester);
      // 面板大字条（计划 5-8 次）
      expect(find.textContaining('目标 5-8 次'), findsWidgets);
      // 面板条 + 顶部 chip 两处都显示当前组号
      expect(find.textContaining('第 1/3 组'), findsNWidgets(2));
    });

    testWidgets('休息页「下一组」chip 带组号与目标次数', (tester) async {
      setSurface(tester, const Size(360, 1200));
      await startLifting(tester);
      await pumpWorkout(tester);
      await tester.runAsync(() async {
        await pickRir2(tester);
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      // 划线 900ms 定时器在真实时区：runAsync 等它走完再 pump 翻页
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1000)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('下一组 · 卧推 第 2/3 组'), findsOneWidget,
          reason: '休息页能看到接下来的动作、组号、次数');
      expect(find.textContaining('× 5-8 次'), findsOneWidget,
          reason: '休息页同时显示下一组的目标次数，防忘');
    });

    testWidgets('加练态面板显示「第 2 组（加练）」且组号不封顶（绝对组号）', (tester) async {
      setSurface(tester, const Size(360, 1200));
      // 单动作 1 组：练满即加练态
      await tester.runAsync(() async {
        final day = await makeDay('加练日');
        final a = await addEx(day, '卧推', 0, workingSets: 1);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tap(find.text('开始训练'));
      await tester.pump(const Duration(milliseconds: 400));
      // 测试闸门（2026-10-07 结束确认弹窗）：本用例只验加练态组号文案，
      // 置 null 放行原自动结束语义（确认面板行为由专测覆盖）。
      container.session.confirmAutoFinish = null;
      await tester.runAsync(() async {
        await pickRir2(tester);
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        container.session.startExtraSet();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump(const Duration(milliseconds: 300));
      // 2026-10-08 口径统一：绝对组号 doneRaw+1（planned=1、已完成 1 → 第 2 组）
      expect(find.textContaining('第 2 组（加练）'), findsWidgets,
          reason: '加练的这一组按绝对组号显性显示（旧 bug：永远显示 1/1）');
      expect(find.textContaining('第 1/1 组'), findsNothing,
          reason: '不再被夹回计划组数');
    });
  });

  group('余力没填写提醒（2026-09-26 Arono：忘了填要提示，不悄悄按默认记）', () {
    testWidgets('第一按只提示不落库；选了余力再按正常记录', (tester) async {
      setSurface(tester, const Size(360, 1200));
      await startLifting(tester);
      await pumpWorkout(tester);

      // 第一按：出现提醒、组不落库
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('余力没填写'), findsWidgets,
          reason: '余力行高亮提示');
      expect(find.textContaining('按计划默认记'), findsOneWidget,
          reason: '提示里给「再按一次用默认」的出路');
      expect(container.session.setsByEx.values
          .fold<int>(0, (n, l) => n + l.length), 0,
          reason: '第一按不落库');

      // 选余力 1：提醒消失
      await tester.tap(find.text('1').last);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('余力没填写'), findsNothing);

      // 第二按：带所选余力正常记录
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump(const Duration(milliseconds: 100));
      final sets = container.session.setsByEx.values.expand((l) => l).toList();
      expect(sets, isNotEmpty, reason: '第二按落库');
      expect(sets.last.rir, 1, reason: '余力取所选值');
    });

    testWidgets('不选余力连按两次：第二按按计划默认落库（不拦人）', (tester) async {
      setSurface(tester, const Size(360, 1200));
      await startLifting(tester);
      await pumpWorkout(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump(const Duration(milliseconds: 100));
      final sets = container.session.setsByEx.values.expand((l) => l).toList();
      expect(sets, isNotEmpty, reason: '第二按放行');
      expect(sets.last.rir, 2, reason: '未填时按计划默认 RIR 2 记');
    });
  });

  group('大字体缩放：休息页数字与按钮永不折行（2026-09-27 截图反馈）', () {
    /// 1.5 倍系统字体下「01:59」五个字符超出屏宽曾被软换行挤成两行；
    /// ±30 秒/暂停/撤销小按钮同理。回归口径：倒计时数字和按钮文字
    /// maxLines == 1 且倒计时包在 FittedBox 里兜底缩小。
    testWidgets('1.5 倍缩放下倒计时单行 + FittedBox 兜底，按钮文字单行', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      setSurface(tester, const Size(360, 800));
      await startLifting(tester);
      await pumpWorkout(tester);
      // 1.5 倍缩放下「完成组」大按钮在 800 高度可能被推出可视区，
      // tap 会落空：绕开坐标点击，直接驱动控制器完成一组进休息态
      // （与「已有记录时不经过起始页」用例同一手法）。
      await tester.runAsync(() async {
        await container.session
            .completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('组间休息'), findsOneWidget, reason: '到达休息页');
      expectNoLayoutError(tester);

      // 倒计时数字（mm:ss，随秒走动不锁具体值）：单行 + FittedBox 兜底
      final countdownFinder = find.byWidgetPredicate((w) =>
          w is Text && RegExp(r'^\d{2}:\d{2}$').hasMatch(w.data ?? ''));
      expect(countdownFinder, findsOneWidget, reason: '休息页有倒计时数字');
      expect(tester.widget<Text>(countdownFinder).maxLines, 1,
          reason: '倒计时数字永不折行');
      expect(
          find.ancestor(of: countdownFinder, matching: find.byType(FittedBox)),
          findsAtLeastNWidgets(1),
          reason: '放不下时整体等比缩小而不是折行');

      // 底部小按钮排：文字单行（截图里「-30 秒」折行被看成「-3 / +3」）
      for (final label in ['-30 秒', '+30 秒', '暂停', '撤销']) {
        final t = tester.widget<Text>(find.text(label));
        expect(t.maxLines, 1, reason: '$label 不折行');
      }
    });
  });

  group('收工兜底（2026-09-28 真机回归）', () {
    testWidgets('控制器记满自动结束后，面板回调即使丢失页面也能进总结页', (tester) async {
      setSurface(tester, const Size(360, 800));
      await startLifting(tester);
      // 全程 controller 直记（模拟真机上面板先被卸载、回调丢失的场景）：
      // 最后一组落库时状态机自动结束会话，页面此后才 build。
      await tester.runAsync(() async {
        final s = container.session;
        for (var i = 0; i < 6; i++) {
          await s.completeSet(
              weight: 60, reps: 8, rir: 2, kind: SetKind.working);
          if (s.phase == WorkoutPhase.resting) s.skipRest();
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      expect(container.session.hasActive, isFalse, reason: '状态机已自动结束');

      await tester.pumpWidget(host(container, const WorkoutPage()));
      // 占位分支调度兜底收尾 → _finishFlow 走真实 isolate DB → 总结页入流
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('本次训练已结束'), findsNothing,
          reason: '不允许停在占位页');
      expect(find.text('训练完成 💪'), findsOneWidget,
          reason: '兜底收尾把总结页接进页面流');
    });
  });

  // ---------- 结束确认弹窗（2026-10-07）----------
  // 计划内最后一组完成后不再静默自动结束：先弹收起面板问「现在结束吗」。
  // 属「结束时点」弹窗豁免（先例忘停表守护），不碰训练中禁弹窗红线。
  group('结束确认弹窗（最后一组完成先问「现在结束吗」）', () {
    /// 单动作 1 计划组的新会话 + 进入训练页记录页。
    Future<void> pumpSingleSetWorkout(WidgetTester tester) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        final day = await makeDay('收尾日');
        final a = await addEx(day, '卧推', 0, workingSets: 1);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await pumpWorkout(tester);
    }

    /// UI 记满唯一一组并等确认面板挂起（面板出现）。
    Future<void> recordLastSetViaUi(WidgetTester tester) async {
      await tester.runAsync(() async {
        await pickRir2(tester);
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.session.hasActive, isTrue,
          reason: '确认面板挂起：等用户拍板，不自动结束');
    }

    testWidgets('用例A 全部组完成：选「结束并保存」→ 落库 done 进总结页', (tester) async {
      await pumpSingleSetWorkout(tester);
      await recordLastSetViaUi(tester);
      expect(find.text('全部组完成，结束训练吗？'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.text('结束并保存'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      // 面板退场动画要出帧才走完 → confirm 才返回 true；随后 completeSet
      // 的收尾（finish 落库）在真实事件环上跑，还需再给真实时间
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pumpAndSettle();
      expect(find.text('训练完成 💪'), findsOneWidget, reason: '收尾后进总结页');
      expect(container.session.hasActive, isFalse);
      expect(container.session.session!.status, 'done');
    });

    testWidgets('用例B 选「继续训练」：不结束落休息页；加练一组后面板再次出现', (tester) async {
      await pumpSingleSetWorkout(tester);
      await recordLastSetViaUi(tester);
      expect(find.text('全部组完成，结束训练吗？'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.text('继续训练'));
        await Future<void>.delayed(const Duration(milliseconds: 1000));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.session.hasActive, isTrue, reason: '继续训练：会话不清场');
      expect(container.session.phase, WorkoutPhase.resting,
          reason: '按原推进语义落加练态休息页');
      expect(find.text('跳过休息，直接开练'), findsOneWidget);
      expect(find.text('训练完成 💪'), findsNothing);

      // 休息页「再来一组」回加练态，记完这一组：面板再次出现（每组再问）
      await tester.runAsync(() async {
        await tester.tap(find.textContaining('再来一组'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump(const Duration(milliseconds: 400));
      await recordLastSetViaUi(tester);
      expect(find.text('全部组完成，结束训练吗？'), findsOneWidget,
          reason: '无「本次不再问」状态：每组最后一组都要再问');
    });

    testWidgets('用例C 跳着做：末位动作练满即问，面板显示「还剩 N 组」，选结束落库 done',
        (tester) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        final day = await makeDay('收尾日');
        final a = await addEx(day, '卧推', 0, workingSets: 1);
        final b = await addEx(day, '划船', 1, workingSets: 1);
        await container.session.startFromDay(day: day, planExercises: [a, b]);
      });
      await pumpWorkout(tester);

      // 跳过首位动作（卧推一组不做），直接做末位动作
      await tester.runAsync(() async {
        await tester.tap(find.text('跳过动作'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      // 换动作是真实异步（DB 读上下文）→ notify 落帧 → AnimatedSwitcher
      // 动画走完还要再出一帧才拆掉 outgoing 旧记录页（否则新旧两页同时
      // 在树上，「完成本组」按钮歧义命中两个）。两轮 settle 夹真实等待。
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      await recordLastSetViaUi(tester);
      expect(find.text('还剩 1 组没做，现在结束吗？'), findsOneWidget,
          reason: '『跳着做』收尾前先看清还差谁');
      expect(find.textContaining('已完成 0/1'), findsOneWidget,
          reason: '逐动作灰字：卧推一组没做');

      await tester.runAsync(() async {
        await tester.tap(find.text('结束并保存'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pumpAndSettle();
      expect(find.text('训练完成 💪'), findsOneWidget);
      expect(container.session.hasActive, isFalse);
      expect(container.session.session!.status, 'done');
    });
  });
}
