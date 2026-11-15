import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/l10n/names.dart';
import 'package:baoji_timer/presets/exercise_library.dart';
import 'package:baoji_timer/presets/exercise_media.dart';
import 'package:baoji_timer/presets/start_weights.dart';
import 'package:baoji_timer/services/session_controller.dart';
import 'package:baoji_timer/ui/plan_editor_page.dart';
import 'package:baoji_timer/ui/workout_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const newExercises = <String, double>{
    '器械辅助引体向上': -25.0,
    '器械辅助引体向上（反手）': -25.0,
    '负重引体向上（反手）': 5.0,
    '器械辅助双杠臂屈伸': -20.0,
    '器械辅助双杠臂屈伸（挺胸）': -20.0,
    '负重双杠臂屈伸（挺胸）': 5.0,
  };

  setUpAll(() {
    sqfliteFfiInit();
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

  tearDownAll(() async {
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/baoji_timer.db');
  });

  group('动作库、别名、媒体与起手重量', () {
    test('新增 6 个辅助/负重动作完整入库并支持 EN 本地化与媒体映射', () {
      Lang.setResolved(true);
      addTearDown(() => Lang.setResolved(false));

      final zhOnly = RegExp(r'[\u4e00-\u9fff]');
      for (final entry in newExercises.entries) {
        final name = entry.key;
        final meta = libraryMetaForLift(name);
        expect(meta, isNotNull, reason: '$name 应在内置动作库中');
        expect(kExerciseImageIdMap[name], isNotNull, reason: '$name 应有图片映射');
        expect(defaultLoadTypeFor(name), LoadMode.weighted,
            reason: '$name 应按 weighted 记录正/负配重');
        expect(knownStartWeightOf(name), entry.value,
            reason: '$name 起手推荐重量应为 ${entry.value}');
        expect(presetStartOf(name), entry.value,
            reason: 'presetStartOf($name) 应为 ${entry.value}');

        final enTitle = exname(name);
        final enCue = cuen(name, meta!.cue);
        expect(enTitle, isNot(name));
        expect(zhOnly.hasMatch(enTitle), isFalse, reason: 'EN 标题不应含中文: $enTitle');
        expect(zhOnly.hasMatch(enCue), isFalse, reason: 'EN 动作要领不应含中文: $enCue');
      }

      expect(knownStartWeightOf('负重引体向上(反手)'), 5.0,
          reason: '半角括号别名也应命中起手重量覆盖');
      expect(knownStartWeightOf('负重引体向上'), 5.0);
      expect(knownStartWeightOf('负重双杠臂屈伸'), 5.0);
    });

    test('别名解析与辅助家族判定正确，且不误伤辅助1/辅助甲', () {
      expect(canonicalExerciseNameOf('辅助引体'), '器械辅助引体向上');
      expect(canonicalExerciseNameOf('assisted pull-up'), '器械辅助引体向上');
      expect(canonicalExerciseNameOf('辅助反手引体'), '器械辅助引体向上（反手）');
      expect(canonicalExerciseNameOf('辅助双杠'), '器械辅助双杠臂屈伸');
      expect(canonicalExerciseNameOf('assisted dip'), '器械辅助双杠臂屈伸');
      expect(canonicalExerciseNameOf('weighted dip'), '负重双杠臂屈伸');
      expect(canonicalExerciseNameOf('负重反手引体'), '负重引体向上（反手）');

      expect(isExplicitAssistedVariantName('器械辅助引体向上'), isTrue);
      expect(isExplicitAssistedVariantName('辅助引体'), isTrue);
      expect(isExplicitAssistedVariantName('辅助双杠'), isTrue);
      expect(isExplicitAssistedVariantName('辅助1'), isFalse,
          reason: '测试常用占位辅助动作名不能误判为器械减重');
      expect(isExplicitAssistedVariantName('辅助甲'), isFalse);

      expect(supportsAssistMachine('引体向上'), isTrue);
      expect(supportsAssistMachine('双杠臂屈伸'), isTrue);
      expect(supportsAssistMachine('卧推'), isFalse);

      expect(
        assistWeightFamilyOf('引体向上'),
        const ['器械辅助引体向上', '引体向上', '负重引体向上'],
      );
      expect(
        assistWeightFamilyOf('双杠臂屈伸（挺胸）'),
        const ['器械辅助双杠臂屈伸（挺胸）', '双杠臂屈伸（挺胸）', '负重双杠臂屈伸（挺胸）'],
      );
    });
  });

  group('器械辅助渐进引擎', () {
    const rule = ProgressionRule(
      repsMin: 5,
      repsMax: 8,
      incrementKg: 2.5,
      rirTarget: 2,
      workingSets: 3,
    );

    List<SetEntry> hitSets(double weightKg, {int reps = 8, int rir = 2}) => [
          for (var i = 0; i < 3; i++)
            SetEntry(
              sessionExerciseId: 1,
              weightKg: weightKg,
              reps: reps,
              rir: rir,
              kind: SetKind.working,
              doneAt: 1000 + i,
            ),
        ];

    test('负配重达标后减少辅助（-25 -> -22.5），且不会越过 0kg', () {
      final v1 = evaluateChain(
        rule: rule,
        state: const ChainState(weightKg: -25.0, targetReps: 8),
        workingSets: hitSets(-25.0),
        targetSets: 3,
        loadType: LoadMode.weighted,
        assisted: true,
      );
      expect(v1.action, 'advance');
      expect(v1.next.weightKg, -22.5);
      expect(v1.next.targetReps, 5);
      expect(v1.reason, contains('减少辅助'));

      final vClamp = evaluateChain(
        rule: rule,
        state: const ChainState(weightKg: -1.0, targetReps: 8),
        workingSets: hitSets(-1.0),
        targetSets: 3,
        loadType: LoadMode.weighted,
        assisted: true,
      );
      expect(vClamp.action, 'advance');
      expect(vClamp.next.weightKg, 0.0, reason: '辅助减到头应在 0kg 自重封顶，不能跳正负重');
      expect(vClamp.reason, contains('进阶到自重'));
    });

    test('0kg 顶格后 chain_end 并建议毕业到纯自重主动作', () {
      final sets = hitSets(0.0);
      final vEnd = evaluateChain(
        rule: rule,
        state: const ChainState(weightKg: 0.0, targetReps: 8),
        workingSets: sets,
        targetSets: 3,
        loadType: LoadMode.weighted,
        assisted: true,
      );
      expect(vEnd.action, 'hold');
      expect(vEnd.holdKind, 'chain_end');

      expect(
        bodyweightVariationSuggestion(
          exerciseName: '器械辅助引体向上',
          rule: rule,
          loadType: LoadMode.weighted,
          workingSets: sets,
          plannedSets: 3,
        ),
        '引体向上',
      );
      expect(
        bodyweightVariationSuggestion(
          exerciseName: '器械辅助双杠臂屈伸',
          rule: rule,
          loadType: LoadMode.weighted,
          workingSets: sets,
          plannedSets: 3,
        ),
        '双杠臂屈伸',
      );
    });
  });

  group('训练页与计划编辑器交互（360×800）', () {
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
      container.session.skipRest();
      await container.db.wipeAll();
      container.dispose();
    });

    void setSurface(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    Future<void> pumpWorkout(WidgetTester tester) async {
      await tester.pumpWidget(
        AppScope(
          container: container,
          child: const MaterialApp(home: WorkoutPage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (find.text('开始训练').evaluate().isNotEmpty) {
        await tester.tap(find.text('开始训练'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('自重引体向上可一键切器械辅助/负重，360×800 满足红线且负配重可落库',
        (tester) async {
      setSurface(tester, const Size(360, 800));
      late int exId;
      await tester.runAsync(() async {
        final plan = await container.db.insertPlan(
          Plan(
            name: '辅助引体测试计划',
            source: 'manual',
            createdAt: '2026-11-15',
            isActive: 1,
          ),
        );
        final dayId = await container.db.insertPlanDay(
          PlanDay(planId: plan.id!, weekday: 1, title: '背日'),
        );
        final day = PlanDay(
          id: dayId,
          planId: plan.id!,
          weekday: 1,
          title: '背日',
        );
        final pe = PlanExercise(
          dayId: dayId,
          name: '引体向上',
          orderIdx: 0,
          sets: 3,
          repsMin: 5,
          repsMax: 8,
          restSec: 90,
          kind: 'compound',
          rule: const ProgressionRule(
            repsMin: 5,
            repsMax: 8,
            workingSets: 3,
          ),
          loadType: LoadMode.bodyweight,
        );
        final peId = await container.db.insertPlanExercise(pe);
        await container.session.startFromDay(
          day: day,
          planExercises: [pe.copyWith(id: peId)],
        );
        exId = container.session.currentEx!.id!;
      });

      await pumpWorkout(tester);

      expect(find.text('自重'), findsOneWidget);
      expect(find.byKey(const Key('workoutSwitchAssisted')), findsOneWidget);
      expect(find.byKey(const Key('workoutSwitchWeighted')), findsOneWidget);

      // 1. 切入器械辅助模式 -> 辅 25kg，底部大按钮满足 >=88dp 且不出屏
      await tester.tap(find.byKey(const Key('workoutSwitchAssisted')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => container.db.setsOfExercise(exId));
      await tester.pump(const Duration(milliseconds: 20));

      expect(container.session.weightDraft, -25.0);
      expect(container.session.currentEx?.loadType, LoadMode.weighted);
      expect(find.text('辅 25'), findsOneWidget);
      expect(find.byKey(const Key('assistedStepHint')), findsOneWidget);
      expect(tester.takeException(), isNull);

      final completeBox = tester.renderObject<RenderBox>(
        find.byKey(const Key('workoutCompleteSet')),
      );
      final completeRect =
          completeBox.localToGlobal(Offset.zero) & completeBox.size;
      expect(completeRect.height, greaterThanOrEqualTo(88));
      expect(completeRect.bottom, lessThanOrEqualTo(800));

      // 2. 负重 <-> 辅助快捷切换
      await tester.tap(find.byKey(const Key('workoutQuickWeighted')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => container.db.setsOfExercise(exId));
      expect(container.session.weightDraft, 5.0);

      await tester.tap(find.byKey(const Key('workoutQuickAssist')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => container.db.setsOfExercise(exId));
      expect(container.session.weightDraft, -25.0);

      // 3. 重量直输弹窗正负号切换：25 -> -25 并确认生效
      await tester.tap(find.byKey(const ValueKey('weightDraftNum')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '25');
      await tester.pump();
      await tester.tap(find.byKey(const Key('weightInputToggleSign')));
      await tester.pump();
      final ctrl =
          tester.widget<TextField>(find.byType(TextField).first).controller!;
      expect(ctrl.text, '-25');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(container.session.weightDraft, -25.0);

      // 4. 选 RIR 2 并点完成按钮保存负配重正式组
      await tester.tap(find.text('2').first);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('workoutCompleteSet')));
      await tester.pump(const Duration(milliseconds: 50));
      final savedSets = await tester.runAsync(() async {
        final sw = Stopwatch()..start();
        var list = await container.db.setsOfExercise(exId);
        while (list.isEmpty) {
          if (sw.elapsed > const Duration(seconds: 5)) {
            fail('等待完成组写入 SQLite 超时');
          }
          await Future<void>.microtask(() {});
          list = await container.db.setsOfExercise(exId);
        }
        return list;
      });
      expect(savedSets, hasLength(1));
      expect(savedSets!.first.weightKg, -25.0);

      await tester.pump(const Duration(milliseconds: 450));
      container.session.skipRest();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('计划动作表单：引体/双杠展示三档快捷切换且辅助档说明可见', (tester) async {
      ExerciseFormResult? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    saved = await Navigator.of(context).push<ExerciseFormResult>(
                      MaterialPageRoute(
                        builder: (_) => const Scaffold(
                          body: ExerciseEditSheet(knownMetas: kExerciseLibrary),
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '引体向上');
      await tester.pump();

      expect(find.byKey(const Key('familyTier_器械辅助引体向上')), findsOneWidget);
      expect(find.byKey(const Key('familyTier_引体向上')), findsOneWidget);
      expect(find.byKey(const Key('familyTier_负重引体向上')), findsOneWidget);

      await tester.tap(find.byKey(const Key('familyTier_器械辅助引体向上')));
      await tester.pump();

      expect(find.byKey(const Key('assistedLoadModeNote')), findsOneWidget);

      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.name, '器械辅助引体向上');
      expect(saved!.loadType, LoadMode.weighted);
    });
  });
}
