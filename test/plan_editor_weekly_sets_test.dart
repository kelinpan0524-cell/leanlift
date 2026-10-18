// P1-B 每周肌群组数目标：计划编辑页命中预览的剂量推演回归测试。
// 验证「按计划推算的每周组数」真的渲染出来（主肌群 1 组 / 次肌群 0.5 组），
// 并与目标区间对比给出不足/达标/过量状态。
// 覆盖：按星期多训练日累加、循环「练2休1 + 6 个训练日」折算、
// 空计划、以及词表外动作的「其他」行。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/presets/exercise_library.dart';
import 'package:baoji_timer/ui/plan_editor_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
    // 计划编辑页从 DB 读动作 meta；补齐内置词表让「杠铃卧推」能归类到胸。
    for (final m in kExerciseLibrary) {
      await container.db.upsertExerciseMeta(m);
    }
  });

  tearDown(() async {
    await container.db.wipeAll();
    container.dispose();
  });

  /// 建一份计划并返回第 1 个训练日（编辑器入口）。
  /// [days] = 每个模板日的 (动作名, 组数)；动作名空串 = 空模板日。
  Future<PlanDay> seedPlan({
    bool isCycle = false,
    int cycleTrain = 0,
    int cycleRest = 0,
    List<(String, int)> days = const [('杠铃卧推', 4)],
  }) async {
    final plan = await container.db.insertPlan(Plan(
      name: '剂量计划',
      source: 'manual',
      createdAt: fmtDate(DateTime.now()),
      isActive: 1,
      pattern: isCycle ? 'cycle' : 'weekly',
      patternStart: isCycle ? fmtDate(DateTime.now()) : '',
      cycleTrain: cycleTrain,
      cycleRest: cycleRest,
    ));
    for (var i = 0; i < days.length; i++) {
      final (name, sets) = days[i];
      final dayId = await container.db.insertPlanDay(
          PlanDay(planId: plan.id!, weekday: i + 1, title: '第${i + 1}练'));
      if (name.isEmpty) continue;
      await container.db.insertPlanExercise(PlanExercise(
        dayId: dayId,
        name: name,
        orderIdx: 0,
        sets: sets,
        repsMin: 5,
        repsMax: 8,
        restSec: 120,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8),
      ));
    }
    await container.planRepo.reload();
    final all = await container.db.planDays(plan.id!);
    return all.firstWhere((d) => d.weekday == 1);
  }

  /// 等页面异步加载（DB 读取）完成，与 stats_overview_test 同节奏。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 打开编辑器并展开「肌群命中预览」（缺省收起）。
  Future<void> pumpEditor(WidgetTester tester, PlanDay day,
      {bool isCycle = false}) async {
    await tester.pumpWidget(AppScope(
        container: container,
        child: MaterialApp(
            home: PlanEditorPage(day: day, isCycle: isCycle))));
    await settle(tester);

    for (var i = 0; i < 10; i++) {
      if (find.text('肌群命中预览').evaluate().isNotEmpty) break;
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('肌群命中预览'), findsOneWidget);
    await tester.tap(find.text('肌群命中预览'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Finder doseRow(String region) =>
      find.byKey(ValueKey('plan-weekly-dose-$region'));

  testWidgets('按星期计划：多训练日累加后再与目标对比', (tester) async {
    // 两个训练日各 4 组卧推 → 每周 8 组（不足）；肩/手臂各 4 组
    final day = (await tester.runAsync(() =>
        seedPlan(days: const [('杠铃卧推', 4), ('杠铃卧推', 4)])))!;
    await pumpEditor(tester, day);

    expect(
        find.descendant(
            of: doseRow('胸'), matching: find.text('每周约 8 组 / 目标 10-20')),
        findsOneWidget);
    expect(find.descendant(of: doseRow('胸'), matching: find.text('不足')),
        findsOneWidget);
    expect(
        find.descendant(
            of: doseRow('肩'), matching: find.text('每周约 4 组 / 目标 8-16')),
        findsOneWidget);
  });

  testWidgets('循环计划：练2休1 + 6 个训练日按真实轮转折算（不是 ×7/3）',
      (tester) async {
    // 6 个模板日各 3 组卧推；一个 3 天周期只练 2 次，模板日轮转 →
    // 每周 18 × 7×2/(3×6) = 14 组（达标）。旧口径 ×7/3 会得到 42（过量）。
    final day = (await tester.runAsync(() => seedPlan(
          isCycle: true,
          cycleTrain: 2,
          cycleRest: 1,
          days: [for (var i = 0; i < 6; i++) ('杠铃卧推', 3)],
        )))!;
    await pumpEditor(tester, day, isCycle: true);

    expect(
        find.descendant(
            of: doseRow('胸'), matching: find.text('每周约 14 组 / 目标 10-20')),
        findsOneWidget);
    expect(find.descendant(of: doseRow('胸'), matching: find.text('达标')),
        findsOneWidget);
    // 次肌群 0.5：14 × 0.5 = 7 组，仍未到肩的 8 组下限
    expect(
        find.descendant(
            of: doseRow('肩'), matching: find.text('每周约 7 组 / 目标 8-16')),
        findsOneWidget);
    expect(find.descendant(of: doseRow('肩'), matching: find.text('不足')),
        findsOneWidget);
  });

  testWidgets('空计划：六区 0 组全部不足，不出现「其他」行', (tester) async {
    final day =
        (await tester.runAsync(() => seedPlan(days: const [('', 0)])))!;
    await pumpEditor(tester, day);

    expect(find.text('每周约 0 组 / 目标 10-20'), findsNWidgets(3),
        reason: '胸/背/腿');
    expect(find.text('每周约 0 组 / 目标 8-16'), findsNWidgets(2),
        reason: '肩/手臂');
    expect(find.text('每周约 0 组 / 目标 6-12'), findsOneWidget, reason: '核心');
    expect(find.text('不足'), findsNWidgets(6));
    expect(doseRow('其他'), findsNothing,
        reason: '没有词表外动作时不显示「其他」行');
  });

  testWidgets('词表外动作：在「其他」行显示推算组数，六区仍为 0', (tester) async {
    final day = (await tester
        .runAsync(() => seedPlan(days: const [('神秘自创动作', 3)])))!;
    await pumpEditor(tester, day);

    expect(
        find.descendant(
            of: doseRow('其他'),
            matching: find.text('每周约 3 组（未归类动作，无目标）')),
        findsOneWidget);
    expect(find.text('每周约 0 组 / 目标 10-20'), findsNWidgets(3),
        reason: '未归类动作不污染六个真实肌群');
  });
}
