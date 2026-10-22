// P2-C 器械设置记忆：exercise_notes 表 DAO（按动作稳定键读写 setup_note）
// 与展示条件（空备注不占空间；训练起始页/第一组前显示，记过组后收起）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/ui/exercise_detail_sheet.dart';
import 'package:baoji_timer/ui/exercise_library_page.dart';
import 'package:baoji_timer/ui/theme.dart';
import 'package:baoji_timer/ui/workout_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    // 训练页会碰到的平台通道：测试环境没有宿主插件，挂空实现。
    final binding = TestWidgetsFlutterBinding.instance;
    final pigeonNullReply = ByteData(3)
      ..setUint8(0, 12)
      ..setUint8(1, 1)
      ..setUint8(2, 0);
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (data) async => pigeonNullReply,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('baoji/focus'),
      (call) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter_local_notifications'),
      (call) async => null,
    );
  });

  group('exercise_notes DAO', () {
    late Database raw;
    late Db db;

    setUp(() async {
      raw = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await Db.instance.createSchema(raw);
      db = Db.forTesting(raw);
    });

    tearDown(() async {
      await raw.close();
    });

    test('空库/空键读不到备注', () async {
      expect(await db.exerciseNote('杠铃卧推'), isNull);
      expect(await db.exerciseNote('   '), isNull);
      expect(await db.exerciseNote(''), isNull);
    });

    test('保存后可读回：键与文本去首尾空白，updated_at 落库', () async {
      await db.saveExerciseNote(' 杠铃卧推 ', '  座椅 4 档，靠背 2 档 ');
      final note = await db.exerciseNote('杠铃卧推');
      expect(note, isNotNull);
      expect(note!.exerciseKey, '杠铃卧推');
      expect(note.setupNote, '座椅 4 档，靠背 2 档');
      expect(note.updatedAt, greaterThan(0));
    });

    test('重复保存覆盖旧值，一门仍只有一条', () async {
      await db.saveExerciseNote('杠铃卧推', '座椅 4 档');
      await db.saveExerciseNote('杠铃卧推', '座椅 5 档');
      expect((await db.exerciseNote('杠铃卧推'))!.setupNote, '座椅 5 档');
      expect(await raw.query('exercise_notes'), hasLength(1));
    });

    test('空串/纯空白删除整行，不留空壳', () async {
      await db.saveExerciseNote('杠铃卧推', '座椅 4 档');
      await db.saveExerciseNote('杠铃卧推', '   ');
      expect(await db.exerciseNote('杠铃卧推'), isNull);
      expect(await raw.query('exercise_notes'), isEmpty);
    });

    test('空键不写库', () async {
      await db.saveExerciseNote('', 'x');
      await db.saveExerciseNote('   ', 'y');
      expect(await raw.query('exercise_notes'), isEmpty);
    });

    test('批量读取：去重、忽略空键、只返回非空备注', () async {
      await db.saveExerciseNote('杠铃卧推', '座椅 4 档');
      await db.saveExerciseNote('杠铃划船', '靠背 2 档');
      final notes = await db.exerciseNotesByKeys(
        ['杠铃卧推', '杠铃卧推', ' 杠铃划船 ', '不存在', '', '   '],
      );
      expect(notes, {
        '杠铃卧推': '座椅 4 档',
        '杠铃划船': '靠背 2 档',
      });
      expect(await db.exerciseNotesByKeys(const []), isEmpty);
    });

    test('knownExerciseKey：改名行保留旧键时仍解析到已落库键', () async {
      final plan = await db.insertPlan(Plan(
        name: '测试计划',
        source: 'manual',
        createdAt: '2026-10-18',
        isActive: 1,
      ));
      final dayId = await db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 1, title: '推日'),
      );
      await db.insertPlanExercise(PlanExercise(
        dayId: dayId,
        name: '卧推王',
        orderIdx: 0,
        sets: 3,
        repsMin: 5,
        repsMax: 8,
        restSec: 120,
        kind: 'compound',
        rule: ProgressionRule.fallback,
        exerciseKey: exerciseKeyOf('杠铃卧推'),
      ));
      expect(await db.knownExerciseKey('卧推王'), exerciseKeyOf('杠铃卧推'),
          reason: '动作库详情应沿用计划/会话行里的稳定键，而不是按新名字现算');
    });
  });

  group('SetupNoteView 展示条件', () {
    setUp(() => Lang.setResolved(false));
    tearDown(() => Lang.setResolved(false));

    Future<void> pumpNote(WidgetTester tester, String note) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(body: SetupNoteView(note: note)),
      ));
    }

    testWidgets('空备注不占空间：不渲染文本且尺寸为零', (tester) async {
      await pumpNote(tester, '');
      expect(find.byKey(const Key('setupNoteText')), findsNothing);
      expect(tester.getSize(find.byType(SetupNoteView)), Size.zero);
    });

    testWidgets('纯空白同样不占空间', (tester) async {
      await pumpNote(tester, '   \n  ');
      expect(find.byKey(const Key('setupNoteText')), findsNothing);
      expect(tester.getSize(find.byType(SetupNoteView)), Size.zero);
    });

    testWidgets('非空备注显示前缀与原文', (tester) async {
      await pumpNote(tester, '座椅 4 档，靠背 2 档');
      expect(find.text('器械设置：座椅 4 档，靠背 2 档'), findsOneWidget);
    });

    testWidgets('英文界面用 Setup 前缀', (tester) async {
      Lang.setResolved(true);
      await pumpNote(tester, 'seat notch 4');
      expect(find.text('Setup: seat notch 4'), findsOneWidget);
    });
  });

  group('训练页展示条件（起始页 + 第一组前）', () {
    late Database raw;
    late AppContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      raw = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await Db.instance.createSchema(raw);
      container = AppContainer(prefs: prefs, db: Db.forTesting(raw));
    });

    tearDown(() async {
      container.session.skipRest();
      container.dispose();
      await raw.close();
    });

    Future<PlanDay> makeDay() async {
      final plan = await container.db.insertPlan(Plan(
        name: '测试计划',
        source: 'manual',
        createdAt: '2026-10-18',
        isActive: 1,
      ));
      final dayId = await container.db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 3, title: '推日'),
      );
      return PlanDay(id: dayId, planId: plan.id!, weekday: 3, title: '推日');
    }

    Future<PlanExercise> addEx(PlanDay day, String name, int order) async {
      final pe = PlanExercise(
        dayId: day.id!,
        name: name,
        orderIdx: order,
        sets: 3,
        repsMin: 5,
        repsMax: 8,
        restSec: 120,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      );
      final id = await container.db.insertPlanExercise(pe);
      return pe.copyWith(id: id);
    }

    Widget host(Widget home) =>
        AppScope(container: container, child: MaterialApp(home: home));

    testWidgets('起始页显示已保存备注且空备注不占位；第一组后收起', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(() async {
        final day = await makeDay();
        final bench = await addEx(day, '杠铃卧推', 0);
        final row = await addEx(day, '杠铃划船', 1);
        // 开练前已存在：startFromDay 应一次预载全部动作的备注。
        await container.db.saveExerciseNote(
          exerciseKeyOf('杠铃卧推'),
          '座椅 4 档，靠背 2 档',
        );
        await container.session.startFromDay(
          day: day,
          planExercises: [bench, row],
        );
      });

      await tester.pumpWidget(host(const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.textContaining('器械设置：座椅 4 档'), findsOneWidget,
          reason: '起始页应显示已保存的器械设置');
      expect(find.byKey(const Key('setupNoteText')), findsOneWidget,
          reason: '另一个动作没有备注，不应渲染占位行');

      // 保存后同屏即时刷新（详情弹层保存走的是同一个入口）。
      await tester.runAsync(() => container.session.saveSetupNote(
            exerciseKeyOf('杠铃划船'),
            '靠背 3 档',
          ));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.textContaining('器械设置：靠背 3 档'), findsOneWidget);

      await tester.tap(find.text('开始训练'));
      // AnimatedSwitcher 280ms：先起一帧，再走完过渡，避免 outgoing
      // 起始页与记录页同时在树上（备注会出现两份）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.textContaining('器械设置：座椅 4 档'), findsOneWidget,
          reason: '该动作第一组前仍应显示设置备注');

      // 记一组（热身组留在动作态、不触发休息页），备注随之收起。
      await tester.runAsync(() async {
        await container.session.completeSet(
          weight: 20,
          reps: 10,
          rir: 2,
          kind: SetKind.warmup,
        );
      });
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.textContaining('器械设置：'), findsNothing,
          reason: '第一组开始后不再占动作区空间');
    });

    test('训练中追加/替换动作后补载该动作的器械设置', () async {
      final day = await makeDay();
      final bench = await addEx(day, '杠铃卧推', 0);
      await container.session.startFromDay(
        day: day,
        planExercises: [bench],
      );

      // 追加动作：新行写入后应立刻能读到该动作已存的备注。
      await container.db.saveExerciseNote(
        exerciseKeyOf('杠铃划船'),
        '靠背 3 档',
      );
      await container.session.appendExercises([
        const ExerciseMeta('杠铃划船', MuscleGroups(main: '背'), true),
      ]);
      expect(
        container.session.setupNoteOf(container.session.exercises.last),
        '靠背 3 档',
        reason: '追加到队尾的动作也要在其第一组前显示器械设置',
      );

      // 替换当前动作：换成已有备注的动作后同样要补载。
      await container.db.saveExerciseNote(
        exerciseKeyOf('高位下拉'),
        '座椅 2 档',
      );
      final replaced = await container.session.replaceCurrentExercise(
        const ExerciseMeta('高位下拉', MuscleGroups(main: '背'), true),
      );
      expect(replaced, isTrue);
      expect(
        container.session.setupNoteOf(container.session.currentEx!),
        '座椅 2 档',
        reason: '替换后的动作也要在其第一组前显示器械设置',
      );
    });

    testWidgets('编辑段：添加→输入→保存写库，清空保存删除整行', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 模拟动作库详情：显示名是改名后的「卧推王」，稳定键仍是杠铃卧推。
      final key = exerciseKeyOf('杠铃卧推');
      await tester.runAsync(() async {
        await tester.pumpWidget(AppScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SetupNoteEditor(name: '卧推王', exerciseKey: key),
              ),
            ),
          ),
        ));
        // 编辑器在 didChangeDependencies 里读库：让真实异步跑完。
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      expect(find.byKey(const Key('setupNoteEditButton')), findsOneWidget);
      expect(find.text('添加'), findsOneWidget);

      await tester.tap(find.byKey(const Key('setupNoteEditButton')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('setupNoteField')),
        '座椅 4 档',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('setupNoteSaveButton')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      expect(find.text('座椅 4 档'), findsOneWidget);
      final saved = await tester.runAsync(() => container.db.exerciseNote(key));
      expect(saved?.setupNote, '座椅 4 档',
          reason: '按传入的稳定键写库，动作库改名后仍与训练页共用一条备注');

      // 再次编辑清空 → 保存删除整行，展示回到「添加」空态。
      await tester.tap(find.byKey(const Key('setupNoteEditButton')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('setupNoteField')), '   ');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('setupNoteSaveButton')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      final cleared =
          await tester.runAsync(() => container.db.exerciseNote(key));
      expect(cleared, isNull, reason: '空备注保存应删除整行，不留空壳');
    });
  });

  group('动作库详情历史匹配（与 SetupNoteEditor 同一稳定键）', () {
    late Database raw;
    late AppContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      raw = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await Db.instance.createSchema(raw);
      container = AppContainer(prefs: prefs, db: Db.forTesting(raw));
    });

    tearDown(() async {
      container.dispose();
      await raw.close();
    });

    /// 「只有 20 分钟」前先练过、后改名的自定义动作：
    /// 显示名「卧推王」，历史/计划行的稳定键仍是杠铃卧推的旧键。
    /// 详情页历史匹配若按新名字现算身份键，会误判成「有备注但没练过」。
    testWidgets('改名保留旧键的动作：详情显示历史成绩而非「还没练过」',
        (tester) async {
      tester.view.physicalSize = const Size(360, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(() async {
        final key = exerciseKeyOf('杠铃卧推');
        final plan = await container.db.insertPlan(Plan(
          name: '测试计划',
          source: 'manual',
          createdAt: '2026-10-18',
          isActive: 1,
        ));
        final dayId = await container.db.insertPlanDay(
          PlanDay(planId: plan.id!, weekday: 1, title: '推日'),
        );
        await container.db.insertPlanExercise(PlanExercise(
          dayId: dayId,
          name: '卧推王',
          orderIdx: 0,
          sets: 3,
          repsMin: 5,
          repsMax: 8,
          restSec: 120,
          kind: 'compound',
          rule: ProgressionRule.fallback,
          exerciseKey: key, // 改名后保留旧键
        ));
        // 自定义动作沉淀进动作库（词表外 → 列表尾出现）
        await container.db.upsertExerciseMeta(
          const ExerciseMeta('卧推王', MuscleGroups(main: '胸'), true),
        );
        // 一场 done 会话：行名是改名后的「卧推王」，键是旧键
        final now = DateTime.now();
        final ses = await container.db.insertSession(Session(
          date: fmtDate(now),
          planDayTitle: '推日',
          startedAt: now.millisecondsSinceEpoch - 3600000,
          endedAt: now.millisecondsSinceEpoch,
          status: 'done',
        ));
        final seId = await container.db.insertSessionExercise(SessionExercise(
          sessionId: ses.id!,
          name: '卧推王',
          orderIdx: 0,
          kind: 'compound',
          rule: ProgressionRule.fallback,
          exerciseKey: key,
        ));
        await container.db.insertSet(SetEntry(
          sessionExerciseId: seId,
          weightKg: 60,
          reps: 8,
          rir: 2,
          kind: SetKind.working,
          doneAt: now.millisecondsSinceEpoch,
        ));
      });

      await tester.pumpWidget(AppScope(
        container: container,
        child: const MaterialApp(home: ExerciseLibraryPage()),
      ));
      // _load 是真实异步（读 exercise_meta），真实延时 ↔ pump 推进
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 词表外自定义动作在列表尾：滚到可见再点开详情。
      // 页面还有两个横向筛选条也是 Scrollable，不能拿 byType(Scrollable)
      // 做 scrollUntilVisible 的锚——直接拖 ListView 本体。
      for (var i = 0; i < 30; i++) {
        if (find.text('卧推王').evaluate().isNotEmpty) break;
        await tester.drag(find.byType(ListView).first, const Offset(0, -600));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('卧推王'));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.textContaining('还没练过这个动作'), findsNothing,
          reason: '历史行按稳定键能匹配上，改名不丢历史');
      expect(find.textContaining('估算 1RM'), findsOneWidget,
          reason: '详情出现历史最佳卡');
    });
  });
}
