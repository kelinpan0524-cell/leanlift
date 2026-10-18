// schema v5→v6 迁移测试（调研条目 14）：老库平滑升级、老数据回退语义、
// 全新库建表含新列、老备份恢复兼容，以及统计过滤纪律的 SQL 锁定
// （active/quit 会话不进任何聚合查询）。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/metrics.dart' show fmtDate;
import 'package:baoji_timer/models/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 手写 v5 结构（v6 之前的 session_exercises 没有 target_* 三列），
/// 供老库升级路径测试。
Future<void> createV5Schema(Database db) async {
  await db.execute('''
    CREATE TABLE plans(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      source TEXT NOT NULL,
      created_at TEXT NOT NULL,
      is_active INTEGER NOT NULL DEFAULT 1,
      pattern TEXT NOT NULL DEFAULT 'weekly',
      pattern_start TEXT NOT NULL DEFAULT '',
      cycle_train INTEGER NOT NULL DEFAULT 0,
      cycle_rest INTEGER NOT NULL DEFAULT 0
    )''');
  await db.execute('''
    CREATE TABLE plan_days(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      plan_id INTEGER NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
      weekday INTEGER NOT NULL,
      title TEXT NOT NULL,
      notes TEXT NOT NULL DEFAULT ''
    )''');
  await db.execute('''
    CREATE TABLE plan_exercises(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      day_id INTEGER NOT NULL REFERENCES plan_days(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      order_idx INTEGER NOT NULL DEFAULT 0,
      sets INTEGER NOT NULL DEFAULT 3,
      reps_min INTEGER NOT NULL DEFAULT 5,
      reps_max INTEGER NOT NULL DEFAULT 8,
      rest_sec INTEGER NOT NULL DEFAULT 120,
      kind TEXT NOT NULL DEFAULT 'assistance',
      rule TEXT NOT NULL DEFAULT '{}'
    )''');
  await db.execute('''
    CREATE TABLE exercise_meta(
      name TEXT PRIMARY KEY,
      main_muscle TEXT NOT NULL,
      secondary TEXT NOT NULL DEFAULT '',
      is_compound INTEGER NOT NULL DEFAULT 0,
      equipment TEXT NOT NULL DEFAULT 'both'
    )''');
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
    )''');
  await db.execute('''
    CREATE TABLE session_exercises(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      order_idx INTEGER NOT NULL DEFAULT 0,
      kind TEXT NOT NULL DEFAULT 'assistance',
      rest_sec INTEGER NOT NULL DEFAULT 0,
      rule TEXT NOT NULL DEFAULT '{}',
      trace TEXT NOT NULL DEFAULT ''
    )''');
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
    )''');
  await db.execute('CREATE INDEX idx_sets_se ON sets(session_exercise_id)');
  await db.execute('CREATE INDEX idx_se_name ON session_exercises(name)');
  await db.execute(
    'CREATE INDEX idx_se_session ON session_exercises(session_id)',
  );
}

Future<int> _seedV5WithData(Database db) async {
  final planId = await db.insert('plans', {
    'name': '老计划',
    'source': 'preset',
    'created_at': '2026-01-01',
    'is_active': 1,
  });
  final dayId = await db.insert('plan_days', {
    'plan_id': planId,
    'weekday': 1,
    'title': '推日',
  });
  await db.insert('plan_exercises', {
    'day_id': dayId,
    'name': '杠铃卧推',
    'order_idx': 0,
    'sets': 3,
    'reps_min': 5,
    'reps_max': 8,
    'rest_sec': 120,
    'kind': 'compound',
    'rule': '{"reps_min":5,"reps_max":8,"increment_kg":2.5}',
  });
  // 一场已结束的训练 + 一场进行中的训练（各 1 动作 1 组）
  final doneId = await db.insert('sessions', {
    'date': '2026-09-01',
    'plan_day_id': dayId,
    'plan_day_title': '推日',
    'started_at': 1000,
    'ended_at': 2000,
    'status': 'done',
  });
  final activeId = await db.insert('sessions', {
    'date': '2026-09-02',
    'plan_day_id': dayId,
    'plan_day_title': '推日',
    'started_at': 3000,
    'status': 'active',
  });
  final doneSe = await db.insert('session_exercises', {
    'session_id': doneId,
    'name': '杠铃卧推',
    'order_idx': 0,
    'kind': 'compound',
    'rest_sec': 120,
    'rule': '{"reps_min":5,"reps_max":8,"increment_kg":2.5}',
    'trace': '',
  });
  await db.insert('sets', {
    'session_exercise_id': doneSe,
    'weight_kg': 60.0,
    'reps': 8,
    'rir': 2,
    'kind': 'working',
    'done_at': 1500,
  });
  final activeSe = await db.insert('session_exercises', {
    'session_id': activeId,
    'name': '杠铃卧推',
    'order_idx': 0,
    'kind': 'compound',
    'rest_sec': 120,
    'rule': '{"reps_min":5,"reps_max":8,"increment_kg":2.5}',
    'trace': '',
  });
  await db.insert('sets', {
    'session_exercise_id': activeSe,
    'weight_kg': 999.0,
    'reps': 1,
    'rir': 0,
    'kind': 'working',
    'done_at': 3500,
  });
  return planId;
}

