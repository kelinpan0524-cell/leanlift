// 中文界面全页面排版扫描（2026-09-28 Arono 反馈「计划页 3 日/一周/一月按钮有问题」，
// 要求中英两语言逐页核验无溢出）：与 lang_en_layout_sweep_test 同一基建，中文是
// 源语言所以文案即源码；额外覆盖计划页 3日/周/月 三种排程模式和窄屏 360 复扫。
// 本地跑 `flutter test --update-goldens test/lang_zh_layout_sweep_test.dart`
// 会在 test/goldens_zh/ 生成各页截图供人工核验（已 gitignore，不进仓库，
// CI 上金图缺失仅打印跳过、不算失败）。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/ui/ai_coach_page.dart';
import 'package:baoji_timer/ui/exercise_library_page.dart';
import 'package:baoji_timer/ui/history_page.dart';
import 'package:baoji_timer/ui/heart_rate_page.dart';
import 'package:baoji_timer/ui/home_page.dart';
import 'package:baoji_timer/ui/plan_page.dart';
import 'package:baoji_timer/ui/settings_page.dart';
import 'package:baoji_timer/ui/stats_page.dart';
import 'package:baoji_timer/ui/theme.dart';
import 'package:baoji_timer/ui/workout_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 收集当前测试中所有布局错误（默认 handler 只让第一个失败）。
class _IssueCollector {
  final issues = <String>[];
  FlutterExceptionHandler? _prev;

  void start(String page) {
    _prev = FlutterError.onError;
    FlutterError.onError = (details) {
      issues.add('$page: ${details.exception}');
    };
  }

  void stop() {
    FlutterError.onError = _prev;
    _prev = null;
  }
}

