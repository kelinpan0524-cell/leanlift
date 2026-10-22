// 引导页与首启初始化的验收测试（真库 ffi + AppContainer 注入，基建同 widget_layout_test）。
// 覆盖：
//  - init 空库首启播种全量动作标注；老用户改过的标注不被启动时重置
//  - 引导页三屏流转：默认选中薄肌计划 → 开始使用 → 计划激活 + onboarded 落盘 + 进主框架
//  - 选五分化模板：走 installTemplate 路径（onboarding 与计划页同一条查重逻辑）
//  - 选「先不选」：不装计划也放行，动作库已由首启播种兜底
//  - 回归：旧版「稍后再说」死按钮（点了没反应）已被「先不选」选项取代
//
// 两条基建红线（踩过坑，勿回退）：
//  1. DB 用唯一文件路径 + Db.forTesting 注入。多个测试文件并发跑时若共用默认的
//     baoji_timer.db，本文件 tearDownAll 删库会把别文件打开的连接打成
//     SQLITE_READONLY_DBMOVED，两文件互相拖挂（曾 7 连挂 + 10 分钟超时）。
//  2. DB 回包经后台 isolate 的真实事件循环投递，pumpAndSettle 的假时钟等不到它。
//     点按后必须「runAsync 真实延时 ↔ pump 刷微任务」交替推进（见 tapFinish）；
//     首页加载中的 CircularProgressIndicator 会把 pumpAndSettle 卡到 10 分钟超时。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/models/models.dart';
import 'package:baoji_timer/presets/baoji_plan.dart';
import 'package:baoji_timer/presets/exercise_library.dart';
import 'package:baoji_timer/ui/onboarding_page.dart';
import 'package:baoji_timer/ui/shell.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database rawDb;
  late String dbPath;

  setUpAll(() async {
    sqfliteFfiInit();
    final binding = TestWidgetsFlutterBinding.instance;
    // 测试环境没有宿主插件：给会碰到的平台通道挂空实现
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('baoji/focus'), (call) async => null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter_local_notifications'),
        (call) async => null);
    // 权限屏刷新会查通知授权状态；requestPermissions 返回 granted(1)
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'),
        (call) async {
      switch (call.method) {
        case 'requestPermissions':
          return <int>[1];
        case 'checkPermissionStatus':
          return 1;
        default:
          return null;
      }
    });

    // 唯一路径真库（并发安全），schema 与生产一致（version 3 + 外键）
    final dir = await databaseFactory.getDatabasesPath();
    dbPath = '$dir/onboarding_${DateTime.now().microsecondsSinceEpoch}.db';
    rawDb = await databaseFactory.openDatabase(dbPath,
        options: OpenDatabaseOptions(
          version: 3,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, v) => Db.instance.createSchema(db),
        ));
  });

  tearDownAll(() async {
    // 先关库再删文件：连接开着删库会把它打成 READONLY_DBMOVED 并卡住删除
    await rawDb.close();
    await databaseFactory.deleteDatabase(dbPath);
  });

  late AppContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = AppContainer(prefs: prefs, db: Db.forTesting(rawDb));
    await container.db.wipeAll();
    // 走生产路径 init（含首启播种），不绕开
    await container.init();
  });

  tearDown(() async {
    await container.db.wipeAll();
    container.dispose();
  });

  // ---------- 首启初始化 ----------

  group('首启初始化（AppContainer.init 播种）', () {
    test('空库 init 后动作库全量就位，计划与会话缓存可用', () async {
      expect(await container.db.exerciseMetaCount(),
          kExerciseLibrary.length,
          reason: '首启播种写入全量内置动作标注');
      expect(container.planRepo.activePlan, isNull,
          reason: '播种不偷装计划，起始计划由引导页决定');
    });

    test('老用户改过的肌群标注不被启动时重置（非空库不重播）', () async {
      // 模拟用户在编辑器里把「杠铃卧推」的肌群标注改掉
      final meta = await container.db.exerciseMeta('杠铃卧推');
      expect(meta, isNotNull, reason: '前置：该动作在内置库里');
      await container.db.upsertExerciseMeta(ExerciseMeta(
          '杠铃卧推', MuscleGroups(main: '胸', secondary: ['肩']),
          meta!.isCompound, meta.equipment));

      await container.ensureFirstRunSeeded(); // 再次启动

      final after = await container.db.exerciseMeta('杠铃卧推');
      expect(after!.muscles.main, '胸',
          reason: 'exercise_meta 非空时不得整行 REPLACE 覆盖用户编辑');
      expect(await container.db.exerciseMetaCount(), kExerciseLibrary.length);
    });
  });

  // ---------- 引导页流转 ----------

  group('引导页三屏流转', () {
    // 手机竖屏视口：默认 800×600 会把「先不选」挤到惰性 ListView 视口外
    void setSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    Future<void> pumpOnboarding(WidgetTester tester) async {
      setSurface(tester);
      await tester.pumpWidget(AppScope(
          container: container,
          child: const MaterialApp(home: OnboardingPage())));
      await tester.pump();
      expect(find.text('薄肌训练计时器'), findsOneWidget, reason: '第 1 屏是欢迎页');
    }

    /// 用固定步进 pump，不用 pumpAndSettle：
    /// HomeShell 首页加载态是无限转圈，假时钟里永不 settle。
    /// 注意 ticker 首帧固定 elapsed=0：点按后必须先 pump() 起帧，
    /// 再 pump(时长) 才推进动画。
    Future<void> gotoPlanPage(WidgetTester tester) async {
      await tester.tap(find.text('下一步'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('需要几个权限'), findsOneWidget, reason: '第 2 屏是权限页');
      await tester.tap(find.text('下一步'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('选择你的起始计划'), findsOneWidget, reason: '第 3 屏是选计划页');
    }

    /// 点「开始使用」后：真库安装在后台 isolate，每个 DB 往返的回包都走真实
    /// 事件循环——runAsync 投递回包，pump 刷假时钟微任务让续体发出下一跳。
    /// 安装+导航+首页加载合计几十跳，固定几下 pump 推不完；循环推进直到
    /// 进了主框架且首页加载态（无限转圈）消失为止。
    Future<void> tapFinish(WidgetTester tester) async {
      await tester.tap(find.text('开始使用'));
      for (var i = 0; i < 300; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 16));
        final enteredShell = find.byType(HomeShell).evaluate().isNotEmpty;
        final stillLoading =
            find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
        if (enteredShell && !stillLoading) {
          // 无在途 DB 调用了，剩下路由过渡动画可以再补两帧走完
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          return;
        }
      }
      fail('点「开始使用」后 300 跳内没有进主框架并完成首屏加载');
    }

    testWidgets('默认选中薄肌计划，开始使用即安装并进主框架', (tester) async {
      await pumpOnboarding(tester);
      await gotoPlanPage(tester);

      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget,
          reason: '默认有且只有一个选中项');
      expect(find.text('推荐'), findsOneWidget, reason: '薄肌计划带推荐标');
      expect(find.text('稍后再说'), findsNothing,
          reason: '回归：旧版点了没反应的死按钮已移除');

      await tapFinish(tester);

      expect(find.byType(HomeShell), findsOneWidget);
      expect(container.prefs.getBool('onboarded'), isTrue,
          reason: '成功路径才落盘 onboarded');
      expect(container.planRepo.activePlan?.name, kBaojiPlanName,
          reason: '薄肌计划已安装并激活');
    });

    testWidgets('改选五分化模板：走模板安装路径', (tester) async {
      await pumpOnboarding(tester);
      await gotoPlanPage(tester);

      await tester.tap(find.text(kBroSplitTemplate.name));
      await tester.pump();
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);

      await tapFinish(tester);

      expect(container.prefs.getBool('onboarded'), isTrue);
      expect(container.planRepo.activePlan?.name, kBroSplitTemplate.name,
          reason: '模板计划已安装并激活');
    });

    testWidgets('选「先不选」：不装计划也放行，动作库兜底可用', (tester) async {
      await pumpOnboarding(tester);
      await gotoPlanPage(tester);

      await tester.tap(find.text('先不选'));
      await tester.pump();
      await tapFinish(tester);

      expect(find.byType(HomeShell), findsOneWidget);
      expect(container.prefs.getBool('onboarded'), isTrue);
      expect(container.planRepo.activePlan, isNull,
          reason: '「先不选」不得偷装计划');
      // DB 调用必须在真实事件循环里跑（假时钟收不到 isolate 回包）
      final metaCount = await tester
          .runAsync(() => container.db.exerciseMetaCount());
      expect(metaCount, kExerciseLibrary.length,
          reason: '跳过计划的用户也有完整动作库（首启播种兜底）');
    });
  });
}
