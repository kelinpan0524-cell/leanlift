import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/engine/today_plan_edit.dart';
import 'package:baoji_timer/engine/weight_unit.dart';
import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/models/app_release.dart';
import 'package:baoji_timer/presets/baoji_plan.dart';
import 'package:baoji_timer/presets/exercise_library.dart' show defaultLoggingFor;
import 'package:baoji_timer/services/lark_service.dart';
import 'package:baoji_timer/services/plan_repository.dart';
import 'package:baoji_timer/services/session_controller.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:baoji_timer/services/update_service.dart';
import 'package:baoji_timer/ui/history_page.dart';
import 'package:baoji_timer/ui/workout_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    final binding = TestWidgetsFlutterBinding.instance;
    final pigeonNullReply = ByteData(3)
      ..setUint8(0, 12)
      ..setUint8(1, 1)
      ..setUint8(2, 0);
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => pigeonNullReply,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('baoji/focus'),
      (_) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter_local_notifications'),
      (_) async => null,
    );
  });

  tearDownAll(() async {
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/baoji_timer.db');
  });

  setUp(() {
    Lang.setResolved(false);
    WeightUnits.setResolved(WeightUnit.kg);
  });

  Future<void> yieldRealLoop() {
    final completer = Completer<void>();
    Timer(const Duration(milliseconds: 20), completer.complete);
    return completer.future;
  }

  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder, {
    String? reason,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (finder.evaluate().isEmpty) {
      if (!DateTime.now().isBefore(deadline)) {
        fail(reason ?? 'Timed out waiting for widget: $finder');
      }
      await tester.runAsync(yieldRealLoop);
      await tester.pump();
    }
  }

  Future<void> pumpUntilGone(
    WidgetTester tester,
    Finder finder, {
    String? reason,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (finder.evaluate().isNotEmpty) {
      if (!DateTime.now().isBefore(deadline)) {
        fail(reason ?? 'Timed out waiting for widget to disappear: $finder');
      }
      await tester.runAsync(yieldRealLoop);
      await tester.pump();
    }
  }

  group('DB 空组跳过保护', () {
    test('后续 done 会话中某动作 0 组或仅热身时，回溯仍命中前一场正式组', () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await databaseFactory.getDatabasesPath();
      final raw = await databaseFactory.openDatabase(
          '$dir/test_db_skip_${DateTime.now().microsecondsSinceEpoch}.db');
      await Db.instance.createSchema(raw);
      final db = Db.forTesting(raw);
      addTearDown(() async => await db.wipeAll());

      final oldStart = DateTime(2026, 10, 1, 18, 0).millisecondsSinceEpoch;
      final newStart = DateTime(2026, 10, 8, 18, 0).millisecondsSinceEpoch;

      final (s1, exs1) = await db.insertSessionWithExercises(
        Session(
          date: '2026-10-01',
          planDayTitle: '推日',
          startedAt: oldStart,
          endedAt: oldStart + 3600000,
          status: 'done',
        ),
        [
          const SessionExercise(
            sessionId: 0,
            name: '杠铃卧推',
            orderIdx: 0,
            kind: 'compound',
            rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
            targetSets: 3,
            logging: LoggingMode.reps,
            loadType: LoadMode.weighted,
          ),
        ],
      );
      await db.insertSet(SetEntry(
        sessionExerciseId: exs1.first.id!,
        weightKg: 60,
        reps: 8,
        rir: 2,
        kind: SetKind.working,
        doneAt: oldStart + 60000,
      ));

      final (_, exs2) = await db.insertSessionWithExercises(
        Session(
          date: '2026-10-08',
          planDayTitle: '推日',
          startedAt: newStart,
          endedAt: newStart + 3600000,
          status: 'done',
        ),
        [
          const SessionExercise(
            sessionId: 0,
            name: '杠铃卧推',
            orderIdx: 0,
            kind: 'compound',
            rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 4),
            targetSets: 4,
            logging: LoggingMode.time,
            loadType: LoadMode.bodyweight,
          ),
        ],
      );
      // 第二场仅做了热身组，没有正式组
      await db.insertSet(SetEntry(
        sessionExerciseId: exs2.first.id!,
        weightKg: 20,
        reps: 10,
        rir: 4,
        kind: SetKind.warmup,
        doneAt: newStart + 60000,
      ));

      final lastSets = await db.lastWorkingSets('杠铃卧推');
      expect(lastSets, hasLength(1));
      expect(lastSets.first.weightKg, 60);
      expect(lastSets.first.sessionExerciseId, exs1.first.id);

      final modes = await db.lastExerciseModes('杠铃卧推');
      expect(modes, (LoggingMode.reps, LoadMode.weighted));

      final targetSets = await db.lastTargetSets('杠铃卧推');
      expect(targetSets, 3);
      expect(s1.id, isNotNull);
    });
  });

  group('SessionController 计时、挂机截断与撤回消休', () {
    Future<(Db, SharedPreferences, SessionController)> makeEnv(
        String suffix) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final dir = await databaseFactory.getDatabasesPath();
      final raw = await databaseFactory.openDatabase(
          '$dir/test_sc_${suffix}_${DateTime.now().microsecondsSinceEpoch}.db');
      await Db.instance.createSchema(raw);
      final db = Db.forTesting(raw);
      final ctrl = SessionController(db, Settings(prefs), prefs, null);
      addTearDown(() async {
        ctrl.skipRest();
        ctrl.dispose();
        await db.wipeAll();
      });
      return (db, prefs, ctrl);
    }

    Future<(PlanDay, List<PlanExercise>)> makeDay(Db db) async {
      final plan = await db.insertPlan(const Plan(
        name: '测试计划',
        source: 'manual',
        createdAt: '2026-11-15',
        isActive: 1,
      ));
      final dayId = await db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 1, title: '推日'),
      );
      final day = PlanDay(id: dayId, planId: plan.id!, weekday: 1, title: '推日');
      const pe = PlanExercise(
        dayId: 0,
        name: '杠铃卧推',
        orderIdx: 0,
        sets: 3,
        repsMin: 5,
        repsMax: 8,
        restSec: 90,
        kind: 'compound',
        rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      );
      final seeded = PlanExercise(
        dayId: dayId,
        name: pe.name,
        orderIdx: 0,
        sets: pe.sets,
        repsMin: pe.repsMin,
        repsMax: pe.repsMax,
        restSec: pe.restSec,
        kind: pe.kind,
        rule: pe.rule,
      );
      final peId = await db.insertPlanExercise(seeded);
      return (day, [seeded.copyWith(id: peId)]);
    }

    test('finish() 补记当前活动段到 activeMs', () async {
      final (db, _, ctrl) = await makeEnv('finish_accrue');
      final (day, exs) = await makeDay(db);
      await ctrl.startFromDay(day: day, planExercises: exs);

      final waitUntil = DateTime.now().add(const Duration(milliseconds: 35));
      while (DateTime.now().isBefore(waitUntil)) {}

      expect(ctrl.activeMs, 0);
      await ctrl.finish();
      final done = await db.sessionById(ctrl.session!.id!);
      expect(done?.status, 'done');
      expect(done?.activeMs ?? 0, greaterThanOrEqualTo(30));
    });

    test('restore() 封顶挂机时长后 truncateDurationToLastSet() 不双重扣减',
        () async {
      final (db, prefs, ctrl1) = await makeEnv('restore_trunc');
      final (day, exs) = await makeDay(db);
      await ctrl1.startFromDay(day: day, planExercises: exs);
      await ctrl1.completeSet(
          weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      final sid = ctrl1.session!.id!;
      final exId = ctrl1.exercises.first.id!;
      ctrl1.skipRest();

      // 把最后一组的 doneAt 改回 2 小时前，并伪造挂机前心跳在 last+1min
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = now - 2 * 3600000;
      final sets = await db.setsOfExercise(exId);
      final oldSet = sets.single;
      await db.updateSet(SetEntry(
        id: oldSet.id,
        sessionExerciseId: oldSet.sessionExerciseId,
        weightKg: oldSet.weightKg,
        reps: oldSet.reps,
        rir: oldSet.rir,
        kind: oldSet.kind,
        doneAt: last,
      ));
      await prefs.setInt('sess.sid', sid);
      await prefs.setInt('sess.since', last + 60000);
      await prefs.setInt('sess.phase', 0); // lifting
      await prefs.setInt('sess.activeMs', 300000); // 已练 5 分钟
      await prefs.setInt('sess.restMs', 60000);

      final ctrl2 = SessionController(db, Settings(prefs), prefs, null);
      addTearDown(ctrl2.dispose);
      await ctrl2.restore();
      expect(ctrl2.activeMs, closeTo(360000, 1500));

      ctrl2.truncateDurationToLastSet();
      expect(ctrl2.activeMs, closeTo(360000, 1500));
      expect(ctrl2.truncatedEndAtMs, last + 2 * 60000);
    });

    test('休息态 undoLastSet() 自动取消休息并清空 extraSetExerciseId', () async {
      final (db, _, ctrl) = await makeEnv('undo_rest');
      final (day, exs) = await makeDay(db);
      await ctrl.startFromDay(day: day, planExercises: exs);
      await ctrl.completeSet(
          weight: 60, reps: 8, rir: 2, kind: SetKind.working);
      expect(ctrl.phase, WorkoutPhase.resting);
      expect(ctrl.extraSetExerciseId, isNotNull);

      await ctrl.undoLastSet();
      expect(ctrl.phase, WorkoutPhase.lifting);
      expect(ctrl.extraSetExerciseId, isNull);
    });
  });

  group('计时动作默认形态与引擎边界', () {
    test('defaultLoggingFor 及计划入口传播平板支撑计时默认值', () {
      expect(defaultLoggingFor('平板支撑'), LoggingMode.time);

      const preset = PresetExercise('平板支撑', 3, 30, 45, 60, 'assistance', 0);
      expect(preset.toPlanExercise(1, 0).logging, LoggingMode.time);

      final todayDef = todayExerciseDefaults(
        dayId: 1,
        orderIdx: 0,
        isCompound: false,
        name: '平板支撑',
      );
      expect(todayDef.logging, LoggingMode.time);
      expect(todayDef.repsMin, 30);
      expect(todayDef.repsMax, 45);
      expect(todayDef.restSec, 60);

      final specExs = PlanRepository.planExercisesFromDaySpec(
        const AiDaySpec(1, '核心', [
          AiExerciseSpec(name: '平板支撑', sets: 3, repsMin: 30, repsMax: 45),
        ]),
        const {},
      );
      expect(specExs.single.logging, LoggingMode.time);

      final generated = localPlanFromDescription('每周3练 居家练核心和腿');
      for (final d in generated) {
        for (final ex in d.exercises) {
          if (defaultLoggingFor(ex.name) == LoggingMode.time) {
            expect(ex.repsMin, 30);
            expect(ex.repsMax, 45);
            expect(ex.restSec, 60);
          }
        }
      }
    });

    test('ProgressionChain repsPerSide 以 +2 递进且封顶到 repsMax', () {
      const rule = ProgressionRule(
        repsMin: 8,
        repsMax: 11,
        workingSets: 3,
        incrementKg: 2.0,
      );
      final chain =
          ProgressionChain.of(rule, logging: LoggingMode.repsPerSide);
      expect(chain.rules.first.axis, 'reps');
      expect(chain.rules.first.step, 2.0);
      expect(chain.rules.first.ceiling, 11.0);

      final v1 = evaluateChain(
        rule: rule,
        state: const ChainState(weightKg: 20, targetReps: 8),
        workingSets: [
          for (var i = 0; i < 3; i++)
            SetEntry(
              sessionExerciseId: 1,
              weightKg: 20,
              reps: 8,
              rir: 2,
              kind: SetKind.working,
              doneAt: 1000 + i,
            ),
        ],
        logging: LoggingMode.repsPerSide,
      );
      expect(v1.next.targetReps, 10);
      expect(v1.next.weightKg, 20);

      final v2 = evaluateChain(
        rule: rule,
        state: const ChainState(weightKg: 20, targetReps: 10),
        workingSets: [
          for (var i = 0; i < 3; i++)
            SetEntry(
              sessionExerciseId: 1,
              weightKg: 20,
              reps: 10,
              rir: 2,
              kind: SetKind.working,
              doneAt: 1000 + i,
            ),
        ],
        logging: LoggingMode.repsPerSide,
      );
      expect(v2.next.targetReps, 11);
      expect(v2.next.weightKg, 20);

      final v3 = evaluateChain(
        rule: rule,
        state: const ChainState(weightKg: 20, targetReps: 11),
        workingSets: [
          for (var i = 0; i < 3; i++)
            SetEntry(
              sessionExerciseId: 1,
              weightKg: 20,
              reps: 11,
              rir: 2,
              kind: SetKind.working,
              doneAt: 1000 + i,
            ),
        ],
        logging: LoggingMode.repsPerSide,
      );
      expect(v3.next.weightKg, 22);
      expect(v3.next.targetReps, 8);
    });

    test('负辅助配重 recommendWeight 与 isPrWeight 正确性', () {
      const rule = ProgressionRule(
        repsMin: 6,
        repsMax: 10,
        workingSets: 3,
        incrementKg: 2.5,
      );
      List<SetEntry> assistedSets(double w, int reps) => [
            for (var i = 0; i < 3; i++)
              SetEntry(
                sessionExerciseId: 1,
                weightKg: w,
                reps: reps,
                rir: 2,
                kind: SetKind.working,
                doneAt: 1000 + i,
              ),
          ];

      expect(
        recommendWeight(historyWorkingSets: assistedSets(-20.0, 10), rule: rule),
        -17.5,
      );
      expect(
        recommendWeight(historyWorkingSets: assistedSets(-1.0, 10), rule: rule),
        0.0,
      );

      final hist = [
        SetEntry(
          sessionExerciseId: 1,
          weightKg: -20.0,
          reps: 8,
          rir: 2,
          kind: SetKind.working,
          doneAt: 1000,
        ),
      ];
      expect(isPrWeight(-15.0, hist), isTrue);
      expect(isPrWeight(-25.0, hist), isFalse);
    });

    test('lbSnap 0.25lb 网格与 -0.0 归一', () {
      expect(lbSnap(22.24), 22.25);
      expect(lbSnap(-66.14), -66.25);
      final zero = lbSnap(-0.01);
      expect(zero, 0.0);
      expect(zero.isNegative, isFalse);
    });

    test('computeHrLoad 使用真实时间戳与 30 秒断连封顶', () {
      final resNormal = computeHrLoad(
        const [
          (ts: 1000, bpm: 175),
          (ts: 6000, bpm: 175),
          (ts: 11000, bpm: 175),
        ],
        age: 30,
        hrRest: 60,
        hrMaxOverride: 190,
      );
      final sumNormal = resNormal.zoneSec.reduce((a, b) => a + b);
      expect(sumNormal, 15);

      final resGap = computeHrLoad(
        const [
          (ts: 1000, bpm: 175),
          (ts: 6000, bpm: 175),
          (ts: 11000, bpm: 175),
          (ts: 71000, bpm: 175),
        ],
        age: 30,
        hrRest: 60,
        hrMaxOverride: 190,
      );
      final sumGap = resGap.zoneSec.reduce((a, b) => a + b);
      expect(sumGap, 12);
    });
  });

  group('多周飞书同步与更新校验', () {
    test('larkSyncForDayDate 多周键分离，removePlanDayEvent 只清未来不碰过去', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final dir = await databaseFactory.getDatabasesPath();
      final raw = await databaseFactory.openDatabase(
          '$dir/test_lark_${DateTime.now().microsecondsSinceEpoch}.db');
      await Db.instance.createSchema(raw);
      final db = Db.forTesting(raw);
      addTearDown(() async => await db.wipeAll());

      final settings = Settings(prefs)
        ..larkEnabled = true
        ..larkAppId = 'app1'
        ..larkAppSecret = 'sec1'
        ..larkRefreshToken = 'ref1'
        ..larkCalendarId = 'cal1'
        ..larkAccessToken = 'tok1'
        ..larkTokenExpiry = DateTime.now().millisecondsSinceEpoch + 3600000;

      final lark = LarkService(settings, db);
      final now = DateTime.now();
      final d1 = fmtDate(now.add(const Duration(days: 1)));
      final d2 = fmtDate(now.add(const Duration(days: 8)));
      final past = fmtDate(now.subtract(const Duration(days: 7)));

      // 先埋一条过去的同日历事件映射
      await db.upsertLarkSync(LarkSync(
        refType: 'plan_day:$past',
        refId: 42,
        larkEventId: 'evt_past',
        eventDate: past,
        syncedAt: now.millisecondsSinceEpoch - 86400000,
      ));

      var seq = 0;
      final deletedIds = <String>[];
      await http.runWithClient(() async {
        await lark.upsertDayEvent(
          date: d1,
          title: '推日',
          detail: 'w1',
          planDayId: 42,
        );
        await lark.upsertDayEvent(
          date: d2,
          title: '推日',
          detail: 'w2',
          planDayId: 42,
        );

        final m1 = await db.larkSyncForDayDate(42, d1);
        final m2 = await db.larkSyncForDayDate(42, d2);
        expect(m1, isNotNull);
        expect(m2, isNotNull);
        expect(m1!.larkEventId, isNot(m2!.larkEventId));
        expect(m1.refType, 'plan_day:$d1');
        expect(m2.refType, 'plan_day:$d2');

        await lark.removePlanDayEvent(42);
      }, () {
        return MockClient((req) async {
          if (req.method == 'POST') {
            seq++;
            return http.Response(
              jsonEncode({
                'code': 0,
                'data': {
                  'event': {'event_id': 'evt_$seq'}
                },
              }),
              200,
            );
          }
          if (req.method == 'DELETE') {
            deletedIds.add(req.url.pathSegments.last);
            return http.Response(jsonEncode({'code': 0}), 200);
          }
          return http.Response('unexpected', 500);
        });
      });

      expect(deletedIds, unorderedEquals(['evt_1', 'evt_2']));
      final remaining = await db.larkSyncsForDay(42);
      expect(remaining, hasLength(1));
      expect(remaining.single.larkEventId, 'evt_past');
    });

    test('AppRelease 解析 sha256 及 UpdateService 相对跳转 + 校验失败清理', () async {
      final payload = utf8.encode('fake-apk-binary-bytes-12345');
      final digestHex = sha256.convert(payload).toString();

      final relOk = AppRelease.fromGithub({
        'tag_name': 'b99',
        'name': 'v2.0',
        'body': 'notes',
        'assets': [
          {
            'id': 123,
            'name': 'leanlift-b99.apk',
            'browser_download_url':
                'https://github.com/kelinpan0524-cell/leanlift/releases/download/b99/leanlift-b99.apk',
            'size': payload.length,
            'digest': 'sha256:$digestHex',
          }
        ],
      });
      expect(relOk.sha256, digestHex);

      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final tmpDir = Directory.systemTemp.createTempSync('leanlift_upd_');
      addTearDown(() {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      });

      final client = MockClient.streaming((req, _) async {
        final u = req.url.toString();
        if (u.endsWith('/assets/123')) {
          return http.StreamedResponse(
            const Stream.empty(),
            302,
            headers: {
              'location': '/repos/kelinpan0524-cell/leanlift/releases/assets/456',
            },
          );
        }
        if (u.endsWith('/assets/456')) {
          expect(req.headers['accept'], 'application/octet-stream');
          return http.StreamedResponse(
            const Stream.empty(),
            302,
            headers: {
              'location': 'https://objects.githubusercontent.com/pkg/test.apk',
            },
          );
        }
        expect(u, 'https://objects.githubusercontent.com/pkg/test.apk');
        return http.StreamedResponse(
          Stream.value(payload),
          200,
          contentLength: payload.length,
        );
      });

      final svc = UpdateService(Settings(prefs), client: client);
      final outPath =
          await svc.downloadApk(relOk, tempDirPathOverride: tmpDir.path);
      expect(File(outPath).existsSync(), isTrue);

      final relBad = AppRelease(
        buildNumber: relOk.buildNumber,
        title: relOk.title,
        notes: relOk.notes,
        apkUrl: relOk.apkUrl,
        assetId: relOk.assetId,
        apkSize: relOk.apkSize,
        sha256: '0' * 64,
      );
      await expectLater(
        svc.downloadApk(relBad, tempDirPathOverride: tmpDir.path),
        throwsA(isA<UpdateException>()),
      );
      expect(File('${tmpDir.path}/baoji_update.apk').existsSync(), isFalse);
    });
  });

  group('UI 回归：紧凑备注入口与历史单组编辑删除', () {
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

    Widget host(Widget home) => AppScope(
          container: container,
          child: MaterialApp(home: home),
        );

    testWidgets('360x800 紧凑 WorkoutPage 展示 workoutNoteMarker 且按钮不越界',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(() async {
        final plan = await container.db.insertPlan(const Plan(
          name: '紧凑测试',
          source: 'manual',
          createdAt: '2026-11-15',
          isActive: 1,
        ));
        final dayId = await container.db.insertPlanDay(
          PlanDay(planId: plan.id!, weekday: 1, title: '胸'),
        );
        final day =
            PlanDay(id: dayId, planId: plan.id!, weekday: 1, title: '胸');
        final pe = PlanExercise(
          dayId: dayId,
          name: '杠铃卧推',
          orderIdx: 0,
          sets: 3,
          repsMin: 5,
          repsMax: 8,
          restSec: 90,
          kind: 'compound',
          rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
        );
        final peId = await container.db.insertPlanExercise(pe);
        await container.session
            .startFromDay(day: day, planExercises: [pe.copyWith(id: peId)]);
      });

      await tester.pumpWidget(host(const WorkoutPage()));
      await tester.pump(const Duration(milliseconds: 20));
      if (find.text('开始训练').evaluate().isNotEmpty) {
        await tester.tap(find.text('开始训练'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('workoutNoteMarker')), findsOneWidget);
      expect(find.text('+ 备注（可选）'), findsNothing);

      final btnRect = tester.getRect(find.byKey(const Key('workoutCompleteSet')));
      expect(btnRect.height, greaterThanOrEqualTo(88));
      expect(btnRect.bottom, lessThanOrEqualTo(800));
    });

    testWidgets('HistoryPage 点单组行编辑并删除', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late int seId;
      await tester.runAsync(() async {
        final now = DateTime.now().millisecondsSinceEpoch;
        final today = fmtDate(DateTime.now());
        final (_, ses) = await container.db.insertSessionWithExercises(
          Session(
            date: today,
            planDayTitle: '推日',
            startedAt: now - 1800000,
            endedAt: now,
            status: 'done',
            activeMs: 600000,
            restMs: 300000,
          ),
          const [
            SessionExercise(
              sessionId: 0,
              name: '杠铃卧推',
              orderIdx: 0,
              kind: 'compound',
              rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
            ),
          ],
        );
        seId = ses.single.id!;
        await container.db.insertSet(SetEntry(
          sessionExerciseId: seId,
          weightKg: 60,
          reps: 8,
          rir: 2,
          kind: SetKind.working,
          doneAt: now - 1200000,
        ));
        await container.db.insertSet(SetEntry(
          sessionExerciseId: seId,
          weightKg: 60,
          reps: 8,
          rir: 2,
          kind: SetKind.working,
          doneAt: now - 600000,
        ));
      });

      await tester.pumpWidget(host(const Scaffold(body: HistoryPage())));
      await pumpUntilFound(tester, find.text('60'), reason: '等待历史明细行渲染');
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('60').first);
      await tester.pumpAndSettle();
      expect(find.text('保存'), findsOneWidget);
      expect(find.text('删除本组'), findsOneWidget);

      final tableCell65 =
          find.descendant(of: find.byType(Table), matching: find.text('65'));
      await tester.enterText(find.byType(TextField).at(0), '65');
      await tester.enterText(find.byType(TextField).at(1), '10');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await pumpUntilFound(tester, tableCell65, reason: '等待单组修改持久化并刷新');
      expect(tester.takeException(), isNull);

      final afterEdit = await tester.runAsync(() => container.db.setsOfExercise(seId));
      expect(afterEdit, hasLength(2));
      expect(afterEdit!.first.weightKg, 65);
      expect(afterEdit.first.reps, 10);

      await tester.tap(tableCell65.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除本组'));
      await tester.pumpAndSettle();
      expect(find.text('删除'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await pumpUntilGone(tester, tableCell65, reason: '等待删除组后界面刷新');
      expect(tester.takeException(), isNull);

      final afterDelete =
          await tester.runAsync(() => container.db.setsOfExercise(seId));
      expect(afterDelete, hasLength(1));
    });
  });
}