/// v14 形状的三张表（无 v15 的 exercise_key / rir_recorded / pain_*），
/// 供 v14→v15 升级夹具复用。
Future<void> createV14Tables(Database db) async {
  await db.execute('''
    CREATE TABLE plan_exercises(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      day_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      order_idx INTEGER NOT NULL DEFAULT 0,
      sets INTEGER NOT NULL DEFAULT 3,
      reps_min INTEGER NOT NULL DEFAULT 5,
      reps_max INTEGER NOT NULL DEFAULT 8,
      rest_sec INTEGER NOT NULL DEFAULT 120,
      kind TEXT NOT NULL DEFAULT 'assistance',
      rule TEXT NOT NULL DEFAULT '{}',
      logging TEXT NOT NULL DEFAULT 'reps',
      load_type TEXT NOT NULL DEFAULT 'weighted',
      superset_tag TEXT NOT NULL DEFAULT ''
    )''');
  await db.execute('''
    CREATE TABLE session_exercises(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      order_idx INTEGER NOT NULL DEFAULT 0,
      kind TEXT NOT NULL DEFAULT 'assistance',
      rest_sec INTEGER NOT NULL DEFAULT 0,
      rule TEXT NOT NULL DEFAULT '{}',
      target_sets INTEGER NOT NULL DEFAULT 0,
      target_reps_min INTEGER NOT NULL DEFAULT 0,
      target_reps_max INTEGER NOT NULL DEFAULT 0,
      trace TEXT NOT NULL DEFAULT '',
      logging TEXT NOT NULL DEFAULT 'reps',
      load_type TEXT NOT NULL DEFAULT 'weighted',
      superset_tag TEXT NOT NULL DEFAULT ''
    )''');
  await db.execute('''
    CREATE TABLE sets(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_exercise_id INTEGER NOT NULL,
      weight_kg REAL NOT NULL,
      reps INTEGER NOT NULL,
      rir INTEGER NOT NULL DEFAULT 2,
      kind TEXT NOT NULL DEFAULT 'working',
      done_at INTEGER NOT NULL,
      note TEXT NOT NULL DEFAULT '',
      target_weight_kg REAL,
      target_reps INTEGER,
      is_extra INTEGER NOT NULL DEFAULT 0,
      duration_sec INTEGER
    )''');
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late String dbPath;

  setUp(() async {
    final dir = await databaseFactory.getDatabasesPath();
    dbPath = '$dir/mig_${DateTime.now().microsecondsSinceEpoch}.db';
  });

  test('v5 老库升级：新列出现、老行 target=0（回退语义）', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await createV5Schema(db);
    final planId = await _seedV5WithData(db);
    expect(planId, greaterThan(0));

    // 生产路径同款迁移
    await Db.instance.upgradeV5to6(db);

    final cols = [
      for (final c in await db.rawQuery(
          'PRAGMA table_info(session_exercises)'))
        c['name'] as String
    ];
    expect(cols, containsAll(['target_sets', 'target_reps_min', 'target_reps_max']));

    // 老行默认 0，model 读回零值（消费端据此回退 rule 参数）
    final rows = await db.query('session_exercises');
    for (final r in rows) {
      final se = SessionExercise.fromMap(r);
      expect(se.targetSets, 0);
      expect(se.targetRepsMin, 0);
      expect(se.targetRepsMax, 0);
      expect(se.rule.repsMax, 8); // rule JSON 未受损，回退数据源完好
    }

    // 升级后可正常写入带快照的新行
    final newSe = await db.insert('session_exercises', {
      'session_id': rows.first['session_id'],
      'name': '上斜哑铃卧推',
      'order_idx': 1,
      'kind': 'assistance',
      'rest_sec': 90,
      'rule': '{}',
      'target_sets': 4,
      'target_reps_min': 8,
      'target_reps_max': 12,
      'trace': '',
    });
    final read = SessionExercise.fromMap(
        (await db.query('session_exercises',
            where: 'id = ?', whereArgs: [newSe])).first);
    expect(read.targetSets, 4);
    expect(read.targetRepsMin, 8);
    expect(read.targetRepsMax, 12);
    await db.close();
  });

  test('全新库 createSchema 含 v6 列', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    final cols = [
      for (final c in await db.rawQuery(
          'PRAGMA table_info(session_exercises)'))
        c['name'] as String
    ];
    expect(cols, containsAll(['target_sets', 'target_reps_min', 'target_reps_max']));
    await db.close();
  });

  test('v7 老库升级：deleted_plans 回收站表出现（可写入/查询）', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    // 模拟 v6 库：先建全套 schema 再删掉 v7 才有的回收站表
    await Db.instance.createSchema(db);
    await db.execute('DROP TABLE deleted_plans');

    // 生产路径同款迁移
    await Db.instance.upgradeV6to7(db);

    // 迁移后表可用：写入与查询正常
    await db.insert('deleted_plans', {
      'name': '旧计划',
      'snapshot': '{}',
      'deleted_at': '2026-09-26T08:00:00.000',
    });
    final rows = await db.query('deleted_plans');
    expect(rows.length, 1);
    expect(rows.first['name'], '旧计划');
    await db.close();
  });

  test('restoreAll 兼容老备份（无 target 键的 session_exercises 行）', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    final wrapper = Db.forTesting(db);
    await wrapper.restoreAll({
      'session_exercises': [
        {
          'id': 7,
          'session_id': 3,
          'name': '杠铃卧推',
          'order_idx': 0,
          'kind': 'compound',
          'rest_sec': 120,
          'rule': '{"reps_min":5,"reps_max":8}',
          'trace': '',
          // 无 target_sets / target_reps_min / target_reps_max
        }
      ],
      'sessions': [
        {
          'id': 3,
          'date': '2026-09-01',
          'plan_day_title': '推日',
          'started_at': 1000,
          'ended_at': 2000,
          'status': 'done',
        }
      ],
    });
    final ses = await wrapper.sessionExercises(3);
    expect(ses.length, 1);
    expect(ses.first.targetSets, 0); // 缺键回退默认 0
    await db.close();
  });

  test('v8 老库升级：superset_tag 列出现、老行默认空串', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    // 手写 v8 形状（v9 之前两张表都没有 superset_tag）
    await db.execute('''
      CREATE TABLE plan_exercises(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        day_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        order_idx INTEGER NOT NULL DEFAULT 0,
        sets INTEGER NOT NULL DEFAULT 3,
        reps_min INTEGER NOT NULL DEFAULT 5,
        reps_max INTEGER NOT NULL DEFAULT 8,
        rest_sec INTEGER NOT NULL DEFAULT 120,
        kind TEXT NOT NULL DEFAULT 'assistance',
        rule TEXT NOT NULL DEFAULT '{}'
      )''');
    await db.execute('''
      CREATE TABLE session_exercises(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        order_idx INTEGER NOT NULL DEFAULT 0,
        kind TEXT NOT NULL DEFAULT 'assistance',
        rest_sec INTEGER NOT NULL DEFAULT 0,
        rule TEXT NOT NULL DEFAULT '{}',
        target_sets INTEGER NOT NULL DEFAULT 0,
        target_reps_min INTEGER NOT NULL DEFAULT 0,
        target_reps_max INTEGER NOT NULL DEFAULT 0,
        trace TEXT NOT NULL DEFAULT ''
      )''');
    final peId = await db.insert('plan_exercises',
        {'day_id': 1, 'name': '杠铃卧推', 'order_idx': 0, 'rule': '{}'});

    // 生产路径同款迁移
    await Db.instance.upgradeV8to9(db);

    for (final table in ['plan_exercises', 'session_exercises']) {
      final cols = [
        for (final c in await db.rawQuery('PRAGMA table_info($table)'))
          c['name'] as String
      ];
      expect(cols, contains('superset_tag'), reason: table);
    }
    // 老行默认空串（model 读回不配对）
    final row = PlanExercise.fromMap(
        (await db.query('plan_exercises', where: 'id = ?', whereArgs: [peId]))
            .first);
    expect(row.supersetTag, '');
    await db.close();
  });

  test('v9：normalizeSupersetTags 拆散/单人清空、相邻保留', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    final wrapper = Db.forTesting(db);
    final plan = await wrapper.insertPlan(Plan(
        name: '超级组测试', source: 'manual', createdAt: '2026-09-29', isActive: 1));
    final dayId = await wrapper.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 1, title: '推拉'));
    // 顺序：A(g) B(g) C(x 孤tag) D(h) E(无tag) F(h)——h 组被 E 隔开
    final seed = [
      ('二头弯举', 'g'), ('三头下压', 'g'), ('卷腹', 'x'),
      ('卧推', 'h'), ('深蹲', ''), ('划船', 'h'),
    ];
    for (var k = 0; k < seed.length; k++) {
      final (name, tag) = seed[k];
      await wrapper.insertPlanExercise(PlanExercise(
          dayId: dayId, name: name, orderIdx: k, sets: 3, restSec: 90,
          repsMin: 8, repsMax: 12, kind: 'assistance',
          rule: const ProgressionRule(repsMin: 8, repsMax: 12, workingSets: 3),
          supersetTag: tag));
    }

    // g,g 相邻保留；x 孤 tag 清；h 被深蹲隔开 → 两个 h 都清
    final detached = await wrapper.normalizeSupersetTags(dayId);
    expect(detached, ['卷腹', '卧推', '划船']);
    final after = await wrapper.dayExercises(dayId);
    expect(after[0].supersetTag, 'g');
    expect(after[1].supersetTag, 'g');
    expect(after[2].supersetTag, '');
    expect(after[3].supersetTag, '');
    expect(after[4].supersetTag, '');
    expect(after[5].supersetTag, '');

    // 再跑一遍：已干净 → 无变化（幂等）
    expect(await wrapper.normalizeSupersetTags(dayId), isEmpty);
    await db.close();
  });

  test('v10 老库升级：exercise_meta 出现 gear 列、老行默认空、可写可删', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    // 手写 v10 形状（无 gear 列）
    await db.execute('''
      CREATE TABLE exercise_meta(
        name TEXT PRIMARY KEY,
        main_muscle TEXT NOT NULL,
        secondary TEXT NOT NULL DEFAULT '',
        is_compound INTEGER NOT NULL DEFAULT 0,
        equipment TEXT NOT NULL DEFAULT 'both'
      )''');
    await db.insert('exercise_meta',
        {'name': '老动作', 'main_muscle': '胸', 'secondary': '', 'is_compound': 1, 'equipment': 'gym'});

    await Db.instance.upgradeV10to11(db);

    final cols = [
      for (final c in await db.rawQuery('PRAGMA table_info(exercise_meta)'))
        c['name'] as String
    ];
    expect(cols, contains('gear'));
    // 老行默认空串
    final old = ExerciseMeta.fromMap(
        (await db.query('exercise_meta')).first);
    expect(old.gear, '');

    // 新行带 gear 落库读回；delete DAO 真删
    final wrapper = Db.forTesting(db);
    await wrapper.upsertExerciseMeta(const ExerciseMeta(
        '我的弹力带动作', MuscleGroups(main: '背', secondary: []), false, 'home', '', '弹力带'));
    final rows = await wrapper.allExerciseMeta();
    final mine = rows.firstWhere((m) => m.name == '我的弹力带动作');
    expect(mine.gear, '弹力带');
    await wrapper.deleteExerciseMeta('我的弹力带动作');
    expect((await wrapper.allExerciseMeta())
        .where((m) => m.name == '我的弹力带动作'), isEmpty);
    await db.close();
  });

  test('统计过滤纪律：active 会话的组不进任何聚合查询', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await createV5Schema(db);
    await _seedV5WithData(db);
    await Db.instance.upgradeV5to6(db);
    // sessionRowsBetween 现在会读 v15 的 rir_recorded：生产路径 openDatabase
    // 会一路升到当前版本，这里补齐后续迁移，避免用「半升级库」锁当前查询口径。
    for (final step in [
      Db.instance.upgradeV6to7,
      Db.instance.upgradeV7to8,
      Db.instance.upgradeV8to9,
      Db.instance.upgradeV9to10,
      Db.instance.upgradeV10to11,
      Db.instance.upgradeV11to12,
      Db.instance.upgradeV12to13,
      Db.instance.upgradeV13to14,
      Db.instance.upgradeV14to15,
      Db.instance.upgradeV15to16,
      Db.instance.upgradeV16to17,
    ]) {
      await step(db);
    }
    final wrapper = Db.forTesting(db);

    // 渐进历史：只有 done 会话的 60×8，没有 active 会话的 999×1
    final history = await wrapper.historySets('杠铃卧推');
    expect(history.length, 1);
    expect(history.first.weightKg, 60);

    // PR 上限：999kg 的 active 组不得抬高门槛
    expect(await wrapper.maxWeightOf('杠铃卧推'), 60);

    // 上次成绩：只来自 done 会话
    final last = await wrapper.lastWorkingSets('杠铃卧推');
    expect(last.single.weightKg, 60);

    // 区间明细与日期查询同样只认 done
    final rows = await wrapper.sessionRowsBetween('2026-09-01', '2026-09-30');
    expect(rows.where((r) => r['weight_kg'] == 999.0), isEmpty);
    final between = await wrapper.sessionsBetween('2026-09-01', '2026-09-30');
    expect(between.length, 1);
    expect(between.first.status, 'done');
    await db.close();
  });

  test('lastTargetSets 只统计计划行：临时追加行不计入计划组数', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    final w = Db.forTesting(db);

    /// 落一场 done 会话，内含一行「杠铃卧推」，按参数控制来源痕迹与快照。
    Future<void> addSessionRow(
      String date, {
      required String trace,
      required int targetSets,
    }) async {
      final s = await w.insertSession(Session(
        date: date,
        planDayTitle: '推日',
        startedAt: 1,
        endedAt: 2,
        status: 'done',
      ));
      await w.insertSessionExercise(SessionExercise(
        sessionId: s.id!,
        name: '杠铃卧推',
        orderIdx: 0,
        kind: 'compound',
        restSec: 120,
        rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
        targetSets: targetSets,
        trace: trace,
      ));
    }

    // ① 计划原样行（trace=''，快照 4）→ 计入 4
    await addSessionRow('2026-10-01', trace: '', targetSets: 4);
    expect(await w.lastTargetSets('杠铃卧推'), 4);

    // ② 替换行（替换自：…，占用计划槽位、保留快照 2）→ 计入 2
    await addSessionRow('2026-10-02', trace: '替换自：杠铃卧推', targetSets: 2);
    expect(await w.lastTargetSets('杠铃卧推'), 2);

    // ③ 临时追加行（追加于：…，无快照）→ 不计入（旧行为回退 rule.workingSets=3）
    await addSessionRow('2026-10-03', trace: '追加于：划船', targetSets: 0);
    expect(await w.lastTargetSets('杠铃卧推'), 0,
        reason: '临时追加行不是计划行，不能把加练当成「上次计划 3 组」');

    // ④ 减载/停练周的追加行（追加快照也 >0）→ 同样被 trace 白名单排除
    await addSessionRow('2026-10-04', trace: '追加于：划船', targetSets: 2);
    expect(await w.lastTargetSets('杠铃卧推'), 0,
        reason: '减载周追加快照 2 组也不算计划组数');

    // ⑤ v6 前老行（trace=''、无快照）→ 计入，回退该行 rule 的 workingSets
    await addSessionRow('2026-10-05', trace: '', targetSets: 0);
    expect(await w.lastTargetSets('杠铃卧推'), 3,
        reason: '老记录无快照时回退行内 rule，trace 为空 = 计划原样');
    await db.close();
  });

  test('lastDoneSessionDate：只认有正式组的 done 会话并忽略未来日期', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    final w = Db.forTesting(db);
    final today = DateTime.now();
    String d(int daysFromNow) =>
        fmtDate(today.add(Duration(days: daysFromNow)));

    // 空库 → null
    expect(await w.lastDoneSessionDate(), isNull);

    /// 落一场会话（可选带一行正式组/热身组）。
    Future<void> addSession(
      String date,
      String status, {
      bool withWorkingSet = false,
      bool withWarmupSet = false,
    }) async {
      final s = await w.insertSession(Session(
        date: date,
        planDayTitle: '推日',
        startedAt: 1,
        endedAt: 2,
        status: status,
      ));
      final se = await w.insertSessionExercise(SessionExercise(
        sessionId: s.id!,
        name: '杠铃卧推',
        orderIdx: 0,
        kind: 'compound',
        rule: const ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      ));
      if (withWorkingSet || withWarmupSet) {
        await w.insertSet(SetEntry(
          sessionExerciseId: se,
          weightKg: 60,
          reps: 8,
          kind: withWorkingSet ? SetKind.working : SetKind.warmup,
          doneAt: 100,
        ));
      }
    }

    // 未来日期的 done（有正式组）→ 忽略：设备时间被拨快留下的未来场
    // 不能永久压住停练判定
    await addSession(d(3), 'done', withWorkingSet: true);
    expect(await w.lastDoneSessionDate(), isNull, reason: '未来日期不算');

    // 今天的 done 但一组正式组没有（只有热身组）→ 不算「练过」
    await addSession(d(0), 'done', withWarmupSet: true);
    expect(await w.lastDoneSessionDate(), isNull, reason: '零正式组的空场不算练过');

    // 昨天的 done 带正式组 → 返回昨天
    await addSession(d(-1), 'done', withWorkingSet: true);
    expect(await w.lastDoneSessionDate(), d(-1));

    // 之后的 quit/active 即便带组也不影响（只认 done）
    await addSession(d(0), 'quit', withWorkingSet: true);
    await addSession(d(0), 'active', withWorkingSet: true);
    expect(await w.lastDoneSessionDate(), d(-1));
    await db.close();
  });

  test('v10 老库升级：plans 增顺延两列，存量行默认未顺延', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    // 模拟 v8/v9 老库：建全套新 schema 后，把 plans 换回没有顺延列的旧结构
    await Db.instance.createSchema(db);
    await db.execute('PRAGMA foreign_keys = OFF');
    await db.execute('DROP TABLE plans');
    await db.execute('''
      CREATE TABLE plans(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        source TEXT NOT NULL,
        created_at TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        pattern TEXT NOT NULL DEFAULT 'weekly',
        pattern_start TEXT NOT NULL DEFAULT '',
        cycle_train INTEGER NOT NULL DEFAULT 0,
        cycle_rest INTEGER NOT NULL DEFAULT 0
      )''');
    await db.execute('PRAGMA foreign_keys = ON');
    final planId = await db.insert('plans', {
      'name': '老计划',
      'source': 'preset',
      'created_at': '2026-09-01',
    });

    // 生产路径同款迁移
    await Db.instance.upgradeV9to10(db);

    final cols =
        (await db.rawQuery('PRAGMA table_info(plans)')).map((c) => c['name']);
    expect(cols, containsAll(['shift_days', 'shift_from']));
    final row = await db.query('plans', where: 'id=?', whereArgs: [planId]);
    final plan = Plan.fromMap(row.single);
    expect(plan.shiftDays, 0, reason: '存量行默认未顺延');
    expect(plan.shiftFrom, '');
    await db.close();
  });

  test('v12 老库升级：sets 出现 is_extra、老行默认 false、写 1 读回 true', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    // 模拟 v11 库：建全套新 schema 后，把 sets 换回没有 is_extra 的旧结构
    await Db.instance.createSchema(db);
    await db.execute('PRAGMA foreign_keys = OFF');
    await db.execute('DROP TABLE sets');
    await db.execute('''
      CREATE TABLE sets(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_exercise_id INTEGER NOT NULL,
        weight_kg REAL NOT NULL,
        reps INTEGER NOT NULL,
        rir INTEGER NOT NULL DEFAULT 2,
        kind TEXT NOT NULL DEFAULT 'working',
        done_at INTEGER NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        target_weight_kg REAL,
        target_reps INTEGER
      )''');
    await db.insert('sets', {
      'session_exercise_id': 1,
      'weight_kg': 60.0,
      'reps': 8,
      'rir': 2,
      'kind': 'working',
      'done_at': 1000,
    });
    await db.execute('PRAGMA foreign_keys = ON');

    // 生产路径同款迁移
    await Db.instance.upgradeV11to12(db);

    final cols = [
      for (final c in await db.rawQuery('PRAGMA table_info(sets)'))
        c['name'] as String
    ];
    expect(cols, contains('is_extra'));
    // 老行默认 0 → model 读回 false（老数据不回溯标注）
    final oldRow = (await db.query('sets')).first;
    expect(SetEntry.fromMap(oldRow).isExtra, isFalse);

    // 新行带 is_extra=1 落库读回 true
    await db.insert('sets', {
      'session_exercise_id': 1,
      'weight_kg': 62.5,
      'reps': 8,
      'rir': 2,
      'kind': 'working',
      'done_at': 2000,
      'is_extra': 1,
    });
    final rows = await db.query('sets', orderBy: 'id');
    expect(SetEntry.fromMap(rows.last).isExtra, isTrue);
    await db.close();
  });

  test('全新库 createSchema 含 is_extra', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    final cols = [
      for (final c in await db.rawQuery('PRAGMA table_info(sets)'))
        c['name'] as String
    ];
    expect(cols, contains('is_extra'));
    await db.close();
  });

  test('restoreAll 兼容老备份（sets 行缺 is_extra 键回退 false，不丢行）', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    final wrapper = Db.forTesting(db);
    await wrapper.restoreAll({
      'sessions': [
        {
          'id': 3,
          'date': '2026-09-01',
          'plan_day_title': '推日',
          'started_at': 1000,
          'ended_at': 2000,
          'status': 'done',
        }
      ],
      'session_exercises': [
        {
          'id': 7,
          'session_id': 3,
          'name': '杠铃卧推',
          'order_idx': 0,
          'kind': 'compound',
          'rest_sec': 120,
          'rule': '{"reps_min":5,"reps_max":8}',
          'trace': '',
        }
      ],
      'sets': [
        {
          'id': 9,
          'session_exercise_id': 7,
          'weight_kg': 60.0,
          'reps': 8,
          'rir': 2,
          'kind': 'working',
          'done_at': 1500,
          // 无 is_extra 键（v11 及更早版本导出的备份行）
        }
      ],
    });
    final sets = await wrapper.setsOfSession(3);
    final flat = sets.values.expand((l) => l).toList();
    expect(flat.length, 1, reason: '老备份行照常恢复');
    expect(flat.first.isExtra, isFalse, reason: '缺键回退默认 false');
    await db.close();
  });

  test('v14 老库升级：logging/load_type/duration_sec 出现、老行回默认', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    // 模拟 v13 库：建全套新 schema 后，把三张表换回没有 v14 列的旧结构
    await Db.instance.createSchema(db);
    await db.execute('PRAGMA foreign_keys = OFF');
    await db.execute('DROP TABLE sets');
    await db.execute('DROP TABLE session_exercises');
    await db.execute('DROP TABLE plan_exercises');
    await db.execute('''
      CREATE TABLE plan_exercises(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        day_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        order_idx INTEGER NOT NULL DEFAULT 0,
        sets INTEGER NOT NULL DEFAULT 3,
        reps_min INTEGER NOT NULL DEFAULT 5,
        reps_max INTEGER NOT NULL DEFAULT 8,
        rest_sec INTEGER NOT NULL DEFAULT 120,
        kind TEXT NOT NULL DEFAULT 'assistance',
        rule TEXT NOT NULL DEFAULT '{}',
        superset_tag TEXT NOT NULL DEFAULT ''
      )''');
    await db.execute('''
      CREATE TABLE session_exercises(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        order_idx INTEGER NOT NULL DEFAULT 0,
        kind TEXT NOT NULL DEFAULT 'assistance',
        rest_sec INTEGER NOT NULL DEFAULT 0,
        rule TEXT NOT NULL DEFAULT '{}',
        target_sets INTEGER NOT NULL DEFAULT 0,
        target_reps_min INTEGER NOT NULL DEFAULT 0,
        target_reps_max INTEGER NOT NULL DEFAULT 0,
        trace TEXT NOT NULL DEFAULT '',
        superset_tag TEXT NOT NULL DEFAULT ''
      )''');
    await db.execute('''
      CREATE TABLE sets(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_exercise_id INTEGER NOT NULL,
        weight_kg REAL NOT NULL,
        reps INTEGER NOT NULL,
        rir INTEGER NOT NULL DEFAULT 2,
        kind TEXT NOT NULL DEFAULT 'working',
        done_at INTEGER NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        target_weight_kg REAL,
        target_reps INTEGER,
        is_extra INTEGER NOT NULL DEFAULT 0
      )''');
    final peId = await db.insert('plan_exercises',
        {'day_id': 1, 'name': '平板支撑', 'order_idx': 0, 'rule': '{}'});
    final seId = await db.insert('session_exercises',
        {'session_id': 1, 'name': '平板支撑', 'order_idx': 0, 'rule': '{}'});
    await db.insert('sets', {
      'session_exercise_id': seId,
      'weight_kg': 0.0,
      'reps': 45,
      'rir': 2,
      'kind': 'working',
      'done_at': 1000,
    });
    await db.execute('PRAGMA foreign_keys = ON');

    // 生产路径同款迁移（v12/v13 直升 v14 均走本函数）
    await Db.instance.upgradeV13to14(db);

    for (final entry in {
      'plan_exercises': ['logging', 'load_type'],
      'session_exercises': ['logging', 'load_type'],
      'sets': ['duration_sec'],
    }.entries) {
      final cols = [
        for (final c in await db.rawQuery('PRAGMA table_info(${entry.key})'))
          c['name'] as String
      ];
      expect(cols, containsAll(entry.value), reason: entry.key);
    }

    // 老行回默认：按次数 + 常规负重；duration_sec 可空回 null（老行为不变）
    final plan = PlanExercise.fromMap(
        (await db.query('plan_exercises', where: 'id = ?', whereArgs: [peId]))
            .first);
    expect(plan.logging, LoggingMode.reps);
    expect(plan.loadType, LoadMode.weighted);
    final se = SessionExercise.fromMap((await db
            .query('session_exercises', where: 'id = ?', whereArgs: [seId]))
        .first);
    expect(se.logging, LoggingMode.reps);
    expect(se.loadType, LoadMode.weighted);
    expect(SetEntry.fromMap((await db.query('sets')).first).durationSec, isNull);

    // 升级后可正常写入带新值的行并读回
    await db.insert('plan_exercises', {
      'day_id': 1,
      'name': '箭步蹲',
      'order_idx': 1,
      'rule': '{}',
      'logging': LoggingMode.repsPerSide,
      'load_type': LoadMode.bodyweight,
    });
    final newPlan = PlanExercise.fromMap((await db.query('plan_exercises',
            where: 'logging = ?', whereArgs: [LoggingMode.repsPerSide]))
        .first);
    expect(newPlan.logging, LoggingMode.repsPerSide);
    expect(newPlan.loadType, LoadMode.bodyweight);
    await db.close();
  });

  test('全新库 createSchema 含 v14 列', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    Future<List<String>> colsOf(String t) async => [
          for (final c in await db.rawQuery('PRAGMA table_info($t)'))
            c['name'] as String
        ];
    expect(await colsOf('plan_exercises'),
        containsAll(['logging', 'load_type']));
    expect(await colsOf('session_exercises'),
        containsAll(['logging', 'load_type']));
    expect(await colsOf('sets'), contains('duration_sec'));
    await db.close();
  });

  test('restoreAll 兼容老备份（v14 键缺失回默认，不丢行）', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    final wrapper = Db.forTesting(db);
    await wrapper.restoreAll({
      'sessions': [
        {
          'id': 3,
          'date': '2026-09-01',
          'plan_day_title': '核心日',
          'started_at': 1000,
          'ended_at': 2000,
          'status': 'done',
        }
      ],
      'session_exercises': [
        {
          'id': 7,
          'session_id': 3,
          'name': '平板支撑',
          'order_idx': 0,
          'kind': 'assistance',
          'rule': '{"reps_min":30,"reps_max":60}',
          'trace': '',
          // 无 logging / load_type 键（v13 及更早版本导出的备份行）
        }
      ],
      'sets': [
        {
          'id': 9,
          'session_exercise_id': 7,
          'weight_kg': 0.0,
          'reps': 45,
          'rir': 2,
          'kind': 'working',
          'done_at': 1500,
          // 无 duration_sec 键
        }
      ],
    });
    final ses = await wrapper.sessionExercises(3);
    expect(ses.single.logging, LoggingMode.reps, reason: '缺键回默认 reps');
    expect(ses.single.loadType, LoadMode.weighted, reason: '缺键回默认 weighted');
    final flat = (await wrapper.setsOfSession(3)).values.expand((l) => l);
    expect(flat.single.durationSec, isNull, reason: '缺键回默认 null');
    await db.close();
  });

  test('v15 老库升级：预留列/表出现、exercise_key 回填 name、老行回默认', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    // 模拟 v14 库：建全套新 schema 后，把三张表换回没有 v15 列的旧结构，
    // 并删掉 v15 才有的 exercise_notes。
    await Db.instance.createSchema(db);
    await db.execute('PRAGMA foreign_keys = OFF');
    await db.execute('DROP TABLE sets');
    await db.execute('DROP TABLE session_exercises');
    await db.execute('DROP TABLE plan_exercises');
    await db.execute('DROP TABLE exercise_notes');
    await createV14Tables(db);
    final peId = await db.insert('plan_exercises', {
      'day_id': 1,
      'name': '杠铃卧推',
      'order_idx': 0,
      'rule': '{}',
    });
    final seId = await db.insert('session_exercises', {
      'session_id': 1,
      'name': '杠铃卧推',
      'order_idx': 0,
      'rule': '{}',
    });
    final setId = await db.insert('sets', {
      'session_exercise_id': seId,
      'weight_kg': 60.0,
      'reps': 8,
      'rir': 2,
      'kind': 'working',
      'done_at': 1000,
    });
    await db.execute('PRAGMA foreign_keys = ON');

    // 生产路径同款迁移（v12/v13/v14 直升 v15 均走本函数）
    await Db.instance.upgradeV14to15(db);

    Future<List<String>> colsOf(String t) async => [
      for (final c in await db.rawQuery('PRAGMA table_info($t)'))
        c['name'] as String,
    ];
    expect(
      await colsOf('sets'),
      containsAll(['rir_recorded', 'pain_level', 'pain_area']),
    );
    expect(await colsOf('plan_exercises'), contains('exercise_key'));
    expect(await colsOf('session_exercises'), contains('exercise_key'));
    expect(
      await colsOf('exercise_notes'),
      containsAll(['exercise_key', 'setup_note', 'updated_at']),
    );

    // 老行 exercise_key 回填为 name（不是空串）
    final plan = PlanExercise.fromMap(
      (await db.query(
        'plan_exercises',
        where: 'id = ?',
        whereArgs: [peId],
      )).first,
    );
    expect(plan.exerciseKey, '杠铃卧推');
    final se = SessionExercise.fromMap(
      (await db.query(
        'session_exercises',
        where: 'id = ?',
        whereArgs: [seId],
      )).first,
    );
    expect(se.exerciseKey, '杠铃卧推');

    // 老组行回默认：RIR 视为已记录、无疼痛描述
    final oldSet = SetEntry.fromMap(
      (await db.query('sets', where: 'id = ?', whereArgs: [setId])).first,
    );
    expect(oldSet.rirRecorded, isTrue);
    expect(oldSet.painLevel, 0);
    expect(oldSet.painArea, '');

    // 新组行不传三列 → 列默认；新动作行 exercise_key 默认 ''
    final newSetId = await db.insert('sets', {
      'session_exercise_id': seId,
      'weight_kg': 62.5,
      'reps': 8,
      'rir': 2,
      'kind': 'working',
      'done_at': 2000,
    });
    final newSet = SetEntry.fromMap(
      (await db.query('sets', where: 'id = ?', whereArgs: [newSetId])).first,
    );
    expect(newSet.rirRecorded, isTrue);
    expect(newSet.painLevel, 0);
    expect(newSet.painArea, '');
    final newPeId = await db.insert('plan_exercises', {
      'day_id': 1,
      'name': '上斜哑铃卧推',
      'order_idx': 1,
      'rule': '{}',
    });
    final newPlan = PlanExercise.fromMap(
      (await db.query(
        'plan_exercises',
        where: 'id = ?',
        whereArgs: [newPeId],
      )).first,
    );
    expect(newPlan.exerciseKey, '');

    // exercise_notes 可写可读，省略列走默认
    await db.insert('exercise_notes', {'exercise_key': 'barbell_bench_press'});
    await db.insert('exercise_notes', {
      'exercise_key': '杠铃卧推',
      'setup_note': '肩胛收紧',
      'updated_at': 1234,
    });
    final notes = await db.query('exercise_notes', orderBy: 'exercise_key');
    final byKey = {for (final n in notes) n['exercise_key']: n};
    final bare = ExerciseNote.fromMap(
      byKey['barbell_bench_press'] as Map<String, Object?>,
    );
    expect(bare.setupNote, '');
    expect(bare.updatedAt, 0);
    final filled = ExerciseNote.fromMap(byKey['杠铃卧推'] as Map<String, Object?>);
    expect(filled.setupNote, '肩胛收紧');
    expect(filled.updatedAt, 1234);

    // 模型 toMap 带齐 v15 键（新写入口径与 schema 对齐）
    final setMap = SetEntry(
      sessionExerciseId: 1,
      weightKg: 60,
      reps: 8,
      kind: SetKind.working,
      doneAt: 1000,
      rirRecorded: false,
      painLevel: 2,
      painArea: '肩',
    ).toMap();
    expect(setMap['rir_recorded'], 0);
    expect(setMap['pain_level'], 2);
    expect(setMap['pain_area'], '肩');
    expect(
      const ExerciseNote(
        exerciseKey: 'k',
        setupNote: 'n',
        updatedAt: 1,
      ).toMap(),
      {'exercise_key': 'k', 'setup_note': 'n', 'updated_at': 1},
    );
    await db.close();
  });

  test('v15→v16 迁移：exercise_key 按别名归一、定制键保留、索引建立', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db); // v16 结构（v15 与 v16 列相同）

    // 模拟 v15 的行：迁移把 exercise_key 回填成了 name。
    final peAlias = await db.insert('plan_exercises', {
      'day_id': 1,
      'name': '平板卧推',
      'order_idx': 0,
      'rule': '{}',
      'exercise_key': '平板卧推',
    });
    final seAlias = await db.insert('session_exercises', {
      'session_id': 1,
      'name': 'Bench Press',
      'order_idx': 0,
      'rule': '{}',
      'exercise_key': 'Bench Press',
    });
    final seEmpty = await db.insert('session_exercises', {
      'session_id': 1,
      'name': ' 我的 自创-动作 ',
      'order_idx': 1,
      'rule': '{}',
      'exercise_key': '',
    });
    final seCustom = await db.insert('session_exercises', {
      'session_id': 1,
      'name': '杠铃深蹲',
      'order_idx': 2,
      'rule': '{}',
      'exercise_key': 'custom_squat',
    });
    // v15 备注按名字写 key；两个同义名最终要并到同一个稳定键。
    await db.insert('exercise_notes', {
      'exercise_key': '平板卧推',
      'setup_note': '中文旧备注',
      'updated_at': 100,
    });
    await db.insert('exercise_notes', {
      'exercise_key': 'Bench Press',
      'setup_note': '英文较新备注',
      'updated_at': 200,
    });
    await db.insert('exercise_notes', {
      'exercise_key': 'bench press',
      'setup_note': '英文小写备注',
      'updated_at': 150,
    });
    await db.insert('exercise_notes', {
      'exercise_key': 'custom_note',
      'setup_note': '定制键备注',
      'updated_at': 300,
    });
    // 动作已不在计划/会话表里，但旧键是别名：也要按别名归一
    await db.insert('exercise_notes', {
      'exercise_key': 'Leg Press',
      'setup_note': '孤立别名备注',
      'updated_at': 50,
    });

    await Db.instance.upgradeV15to16(db);

    Future<String> keyOf(String table, int id) async =>
        (await db.query(
              table,
              columns: ['exercise_key'],
              where: 'id = ?',
              whereArgs: [id],
            )).first['exercise_key']
            as String;
    expect(
      await keyOf('plan_exercises', peAlias),
      '杠铃卧推',
      reason: '中文别名归一到规范名',
    );
    expect(
      await keyOf('session_exercises', seAlias),
      '杠铃卧推',
      reason: '英文别名/大小写同样归一',
    );
    expect(
      await keyOf('session_exercises', seEmpty),
      '我的自创动作',
      reason: '空键按名字去空白/标点补上',
    );
    expect(
      await keyOf('session_exercises', seCustom),
      'custom_squat',
      reason: '显式定制键不能覆盖',
    );

    // 备注：两个同义名的旧 key 并到规范键，冲突取 updated_at 较新的一条；
    // 非动作名的定制键原样保留。
    var notes = await db.query('exercise_notes', orderBy: 'exercise_key');
    var noteByKey = {for (final n in notes) n['exercise_key']: n};
    expect(noteByKey.containsKey('平板卧推'), isFalse);
    expect(noteByKey.containsKey('Bench Press'), isFalse);
    expect(noteByKey['杠铃卧推'], isNotNull);
    expect((noteByKey['杠铃卧推'] as Map)['setup_note'], '英文较新备注');
    expect((noteByKey['custom_note'] as Map)['setup_note'], '定制键备注');
    expect(
      (noteByKey['腿举倒蹬机'] as Map)['setup_note'],
      '孤立别名备注',
      reason: '没有动作行时，别名键也要按别名归一',
    );

    // 幂等：再跑一次不改任何已归一/定制键
    await Db.instance.upgradeV15to16(db);
    expect(await keyOf('plan_exercises', peAlias), '杠铃卧推');
    expect(await keyOf('session_exercises', seCustom), 'custom_squat');
    notes = await db.query('exercise_notes', orderBy: 'exercise_key');
    noteByKey = {for (final n in notes) n['exercise_key']: n};
    expect(noteByKey['杠铃卧推'], isNotNull);
    expect((noteByKey['杠铃卧推'] as Map)['setup_note'], '英文较新备注');

    final idx = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_se_exercise_key'",
    );
    expect(idx, isNotEmpty, reason: '纵向查询按 exercise_key 过滤，需要索引');
    await db.close();
  });

  test('v15→v16 迁移：自建键 barbell_bench_press 行与备注都原样保留', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db); // v16 结构（v15 与 v16 列相同）

    // AI 导入/外部同步留下的自建键：名字是普通英文名（按别名表会归一成
    // 「杠铃卧推」），键是机生下划线键 `barbell_bench_press`。
    final peId = await db.insert('plan_exercises', {
      'day_id': 1,
      'name': 'Barbell Bench Press',
      'order_idx': 0,
      'rule': '{}',
      'exercise_key': 'barbell_bench_press',
    });
    final seId = await db.insert('session_exercises', {
      'session_id': 1,
      'name': 'Barbell Bench Press',
      'order_idx': 0,
      'rule': '{}',
      'exercise_key': 'barbell_bench_press',
    });
    // 按自建键写的备注（较新）：必须原地不动，不能被归一到「杠铃卧推」。
    await db.insert('exercise_notes', {
      'exercise_key': 'barbell_bench_press',
      'setup_note': '自建键备注',
      'updated_at': 200,
    });
    // 按名字写的备注（较旧）：要迁到行上已有的自建键，而不是别名规范键。
    await db.insert('exercise_notes', {
      'exercise_key': 'Barbell Bench Press',
      'setup_note': '按名字写的备注',
      'updated_at': 100,
    });

    await Db.instance.upgradeV15to16(db);

    Future<String> keyOf(String table, int id) async =>
        (await db.query(
          table,
          columns: ['exercise_key'],
          where: 'id = ?',
          whereArgs: [id],
        )).first['exercise_key'] as String;
    // 断言 exercise_key 本身，不只看备注内容。
    expect(
      await keyOf('plan_exercises', peId),
      'barbell_bench_press',
      reason: '显式自建键升级后原样保留（虽然名字归一会撞上 barbell bench press 别名）',
    );
    expect(
      await keyOf('session_exercises', seId),
      'barbell_bench_press',
      reason: '显式自建键升级后原样保留',
    );

    final notes = await db.query('exercise_notes', orderBy: 'exercise_key');
    final noteByKey = {for (final n in notes) n['exercise_key']: n};
    expect(noteByKey['杠铃卧推'], isNull,
        reason: '备注不能被归一到别名规范键，否则与自建键的行失联');
    expect(noteByKey.containsKey('Barbell Bench Press'), isFalse,
        reason: '按名字写的备注迁到行上已有的自建键（nameToKey 以行上键为准）');
    expect((noteByKey['barbell_bench_press'] as Map)['setup_note'], '自建键备注',
        reason: '同键冲突取 updated_at 较新的一条（200 > 100）');
    await db.close();
  });

  test('restoreAll：自建键 barbell_bench_press 的行与备注都原样保留', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    final wrapper = Db.forTesting(db);
    await wrapper.restoreAll({
      'plans': [
        {'id': 1, 'name': 'P', 'source': 'preset', 'created_at': '2026-01-01'},
      ],
      'plan_days': [
        {'id': 1, 'plan_id': 1, 'weekday': 1, 'title': '推日'},
      ],
      'sessions': [
        {
          'id': 3,
          'date': '2026-09-01',
          'plan_day_title': '推日',
          'started_at': 1000,
          'ended_at': 2000,
          'status': 'done',
        },
      ],
      'session_exercises': [
        {
          'id': 7,
          'session_id': 3,
          'name': 'Barbell Bench Press',
          'order_idx': 0,
          'kind': 'compound',
          'rest_sec': 120,
          'rule': '{}',
          'trace': '',
          'exercise_key': 'barbell_bench_press',
        },
      ],
      'exercise_notes': [
        {
          'exercise_key': 'barbell_bench_press',
          'setup_note': '自建键备注',
          'updated_at': 100,
        },
        {
          'exercise_key': '杠铃卧推',
          'setup_note': '规范键另有一条',
          'updated_at': 50,
        },
      ],
    });

    // 断言 exercise_key 本身，不只看备注内容。
    final ses = await wrapper.sessionExercises(3);
    expect(ses.single.exerciseKey, 'barbell_bench_press',
        reason: '备份里的显式自建键恢复后原样保留');
    final notes = await db.query('exercise_notes', orderBy: 'exercise_key');
    final noteByKey = {for (final n in notes) n['exercise_key']: n};
    expect(noteByKey, hasLength(2));
    expect((noteByKey['barbell_bench_press'] as Map)['setup_note'], '自建键备注',
        reason: '自建键备注不能被恢复流程归一到别名规范键');
    expect((noteByKey['杠铃卧推'] as Map)['setup_note'], '规范键另有一条');
    await db.close();
  });

  test('v16→v17 迁移：plans 增 activated_at 列，存量行默认空串', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    // 模拟 v16 库：建全套新 schema 后，把 plans 换回没有 activated_at 的旧结构
    await Db.instance.createSchema(db);
    await db.execute('PRAGMA foreign_keys = OFF');
    await db.execute('DROP TABLE plans');
    await db.execute('''
      CREATE TABLE plans(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        source TEXT NOT NULL,
        created_at TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        pattern TEXT NOT NULL DEFAULT 'weekly',
        pattern_start TEXT NOT NULL DEFAULT '',
        cycle_train INTEGER NOT NULL DEFAULT 0,
        cycle_rest INTEGER NOT NULL DEFAULT 0,
        shift_days INTEGER NOT NULL DEFAULT 0,
        shift_from TEXT NOT NULL DEFAULT ''
      )''');
    await db.execute('PRAGMA foreign_keys = ON');
    final planId = await db.insert('plans', {
      'name': '老计划',
      'source': 'preset',
      'created_at': '2026-09-01',
    });

    // 生产路径同款迁移
    await Db.instance.upgradeV16to17(db);

    final cols = [
      for (final c in await db.rawQuery('PRAGMA table_info(plans)'))
        c['name'] as String,
    ];
    expect(cols, contains('activated_at'));
    final plan = Plan.fromMap(
      (await db.query('plans', where: 'id=?', whereArgs: [planId])).single,
    );
    expect(plan.activatedAt, '', reason: '存量行默认空串，页面回退 createdAt');
    await db.close();
  });

  test('回收站恢复 v15 快照：exercise_key 按别名归一', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    final wrapper = Db.forTesting(db);
    final plan = await wrapper.insertPlan(
      Plan(name: '老计划', source: 'manual', createdAt: '2026-10-17'),
    );
    final dayId = await wrapper.insertPlanDay(
      PlanDay(planId: plan.id!, weekday: 1, title: '推日'),
    );
    // 直接写 v15 形状的行：键 = 名字（同义名）
    await db.insert('plan_exercises', {
      'day_id': dayId,
      'name': '平板卧推',
      'order_idx': 0,
      'rule': '{}',
      'exercise_key': '平板卧推',
    });
    await wrapper.snapshotAndDeletePlan(plan.id!);
    final restoredId = await wrapper.restoreDeletedPlan(
      (await db.query('deleted_plans')).single['id'] as int,
    );
    expect(restoredId, isNotNull);
    final days = await wrapper.planDays(restoredId!);
    final ex = (await wrapper.dayExercises(days.single.id!)).single;
    expect(ex.exerciseKey, '杠铃卧推', reason: '回收站里的 v15 快照恢复后也要用稳定键');
    await db.close();
  });

  test('全新库 createSchema 含 v15 预留列与 exercise_notes', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    Future<List<String>> colsOf(String t) async => [
      for (final c in await db.rawQuery('PRAGMA table_info($t)'))
        c['name'] as String,
    ];
    expect(Db.schemaVersion, 17, reason: 'openDatabase 用的版本号');
    expect(
      await colsOf('sets'),
      containsAll(['duration_sec', 'rir_recorded', 'pain_level', 'pain_area']),
    );
    expect(
      await colsOf('plan_exercises'),
      containsAll(['logging', 'load_type', 'exercise_key']),
    );
    expect(
      await colsOf('session_exercises'),
      containsAll(['logging', 'load_type', 'exercise_key']),
    );
    expect(
      await colsOf('exercise_notes'),
      containsAll(['exercise_key', 'setup_note', 'updated_at']),
    );
    expect(
      await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_se_exercise_key'",
      ),
      isNotEmpty,
      reason: 'fresh 库也要有纵向查询用的 exercise_key 索引',
    );

    // fresh 库的列默认值与 v14→v15 升级后一致
    await db.insert('session_exercises', {
      'session_id': 1,
      'name': '深蹲',
      'order_idx': 0,
      'rule': '{}',
    });
    final setId = await db.insert('sets', {
      'session_exercise_id': 1,
      'weight_kg': 100.0,
      'reps': 5,
      'rir': 2,
      'kind': 'working',
      'done_at': 1000,
    });
    final set = SetEntry.fromMap(
      (await db.query('sets', where: 'id = ?', whereArgs: [setId])).first,
    );
    expect(set.rirRecorded, isTrue);
    expect(set.painLevel, 0);
    expect(set.painArea, '');
    final peId = await db.insert('plan_exercises', {
      'day_id': 1,
      'name': '深蹲',
      'order_idx': 0,
      'rule': '{}',
    });
    final pe = PlanExercise.fromMap(
      (await db.query(
        'plan_exercises',
        where: 'id = ?',
        whereArgs: [peId],
      )).first,
    );
    expect(pe.exerciseKey, '');
    final se = SessionExercise.fromMap(
      (await db.query('session_exercises', where: 'session_id = 1')).first,
    );
    expect(se.exerciseKey, '');

    // 备注表可写可读（主键 update 覆盖）
    await db.insert('exercise_notes', {
      'exercise_key': 'squat',
      'setup_note': '膝盖对准脚尖',
      'updated_at': 100,
    });
    final note = ExerciseNote.fromMap(
      (await db.query(
        'exercise_notes',
        where: 'exercise_key = ?',
        whereArgs: ['squat'],
      )).first,
    );
    expect(note.setupNote, '膝盖对准脚尖');
    expect(note.updatedAt, 100);
    await db.close();
  });

  test('restoreAll 兼容老备份（v15 键缺失回默认，不丢行）', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    final wrapper = Db.forTesting(db);
    await wrapper.restoreAll({
      'plans': [
        {
          'id': 1,
          'name': '老计划',
          'source': 'preset',
          'created_at': '2026-01-01',
        },
      ],
      'plan_days': [
        {'id': 1, 'plan_id': 1, 'weekday': 1, 'title': '推日'},
      ],
      'plan_exercises': [
        {
          'id': 1,
          'day_id': 1,
          'name': '杠铃卧推',
          'order_idx': 0,
          'rule': '{}',
          // 无 exercise_key（v14 及更早版本导出的备份行）
        },
      ],
      'sessions': [
        {
          'id': 3,
          'date': '2026-09-01',
          'plan_day_title': '推日',
          'started_at': 1000,
          'ended_at': 2000,
          'status': 'done',
        },
      ],
      'session_exercises': [
        {
          'id': 7,
          'session_id': 3,
          'name': '杠铃卧推',
          'order_idx': 0,
          'kind': 'compound',
          'rest_sec': 120,
          'rule': '{}',
          'trace': '',
          // 无 exercise_key
        },
      ],
      'sets': [
        {
          'id': 9,
          'session_exercise_id': 7,
          'weight_kg': 60.0,
          'reps': 8,
          'rir': 2,
          'kind': 'working',
          'done_at': 1500,
          // 无 rir_recorded / pain_level / pain_area
        },
      ],
      'exercise_notes': [
        {'exercise_key': '平板卧推', 'setup_note': '中文旧别名备注', 'updated_at': 100},
        {
          'exercise_key': 'bench press',
          'setup_note': '英文小写较新备注',
          'updated_at': 200,
        },
        {
          'exercise_key': 'custom_note',
          'setup_note': '定制键备注',
          'updated_at': 300,
        },
      ],
    });
    final planEx = (await wrapper.dayExercises(1)).single;
    expect(planEx.exerciseKey, '杠铃卧推', reason: 'v16：老备份缺键按名字补稳定键');
    final ses = await wrapper.sessionExercises(3);
    expect(ses.single.exerciseKey, '杠铃卧推', reason: 'v16：老备份缺键按名字补稳定键');
    final set = (await wrapper.setsOfExercise(7)).single;
    expect(set.rirRecorded, isTrue, reason: '缺键回默认已记录');
    expect(set.painLevel, 0);
    expect(set.painArea, '');
    // 备注：旧别名/大小写差异按稳定键归一，冲突取较新一条；定制键保留
    final notes = await db.query('exercise_notes', orderBy: 'exercise_key');
    final noteByKey = {for (final n in notes) n['exercise_key']: n};
    expect(noteByKey['杠铃卧推'], isNotNull);
    expect((noteByKey['杠铃卧推'] as Map)['setup_note'], '英文小写较新备注');
    expect(noteByKey.containsKey('平板卧推'), isFalse);
    expect(noteByKey.containsKey('bench press'), isFalse);
    expect((noteByKey['custom_note'] as Map)['setup_note'], '定制键备注');
    await db.close();
  });

  test('v15 新字段与 exercise_notes 导出-恢复往返', () async {
    final db = await databaseFactory.openDatabase(dbPath);
    await Db.instance.createSchema(db);
    final wrapper = Db.forTesting(db);
    final plan = await wrapper.insertPlan(
      Plan(name: 'v15 计划', source: 'manual', createdAt: '2026-10-17'),
    );
    final dayId = await wrapper.insertPlanDay(
      PlanDay(planId: plan.id!, weekday: 1, title: '推日'),
    );
    await wrapper.insertPlanExercise(
      PlanExercise(
        dayId: dayId,
        name: '杠铃卧推',
        orderIdx: 0,
        sets: 3,
        repsMin: 5,
        repsMax: 8,
        restSec: 120,
        kind: 'compound',
        rule: ProgressionRule.fallback,
        exerciseKey: 'barbell_bench_press',
      ),
    );
    final s = await wrapper.insertSession(
      Session(
        date: '2026-10-17',
        planDayTitle: '推日',
        startedAt: 1000,
        endedAt: 2000,
        status: 'done',
      ),
    );
    final seId = await wrapper.insertSessionExercise(
      SessionExercise(
        sessionId: s.id!,
        name: '杠铃卧推',
        orderIdx: 0,
        kind: 'compound',
        restSec: 120,
        rule: ProgressionRule.fallback,
        exerciseKey: 'barbell_bench_press',
      ),
    );
    await wrapper.insertSet(
      SetEntry(
        sessionExerciseId: seId,
        weightKg: 60,
        reps: 8,
        kind: SetKind.working,
        doneAt: 1500,
        rirRecorded: false,
        painLevel: 2,
        painArea: '肩',
      ),
    );
    await db.insert(
      'exercise_notes',
      const ExerciseNote(
        exerciseKey: 'barbell_bench_press',
        setupNote: '肩胛收紧',
        updatedAt: 1234,
      ).toMap(),
    );

    // 先确认新值本身能落库读回（尤其 rir_recorded=0 不被默认值吞掉）
    final before = (await wrapper.setsOfExercise(seId)).single;
    expect(before.rirRecorded, isFalse);
    expect(before.painLevel, 2);
    expect(before.painArea, '肩');

    final data = await wrapper.exportAllJson();
    expect((data['exercise_notes'] as List).length, 1);
    await wrapper.wipeAll();
    expect(
      await db.query('exercise_notes'),
      isEmpty,
      reason: 'wipeAll 连动作备注一起清',
    );
    await wrapper.restoreAll(data);

    final planEx = (await wrapper.dayExercises(dayId)).single;
    expect(planEx.exerciseKey, 'barbell_bench_press');
    final se = (await wrapper.sessionExercises(s.id!)).single;
    expect(se.exerciseKey, 'barbell_bench_press');
    final set = (await wrapper.setsOfExercise(se.id!)).single;
    expect(set.rirRecorded, isFalse, reason: '0 落库再读回');
    expect(set.painLevel, 2);
    expect(set.painArea, '肩');
    final note = ExerciseNote.fromMap(
      (await db.query('exercise_notes')).single,
    );
    expect(note.setupNote, '肩胛收紧');
    expect(note.updatedAt, 1234);
    await db.close();
  });

  test('真实 openDatabase(v14→v17)：_onUpgrade 分发到 v15/v16/v17 并回填', () async {
    final dir = await databaseFactory.getDatabasesPath();
    // 独立路径：不碰其它测试共用的 baoji_timer.db（并行跑会互删/锁库）
    final prodPath = p.join(
      dir,
      'mig_real_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    await databaseFactory.deleteDatabase(prodPath);

    // 造一个 user_version=14 的库：先按现行 schema 建表，再把 v15 增量拆掉
    final v14 = await databaseFactory.openDatabase(
      prodPath,
      options: OpenDatabaseOptions(
        version: 14,
        onCreate: (db, v) => Db.instance.createSchema(db),
      ),
    );
    await v14.execute('PRAGMA foreign_keys = OFF');
    await v14.execute('DROP TABLE sets');
    await v14.execute('DROP TABLE session_exercises');
    await v14.execute('DROP TABLE plan_exercises');
    await v14.execute('DROP TABLE exercise_notes');
    // plans 也换回 v14 结构（没有 v17 的 activated_at）
    await v14.execute('DROP TABLE plans');
    await v14.execute('''
      CREATE TABLE plans(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        source TEXT NOT NULL,
        created_at TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        pattern TEXT NOT NULL DEFAULT 'weekly',
        pattern_start TEXT NOT NULL DEFAULT '',
        cycle_train INTEGER NOT NULL DEFAULT 0,
        cycle_rest INTEGER NOT NULL DEFAULT 0,
        shift_days INTEGER NOT NULL DEFAULT 0,
        shift_from TEXT NOT NULL DEFAULT ''
      )''');
    await createV14Tables(v14);
    await v14.insert('plans', {
      'id': 1,
      'name': '老计划',
      'source': 'preset',
      'created_at': '2026-01-01',
    });
    await v14.insert('plan_days', {
      'id': 1,
      'plan_id': 1,
      'weekday': 1,
      'title': '推日',
    });
    await v14.insert('sessions', {
      'id': 1,
      'date': '2026-09-01',
      'plan_day_title': '推日',
      'started_at': 1000,
      'status': 'done',
    });
    // 用同义名当老名字：v15 先回填 name，v16 再归一到规范键，
    // 一次走通真实升级链路（不是只验证版本号）。
    final peId = await v14.insert('plan_exercises', {
      'day_id': 1,
      'name': '平板卧推',
      'order_idx': 0,
      'rule': '{}',
    });
    final seId = await v14.insert('session_exercises', {
      'session_id': 1,
      'name': '平板卧推',
      'order_idx': 0,
      'rule': '{}',
    });
    await v14.insert('sets', {
      'session_exercise_id': seId,
      'weight_kg': 60.0,
      'reps': 8,
      'rir': 2,
      'kind': 'working',
      'done_at': 1000,
    });
    await v14.execute('PRAGMA foreign_keys = ON');
    expect(await v14.getVersion(), 14);
    await v14.close();

    // 生产同款打开选项：version=Db.schemaVersion，由 _onUpgrade(14, 17)
    // 分发 v15/v16/v17；独立路径避免污染 Db.instance 的单例缓存。
    final db = await Db.instance.openWithProductionOptions(prodPath);
    try {
      expect(await db.getVersion(), 17);
      final planCols = [
        for (final c in await db.rawQuery('PRAGMA table_info(plans)'))
          c['name'] as String,
      ];
      expect(planCols, contains('activated_at'));
      final setCols = [
        for (final c in await db.rawQuery('PRAGMA table_info(sets)'))
          c['name'] as String,
      ];
      expect(setCols, containsAll(['rir_recorded', 'pain_level', 'pain_area']));
      final plan = PlanExercise.fromMap(
        (await db.query(
          'plan_exercises',
          where: 'id = ?',
          whereArgs: [peId],
        )).first,
      );
      expect(plan.exerciseKey, '杠铃卧推');
      final se = SessionExercise.fromMap(
        (await db.query(
          'session_exercises',
          where: 'id = ?',
          whereArgs: [seId],
        )).first,
      );
      expect(se.exerciseKey, '杠铃卧推');
      final set = SetEntry.fromMap((await db.query('sets')).single);
      expect(set.rirRecorded, isTrue);
      expect(set.painLevel, 0);
      expect(set.painArea, '');
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='exercise_notes'",
        ),
        isNotEmpty,
      );
    } finally {
      await db.close();
      await databaseFactory.deleteDatabase(prodPath);
    }
  });
}
