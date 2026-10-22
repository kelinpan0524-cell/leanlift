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
import 'package:baoji_timer/engine/weight_unit.dart';
import 'package:baoji_timer/services/session_controller.dart';
import 'package:baoji_timer/ui/workout_page.dart';
import 'package:baoji_timer/ui/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
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

  test('起始页副标题按会话快照组数：快照 4 / 规则 3 → 显示 4 组', () {
    final ex = SessionExercise(
      sessionId: 1,
      name: '深蹲',
      orderIdx: 0,
      kind: 'compound',
      rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      targetSets: 4,
    );
    expect(startCardSub(ex), contains('4 组'));
    expect(startCardSub(ex), isNot(contains('3 组')));
  });

  test('热身文案跟随记录形态：计时说秒、单侧说每边（自重与负重都生效）', () {
    final timed = warmupHintTextFor(
      name: '平板支撑',
      targetWeightKg: 0,
      loadType: LoadMode.bodyweight,
      logging: LoggingMode.time,
    );
    expect(timed, contains('秒'));
    final perSide = warmupHintTextFor(
      name: '箭步蹲',
      targetWeightKg: 0,
      loadType: LoadMode.bodyweight,
      logging: LoggingMode.repsPerSide,
    );
    expect(perSide, contains('每边'));

    // 负重阶梯同样要换口径：计时动作不能写成「×5 次」。
    final weightedTimed = warmupHintTextFor(
      name: '哑铃农夫行走',
      targetWeightKg: 10,
      loadType: LoadMode.weighted,
      logging: LoggingMode.time,
    );
    expect(weightedTimed, contains('秒'));
    expect(weightedTimed, isNot(contains('次')));
    final weightedPerSide = warmupHintTextFor(
      name: '哑铃箭步蹲',
      targetWeightKg: 10,
      loadType: LoadMode.weighted,
      logging: LoggingMode.repsPerSide,
    );
    expect(weightedPerSide, contains('每边'));
  });

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

  /// 把当前树上的文案抓出来，供轮询超时时定位「卡在哪一页」。
  String visibleTexts(WidgetTester tester) {
    final texts = find
        .byType(Text)
        .evaluate()
        .map((e) {
          final t = e.widget as Text;
          return t.data ?? t.textSpan?.toPlainText() ?? '';
        })
        .where((t) => t.trim().isNotEmpty)
        .toSet()
        .take(30)
        .join(' / ');
    return texts.isEmpty ? '（屏上没有文字）' : texts;
  }

  /// 条件轮询：每 [step] 先 pump 一帧假时钟（推进动画/翻页），再让真实
  /// 事件环跑 [step]。widget 测试的 pump 只推假时钟，等不到 sqflite 的
  /// 真实回包和真实区定时器，必须把真实时间也交出去。超时按墙钟算，
  /// 失败信息带上当前屏文案。
  ///
  /// 不用固定 sleep：本地快、CI runner 慢，固定 400/600ms 偶发不够，
  /// 正是 PR #79 上找不到「训练完成 💪」的根因。轮询让等待时长由实际
  /// 完成时刻决定，慢机器只是多跑几轮，断言本身不变。
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() condition, {
    required String reason,
    Duration timeout = const Duration(seconds: 10),
    Duration step = const Duration(milliseconds: 100),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      await tester.pump(step);
      if (condition()) return;
      if (!DateTime.now().isBefore(deadline)) {
        fail('$reason：等了 ${timeout.inSeconds} 秒仍未成立。'
            '当前屏上的文字：${visibleTexts(tester)}');
      }
      await tester.runAsync(() => Future<void>.delayed(step));
    }
  }

  /// 等某个 widget 出现（异步落库/翻页后才挂载的页面）。
  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 10),
    Duration step = const Duration(milliseconds: 100),
    String? reason,
  }) =>
      pumpUntil(tester, () => finder.evaluate().isNotEmpty,
          reason: reason ?? '等 ${finder.describeMatch(Plurality.one)} 出现',
          timeout: timeout,
          step: step);

  /// 等某个 widget 消失（划线窗口、按钮入口消费这类定时器走完就撤的等待）。
  Future<void> pumpUntilGone(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 10),
    Duration step = const Duration(milliseconds: 100),
    String? reason,
  }) =>
      pumpUntil(tester, () => finder.evaluate().isEmpty,
          reason: reason ?? '等 ${finder.describeMatch(Plurality.zero)} 消失',
          timeout: timeout,
          step: step);

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
      {int workingSets = 3,
      int restSec = 120,
      int repsMin = 5,
      int repsMax = 8,
      String logging = LoggingMode.reps,
      String loadType = LoadMode.weighted}) async {
    final pe = PlanExercise(
      dayId: day.id!,
      name: name,
      orderIdx: order,
      sets: workingSets,
      repsMin: repsMin,
      repsMax: repsMax,
      restSec: restSec,
      kind: 'compound',
      rule: ProgressionRule(
          repsMin: repsMin, repsMax: repsMax, workingSets: workingSets),
      logging: logging,
      loadType: loadType,
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

    testWidgets('起始页给首个动作展示热身建议（只展示，不自动落库）', (tester) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        final day = await makeDay('推日');
        final a = await addEx(day, '杠铃卧推', 0, workingSets: 2);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));

      final hint =
          tester.widget<Text>(find.byKey(const Key('startWarmupHint')));
      expect(hint.data, contains('空杆'), reason: '杠铃先做空杆');
      expect(hint.data, contains('80%'), reason: '大重量给 80% 单次档');
      // 只展示：开练前不自动生成热身组。
      expect(container.session.setsByEx.values.expand((e) => e), isEmpty);
    });

    testWidgets('起始页 ≤40kg 杠铃走简化版，也显示空杆步', (tester) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        final day = await makeDay('手臂日');
        final a = await addEx(day, '杠铃弯举', 0, workingSets: 2);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));

      final hint =
          tester.widget<Text>(find.byKey(const Key('startWarmupHint')));
      expect(hint.data, contains('简化'), reason: '20kg 走简化版');
      expect(hint.data, contains('空杆'), reason: '20kg 也要有空杆热身');
      expect(hint.data, isNot(contains('80%')), reason: '简化版不追 80% 单次');
    });

    testWidgets('起始页计时自重动作的热身文案用秒', (tester) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        final day = await makeDay('核心日');
        final a = await addEx(
          day,
          '平板支撑',
          0,
          workingSets: 2,
          logging: LoggingMode.time,
          loadType: LoadMode.bodyweight,
        );
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));

      final hint =
          tester.widget<Text>(find.byKey(const Key('startWarmupHint')));
      expect(hint.data, contains('秒'), reason: '计时动作不能用「次」');
    });

    testWidgets('起始页 lb 模式的空杆与片重文案', (tester) async {
      setSurface(tester, const Size(360, 800));
      WeightUnits.setResolved(WeightUnit.lb);
      addTearDown(() => WeightUnits.setResolved(WeightUnit.kg));
      await tester.runAsync(() async {
        final day = await makeDay('推日');
        final a = await addEx(day, '杠铃卧推', 0, workingSets: 2);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));

      final hint =
          tester.widget<Text>(find.byKey(const Key('startWarmupHint')));
      expect(hint.data, contains('45lb'), reason: '空杆与挂片提示同源');
      expect(hint.data, isNot(contains('44lb')), reason: '不出现 44/45lb 打架');
    });

    testWidgets('起始页 lb 20kg 杠铃仍有热身行（44lb 目标对 45lb 空杆）',
        (tester) async {
      setSurface(tester, const Size(360, 800));
      WeightUnits.setResolved(WeightUnit.lb);
      addTearDown(() => WeightUnits.setResolved(WeightUnit.kg));
      await tester.runAsync(() async {
        final day = await makeDay('手臂日');
        final a = await addEx(day, '杠铃弯举', 0, workingSets: 2);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));

      final hint =
          tester.widget<Text>(find.byKey(const Key('startWarmupHint')));
      expect(hint.data, contains('45lb'), reason: '空杆与挂片提示同源');
    });

    testWidgets('起始页 EZ 杠用 10kg 空杆', (tester) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        final day = await makeDay('手臂日');
        final a = await addEx(day, '曲杠弯举（EZ杠）', 0, workingSets: 2);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));

      final hint =
          tester.widget<Text>(find.byKey(const Key('startWarmupHint')));
      expect(hint.data, contains('空杆 10kg'), reason: 'EZ 杠不是 20kg 奥杆');
    });

    testWidgets('480×320 横屏：完整热身阶梯不被截断', (tester) async {
      setSurface(tester, const Size(480, 320));
      await tester.runAsync(() async {
        final day = await makeDay('推日');
        final a = await addEx(day, '杠铃卧推', 0, workingSets: 2);
        await container.session.startFromDay(day: day, planExercises: [a]);
        container.session.setWeightDraft(100); // 长阶梯：空杆 + 40/60/80
      });
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));

      final hint =
          tester.widget<Text>(find.byKey(const Key('startWarmupHint')));
      expect(hint.maxLines, isNull, reason: '不允许单行省略号截断');
      expect(hint.data, contains('空杆'));
      expect(hint.data, contains('40%'));
      expect(hint.data, contains('60%'));
      expect(hint.data, contains('80%'));
    });

    testWidgets('800×360 横屏：热身行仍显示，开始按钮在屏内', (tester) async {
      setSurface(tester, const Size(800, 360));
      await tester.runAsync(() async {
        final day = await makeDay('推日');
        final a = await addEx(day, '杠铃卧推', 0, workingSets: 2);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.byKey(const Key('startWarmupHint')), findsOneWidget,
          reason: '横屏也要显示热身建议');
      final btn = tester.getRect(find.text('开始训练'));
      expect(btn.bottom, lessThanOrEqualTo(360), reason: '开始按钮不能被挤出屏');
    });

    testWidgets('减载周：起始页/训练页都有非弹窗横幅，组数 -1', (tester) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        final day = await makeDay('推日');
        final ex = await addEx(day, '卧推', 0, workingSets: 3);
        // 28 天前一场 done（60kg×8×3）→ 5 周一块的第 5 周；
        // 另补 1 天前一场正常训练，避免触发 P1-D 停练回归（块起点仍取
        // MIN=28 天前的首场，减载周不变）。
        for (final daysAgo in [28, 1]) {
          final when = DateTime.now().subtract(Duration(days: daysAgo));
          final done = await container.db.insertSession(Session(
            date: fmtDate(when),
            planDayId: day.id,
            planDayTitle: day.title,
            startedAt: 1,
            status: 'done',
          ));
          final se =
              await container.db.insertSessionExercise(SessionExercise(
            sessionId: done.id!,
            name: '卧推',
            orderIdx: 0,
            kind: 'compound',
            restSec: 120,
            rule: ex.rule,
            targetSets: 3,
            targetRepsMin: 5,
            targetRepsMax: 8,
          ));
          for (var i = 0; i < 3; i++) {
            await container.db.insertSet(SetEntry(
              sessionExerciseId: se,
              weightKg: 60,
              reps: 8,
              kind: SetKind.working,
              doneAt: when.millisecondsSinceEpoch + i,
            ));
          }
        }
        await container.session.startFromDay(day: day, planExercises: [ex]);
      });
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));

      // 起始页：横幅说明本周减载；组数快照已 -1（3 → 2）
      expect(find.textContaining('本周减载'), findsOneWidget);
      expect(find.textContaining('1 个动作 · 2 个正式组'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing,
          reason: '横幅不是弹窗，不打断训练');
      expectNoLayoutError(tester);

      await tester.tap(find.text('开始训练'));
      await tester.pump(); // 先落一帧启动 AnimatedSwitcher，再走完 280ms 动画
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 50));
      // 训练页：横幅仍在（三要素之外的顶部条下方），本组目标按 2 组走
      expect(find.textContaining('本周减载'), findsOneWidget);
      // 当前动作名（三要素之一）仍可见，不被顶部标记遮挡
      expect(find.text('卧推'), findsOneWidget);
      // 顶部条与动作面板都显示「第 1/2 组」（减载后 3 → 2）
      expect(find.textContaining('第 1/2 组'), findsWidgets);
      expect(find.byType(AlertDialog), findsNothing);
      expectNoLayoutError(tester);

      // 休息页也保留减载横幅（非弹窗，不占三要素）
      // 该测试的 2 组计划在 360×800 下按钮刚好在视口下沿，先滚到可点位置。
      await tester.ensureVisible(find.byKey(const Key('workoutCompleteSet')));
      await tester.pump();
      await tester.runAsync(() async {
        await pickRir2(tester);
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 950)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('组间休息'), findsOneWidget, reason: '确实进了休息页');
      expect(find.textContaining('本周减载'), findsOneWidget,
          reason: '休息页横幅');
      expect(find.byType(AlertDialog), findsNothing);
      expectNoLayoutError(tester);
    });

    testWidgets('停练回归：起始页非弹窗横幅「停练 20 天 / 85%」，组数 -1',
        (tester) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        final day = await makeDay('推日');
        final ex = await addEx(day, '卧推', 0, workingSets: 3);
        // 20 天前一场 done（60kg×6×3）：≥14 天 → 停练回归；20 天落在
        // 5 周一块的第 3 周，不同时触发减载。
        final when = DateTime.now().subtract(const Duration(days: 20));
        final done = await container.db.insertSession(Session(
          date: fmtDate(when),
          planDayId: day.id,
          planDayTitle: day.title,
          startedAt: 1,
          status: 'done',
        ));
        final se = await container.db.insertSessionExercise(SessionExercise(
          sessionId: done.id!,
          name: '卧推',
          orderIdx: 0,
          kind: 'compound',
          restSec: 120,
          rule: ex.rule,
          targetSets: 3,
          targetRepsMin: 5,
          targetRepsMax: 8,
        ));
        for (var i = 0; i < 3; i++) {
          await container.db.insertSet(SetEntry(
            sessionExerciseId: se,
            weightKg: 60,
            reps: 6,
            kind: SetKind.working,
            doneAt: when.millisecondsSinceEpoch + i,
          ));
        }
        await container.session.startFromDay(day: day, planExercises: [ex]);
      });
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));

      // 起始页：非弹窗横幅说明停练天数与 85% 处方；组数 3 → 2
      expect(find.textContaining('停练 20 天'), findsOneWidget);
      expect(find.textContaining('85%'), findsWidgets);
      expect(find.textContaining('1 个动作 · 2 个正式组'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing,
          reason: '横幅不是弹窗，不打断训练');
      expectNoLayoutError(tester);

      await tester.tap(find.text('开始训练'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 50));
      // 记录页顶部条保留停练天数标记（非弹窗、不占三要素）；
      // 目标行下方同时显示「为什么是 85%」的同口径说明（2 处文案）。
      expect(find.text('停练 20 天'), findsOneWidget, reason: '顶部条标记');
      expect(find.textContaining('停练 20 天'), findsWidgets);
      expect(find.textContaining('85%'), findsWidgets);
      expect(find.textContaining('第 1/2 组'), findsWidgets);
      expect(find.text('卧推'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expectNoLayoutError(tester);

      // 休息页也保留停练横幅（非弹窗，不占三要素）
      await tester.ensureVisible(find.byKey(const Key('workoutCompleteSet')));
      await tester.pump();
      await tester.runAsync(() async {
        await pickRir2(tester);
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 950)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('组间休息'), findsOneWidget, reason: '确实进了休息页');
      expect(find.textContaining('停练 20 天'), findsOneWidget,
          reason: '休息页横幅');
      expect(find.byType(AlertDialog), findsNothing);
      expectNoLayoutError(tester);
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
      // 刚记完一组（90 秒窗口内）就跳页：按新语义补起休息，休息页写明目标动作
      expect(find.text('组间休息'), findsOneWidget,
          reason: '刚练完就切走 → 补起休息，不直接进记录页');
      expect(find.textContaining('划船'), findsOneWidget,
          reason: '休息页的「下一组」指向切过去的目标动作');
      expect(container.session.phase, WorkoutPhase.resting);

      // 主动跳过休息 → 落到划船的记录页
      await tester.runAsync(() async {
        await tester.tap(find.text('跳过休息，直接开练'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump(const Duration(milliseconds: 400));
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

  group('带入上次成绩只预填（2026-10-18：不把预填 RIR 标成已记录）', () {
    /// 上次成绩行：60kg×8 R2（已记录）。
    Future<void> seedLastPerformance() async {
      final s0 = await container.db.insertSession(Session(
          // 相对日期：固定日期会随时间漂进停练回归语境（2026-10-24 教训）
          date: fmtDate(DateTime.now().subtract(const Duration(days: 2))),
          planDayTitle: '旧训练',
          startedAt: 1,
          endedAt: 2,
          status: 'done'));
      final se0 = await container.db.insertSessionExercise(SessionExercise(
          sessionId: s0.id!,
          name: '卧推',
          orderIdx: 0,
          kind: 'compound',
          rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3)));
      await container.db.insertSet(SetEntry(
          sessionExerciseId: se0,
          weightKg: 60,
          reps: 8,
          rir: 2,
          kind: SetKind.working,
          doneAt: 1000,
          rirRecorded: true));
    }

    testWidgets('点「上次」整套带入后直接完成：数值预填但 rir_recorded=0',
        (tester) async {
      setSurface(tester, const Size(360, 1200));
      await tester.runAsync(() async {
        await seedLastPerformance();
        final day = await makeDay('推日');
        final a = await addEx(day, '卧推', 0);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await pumpWorkout(tester);

      // 上次成绩行可见：60kg×8 R2，点按整套带入
      expect(find.textContaining('点按整套带入'), findsWidgets);
      await tester.ensureVisible(find.textContaining('点按整套带入').first);
      await tester.pump();
      await tester.tap(find.textContaining('点按整套带入').first);
      await tester.pump(const Duration(milliseconds: 50));

      // 带入后直接「完成本组」（不点余力行）：
      await tester.ensureVisible(find.byKey(const Key('workoutCompleteSet')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump(const Duration(milliseconds: 100));
      final sets = container.session.setsByEx.values.expand((l) => l).toList();
      expect(sets, isNotEmpty, reason: '带入后无需余力提醒即可记录');
      expect(sets.last.weightKg, 60, reason: '重量按上次预填');
      expect(sets.last.reps, 8, reason: '次数按上次预填');
      expect(sets.last.rir, 2, reason: '余力展示值按上次预填');
      expect(sets.last.rirRecorded, isFalse,
          reason: '预填不是本场点选的观测：落库标「未记录」');
    });

    testWidgets('带入后亲手点余力行再完成：rir_recorded=1（点选路径不受影响）',
        (tester) async {
      setSurface(tester, const Size(360, 1200));
      await tester.runAsync(() async {
        await seedLastPerformance();
        final day = await makeDay('推日');
        final a = await addEx(day, '卧推', 0);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await pumpWorkout(tester);

      await tester.ensureVisible(find.textContaining('点按整套带入').first);
      await tester.pump();
      await tester.tap(find.textContaining('点按整套带入').first);
      await tester.pump(const Duration(milliseconds: 50));
      // 亲手把余力改成 1：此后该值才算真实观测
      await tester.ensureVisible(find.text('1').last);
      await tester.pump();
      await tester.tap(find.text('1').last);
      await tester.pump(const Duration(milliseconds: 50));

      await tester.ensureVisible(find.byKey(const Key('workoutCompleteSet')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump(const Duration(milliseconds: 100));
      final sets = container.session.setsByEx.values.expand((l) => l).toList();
      expect(sets.last.rir, 1);
      expect(sets.last.rirRecorded, isTrue, reason: '亲手点过余力 = 真实记录');
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
      expect(sets.last.rirRecorded, isTrue, reason: '点过余力 = 真实记录');
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
      expect(sets.last.rirRecorded, isFalse, reason: '没点过余力 = 仅默认填充，标记未记录');
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
    Future<void> recordLastSetViaUi(WidgetTester tester,
        {required String confirmText}) async {
      await tester.runAsync(() async {
        await pickRir2(tester);
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
      });
      // 落库在真实事件环上完成，确认面板挂起后 completeSet 才走到收尾
      await pumpUntilFound(tester, find.text(confirmText),
          reason: '记满最后一组后应弹收尾确认面板');
      // 文案一挂上就在树里，但底部弹层还在入场动画中（按钮坐标还在屏外），
      // 直接点会落空。settle 只推假时钟收动画，不等真实异步，确定性行为。
      await tester.pumpAndSettle();
      expect(container.session.hasActive, isTrue,
          reason: '确认面板挂起：等用户拍板，不自动结束');
    }

    testWidgets('用例A 全部组完成：选「结束并保存」→ 落库 done 进总结页', (tester) async {
      await pumpSingleSetWorkout(tester);
      await recordLastSetViaUi(tester, confirmText: '全部组完成，结束训练吗？');
      expect(find.text('全部组完成，结束训练吗？'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.text('结束并保存'));
      });
      // 面板退场动画走完 confirm 才返回 true；随后 stats/verdicts/finish
      // 的落库全在真实事件环上跑 → 轮询等总结页挂载，慢 runner 多等几轮
      await pumpUntilFound(tester, find.text('训练完成 💪'),
          reason: '选「结束并保存」后应进总结页');
      expect(find.text('训练完成 💪'), findsOneWidget, reason: '收尾后进总结页');
      expect(container.session.hasActive, isFalse);
      expect(container.session.session!.status, 'done');
    });

    testWidgets('用例B 选「继续训练」：不结束落休息页；加练一组后面板再次出现', (tester) async {
      await pumpSingleSetWorkout(tester);
      await recordLastSetViaUi(tester, confirmText: '全部组完成，结束训练吗？');
      expect(find.text('全部组完成，结束训练吗？'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.text('继续训练'));
      });
      // 面板退场 + 控制器进加练态休息都在真实异步里：等休息页接管
      await pumpUntilFound(tester, find.text('跳过休息，直接开练'),
          reason: '选「继续训练」应落加练态休息页');
      expect(container.session.hasActive, isTrue, reason: '继续训练：会话不清场');
      expect(container.session.phase, WorkoutPhase.resting,
          reason: '按原推进语义落加练态休息页');
      expect(find.text('跳过休息，直接开练'), findsOneWidget);
      expect(find.text('训练完成 💪'), findsNothing);

      // 休息页「再来一组」：只把落点改回加练组，休息倒计时继续
      // （2026-10-17 加练带休息计时），跳过休息后才进动作面板
      await tester.runAsync(() async {
        await tester.tap(find.textContaining('再来一组'));
      });
      await pumpUntilGone(tester, find.textContaining('再来一组'),
          reason: '入口即消费，按钮不残留');
      expect(container.session.phase, WorkoutPhase.resting,
          reason: '加练也带休息计时：不立即进动作态');
      expect(find.textContaining('再来一组'), findsNothing,
          reason: '入口即消费，按钮不残留');
      await tester.runAsync(() async {
        await tester.tap(find.text('跳过休息，直接开练'));
      });
      await pumpUntilGone(tester, find.text('跳过休息，直接开练'),
          reason: '跳过休息后休息页应退场');
      await pumpUntilFound(tester, find.byKey(const Key('workoutCompleteSet')),
          reason: '跳过休息后应落到加练组记录页');
      await recordLastSetViaUi(tester, confirmText: '全部组完成，结束训练吗？');
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
      });
      // 换动作是真实异步（DB 读上下文）→ notify 落帧 → AnimatedSwitcher
      // 动画走完还要再出帧才拆掉 outgoing 旧记录页（否则新旧两页同时在
      // 树上，「完成本组」按钮歧义命中两个）。等划船页挂载且旧页退场。
      await pumpUntilFound(tester, find.text('划船'),
          reason: '跳过卧推后应落到划船记录页');
      await pumpUntil(
          tester,
          () => find
                  .byKey(const Key('workoutCompleteSet'))
                  .evaluate()
                  .length ==
              1,
          reason: '旧记录页退场（「完成本组」只剩一个）');

      await recordLastSetViaUi(tester, confirmText: '还剩 1 组没做，现在结束吗？');
      expect(find.text('还剩 1 组没做，现在结束吗？'), findsOneWidget,
          reason: '『跳着做』收尾前先看清还差谁');
      expect(find.textContaining('已完成 0/1'), findsOneWidget,
          reason: '逐动作灰字：卧推一组没做');

      await tester.runAsync(() async {
        await tester.tap(find.text('结束并保存'));
      });
      await pumpUntilFound(tester, find.text('训练完成 💪'),
          reason: '选「结束并保存」后应进总结页');
      expect(find.text('训练完成 💪'), findsOneWidget);
      expect(container.session.hasActive, isFalse);
      expect(container.session.session!.status, 'done');
    });
  });

  group('记录形态（v14）：计时页 / 自重页', () {
    testWidgets('计时动作：大号工作计时 + 完成/跳过，无重量步进无次数点选',
        (tester) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        final day = await makeDay('核心日');
        final a = await addEx(day, '平板支撑', 0,
            workingSets: 2,
            repsMin: 30,
            repsMax: 60,
            logging: LoggingMode.time,
            loadType: LoadMode.bodyweight);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await pumpWorkout(tester);

      expect(find.byKey(const Key('workTimerText')), findsOneWidget,
          reason: '计时页大号工作计时（分:秒）');
      expect(find.text('完成'), findsOneWidget, reason: '计时动作按钮文案「完成」');
      expect(find.text('跳过'), findsOneWidget, reason: '跳过 = 放弃本次计时');
      expect(find.byType(WeightStepButton), findsNothing,
          reason: '计时动作没有重量概念，步进整块收起');
      expect(find.byType(ChoiceChip), findsNothing, reason: '无次数点选');
      // 目标行在 Text.rich 内：用 textContaining 匹配整串片段
      expect(find.textContaining('目标 30-60 秒'), findsOneWidget,
          reason: '目标行按秒表述');

      // 卸树取消 1s 周期计时器（避免 pending timer）
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('自重动作：自重标识 + 无重量步进，上次对比按次数不显示 0kg',
        (tester) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        // 历史：上次 0kg×8
        final s0 = await container.db.insertSession(Session(
            // 相对日期：固定日期会随时间漂进停练回归语境
            date: fmtDate(DateTime.now().subtract(const Duration(days: 2))),
            planDayTitle: '旧训练',
            startedAt: 1,
            endedAt: 2,
            status: 'done'));
        final se0 = await container.db.insertSessionExercise(SessionExercise(
            sessionId: s0.id!,
            name: '引体向上',
            orderIdx: 0,
            kind: 'compound',
            rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3)));
        await container.db.insertSet(SetEntry(
            sessionExerciseId: se0,
            weightKg: 0,
            reps: 8,
            rir: 2,
            kind: SetKind.working,
            doneAt: 1000));
        final day = await makeDay('背日');
        final a = await addEx(day, '引体向上', 0, loadType: LoadMode.bodyweight);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await pumpWorkout(tester);

      expect(find.text('自重'), findsOneWidget, reason: '自重标识取代重量大数字');
      expect(find.byKey(const ValueKey('weightDraftNum')), findsNothing,
          reason: '自重页没有重量大数字');
      expect(find.byType(WeightStepButton), findsNothing, reason: '无重量步进');
      // 信息区「上次：8 次」+ 面板上次对比行「上次：8 次 R2（点按整套带入）」
      // 两处都按次数口径，不再出现 0kg×8 假重量
      expect(find.textContaining('上次：8 次'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('负重变体改名保留旧键（H3 收尾）：有重量步进，保存不强制 0kg',
        (tester) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        final day = await makeDay('背日');
        // 名字带「负重」且 stored bodyweight——改名保留旧键的典型形态，
        // 规则①要求训练页按负重 UI 处理，不能落进自重 UI 强制 0kg
        final a = await addEx(day, '引体向上（负重版）', 0,
            loadType: LoadMode.bodyweight);
        await container.session.startFromDay(day: day, planExercises: [a]);
        container.session.setWeightDraft(5);
      });
      await pumpWorkout(tester);

      expect(find.text('自重'), findsNothing,
          reason: '名字含「负重」→ 不再显示自重大字标识');
      expect(find.byKey(const ValueKey('weightDraftNum')), findsOneWidget,
          reason: '给重量大数字，可记外加载重');
      await tester.runAsync(() async {
        await container.session.completeSet(
            weight: container.session.weightDraft,
            reps: 6,
            rir: 2,
            kind: SetKind.working);
      });
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        final sets = await container.db
            .setsOfExercise(container.session.exercises.first.id!);
        expect(sets.last.weightKg, 5.0,
            reason: '保存走 weightDraft，不再被强制 0kg');
      });
      await tester.pumpWidget(const SizedBox());
    });

    /// 造「自重动作 + 一个后续动作」的两动作会话（P2-E）：练满前者后落到
    /// 后者的休息页，正好观察刚完成动作的变式建议（单动作练满会进收尾确认）。
    /// 不传 loadType = 与内置薄肌计划/模板安装一致，走默认 weighted。
    Future<void> startBodyweightThenOther(WidgetTester tester,
        {bool withPriorLayoff = false, bool withDeload = false}) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        if (withPriorLayoff) {
          // 20 天前一场**有正式组**的 done 训练（lastDoneSessionDate 只认
          // 有 working 组的会话，2026-10-18 起：空场不算"练过"）。
          final layoffSession = await container.db.insertSession(Session(
              date:
                  fmtDate(DateTime.now().subtract(const Duration(days: 20))),
              planDayTitle: '旧训练',
              startedAt: 1,
              endedAt: 2,
              status: 'done'));
          final layoffSe = await container.db.insertSessionExercise(
              SessionExercise(
                  sessionId: layoffSession.id!,
                  name: '引体向上',
                  orderIdx: 0,
                  kind: 'compound',
                  rule: const ProgressionRule(
                      repsMin: 5, repsMax: 8, workingSets: 3)));
          await container.db.insertSet(SetEntry(
              sessionExerciseId: layoffSe,
              weightKg: 0,
              reps: 8,
              rir: 2,
              kind: SetKind.working,
              doneAt: 100));
        }
        final day = await makeDay('背日');
        if (withDeload) {
          // 2 周一个训练块：同计划 7 天前那场是块起点，今天 = 第 2 周减载
          container.settings.trainingBlockWeeks = 2;
          await container.db.insertSession(Session(
              date:
                  fmtDate(DateTime.now().subtract(const Duration(days: 7))),
              planDayId: day.id,
              planDayTitle: '背日',
              startedAt: 1,
              endedAt: 2,
              status: 'done'));
        }
        final a = await addEx(day, '引体向上', 0);
        final b = await addEx(day, '坐姿划船', 1);
        await container.session.startFromDay(day: day, planExercises: [a, b]);
      });
      await pumpWorkout(tester);
    }

    Future<void> completeBodyweightSet(WidgetTester tester) async {
      await tester.runAsync(() async {
        await container.session
            .completeSet(weight: 0, reps: 8, rir: 2, kind: SetKind.working);
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('默认计划（weighted）的自重动作：练满计划组且次数到顶才建议下一档',
        (tester) async {
      await startBodyweightThenOther(tester);

      await completeBodyweightSet(tester);
      expect(find.text('组间休息'), findsOneWidget, reason: '完成一组进休息页');
      expect(find.textContaining('试试负重引体向上'), findsNothing,
          reason: '计划 3 组只做 1 组：不提前建议换动作');

      await tester.runAsync(() async {
        container.session.skipRest();
        await container.session
            .completeSet(weight: 0, reps: 8, rir: 2, kind: SetKind.working);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        container.session.skipRest();
        await container.session
            .completeSet(weight: 0, reps: 8, rir: 2, kind: SetKind.working);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('试试负重引体向上'), findsOneWidget,
          reason: '计划组全部练满、顶格且余力达标 → 给下一档建议');
      expect(find.byType(AlertDialog), findsNothing, reason: '训练中禁止弹窗');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('停练回归场次不叠加「试试下一档」升级建议', (tester) async {
      await startBodyweightThenOther(tester, withPriorLayoff: true);
      // 停练回归的计划组数少 1（3 → 2），练满 2 组即落到下一动作休息页
      await completeBodyweightSet(tester);
      await tester.runAsync(() async {
        container.session.skipRest();
        await container.session
            .completeSet(weight: 0, reps: 8, rir: 2, kind: SetKind.working);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.session.inLayoff, isTrue, reason: '20 天没练 → 回归场');
      expect(find.textContaining('试试负重引体向上'), findsNothing,
          reason: '恢复处方优先，不叠加升级建议');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('减载周不叠加「试试下一档」升级建议', (tester) async {
      await startBodyweightThenOther(tester, withDeload: true);
      // 减载周计划组数少 1（3 → 2），练满 2 组即落到下一动作休息页
      await completeBodyweightSet(tester);
      await tester.runAsync(() async {
        container.session.skipRest();
        await container.session
            .completeSet(weight: 0, reps: 8, rir: 2, kind: SetKind.working);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.session.inDeloadWeek, isTrue, reason: '块第 2/2 周');
      expect(find.textContaining('试试负重引体向上'), findsNothing,
          reason: '减载周的处方是恢复，不叠加升级建议');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('总结页：自重顶格给加组与下一档建议（默认 weighted 也生效）',
        (tester) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        final day = await makeDay('背日');
        final a = await addEx(day, '引体向上', 0, workingSets: 1);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      // 不先挂训练页：confirmAutoFinish 未接线，记满最后一组按原语义
      // 自动结束（挂了页面会弹「现在结束吗」，测试里没人点会一直等）。
      await tester.runAsync(() async {
        await container.session
            .completeSet(weight: 0, reps: 8, rir: 2, kind: SetKind.working);
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      expect(container.session.hasActive, isFalse, reason: '控制器记满自动结束');
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('训练完成 💪'), findsOneWidget, reason: '收尾进总结页');
      expect(find.textContaining('次数到顶，下次建议加练一组'), findsOneWidget,
          reason: '总结页加组建议');
      expect(find.textContaining('也可以试试负重引体向上'), findsOneWidget,
          reason: '总结页下一档建议（默认 weighted 的自重动作也生效）');
      // 同屏 verdict 必须与 P2-E 同一口径：老计划 weighted 的 0kg 引体
      // 不能再写「下次加重至 2.5kg」和「试试负重引体」互相矛盾。
      expect(find.textContaining('自重档位'), findsOneWidget,
          reason: 'verdict 走自重口径');
      expect(find.textContaining('加重至 2.5kg'), findsNothing,
          reason: '不得同时建议负重加重');
      await tester.pumpWidget(const SizedBox());
    });
  });

  // 杠铃片速配（2026-10-18）：记录页「每边挂几片」的杆重口径与起始页热身
  // 同源（warmupBarKgFor）：EZ 杠 10kg/25lb，标准奥杆 20kg/45lb 不变。
  group('杠铃片速配（杆重与起始页热身同口径）', () {
    /// 起一个单动作会话并进到第一记录页（起始页已过）。
    Future<void> pumpRecording(WidgetTester tester, String name) async {
      setSurface(tester, const Size(360, 800));
      await tester.runAsync(() async {
        final day = await makeDay('手臂日');
        final a = await addEx(day, name, 0, workingSets: 2);
        await container.session.startFromDay(day: day, planExercises: [a]);
      });
      await pumpWorkout(tester);
    }

    /// 改重量草稿触发速配闪现（didUpdateWidget：重量变了才闪）。
    Future<void> flashTo(WidgetTester tester, double kg) async {
      container.session.setWeightDraft(kg);
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('EZ 杠：30kg 按 10kg 空杆配片，每边 10', (tester) async {
      await pumpRecording(tester, '曲杠弯举（EZ杠）');
      await flashTo(tester, 30);

      expect(find.text('每边 10'), findsOneWidget,
          reason: '30 − EZ 空杆 10 = 每边 10，不再按 20kg 奥杆算成每边 5');
      expect(find.textContaining('20kg'), findsNothing,
          reason: 'EZ 杠提示里不出现奥杆口径的 20kg');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('EZ 杠：打回 10kg 提示「空杆 10kg」，4 秒后自动收起',
        (tester) async {
      await pumpRecording(tester, '曲杠弯举（EZ杠）');
      await flashTo(tester, 30);
      await flashTo(tester, 10);

      expect(find.text('空杆 10kg，不用挂片'), findsOneWidget,
          reason: 'EZ 空杆文案也是 10kg 口径');

      // 收起 = 透明（Text 留在树里，数据不清空）
      await tester.pump(const Duration(seconds: 4, milliseconds: 500));
      final strip = tester.widget<AnimatedOpacity>(find.ancestor(
          of: find.text('空杆 10kg，不用挂片'),
          matching: find.byType(AnimatedOpacity)));
      expect(strip.opacity, 0, reason: '约 4 秒自动收起');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('标准奥杆不变：60kg 每边 20、20kg 仍报「空杆 20kg」',
        (tester) async {
      await pumpRecording(tester, '杠铃卧推');
      await flashTo(tester, 60);
      expect(find.text('每边 20'), findsOneWidget, reason: '标准奥杆 20kg 口径不变');

      await flashTo(tester, 20);
      expect(find.text('空杆 20kg，不用挂片'), findsOneWidget,
          reason: '标准杆空杆文案不变');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('EZ 杠 lb 模式：空杆提示 25lb（不是奥杆 45lb）', (tester) async {
      WeightUnits.setResolved(WeightUnit.lb);
      addTearDown(() => WeightUnits.setResolved(WeightUnit.kg));
      await pumpRecording(tester, '曲杠弯举（EZ杠）');
      await flashTo(tester, 10);

      expect(find.text('空杆 25lb，不用挂片'), findsOneWidget,
          reason: 'lb 模式 EZ 空杆 25lb，与起始页热身同口径');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('标准奥杆 lb 模式不变：仍报「空杆 45lb」不漂成 44',
        (tester) async {
      WeightUnits.setResolved(WeightUnit.lb);
      addTearDown(() => WeightUnits.setResolved(WeightUnit.kg));
      await pumpRecording(tester, '杠铃卧推');
      await flashTo(tester, 20);

      expect(find.text('空杆 45lb，不用挂片'), findsOneWidget,
          reason: '标准奥杆 45lb 口径不变（不走 20kg→44lb 换算）');
      expect(find.textContaining('44lb'), findsNothing,
          reason: '不出现 44/45lb 打架');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
