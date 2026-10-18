// 丢历史重量 bug 复现（2026-10-18 Arono 报障：杠铃划船上次练过，升级
// b173 后开练变回 20kg 默认）。两个场景：
// 1. fresh v17 库：老历史 + 计划行 → 开练应拿到 ~60kg 档；
// 2. 真实 v14 库（b171 时代 DDL，无 exercise_key 列）+ 老历史/计划行
//    → openWithProductionOptions 走 v14→v17 真迁移 → 同样断言。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/services/session_controller.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// b171（DB v14）时代的真实建表语句（git show b171:lib/db/db.dart）。
const _v14Ddl = [
  '''
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
  )''',
  '''
  CREATE TABLE plan_days(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    plan_id INTEGER NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
    weekday INTEGER NOT NULL,
    title TEXT NOT NULL,
    notes TEXT NOT NULL DEFAULT ''
  )''',
  '''
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
    rule TEXT NOT NULL DEFAULT '{}',
    logging TEXT NOT NULL DEFAULT 'reps',
    load_type TEXT NOT NULL DEFAULT 'weighted',
    superset_tag TEXT NOT NULL DEFAULT ''
  )''',
  '''
  CREATE TABLE exercise_meta(
    name TEXT PRIMARY KEY,
    main_muscle TEXT NOT NULL,
    secondary TEXT NOT NULL DEFAULT '',
    is_compound INTEGER NOT NULL DEFAULT 0,
    equipment TEXT NOT NULL DEFAULT 'both',
    gear TEXT NOT NULL DEFAULT ''
  )''',
  '''
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
    active_ms INTEGER NOT NULL DEFAULT 0,
    impression INTEGER
  )''',
  '''
  CREATE TABLE session_exercises(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
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
  )''',
  '''
  CREATE TABLE sets(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_exercise_id INTEGER NOT NULL
      REFERENCES session_exercises(id) ON DELETE CASCADE,
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
  )''',
  'CREATE INDEX idx_sets_se ON sets(session_exercise_id)',
  'CREATE INDEX idx_se_name ON session_exercises(name)',
  'CREATE INDEX idx_se_session ON session_exercises(session_id)',
  'CREATE INDEX idx_sessions_date ON sessions(date)',
  '''
  CREATE TABLE body_metrics(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    date TEXT NOT NULL UNIQUE,
    weight_kg REAL,
    waist_cm REAL,
    bodyfat_pct REAL
  )''',
  '''
  CREATE TABLE lark_sync(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ref_type TEXT NOT NULL,
    ref_id INTEGER NOT NULL,
    lark_event_id TEXT NOT NULL,
    event_date TEXT NOT NULL,
    synced_at INTEGER NOT NULL,
    summary TEXT NOT NULL DEFAULT ''
  )''',
  '''
  CREATE TABLE plan_schedule(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    plan_id INTEGER NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
    date TEXT NOT NULL,
    day_id INTEGER REFERENCES plan_days(id) ON DELETE CASCADE,
    UNIQUE(plan_id, date)
  )''',
  '''
  CREATE TABLE deleted_plans(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    snapshot TEXT NOT NULL,
    deleted_at TEXT NOT NULL
  )''',
  '''
  CREATE TABLE hr_sample(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    ts INTEGER NOT NULL,
    bpm INTEGER NOT NULL
  )''',
  'CREATE INDEX idx_hr_session ON hr_sample(session_id)',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final pigeonNullReply = ByteData(3)
      ..setUint8(0, 12)
      ..setUint8(1, 1)
      ..setUint8(2, 0);
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (data) async => pigeonNullReply,
    );
  });

  /// 在 [rawDb] 里造 b171 时代的数据：2 天前一场 done 训练，
  /// 杠铃划船 4 组 × 60kg 正式组；激活计划 + 背日 + 杠铃划船 4 组。
  Future<void> seedLegacyRowData(Database rawDb) async {
    final now = DateTime.now();
    final date = fmtDate(now.subtract(const Duration(days: 2)));
    final startedAt =
        now.subtract(const Duration(days: 2)).millisecondsSinceEpoch;
    await rawDb.insert('sessions', {
      'date': date,
      'plan_day_title': '背日',
      'started_at': startedAt,
      'ended_at': startedAt + 3600000,
      'status': 'done',
    });
    final seId = await rawDb.insert('session_exercises', {
      'session_id': 1,
      'name': '杠铃划船',
      'order_idx': 0,
      'kind': 'compound',
      'rest_sec': 150,
      'rule': ruleToJson(
          const ProgressionRule(repsMin: 8, repsMax: 10, workingSets: 4)),
      'target_sets': 4,
      'target_reps_min': 8,
      'target_reps_max': 10,
    });
    for (var i = 0; i < 4; i++) {
      await rawDb.insert('sets', {
        'session_exercise_id': seId,
        'weight_kg': 60.0,
        'reps': 8,
        'rir': 2,
        'kind': 'working',
        'done_at': startedAt + i * 300000,
      });
    }
    await rawDb.insert('plans', {
      'name': '薄肌计划',
      'source': 'preset',
      'created_at': '2026-09-01',
      'is_active': 1,
    });
    await rawDb
        .insert('plan_days', {'plan_id': 1, 'weekday': 2, 'title': '背日'});
    await rawDb.insert('plan_exercises', {
      'day_id': 1,
      'name': '杠铃划船',
      'order_idx': 0,
      'sets': 4,
      'reps_min': 8,
      'reps_max': 10,
      'rest_sec': 150,
      'kind': 'compound',
      'rule': ruleToJson(
          const ProgressionRule(repsMin: 8, repsMax: 10, workingSets: 4)),
    });
  }

  group('杠铃划船历史重量连续性（Arono 报障复现）', () {
    test('fresh v17：开练建议基于上次 60kg，不是 20kg 起始', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final dir = await databaseFactory.getDatabasesPath();
      final path = '$dir/wc_fresh_${DateTime.now().microsecondsSinceEpoch}.db';
      final rawDb = await databaseFactory.openDatabase(path);
      await Db.instance.createSchema(rawDb);
      await seedLegacyRowData(rawDb);
      final db = Db.forTesting(rawDb);

      final last = await db.lastWorkingSets('杠铃划船');
      expect(last, isNotEmpty, reason: 'DB 层键查询应命中上次历史');
      expect(last.first.weightKg, 60.0);

      final planExs = await db.dayExercises(1);
      final c = SessionController(db, Settings(prefs), prefs, null);
      addTearDown(c.dispose);
      await c.startFromDay(
        day: const PlanDay(id: 1, planId: 1, weekday: 2, title: '背日'),
        planExercises: planExs,
      );
      expect(c.weightDraft, greaterThan(55),
          reason: '上次 60kg×8×4 → 建议 ≈60 或 +2.5，绝不是 20kg 起始');
      await db.wipeAll();
    });

    test('键分叉（历史键≠当前键但同名）：名字兜底不丢历史', () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await databaseFactory.getDatabasesPath();
      final path = '$dir/wc_div_${DateTime.now().microsecondsSinceEpoch}.db';
      final rawDb = await databaseFactory.openDatabase(path);
      await Db.instance.createSchema(rawDb);
      await seedLegacyRowData(rawDb);
      // 模拟键分叉：历史行落在另一个键上（老备份恢复/键规则修订的产物）
      await rawDb.update('session_exercises',
          {'exercise_key': 'legacy_split_key'},
          where: "name = '杠铃划船'");
      final db = Db.forTesting(rawDb);

      final last = await db.lastWorkingSets('杠铃划船');
      expect(last, isNotEmpty, reason: '同名即同一动作：键分叉不丢历史');
      expect(last.first.weightKg, 60.0);
      expect(await db.maxWeightOf('杠铃划船'), 60.0);
      expect(await db.lastTargetSets('杠铃划船'), 4);
      await db.wipeAll();
    });

    test('真实 v14 库升级 v14→v17：老历史在新键体系下不丢', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final dir = await databaseFactory.getDatabasesPath();
      final path = '$dir/wc_v14_${DateTime.now().microsecondsSinceEpoch}.db';
      // 先按 b171 的方式把库立在 version 14：onCreate 里跑 v14 DDL，
      // 让 user_version=14，模拟真实升级起点（sqflite 对 user_version=0
      // 的库首次带 version 打开会走 onCreate 而不是 onUpgrade）。
      final oldDb = await openDatabase(
        path,
        version: 14,
        onCreate: (db, v) async {
          for (final ddl in _v14Ddl) {
            await db.execute(ddl);
          }
        },
      );
      await seedLegacyRowData(oldDb);
      await oldDb.close();

      // 生产同款选项重新打开：触发 v14→v17 真迁移
      final migrated = await Db.instance.openWithProductionOptions(path);
      final db = Db.forTesting(migrated);

      final last = await db.lastWorkingSets('杠铃划船');
      expect(last, isNotEmpty,
          reason: '迁移后 DB 层键查询必须命中老历史（别名/归一两侧一致）');
      expect(last.first.weightKg, 60.0);

      final keys = await migrated.rawQuery(
          "SELECT DISTINCT exercise_key FROM session_exercises WHERE name = '杠铃划船'");
      // ignore: avoid_print
      print('迁移后 session 行键 = $keys');
      final planKeys = await migrated.rawQuery(
          "SELECT DISTINCT exercise_key FROM plan_exercises WHERE name = '杠铃划船'");
      // ignore: avoid_print
      print('迁移后 plan 行键 = $planKeys');

      final planExs = await db.dayExercises(1);
      final c = SessionController(db, Settings(prefs), prefs, null);
      addTearDown(c.dispose);
      await c.startFromDay(
        day: const PlanDay(id: 1, planId: 1, weekday: 2, title: '背日'),
        planExercises: planExs,
      );
      expect(c.weightDraft, greaterThan(55),
          reason: '升级后开练建议必须基于上次 60kg，不能回落 20kg 起始');
    });
  });
}