ByteData _fontBytes(String path) =>
    ByteData.view(File(path).readAsBytesSync().buffer);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
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
    // 真实字体：Arial Unicode（拉丁+中日韩一体）。除 Roboto 家族外还要注册
    // FlutterTest / CupertinoSystemText 等家族——按钮 textStyle、ListTile 副标题
    // 等经 M3 文本主题解析后的家族在测试环境落到这些名字，不注册就渲染成方框，
    // 没法人工核验排版（已用 _font_probe 实验确认）。
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root != null) {
      final dir = '$root/bin/cache/artifacts/material_fonts';
      final cjk = File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
      if (cjk.existsSync()) {
        for (final family in [
          'Roboto',
          'FlutterTest',
          'CupertinoSystemText',
          '.SF Pro',
          'SF Pro Text',
        ]) {
          final loader = FontLoader(family)
            ..addFont(Future.value(_fontBytes(cjk.path)));
          await loader.load();
        }
      } else {
        // 兜底：没有 CJK 字体就退回 Roboto（金图中文是方框，仅保 CI 不炸）
        final loader = FontLoader('Roboto')
          ..addFont(Future.value(_fontBytes('$dir/Roboto-Regular.ttf')))
          ..addFont(Future.value(_fontBytes('$dir/Roboto-Medium.ttf')))
          ..addFont(Future.value(_fontBytes('$dir/Roboto-Bold.ttf')))
          ..addFont(Future.value(_fontBytes('$dir/Roboto-Black.ttf')));
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(Future.value(_fontBytes('$dir/MaterialIcons-Regular.otf')));
      await icons.load();
    }
  });

  tearDownAll(() async {
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/zh_sweep_${DateTime.now().day}.db');
  });

  late AppContainer container;
  late Database rawDb;
  late String dbPath;

  setUp(() async {
    Lang.setResolved(false); // 中文（源语言）
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final factory = databaseFactory;
    dbPath =
        '${await factory.getDatabasesPath()}/zh_sweep_${DateTime.now().microsecondsSinceEpoch}.db';
    rawDb = await factory.openDatabase(dbPath,
        options: OpenDatabaseOptions(
          version: 3,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, v) => Db.instance.createSchema(db),
        ));
    container = AppContainer(prefs: prefs, db: Db.forTesting(rawDb));
    await container.db.wipeAll();
    await container.planRepo.reload();
    await container.session.restore();
  });

  tearDown(() async {
    await container.db.wipeAll();
    await rawDb.close();
    await databaseFactory.deleteDatabase(dbPath);
    container.dispose();
  });

  /// 手机视口（多数 Android 逻辑宽 360-430）
  void setSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(AppContainer c, Widget home, {double textScale = 1.0}) =>
      AppScope(
          container: c,
          // 与真实 shell 一致：深色主题 + Scaffold 提供 Material 祖先
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.dark,
              home: Builder(
                  builder: (context) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(textScale)),
                      child: Scaffold(body: home)))));

  /// 跨后台 isolate 的加载推进 + 金截图
  Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> golden(WidgetTester tester, String name) async {
    // 金图问题（缺失/不匹配）永不判布局失败：mismatch 除走 expectLater 的
    // future 外还会上报 FlutterError.onError，被 _IssueCollector 误收成
    // 布局异常——期间换 no-op handler 把这条上报通路断掉
    final prev = FlutterError.onError;
    FlutterError.onError = (details) {};
    try {
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens_zh/$name.png'));
    } catch (_) {
      // 无基线（CI / 未带 --update-goldens）或画面变化：仅提示，不算失败
    } finally {
      FlutterError.onError = prev;
    }
  }

  /// 纵向滚到底（ListView 只布局可见项，滚过去才会暴露下方条目的溢出）
  Future<void> scrollThrough(WidgetTester tester,
      {int screens = 3, Finder? on}) async {
    final target = on ?? find.byType(Scrollable).first;
    for (var i = 0; i < screens; i++) {
      if (!target.evaluate().isNotEmpty) break;
      await tester.drag(target, const Offset(0, -800));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// 造内容充实的数据：5 日计划 + 动作 + 一周已完成记录 + 身体数据
  Future<void> seed() async {
    final plan = await container.db.insertPlan(Plan(
        name: '薄肌五分化',
        source: 'manual',
        createdAt: '2026-09-20',
        isActive: 1));
    final days = ['推日', '拉日', '腿日', '肩臂', '休息'];
    final dayIds = <int>[];
    for (var i = 0; i < days.length; i++) {
      dayIds.add(await container.db.insertPlanDay(
          PlanDay(planId: plan.id!, weekday: i + 1, title: days[i])));
    }
    final exSets = [
      ('卧推', 60.0),
      ('上斜哑铃卧推', 22.5),
      ('划船', 55.0),
      ('深蹲', 90.0),
      ('侧平举', 8.0),
    ];
    for (var i = 0; i < exSets.length; i++) {
      final (name, _) = exSets[i];
      await container.db.insertPlanExercise(PlanExercise(
        dayId: dayIds.first,
        name: name,
        orderIdx: i,
        sets: 3,
        repsMin: 5,
        repsMax: 8,
        restSec: 120,
        kind: 'compound',
        rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      ));
    }
    // 一周内 3 条已完成 session（各带组记录 + 休息时长），喂历史/数据/统计
    final now = DateTime.now();
    for (final ago in [6, 4, 1]) {
      final when = now.subtract(Duration(days: ago));
      final sid = (await container.db.insertSession(Session(
        date: fmtDate(when),
        planDayTitle: '推日',
        startedAt: when.millisecondsSinceEpoch - 3300000,
        endedAt: when.millisecondsSinceEpoch,
        status: 'done',
        restMs: 14 * 60000,
        impression: 3,
      )))
          .id!;
      final seId = await container.db.insertSessionExercise(SessionExercise(
        sessionId: sid,
        name: '杠铃卧推',
        orderIdx: 0,
        kind: 'compound',
        rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      ));
      for (final (w, r) in [(60.0, 8), (62.5, 7), (65.0, 6)]) {
        await container.db.insertSet(SetEntry(
          sessionExerciseId: seId,
          weightKg: w,
          reps: r,
          rir: 2,
          kind: SetKind.working,
          doneAt: when.millisecondsSinceEpoch,
        ));
      }
      // 腿日第二动作：让「肌肉」Tab 有跨肌群的容量分布，而不是只剩「其他」
      final squatId = await container.db.insertSessionExercise(SessionExercise(
        sessionId: sid,
        name: '杠铃深蹲',
        orderIdx: 1,
        kind: 'compound',
        rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      ));
      for (final (w, r) in [(80.0, 6), (85.0, 5)]) {
        await container.db.insertSet(SetEntry(
          sessionExerciseId: squatId,
          weightKg: w,
          reps: r,
          rir: 1,
          kind: SetKind.working,
          doneAt: when.millisecondsSinceEpoch,
        ));
      }
    }
    await container.db.upsertBodyMetric(BodyMetric(
        date: fmtDate(now.subtract(const Duration(days: 7))),
        weightKg: 72.5));
    await container.db
        .upsertBodyMetric(BodyMetric(date: fmtDate(now), weightKg: 72.0));
    await container.planRepo.reload();
  }

  Future<void> pumpAllMainPages(
      WidgetTester tester, List<String> issues, String tag) async {
    final c = _IssueCollector();
    final pages = <String, Widget>{
      'home': const HomePage(),
      'plan': const PlanPage(),
      'history': const HistoryPage(),
      'stats': const StatsPage(),
      'settings': const SettingsPage(),
    };
    for (final entry in pages.entries) {
      c.start(entry.key);
      try {
        await tester.pumpWidget(host(container, entry.value));
        await settle(tester);
        // 首屏单独留档：滚动后截图看不到页首层级（数据页 KPI/设置页分组），
        // 人工核验需要一张未滚动的原貌
        await golden(tester, '${tag}_${entry.key}_top');
        // 第二屏：数据页的 1RM/余力/休息卡都在中段，只留首尾会漏看
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -800));
        await tester.pump(const Duration(milliseconds: 200));
        await golden(tester, '${tag}_${entry.key}_mid');
        await scrollThrough(tester, screens: 2);
        await golden(tester, '${tag}_${entry.key}');
      } catch (e) {
        issues.add('${entry.key}: pump threw $e');
      }
      c.stop();
      issues.addAll(c.issues.map((e) => '${entry.key}: $e'));
    }
    // 数据页 muscle / body 两个 Tab 也扫
    c.start('stats-muscle');
    try {
      await tester.pumpWidget(host(container, const StatsPage()));
      await settle(tester);
      await tester.tap(find.text('肌肉'));
      await settle(tester, rounds: 8);
      await golden(tester, '${tag}_stats_muscle_top');
      await scrollThrough(tester);
      await golden(tester, '${tag}_stats_muscle');
      await tester.tap(find.text('身体'));
      await settle(tester, rounds: 4);
      await golden(tester, '${tag}_stats_body_top');
      await scrollThrough(tester);
      await golden(tester, '${tag}_stats_body');
    } catch (e) {
      issues.add('stats tabs: $e');
    }
    c.stop();
    issues.addAll(c.issues.map((e) => 'stats tabs: $e'));
  }

  testWidgets('主框架五页 + 统计双 Tab（中文全扫）', (tester) async {
    setSurface(tester, const Size(412, 915));
    await tester.runAsync(seed);
    final issues = <String>[];
    await pumpAllMainPages(tester, issues, 'zh');

    if (issues.isNotEmpty) {
      // 全部打出来，一次看全，不要修一个冒一个
      // ignore: avoid_print
      print('==== 中文布局问题清单 ====');
      for (final s in issues.toSet()) {
        // ignore: avoid_print
        print('• $s');
      }
      fail('${issues.toSet().length} 处中文布局异常');
    }
  });

  testWidgets('计划页：3日/周/月 三种排程模式（中文全扫）', (tester) async {
    setSurface(tester, const Size(412, 915));
    await tester.runAsync(seed);
    final c = _IssueCollector();
    final issues = <String>[];

    c.start('plan-week');
    try {
      await tester.pumpWidget(host(container, const PlanPage()));
      await settle(tester);
      await golden(tester, 'zh_plan_week');
    } catch (e) {
      issues.add('plan-week: $e');
    }
    c.stop();
    issues.addAll(c.issues.map((e) => 'plan-week: $e'));

    // 切 3 日视图
    c.start('plan-d3');
    try {
      await tester.tap(find.text('三天'));
      await settle(tester, rounds: 4);
      await golden(tester, 'zh_plan_d3');
    } catch (e) {
      issues.add('plan-d3: $e');
    }
    c.stop();
    issues.addAll(c.issues.map((e) => 'plan-d3: $e'));

    // 切月视图
    c.start('plan-month');
    try {
      await tester.tap(find.text('一月'));
      await settle(tester, rounds: 4);
      await golden(tester, 'zh_plan_month');
      await scrollThrough(tester);
    } catch (e) {
      issues.add('plan-month: $e');
    }
    c.stop();
    issues.addAll(c.issues.map((e) => 'plan-month: $e'));

    if (issues.isNotEmpty) {
      // ignore: avoid_print
      print('==== 中文布局问题清单（计划页三模式）====');
      for (final s in issues.toSet()) {
        // ignore: avoid_print
        print('• $s');
      }
      fail('${issues.toSet().length} 处中文布局异常');
    }
  });

  testWidgets('窄屏 360：五主页复扫（中文，暴露窄屏溢出）', (tester) async {
    setSurface(tester, const Size(360, 800));
    await tester.runAsync(seed);
    final issues = <String>[];
    await pumpAllMainPages(tester, issues, 'zh_n');

    if (issues.isNotEmpty) {
      // ignore: avoid_print
      print('==== 中文布局问题清单（窄屏 360）====');
      for (final s in issues.toSet()) {
        // ignore: avoid_print
        print('• $s');
      }
      fail('${issues.toSet().length} 处中文布局异常（窄屏 360）');
    }
  });

  testWidgets('计划页极端条件：320 宽 + 1.3 倍字号（中文，暴露小屏/大字溢出）',
      (tester) async {
    setSurface(tester, const Size(320, 720));
    await tester.runAsync(seed);
    final c = _IssueCollector();
    final issues = <String>[];

    for (final (tag, scale) in [('s10', 1.0), ('s13', 1.3)]) {
      c.start('plan-320-$tag');
      try {
        await tester.pumpWidget(
            host(container, const PlanPage(), textScale: scale));
        await settle(tester);
        await golden(tester, 'zh_plan_320_$tag');
      } catch (e) {
        issues.add('plan-320-$tag: $e');
      }
      c.stop();
      issues.addAll(c.issues.map((e) => 'plan-320-$tag: $e'));
    }

    if (issues.isNotEmpty) {
      // ignore: avoid_print
      print('==== 中文布局问题清单（计划页 320/大字）====');
      for (final s in issues.toSet()) {
        // ignore: avoid_print
        print('• $s');
      }
      fail('${issues.toSet().length} 处中文布局异常（320/大字）');
    }
  });

  testWidgets('训练页：起始页/记录页/休息页（中文全扫）', (tester) async {
    setSurface(tester, const Size(412, 915));
    await tester.runAsync(() async {
      final plan = await container.db.insertPlan(Plan(
          name: '薄肌五分化',
          source: 'manual',
          createdAt: '2026-09-20',
          isActive: 1));
      final dayId = await container.db.insertPlanDay(
          PlanDay(planId: plan.id!, weekday: 3, title: '推日'));
      final exs = [('卧推', 0), ('划船', 1)];
      final pes = <PlanExercise>[];
      for (final (name, i) in exs) {
        final pe = PlanExercise(
          dayId: dayId,
          name: name,
          orderIdx: i,
          sets: 3,
          repsMin: 5,
          repsMax: 8,
          restSec: 120,
          kind: 'compound',
          rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
        );
        pes.add(pe.copyWith(
            id: await container.db.insertPlanExercise(pe)));
      }
      await container.session.startFromDay(
          day: PlanDay(id: dayId, planId: plan.id!, weekday: 3, title: '推日'),
          planExercises: pes);
    });
    final c = _IssueCollector();
    final issues = <String>[];

    // 起始页
    c.start('workout-start');
    try {
      await tester.pumpWidget(host(container, const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));
      await golden(tester, 'zh_workout_start');
      // 进第一记录页（settle 等跨 isolate 的状态事件 + 转场动画走完再截图）
      await tester.tap(find.text('开始训练'));
      await settle(tester, rounds: 4);
      await golden(tester, 'zh_workout_lift');
    } catch (e) {
      issues.add('workout start/lift: $e');
    }
    c.stop();
    issues.addAll(c.issues.map((e) => 'workout: $e'));

    // 完成一组 → 休息页
    await tester.runAsync(() async {
      await container.session
          .completeSet(weight: 60, reps: 8, rir: 2, kind: SetKind.working);
    });
    c.start('workout-rest');
    try {
      await settle(tester, rounds: 4);
      await golden(tester, 'zh_workout_rest');
    } catch (e) {
      issues.add('workout rest: $e');
    }
    c.stop();
    issues.addAll(c.issues.map((e) => 'workout-rest: $e'));

    if (issues.isNotEmpty) {
      // ignore: avoid_print
      print('==== 中文布局问题清单（训练页）====');
      for (final s in issues.toSet()) {
        // ignore: avoid_print
        print('• $s');
      }
      fail('${issues.toSet().length} 处中文布局异常');
    }
  });

  testWidgets('心率设备页（中文）', (tester) async {
    setSurface(tester, const Size(412, 915));
    await tester.runAsync(seed);
    final c = _IssueCollector();
    final issues = <String>[];
    c.start('heart-rate');
    try {
      await tester.pumpWidget(host(container, const HeartRatePage()));
      await settle(tester);
      await golden(tester, 'zh_heart_rate');
    } catch (e) {
      issues.add('heart-rate: $e');
    }
    c.stop();
    issues.addAll(c.issues.map((e) => 'heart-rate: $e'));

    if (issues.isNotEmpty) {
      // ignore: avoid_print
      print('==== 中文布局问题清单（心率设备页）====');
      for (final s in issues.toSet()) {
        // ignore: avoid_print
        print('• $s');
      }
      fail('${issues.toSet().length} 处中文布局异常（心率设备页）');
    }
  });

  testWidgets('动作库 + AI 教练页（中文全扫）', (tester) async {
    setSurface(tester, const Size(412, 915));
    final c = _IssueCollector();
    final issues = <String>[];
    c.start('library');
    try {
      await tester.pumpWidget(host(container, const ExerciseLibraryPage()));
      await settle(tester);
      await golden(tester, 'zh_library');
      await scrollThrough(tester, screens: 2);
    } catch (e) {
      issues.add('library: $e');
    }
    c.stop();
    c.start('ai-coach');
    try {
      await tester.pumpWidget(host(container, const AiCoachPage()));
      await settle(tester);
      await golden(tester, 'zh_ai_coach');
    } catch (e) {
      issues.add('ai: $e');
    }
    c.stop();
    issues.addAll(c.issues.map((e) => e));

    if (issues.isNotEmpty) {
      // ignore: avoid_print
      print('==== 中文布局问题清单（动作库/AI）====');
      for (final s in issues.toSet()) {
        // ignore: avoid_print
        print('• $s');
      }
      fail('${issues.toSet().length} 处中文布局异常');
    }
  });
}
