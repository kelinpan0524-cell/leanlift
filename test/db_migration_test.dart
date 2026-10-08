// schema v5→v6 迁移测试（调研条目 14）：老库平滑升级、老数据回退语义、
// 全新库建表含新列、老备份恢复兼容，以及统计过滤纪律的 SQL 锁定
// （active/quit 会话不进任何聚合查询）。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/models/models.dart';
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
  await db.execute(
      'CREATE INDEX idx_sets_se ON sets(session_exercise_id)');
  await db.execute(
      'CREATE INDEX idx_se_name ON session_exercises(name)');
  await db.execute(
      'CREATE INDEX idx_se_session ON session_exercises(session_id)');
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
}
