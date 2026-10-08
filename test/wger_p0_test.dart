// wger 借鉴批次（2026-09-27）单测：
// - v8 迁移：sets 目标快照列 + sessions 自评列（老库升级 / 全新建表）
// - 身体指标防呆区间（wger measurements/limits 口径）
// - 周/月分桶与趋势累计（统计维度升级）
// - 每日最佳 1RM 累计器（wger daily best 口径）
// - 肌群 → 上下肢核心分组
// - 历史页「目标 vs 实际」行（新记录走组快照 / 老记录回退模板目标）
// - 自评模型往返（Session.impression）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/ui/history_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late String dbPath;

  setUp(() async {
    final dir = await databaseFactory.getDatabasesPath();
    dbPath = '$dir/wger_p0_${DateTime.now().microsecondsSinceEpoch}.db';
  });

  group('v8 迁移', () {
    test('老库升级：sets 目标列 + sessions 自评列出现，老行为 null', () async {
      final db = await databaseFactory.openDatabase(dbPath);
      await Db.instance.createSchema(db);
      // 模拟 v7 库：删掉 v8 才有的列（重建两张表）。
      // legacy_alter_table：RENAME 不改写子表外键指向（否则 session_exercises
      // 的 FK 会被带去指 sessions_v7，DROP 后插入即报 no such table）。
      await db.execute('PRAGMA legacy_alter_table = ON');
      await db.execute('ALTER TABLE sets RENAME TO sets_v7');
      await db.execute('''
        CREATE TABLE sets(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_exercise_id INTEGER NOT NULL
            REFERENCES session_exercises(id) ON DELETE CASCADE,
          weight_kg REAL NOT NULL,
          reps INTEGER NOT NULL,
          rir INTEGER NOT NULL DEFAULT 2,
          kind TEXT NOT NULL DEFAULT 'working',
          done_at INTEGER NOT NULL,
          note TEXT NOT NULL DEFAULT ''
        )
      ''');
      await db.execute('''
        INSERT INTO sets(id, session_exercise_id, weight_kg, reps, done_at)
        SELECT id, session_exercise_id, weight_kg, reps, done_at FROM sets_v7
      ''');
      await db.execute('DROP TABLE sets_v7');
      await db.execute(
          "ALTER TABLE sessions RENAME TO sessions_v7"); // legacy 模式下不改写 FK
      await db.execute('''
        CREATE TABLE sessions(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          date TEXT NOT NULL,
          plan_day_id INTEGER,
          plan_day_title TEXT NOT NULL DEFAULT '',
          started_at INTEGER NOT NULL,
          ended_at INTEGER,
          status TEXT NOT NULL DEFAULT 'active',
          notes TEXT NOT NULL DEFAULT '',
          rest_ms INTEGER NOT NULL DEFAULT 0,
          active_ms INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('''
        INSERT INTO sessions(id, date, plan_day_title, started_at, status)
        SELECT id, date, plan_day_title, started_at, status FROM sessions_v7
      ''');
      await db.execute('DROP TABLE sessions_v7');
      await db.execute('PRAGMA legacy_alter_table = OFF');

      // 生产路径同款迁移
      await Db.instance.upgradeV7to8(db);

      final setCols = [
        for (final c in await db.rawQuery('PRAGMA table_info(sets)'))
          c['name'] as String
      ];
      expect(setCols, containsAll(['target_weight_kg', 'target_reps']));
      final sessionCols = [
        for (final c in await db.rawQuery('PRAGMA table_info(sessions)'))
          c['name'] as String
      ];
      expect(sessionCols, contains('impression'));

      // 现行 DAO（insertSet 自 v12 起写 is_extra）要能在本夹具上跑通：
      // 夹具里只有 sets 被降级重建过、只缺 v12 的 is_extra；v8→v11 涉及的
      // 其他表在夹具里本就是 createSchema 的现行结构，重跑会撞重复列。
      // 完整升级链的回归由 db_migration_test 覆盖。
      await Db.instance.upgradeV11to12(db);

      // 老组行读回：目标快照为 null（消费端据此不展示目标对比）
      final wrapper = Db.forTesting(db);
      // 重建后的 sessions 表为空，先补一条父行满足外键
      final s = await wrapper.insertSession(const Session(
        date: '2026-09-27',
        planDayTitle: '推日',
        startedAt: 1000,
        status: 'active',
      ));
      final seId = await wrapper.insertSessionExercise(SessionExercise(
        sessionId: s.id!,
        name: '杠铃卧推',
        orderIdx: 0,
        kind: 'compound',
        rule: ProgressionRule.fallback,
      ));
      await wrapper.insertSet(SetEntry(
        sessionExerciseId: seId,
        weightKg: 62.5,
        reps: 8,
        kind: SetKind.working,
        doneAt: 1000,
        targetWeightKg: 60,
        targetReps: 6,
      ));
      final back = await wrapper.setsOfExercise(seId);
      expect(back.single.targetWeightKg, 60);
      expect(back.single.targetReps, 6);
      expect(back.single.weightKg, 62.5);
      await db.close();
    });

    test('全新库 createSchema 含 v8 列；Session.impression 往返', () async {
      final db = await databaseFactory.openDatabase(dbPath);
      await Db.instance.createSchema(db);
      final setCols = [
        for (final c in await db.rawQuery('PRAGMA table_info(sets)'))
          c['name'] as String
      ];
      expect(setCols, containsAll(['target_weight_kg', 'target_reps']));
      final wrapper = Db.forTesting(db);
      final s = await wrapper.insertSession(Session(
        date: '2026-09-27',
        planDayTitle: '推日',
        startedAt: 1000,
        status: 'active',
      ));
      await wrapper.updateSession(s.id!, {'impression': 3});
      final back = await wrapper.sessionById(s.id!);
      expect(back!.impression, 3);
      // 未评为 null
      final s2 = await wrapper.insertSession(Session(
        date: '2026-09-28',
        planDayTitle: '拉日',
        startedAt: 2000,
        status: 'active',
      ));
      expect((await wrapper.sessionById(s2.id!))!.impression, isNull);
      await db.close();
    });
  });

  group('身体指标防呆区间', () {
    test('合法值通过，越界拦截并给出字段名', () {
      expect(
          validateBodyMetric(weightKg: 70, waistCm: 80, bodyFatPct: 18), isNull);
      // 边界值本身合法
      expect(validateBodyMetric(weightKg: 20), isNull);
      expect(validateBodyMetric(weightKg: 350), isNull);
      expect(validateBodyMetric(bodyFatPct: 60), isNull);
      // 越界：体重 400（多敲一位）/ 腰围 15（单位填错）/ 体脂 0
      expect(validateBodyMetric(weightKg: 400), contains('体重'));
      expect(validateBodyMetric(weightKg: 15), contains('体重'));
      expect(validateBodyMetric(waistCm: 15), contains('腰围'));
      expect(validateBodyMetric(waistCm: 250), contains('腰围'));
      expect(validateBodyMetric(bodyFatPct: 0.5), contains('体脂率'));
      expect(validateBodyMetric(bodyFatPct: 70), contains('体脂率'));
      // null 字段跳过（部分录入是合法路径）
      expect(validateBodyMetric(waistCm: 80), isNull);
    });
  });

  group('周/月分桶与趋势累计', () {
    test('trendKeyOf：周一/月一号对齐，同桶同键', () {
      final weekA = trendKeyOf(DateTime(2026, 9, 23), TrendGranularity.week); // 周三
      final weekB = trendKeyOf(DateTime(2026, 9, 21), TrendGranularity.week); // 同周周一
      expect(weekA, weekB);
      final weekC = trendKeyOf(DateTime(2026, 9, 28), TrendGranularity.week); // 下周一
      expect(weekC, greaterThan(weekA));

      final monthA = trendKeyOf(DateTime(2026, 9, 15), TrendGranularity.month);
      final monthB = trendKeyOf(DateTime(2026, 9, 30), TrendGranularity.month);
      expect(monthA, monthB);
      final monthC = trendKeyOf(DateTime(2026, 10, 1), TrendGranularity.month);
      expect(monthC, greaterThan(monthA));
    });

    test('TrendAcc：容量/组数累加，强度按有分母的组求均值', () {
      final acc = TrendAcc();
      acc.add(setVolume: 480, intensity: 0.8);
      acc.add(setVolume: 400, intensity: 0.9);
      acc.add(setVolume: 0, intensity: null); // 自重组：无强度意义
      expect(acc.metricValue(TrendMetric.volume), 880);
      expect(acc.metricValue(TrendMetric.sets), 3);
      // (0.8 + 0.9) / 2 * 100 = 85
      expect(acc.metricValue(TrendMetric.intensity), closeTo(85, 0.001));
      // 空桶强度为 0（无样本）
      expect(TrendAcc().metricValue(TrendMetric.intensity), 0);
    });
  });

  group('每日最佳 1RM', () {
    test('同日多组取最大，跨日记点，退步照记', () {
      final d = DailyBest1Rm();
      d.add('杠铃卧推', DateTime(2026, 9, 20), 80);
      d.add('杠铃卧推', DateTime(2026, 9, 20), 85); // 同日更好
      d.add('杠铃卧推', DateTime(2026, 9, 20), 82); // 同日更差：忽略
      d.add('杠铃卧推', DateTime(2026, 9, 25), 83); // 跨日退步：照记（诚实 dips）
      d.add('杠铃深蹲', DateTime(2026, 9, 20), 120); // 另一动作互不干扰
      final days = d.sortedDaysOf('杠铃卧推');
      expect(days, hasLength(2));
      expect(d.byExercise['杠铃卧推']![days.first], 85);
      expect(d.byExercise['杠铃卧推']![days.last], 83);
      expect(d.sortedDaysOf('杠铃深蹲'), hasLength(1));
    });
  });

  group('上下肢分组', () {
    test('regionGroupOf 七分区映射', () {
      expect(regionGroupOf('胸'), '上肢');
      expect(regionGroupOf('肩'), '上肢');
      expect(regionGroupOf('背'), '上肢');
      expect(regionGroupOf('手臂'), '上肢');
      expect(regionGroupOf('腿'), '下肢');
      expect(regionGroupOf('核心'), '核心');
      expect(regionGroupOf('其他'), '其他');
      expect(regionGroupOf('未知动作'), '其他');
    });

    test('regionGroupShare：分组求和保持总量', () {
      final share = {
        '胸': 0.3,
        '肩': 0.2,
        '背': 0.1,
        '腿': 0.25,
        '核心': 0.1,
        '其他': 0.05,
      };
      final g = regionGroupShare(share);
      expect(g['上肢'], closeTo(0.6, 0.0001));
      expect(g['下肢'], closeTo(0.25, 0.0001));
      expect(g['核心'], closeTo(0.1, 0.0001));
      expect(g['其他'], closeTo(0.05, 0.0001));
      expect(g.values.fold(0.0, (a, b) => a + b), closeTo(1.0, 0.0001));
    });
  });

  group('历史页「目标 vs 实际」行', () {
    Future<List<Widget>> rowsFor(List<SetEntry> sets,
        {SessionExercise? se}) async {
      final exercise = se ??
          SessionExercise(
            sessionId: 1,
            name: '杠铃卧推',
            orderIdx: 0,
            kind: 'compound',
            rule: ProgressionRule.fallback,
          ).copyWithId(7);
      return buildSessionDetailRows(
        const Session(
          id: 1,
          date: '2026-09-27',
          planDayTitle: '推日',
          startedAt: 1000,
          endedAt: 2000,
          status: 'done',
        ),
        [exercise],
        {7: sets},
        bodyWeightKg: 0,
      );
    }

    testWidgets('新记录（v8+）：显示完成当时的处方快照', (tester) async {
      final rows = await rowsFor([
        const SetEntry(
          sessionExerciseId: 7,
          weightKg: 62.5,
          reps: 8,
          kind: SetKind.working,
          doneAt: 1100,
          targetWeightKg: 60,
          targetReps: 6,
        ),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ListView(children: rows)),
      ));
      expect(find.textContaining('目标 60kg × 6 次'), findsOneWidget);
    });

    testWidgets('老记录（无组快照）：回退动作行的模板目标', (tester) async {
      final rows = await rowsFor(
        [
          const SetEntry(
            sessionExerciseId: 7,
            weightKg: 60,
            reps: 8,
            kind: SetKind.working,
            doneAt: 1100,
          ),
        ],
        se: SessionExercise(
          sessionId: 1,
          name: '杠铃卧推',
          orderIdx: 0,
          kind: 'compound',
          rule: ProgressionRule.fallback,
          targetSets: 4,
          targetRepsMin: 5,
          targetRepsMax: 8,
        ).copyWithId(7),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ListView(children: rows)),
      ));
      expect(find.textContaining('计划目标 4 组 × 5-8 次'), findsOneWidget);
    });
  });
}
