// 批次4：多屏适配与防移位的 widget 测试矩阵（项目首个 widget 测试）。
// 真库（ffi）+ AppContainer 注入 + 多尺寸驱动关键页面：
//   - 动作态 WorkoutPage：A8-1 单栏滚动兜底 / compact 600dp 断点
//   - 休息态 WorkoutPage：A8-1② 底部操作区滚动兜底 + 大数字 clamp 下限
//   - 总结页：A8-3 统计格 FittedBox（长容量串 + 大字号）
//   - 挑选页：A8-4 筛选行 Flexible / A2-3 词表口径合并 DB 沉淀
// 断言口径：takeException 为 null（无 RenderFlex 溢出）+ 关键按钮矩形在屏内。
// 冻结基线回归锚点：完成本组按钮（BigButton 88dp）、休息大数字为屏内最大
// 元素、重量微调主入口仍是步进按钮（点数字键盘直输为 2026-09-24 新增入口）。
//
// ⚠ sqflite_common_ffi 的 SQL 在后台 isolate 跑，回包走真实事件循环，
// testWidgets 的 FakeAsync 驱不动（直接 await 会死锁到 10 分钟超时）——
// 所有 DB/会话操作必须包进 tester.runAsync；页内异步加载（如挑选页
// _load）用「runAsync 真实延时让 isolate 回包送达 + pumpAndSettle 渲染」桥接。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/services/session_controller.dart';
import 'package:baoji_timer/ui/exercise_picker_page.dart';
import 'package:baoji_timer/ui/plan_page.dart';
import 'package:baoji_timer/ui/stats_page.dart';
import 'package:baoji_timer/ui/widgets/common.dart';
import 'package:baoji_timer/ui/workout_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final binding = TestWidgetsFlutterBinding.instance;
    // 测试环境没有宿主插件：给会碰到的平台通道挂空实现，避免
    // MissingPluginException。wakelock_plus 走 pigeon：对 null 回包抛
    // channel-error，void 方法的合法回包是编码后的 [null]
    // （StandardMessageCodec：0x0C 0x01 0x00）。
    final pigeonNullReply = ByteData(3)
      ..setUint8(0, 12)
      ..setUint8(1, 1)
      ..setUint8(2, 0);
    binding.defaultBinaryMessenger.setMockMessageHandler(
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
        (data) async => pigeonNullReply);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('baoji/focus'), (call) async => null);
    // 防御性兜底（notify 未初始化时其实不会调用）：
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter_local_notifications'),
        (call) async => null);
  });

  tearDownAll(() async {
    // 清掉 Db.instance 打开的测试库文件（在 .dart_tool 下，不进仓库）
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/baoji_timer.db');
  });

  late AppContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = AppContainer(prefs: prefs);
    // 不调 container.init()：notify 未初始化即全部 no-op（避开平台通道）；
    // 手动拉起计划缓存与会话恢复。setUp 在真实 async 区跑，DB 可直接 await。
    await container.db.wipeAll(); // 清掉上次运行残留的会话/计划
    await container.planRepo.reload();
    await container.session.restore();
  });

  tearDown(() async {
    // 若还挂在休息态：取消 250ms tick（可能是真实定时器），避免 pending timer
    container.session.skipRest();
    await container.db.wipeAll();
    container.dispose();
  });

  // ---------- 基建 helper ----------

  /// 设定测试视口（逻辑像素 = physicalSize / dpr = size）。
  void setSurface(WidgetTester tester, Size size, {double textScale = 1.0}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    if (textScale != 1.0) {
      tester.view.platformDispatcher.textScaleFactorTestValue = textScale;
    }
    addTearDown(() {
      tester.view.reset();
      tester.view.platformDispatcher.clearAllTestValues();
    });
  }

  Widget host(AppContainer c, Widget home) =>
      AppScope(container: c, child: MaterialApp(home: home));

  /// 断言本帧无布局异常（RenderFlex 溢出等），失败时打印完整错误链
  /// （含 "relevant error-causing widget"，便于定位是哪个组件溢出）。
  void expectNoLayoutError(WidgetTester tester) {
    final err = tester.takeException();
    if (err != null) fail('页面布局异常: $err');
  }

  /// 断言 finder 命中的组件矩形完整落在 size 视口内（在屏内、拇指可达）。
  void expectOnScreen(
    WidgetTester tester,
    Finder finder,
    Size size, {
    String? reason,
  }) {
    final rect = tester.getRect(finder);
    final why = reason ?? '$finder 应完整在 ${size.width}x${size.height} 屏内';
    expect(rect.top, greaterThanOrEqualTo(0.0), reason: why);
    expect(rect.bottom, lessThanOrEqualTo(size.height), reason: why);
    expect(rect.left, greaterThanOrEqualTo(0.0), reason: why);
    expect(rect.right, lessThanOrEqualTo(size.width), reason: why);
  }

  Future<PlanDay> makeDay(String title) async {
    final plan = await container.db.insertPlan(Plan(
        name: '测试计划-$title',
        source: 'manual',
        createdAt: '2026-09-24',
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

  /// 造 2 动作 × 3 正式组的会话并进入动作态（DB 段在 runAsync 里跑）。
  Future<void> startLifting(WidgetTester tester) async {
    await tester.runAsync(() async {
      final day = await makeDay('推日');
      final a = await addEx(day, '卧推', 0, restSec: 120);
      final b = await addEx(day, '划船', 1, restSec: 120);
      await container.session.startFromDay(day: day, planExercises: [a, b]);
    });
  }

  Future<void> pumpWorkout(WidgetTester tester) async {
    await tester.pumpWidget(host(container, const WorkoutPage()));
    await tester.pump(const Duration(milliseconds: 20));
    // 页面流（调研条目 8）：零记录的新会话先落起始页，点「开始训练」进当前记录页
    if (find.text('开始训练').evaluate().isNotEmpty) {
      await tester.tap(find.text('开始训练'));
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  const phone = Size(360, 800);
  const foldNear = Size(600, 1000);
  const foldWide = Size(840, 1100);
  const landscape = Size(800, 360); // 720p 机型横屏：原 A8-1 触发场景
  const narrow = Size(599, 960); // 600dp 断点之下

  // ---------- 动作态 ----------

  group('动作态 WorkoutPage（A8-1 单栏滚动兜底 + compact 断点）', () {
    for (final size in [phone, foldNear, foldWide]) {
      testWidgets('${size.width}x${size.height} 无溢出，完成本组按钮在屏内',
          (tester) async {
        setSurface(tester, size);
        await startLifting(tester);
        await pumpWorkout(tester);
        expectNoLayoutError(tester);

        final btn = find.byKey(const Key('workoutCompleteSet'));
        expect(btn, findsOneWidget);
        expectOnScreen(tester, btn, size, reason: '完成本组按钮（88dp 主操作）');
        // 冻结基线：完成本组按钮高度 ≥88dp；步进按钮 8 枚原样（键盘直输为新增入口，不替代）
        expect(tester.getSize(btn).height, greaterThanOrEqualTo(88.0),
            reason: '冻结基线：完成本组按钮高度 ≥88dp');
        expect(find.byType(WeightStepButton), findsNWidgets(8),
            reason: '冻结基线：重量微调仍是 0.5/1.25/2.5/5kg 步进按钮');

        // 冻结基线回归：<600 收起备注行（compact 生效），600 及以上保留
        if (size.width < 600) {
          expect(find.text('+ 备注（可选）'), findsNothing,
              reason: 'narrow(<600) compact：备注行收起');
        } else {
          expect(find.text('+ 备注（可选）'), findsOneWidget,
              reason: '600-839/≥840 非紧凑：备注行保留');
        }
      });
    }

    testWidgets('840×1100 双栏：操作面板在右栏且为滚动布局', (tester) async {
      setSurface(tester, foldWide);
      await startLifting(tester);
      await pumpWorkout(tester);
      expectNoLayoutError(tester);

      final btn = find.byKey(const Key('workoutCompleteSet'));
      expect(tester.getRect(btn).left, greaterThan(foldWide.width / 2),
          reason: '≥840 双栏：操作面板应在右半屏');
      expect(
        find.ancestor(
            of: btn, matching: find.byType(SingleChildScrollView)),
        findsOneWidget,
        reason: '840 档右栏应为滚动布局',
      );
    });

    testWidgets('599×960 narrow 分支：compact 生效且完成按钮在屏内', (tester) async {
      setSurface(tester, narrow);
      await startLifting(tester);
      await pumpWorkout(tester);
      expectNoLayoutError(tester);
      expect(find.text('+ 备注（可选）'), findsNothing,
          reason: '599<600：compact 生效，备注行收起');
      expectOnScreen(tester, find.byKey(const Key('workoutCompleteSet')),
          narrow,
          reason: '完成本组按钮（88dp 主操作）');
    });

    testWidgets('800×360 横屏：面板可滚动，完成按钮不再被挤出屏幕', (tester) async {
      setSurface(tester, landscape);
      await startLifting(tester);
      await pumpWorkout(tester);
      // 修复前：固定面板 ~515dp 装进 ~360dp 可用高 → RenderFlex 溢出抛异常
      expectNoLayoutError(tester);

      final btn = find.byKey(const Key('workoutCompleteSet'));
      await tester.ensureVisible(btn); // 滚动兜底后可达
      await tester.pump(const Duration(milliseconds: 10));
      expectOnScreen(tester, btn, landscape,
          reason: '横屏下完成本组按钮应可通过滚动到达并点按');
    });
  });

  // ---------- 休息态 ----------

  group('休息态 WorkoutPage（A8-1② 底部操作区滚动兜底）', () {
    Future<void> pumpResting(WidgetTester tester, Size size) async {
      setSurface(tester, size);
      await startLifting(tester);
      await pumpWorkout(tester);
      await tester.runAsync(() async {
        await container.session
            .completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
        // 排干 _beginRestFor 里 _loadContextForCurrent().then(...) 的悬挂续体
        //（真实事件循环里跑完，避免它落在 dispose 之后报 used-after-disposed）
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump(const Duration(milliseconds: 20));
      expect(container.session.phase, WorkoutPhase.resting);
    }

    for (final size in [phone, foldNear, foldWide, landscape]) {
      testWidgets('${size.width}x${size.height} 休息操作按钮都在屏内',
          (tester) async {
        await pumpResting(tester, size);
        expectNoLayoutError(tester);
        // 页面流顶部条 + 3px 进度条（调研条目 8）占约 35dp：横屏矮屏下
        // 底部操作区改为"滚动可达"口径（与动作态横屏用例一致）
        if (size == landscape) {
          await tester.ensureVisible(find.text('跳过休息，直接开练'));
          await tester.pump(const Duration(milliseconds: 10));
        }
        expectOnScreen(tester, find.text('跳过休息，直接开练'), size);
        expectOnScreen(tester, find.text('+30 秒'), size);
        expectOnScreen(tester, find.text('暂停'), size);

        if (size == phone) {
          // 冻结基线：休息倒计时数字保持屏内最大文字元素（clamp 下限 56）
          final countdown = find.textContaining(RegExp(r'^\d{2}:\d{2}$'));
          expect(countdown, findsOneWidget);
          final cdRect = tester.getRect(countdown);
          expect(cdRect.height, greaterThanOrEqualTo(56.0),
              reason: '休息大数字 clamp 下限 56');
          expect(cdRect.height,
              greaterThan(tester.getRect(find.text('组间休息')).height),
              reason: '冻结基线：倒计时数字是屏内最大文字元素');
        }
      });
    }
  });

  // ---------- 重量键盘输入 ----------

  group('重量键盘输入（点数字/直接输入 → 数字键盘直输）', () {
    // 弹层动画：tap 后先 pump() 起帧、再 pump(时长) 才会推进（单次 pump(300)
    // 首帧 elapsed=0，弹层停在屏外起点，tap 落空）。
    testWidgets('动作态：点重量数字弹输入层，输入 86.5 确认后草稿生效',
        (tester) async {
      setSurface(tester, phone);
      await startLifting(tester);
      await pumpWorkout(tester);

      await tester.tap(find.byKey(const ValueKey('weightDraftNum')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(TextField), findsOneWidget, reason: '弹出数字输入层');
      expect(find.text('输入重量（kg）'), findsOneWidget,
          reason: '输入层标题可见（底层动作面板仍在树中，属正常浮层结构）');

      await tester.enterText(find.byType(TextField), '86.5');
      await tester.tap(find.text('确认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.session.weightDraft, 86.5);
      expect(find.byType(WeightStepButton), findsNWidgets(8),
          reason: '确认后回到动作面板，0.5/1.25/2.5/5kg 步进按钮原样');
    });

    testWidgets('动作态：空输入不关层并提示；取消不改草稿', (tester) async {
      setSurface(tester, phone);
      await startLifting(tester);
      await pumpWorkout(tester);
      final before = container.session.weightDraft;

      await tester.tap(find.byKey(const ValueKey('weightDraftNum')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 输入层已过滤字母，空文本是仅剩的非法态
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('确认'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('请输入数字，如 62.5 或 -30'), findsOneWidget,
          reason: '空输入给错误提示，不关层');
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.session.weightDraft, before, reason: '取消不改草稿');
      expect(find.byType(TextField), findsNothing, reason: '输入层已关');
    });

    testWidgets('休息态：展开步进后有「直接输入重量」，输 -27.5 = 辅助配重',
        (tester) async {
      setSurface(tester, phone);
      await startLifting(tester);
      await pumpWorkout(tester);
      await tester.runAsync(() async {
        await container.session
            .completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
        // 排干 _beginRestFor 里 _loadContextForCurrent 的悬挂续体
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump(const Duration(milliseconds: 20));
      expect(container.session.phase, WorkoutPhase.resting);

      await tester.tap(find.textContaining('下一组'));
      await tester.pump(const Duration(milliseconds: 50));
      final inputBtn = find.text('直接输入重量');
      expect(inputBtn, findsOneWidget);
      await tester.ensureVisible(inputBtn);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(inputBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField), '-27.5');
      await tester.tap(find.text('确认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.session.weightDraft, -27.5,
          reason: '休息态键盘直输负值 = 辅助配重');
    });
  });

  // ---------- 总结页 ----------

  group('总结页（A8-3 统计格自适应 · 页面流入流版）', () {
    // 2 动作 × 3 组 × 60kg × 8 次 = 2880kg → fmtVolume 输出 "2880kg" 长串。
    // 前 5 组 controller 直记，最后一组走 UI「完成本组」→ 保存→写库→
    // 状态机自动结束→页面流收尾，总结页作为流程最后一页就地展示
    // （调研条目 8：不再走 Navigator.pushReplacement）。
    Future<void> finishToSummary(WidgetTester tester) async {
      await startLifting(tester);
      await tester.runAsync(() async {
        final s = container.session;
        for (var i = 0; i < 5; i++) {
          await s.completeSet(
              weight: 60, reps: 8, rir: 2, kind: SetKind.working);
          if (s.phase == WorkoutPhase.resting) s.skipRest();
        }
        // 排干 completeSet → _beginRestFor 的悬挂续体
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await pumpWorkout(tester); // 已有 5 组记录：直接落到最后一个记录页
      // 测试闸门（2026-10-07 结束确认弹窗）：本用例验证「自动结束→总结页」
      // 收尾管线，确认面板行为由 workout_flow_widget_test 专测覆盖——
      // 置 null 放行原自动结束语义，否则最后一组会被确认面板挂住。
      container.session.confirmAutoFinish = null;
      expect(
        WorkoutFlow(
          exercises: container.session.exercises,
          setsByEx: container.session.setsByEx,
        ).donePlannedSets,
        5,
        reason: '前 5 个计划组已记（全程口径）',
      );
      // UI tap 触发的 completeSet 走真实 isolate DB：tap 与真实延时一起
      // 包进 runAsync，回包与后续收尾链才有机会跑完（本文件头部已知坑）。
      // 草稿重量/次数与 controller 直记的 5 组同口径（60kg×8 → 6 组 2880kg）。
      await tester.runAsync(() async {
        container.session.setWeightDraft(60);
        // 大字号下次数 chips 可能滚出屏：先滚动可达再点选
        await tester.ensureVisible(find.text('8'));
        await tester.pump(const Duration(milliseconds: 50));
        // 余力没填写提醒上线后：落库前先选余力 2（RIR 行在次数行上方）
        await tester.ensureVisible(find.text('2'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('2'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('8'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pumpAndSettle();
      expect(find.text('训练完成 💪'), findsOneWidget,
          reason: '最后一组保存后页面流自动进入总结页');
    }

    testWidgets('360×800：无异常，长容量串显示且收工按钮在屏内', (tester) async {
      setSurface(tester, phone);
      await finishToSummary(tester);
      expectNoLayoutError(tester);
      expect(find.text('2880kg'), findsOneWidget,
          reason: 'A8-3：总容量长串（不可软断行的 kg 文本）');
      expectOnScreen(tester, find.text('收工'), phone);
    });

    testWidgets('360×800 大字号 1.6：无异常且收工按钮在屏内', (tester) async {
      setSurface(tester, phone, textScale: 1.6);
      await finishToSummary(tester);
      expectNoLayoutError(tester);
      expect(find.text('2880kg'), findsOneWidget);
      // 大字号下总结内容自然超过一屏（ListView 可滚动）：按"可达"口径验证
      final done = find.text('收工');
      await tester.ensureVisible(done);
      await tester.pump(const Duration(milliseconds: 10));
      expectOnScreen(tester, done, phone, reason: '大字号下收工按钮滚动可达');
    });

    testWidgets('收工按钮：popUntil 回到页面流入口之前的首个路由', (tester) async {
      // 总结页并入 WorkoutPage 后，收工应退出训练页回到入口页
      setSurface(tester, phone);
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
        final a = await addEx(day, '卧推', 0, restSec: 120);
        final b = await addEx(day, '划船', 1, restSec: 120);
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
      // 测试闸门（2026-10-07 结束确认弹窗）：同 finishToSummary——本用例
      // 验证收工按钮回入口页，置 null 放行原自动结束语义，否则最后一组
      // 会被确认面板挂住。
      container.session.confirmAutoFinish = null;
      await tester.runAsync(() async {
        container.session.setWeightDraft(60);
        // 余力没填写提醒上线后：落库前先选余力 2
        await tester.ensureVisible(find.text('2'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('2'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('8'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byKey(const Key('workoutCompleteSet')));
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pumpAndSettle();
      expect(find.text('训练完成 💪'), findsOneWidget);

      await tester.tap(find.text('收工'));
      await tester.pumpAndSettle();
      expect(find.text('去训练'), findsOneWidget,
          reason: '收工 = popUntil 首个路由，回到入口页');
      expect(find.text('训练完成 💪'), findsNothing);
    });
  });

  // ---------- 动作挑选页 ----------

  group('动作挑选页（A8-4 筛选行 + A2-3 词表口径）', () {
    // 词表外动作：内置库只有「面拉」「弹力带面拉」，此名字只能来自 DB 沉淀
    const seeded = '面拉加强版';

    Future<void> seedAndPump(WidgetTester tester, Size size,
        {double textScale = 1.0}) async {
      setSurface(tester, size, textScale: textScale);
      await tester.runAsync(() async {
        // 模拟 AI 拆解/手动添加沉淀进 exercise_meta 的词表外动作
        await container.db.upsertExerciseMeta(const ExerciseMeta(
            seeded, MuscleGroups(main: '肩', secondary: ['背']), false, 'gym'));
      });
      await tester.pumpWidget(
          host(container, const ExercisePickerPage(existingNames: {})));
      // 首帧后 _load 异步合入 DB 沉淀：真实延时让 isolate 回包送达，再渲染
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }

    testWidgets('360×800：无溢出，DB 沉淀动作可搜到（A2-3 回归）', (tester) async {
      await seedAndPump(tester, phone);
      expectNoLayoutError(tester);
      expect(find.textContaining('共 '), findsOneWidget, reason: '计数行存在');

      await tester.enterText(find.byType(TextField), seeded);
      await tester.pump();
      expect(find.widgetWithText(Card, seeded), findsOneWidget,
          reason: '沉淀进 exercise_meta 的词表外动作要能在挑选页搜到');

      final addBtn = find.textContaining('添加');
      expect(addBtn, findsOneWidget);
      expectOnScreen(tester, addBtn, phone);
    });

    testWidgets('360×800 大字号 1.6：筛选行不溢出，底部按钮在屏内', (tester) async {
      await seedAndPump(tester, phone, textScale: 1.6);
      expectNoLayoutError(tester); // A8-4：大字号下筛选行/计数不再 RenderFlex 溢出
      expectOnScreen(tester, find.textContaining('添加'), phone);
    });
  });

  // ---------- 320dp 窄屏 + 1.6 大字号（2026-09-26 Arono 报障：数字折行/分布错乱） ----------

  group('320dp 窄屏 + 1.6 大字号：计划页与数据页无溢出、数字不断行', () {
    const tiny = Size(320, 640);

    /// PlanPage 无自身 Scaffold（真实 App 由 HomeShell 提供），宿主要补。
    Widget hostWithScaffold(Widget page) => AppScope(
          container: container,
          child: MaterialApp(home: Scaffold(body: page)),
        );

    testWidgets('计划页：排程行/模板按钮/步进值无布局异常', (tester) async {
      setSurface(tester, tiny, textScale: 1.6);
      await tester.runAsync(() async {
        await makeDay('推日');
        await container.planRepo.reload();
      });
      await tester.pumpWidget(hostWithScaffold(const PlanPage()));
      // _refresh 的 db 回包桥接（同挑选页口径：真实延时 + pump）
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump(const Duration(milliseconds: 100));
      expectNoLayoutError(tester);
      expect(find.textContaining('测试计划'), findsOneWidget,
          reason: '计划已加载（日期视图按排程推导，不保证显示模板日名）');
    });

    testWidgets('数据页肌肉 Tab：恢复度/容量行数字不断行、无布局异常',
        (tester) async {
      setSurface(tester, tiny, textScale: 1.6);
      await tester.pumpWidget(host(container, const StatsPage()));
      // 先让概览 Tab 的加载完成（无限转圈不能 pumpAndSettle，真实延时桥接）
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('肌肉'), findsOneWidget);
      await tester.tap(find.text('肌肉'));
      await tester.pump(const Duration(milliseconds: 50));
      // 肌肉 Tab 两个 FutureBuilder 的 db 查询回包桥接：
      // 多轮「真实延时 + pump」直到内容出现（上限约 2 秒防死等）
      var loaded = false;
      for (var i = 0; i < 6 && !loaded; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump(const Duration(milliseconds: 100));
        loaded = find.text('肌群恢复度').evaluate().isNotEmpty;
      }
      expect(loaded, isTrue, reason: '肌肉 Tab 应加载出恢复度卡片');
      expectNoLayoutError(tester);
      // 百分比标签全部单行：两行文本的高度会明显超过 1.6 倍字号的行高
      for (final e in find.textContaining('%').evaluate()) {
        final w = e.widget as Text;
        expect(tester.getSize(find.text(w.data!).last).height, lessThan(42),
            reason: '「${w.data}」不应折行（FittedBox 缩放兜底）');
      }
    });
  });
}
