import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../engine/superset.dart';
import '../models/models.dart';

/// SQLite 本地库：唯一数据源。所有查询经 DatabaseProvider。
///
/// ## 统计过滤纪律（调研条目 14，Fast N Fitness 的教训）
///
/// 统计/渐进/PR 类查询必须显式排除「未开始行」与模板行，防止没练的
/// 数据污染曲线。本库的对应纪律（新增查询时必须遵守）：
/// - **模板行**：plans/plan_days/plan_exercises 是模板表，sets 永远只挂在
///   session_exercises 下——模板天然不进统计，无需过滤；
/// - **未开始/未完成的会话**：一切聚合查询（historySets / maxWeightOf /
///   lastWorkingSets / sessionRowsBetween / sessionsBetween /
///   recentSessions）显式限定 `sessions.status = 'done'`——进行中
///   （active）与中途放弃（quit）的会话不产生曲线数据点；
/// - **热身组**：容量/渐进统计一律 `sets.kind = 'working'`
///   （或 model 层 `SetEntry.volume` 对 warmup 记 0）；
/// - **计划目标快照**：session_exercises.target_sets / target_reps_min /
///   target_reps_max（v6 起）是"本次训练当时"的模板参数，用于完成度
///   对比；模板表本身被修改不影响老记录。
class Db {
  Db._() : _override = null;
  static final Db instance = Db._();

  /// 测试缝：注入已打开的内存库（sqflite_common_ffi）。
  @visibleForTesting
  Db.forTesting(this._override);

  final Database? _override;
  Future<Database>? _overrideFuture;

  Future<Database>? _dbFuture;

  Future<Database> get database {
    final o = _override;
    if (o != null) {
      // 与生产路径一致：开启外键（级联删除依赖它）
      return _overrideFuture ??= () async {
        await o.execute('PRAGMA foreign_keys = ON');
        return o;
      }();
    }
    final existing = _dbFuture;
    if (existing != null) return existing;
    final dir = getDatabasesPath();
    final future = dir.then((d) => openDatabase(
          p.join(d, 'baoji_timer.db'),
          // v9=超级组（superset_tag），v10=全计划顺延（plans.shift_*），
          // v11=动作库 gear，v12=加练标注（sets.is_extra）。
          version: 12,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, v) => createSchema(db),
          onUpgrade: _onUpgrade,
        ));
    // 失败自清理：首次打开瞬时失败（磁盘满/IO 抖动）后，
    // 下一次调用重新尝试打开，不让同一个 failed Future 缓存到进程结束。
    _dbFuture = future.catchError((Object e) {
      _dbFuture = null;
      throw e;
    });
    return _dbFuture!;
  }

  Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    if (oldV < 2) {
      // v2：session_exercises 增加动作级休息秒数 + 新索引
      await db.execute(
          'ALTER TABLE session_exercises ADD COLUMN rest_sec INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_se_name ON session_exercises(name)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_se_session ON session_exercises(session_id)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_sets_se ON sets(session_exercise_id)');
    }
    if (oldV < 3) {
      // v3：动作库加器械场景（gym/home/both）
      await db.execute(
          "ALTER TABLE exercise_meta ADD COLUMN equipment TEXT NOT NULL DEFAULT 'both'");
    }
    if (oldV < 4) {
      // v4：日期化排程——plans 加循环模式参数；plan_schedule 存手动改期覆盖行；
      // sessions 记录训练/休息净时长
      await db.execute(
          "ALTER TABLE plans ADD COLUMN pattern TEXT NOT NULL DEFAULT 'weekly'");
      await db.execute(
          "ALTER TABLE plans ADD COLUMN pattern_start TEXT NOT NULL DEFAULT ''");
      await db.execute(
          'ALTER TABLE plans ADD COLUMN cycle_train INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE plans ADD COLUMN cycle_rest INTEGER NOT NULL DEFAULT 0');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS plan_schedule(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          plan_id INTEGER NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
          date TEXT NOT NULL,
          day_id INTEGER REFERENCES plan_days(id) ON DELETE CASCADE,
          UNIQUE(plan_id, date)
        )''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_sched_date ON plan_schedule(date)');
      await db.execute(
          'ALTER TABLE sessions ADD COLUMN rest_ms INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE sessions ADD COLUMN active_ms INTEGER NOT NULL DEFAULT 0');
    }
    if (oldV < 5) {
      // v5：会话动作行保留临时替换/追加痕迹（点名条目三）：
      // ''=计划原样；'替换自：X'/'追加于：Y' 便于历史与统计追溯。
      await db.execute(
          "ALTER TABLE session_exercises ADD COLUMN trace TEXT NOT NULL DEFAULT ''");
    }
    if (oldV < 6) {
      await upgradeV5to6(db);
    }
    if (oldV < 7) {
      await upgradeV6to7(db);
    }
    if (oldV < 8) {
      await upgradeV7to8(db);
    }
    if (oldV < 9) {
      await upgradeV8to9(db);
    }
    if (oldV < 10) {
      await upgradeV9to10(db);
    }
    if (oldV < 11) {
      await upgradeV10to11(db);
    }
    if (oldV < 12) {
      await upgradeV11to12(db);
    }
  }

  /// v10：plans 加全计划顺延字段（shift_days / shift_from）。
  /// 纯加列，无表重建。v9 见 upgradeV8to9（超级组）。
  Future<void> upgradeV9to10(Database db) async {
    await db.execute(
        'ALTER TABLE plans ADD COLUMN shift_days INTEGER NOT NULL DEFAULT 0');
    await db.execute(
        "ALTER TABLE plans ADD COLUMN shift_from TEXT NOT NULL DEFAULT ''");
  }

  /// v11：动作库自定义管理（2026-09-29）——exercise_meta 加 gear 列，
  /// 自定义/沉淀动作可带器械分类（弹力带/哑铃/自重…），浏览页器械筛选
  /// 与 AI 词表的器械标注由此取数。DEFAULT '' 兼容老行（未标注）。
  @visibleForTesting
  Future<void> upgradeV10to11(Database db) async {
    await db.execute(
        "ALTER TABLE exercise_meta ADD COLUMN gear TEXT NOT NULL DEFAULT ''");
  }

  /// v12：加练组标注（2026-10-08）——sets 加 is_extra 列：计划内正式组
  /// 练满后继续记的组（kind=working 且落库前正式组数已 ≥ workingSets）
  /// 标 1，训练后历史页/总结页才看得出哪组是加练（修复①②之后的第三块）。
  /// 纯加列 DEFAULT 0 平滑兼容老行；老数据不回溯标注（加练身份落库时
  /// 已丢失的旧记录维持原样）。
  @visibleForTesting
  Future<void> upgradeV11to12(Database db) async {
    await db.execute(
        'ALTER TABLE sets ADD COLUMN is_extra INTEGER NOT NULL DEFAULT 0');
  }

  /// v6：计划模板目标参数快照进训练记录（调研条目 14）。
  /// 一次迁移只动 session_exercises 一层：开始训练时把模板日的
  /// 目标组数 / 目标次数区间整套快照进动作行（Fast N Fitness 的
  /// 「防程序日后修改导致老记录判定翻车」口径），模板日后怎么改
  /// 都不影响老记录的完成度对比。
  /// 老数据平滑兼容：DEFAULT 0 = 无快照，消费端回退 rule JSON 里的参数。
  @visibleForTesting
  Future<void> upgradeV5to6(Database db) async {
    await db.execute(
        'ALTER TABLE session_exercises ADD COLUMN target_sets INTEGER NOT NULL DEFAULT 0');
    await db.execute(
        'ALTER TABLE session_exercises ADD COLUMN target_reps_min INTEGER NOT NULL DEFAULT 0');
    await db.execute(
        'ALTER TABLE session_exercises ADD COLUMN target_reps_max INTEGER NOT NULL DEFAULT 0');
  }

  /// v7：计划删除快照回收站（2026-09-26 Arono：删除的计划保留 7 天可恢复）。
  /// 删除计划时整套快照（计划行+训练日+动作+排程覆盖行）进 deleted_plans，
  /// 恢复时重建为新 id 的计划；过期（7 天）由调用方惰性清除。
  @visibleForTesting
  Future<void> upgradeV6to7(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS deleted_plans(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        snapshot TEXT NOT NULL,
        deleted_at TEXT NOT NULL
      )''');
  }

  /// v8：wger 借鉴两条（2026-09-27）——
  /// ① 组行「当时处方」快照：sets 加 target_weight_kg / target_reps（可空，
  ///   老记录 null = 无快照，消费端不展示目标对比）；
  /// ② 会话主观自评：sessions 加 impression（1=差/2=一般/3=好，null=未评）。
  @visibleForTesting
  Future<void> upgradeV7to8(Database db) async {
    await db.execute('ALTER TABLE sets ADD COLUMN target_weight_kg REAL');
    await db.execute('ALTER TABLE sets ADD COLUMN target_reps INTEGER');
    await db.execute('ALTER TABLE sessions ADD COLUMN impression INTEGER');
  }

  /// v9：超级组（2026-09-29）——计划动作行与会话动作快照行各加
  /// superset_tag（'' = 不配对；同 tag 且日内相邻 = 一个超级组，训练时
  /// 轮转交替）。带 DEFAULT ''，回收站快照/导出导入的老行缺列可安全落库。
  @visibleForTesting
  Future<void> upgradeV8to9(Database db) async {
    await db.execute(
        "ALTER TABLE plan_exercises ADD COLUMN superset_tag TEXT NOT NULL DEFAULT ''");
    await db.execute(
        "ALTER TABLE session_exercises ADD COLUMN superset_tag TEXT NOT NULL DEFAULT ''");
  }

  /// 建表（onCreate 与单元测试共用）。
  @visibleForTesting
  Future<void> createSchema(Database db) async => _onCreate(db, 1);

  Future<void> _onCreate(Database db, int v) async {
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
        rule TEXT NOT NULL DEFAULT '{}',
        superset_tag TEXT NOT NULL DEFAULT ''
      )''');
    await db.execute('''
      CREATE TABLE exercise_meta(
        name TEXT PRIMARY KEY,
        main_muscle TEXT NOT NULL,
        secondary TEXT NOT NULL DEFAULT '',
        is_compound INTEGER NOT NULL DEFAULT 0,
        equipment TEXT NOT NULL DEFAULT 'both',
        gear TEXT NOT NULL DEFAULT ''
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
        active_ms INTEGER NOT NULL DEFAULT 0,
        impression INTEGER
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
        target_sets INTEGER NOT NULL DEFAULT 0,
        target_reps_min INTEGER NOT NULL DEFAULT 0,
        target_reps_max INTEGER NOT NULL DEFAULT 0,
        trace TEXT NOT NULL DEFAULT '',
        superset_tag TEXT NOT NULL DEFAULT ''
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
        note TEXT NOT NULL DEFAULT '',
        target_weight_kg REAL,
        target_reps INTEGER,
        is_extra INTEGER NOT NULL DEFAULT 0
      )''');
    await db.execute(
        'CREATE INDEX idx_sets_se ON sets(session_exercise_id)');
    await db.execute(
        'CREATE INDEX idx_se_name ON session_exercises(name)');
    await db.execute(
        'CREATE INDEX idx_se_session ON session_exercises(session_id)');
    await db.execute(
        'CREATE INDEX idx_sessions_date ON sessions(date)');
    await db.execute('''
      CREATE TABLE body_metrics(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        date TEXT NOT NULL UNIQUE,
        weight_kg REAL,
        waist_cm REAL,
        bodyfat_pct REAL
      )''');
    await db.execute('''
      CREATE TABLE lark_sync(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ref_type TEXT NOT NULL,
        ref_id INTEGER NOT NULL,
        lark_event_id TEXT NOT NULL,
        event_date TEXT NOT NULL,
        synced_at INTEGER NOT NULL,
        summary TEXT NOT NULL DEFAULT '',
        UNIQUE(ref_type, ref_id)
      )''');
    await db.execute('''
      CREATE TABLE sync_queue(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        op TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE plan_schedule(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        plan_id INTEGER NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
        date TEXT NOT NULL,
        day_id INTEGER REFERENCES plan_days(id) ON DELETE CASCADE,
        UNIQUE(plan_id, date)
      )''');
    await db.execute(
        'CREATE INDEX idx_sched_date ON plan_schedule(date)');
    await db.execute('''
      CREATE TABLE deleted_plans(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        snapshot TEXT NOT NULL,
        deleted_at TEXT NOT NULL
      )''');
  }

  // ---------- plans ----------
  Future<Plan> insertPlan(Plan plan) async {
    final db = await database;
    final id = await db.insert('plans', plan.toMap());
    return Plan.fromMap({...plan.toMap(), 'id': id});
  }

  Future<Plan?> activePlan() async {
    final db = await database;
    final rows =
        await db.query('plans', where: 'is_active=1', limit: 1);
    return rows.isEmpty ? null : Plan.fromMap(rows.first);
  }

  /// 全部计划（启用中的排最前，其余按创建时间倒序）。
  Future<List<Plan>> allPlans() async {
    final db = await database;
    final rows = await db
        .query('plans', orderBy: 'is_active DESC, id DESC');
    return rows.map(Plan.fromMap).toList();
  }

  Future<void> renamePlan(int planId, String name) async {
    final db = await database;
    await db.update('plans', {'name': name},
        where: 'id = ?', whereArgs: [planId]);
  }

  Future<void> setActivePlan(int planId) async {
    final db = await database;
    await db.transaction((tx) async {
      await tx.update('plans', {'is_active': 0});
      await tx.update('plans', {'is_active': 1},
          where: 'id = ?', whereArgs: [planId]);
    });
  }

  Future<void> deletePlan(int planId) async {
    final db = await database;
    await db.delete('plans', where: 'id = ?', whereArgs: [planId]);
  }

  /// 删除前把计划整套快照（计划行 + 训练日 + 动作 + 排程覆盖行）存进
  /// 回收站 deleted_plans，随后硬删原计划（级联清依赖）。
  /// day_id 在快照里换成 days 数组下标，恢复时按新 id 重建映射。
  Future<void> snapshotAndDeletePlan(int planId) async {
    final db = await database;
    await db.transaction((tx) async {
      final planRows =
          await tx.query('plans', where: 'id = ?', whereArgs: [planId]);
      if (planRows.isEmpty) return;
      final plan = planRows.first;
      final days = await tx.query('plan_days',
          where: 'plan_id = ?', whereArgs: [planId], orderBy: 'id ASC');
      final exRows = days.isEmpty
          ? const <Map<String, Object?>>[]
          : await tx.query(
              'plan_exercises',
              where: 'day_id IN (${days.map((d) => d['id'] as int).join(',')})',
              orderBy: 'id ASC',
            );
      final schedRows =
          await tx.query('plan_schedule', where: 'plan_id = ?', whereArgs: [planId]);
      final dayIndex = <Object?, int>{
        for (var i = 0; i < days.length; i++) days[i]['id']: i,
      };
      final snapshot = jsonEncode({
        'plan': plan,
        'days': [
          for (final d in days)
            {
              'day': d,
              'exercises': [
                for (final e in exRows) if (e['day_id'] == d['id']) e,
              ],
            }
        ],
        'schedule': [
          for (final sc in schedRows)
            {
              ...sc,
              'day_id':
                  sc['day_id'] == null ? null : dayIndex[sc['day_id']],
            }
        ],
      });
      await tx.insert('deleted_plans', {
        'name': plan['name'] as String,
        'snapshot': snapshot,
        'deleted_at': DateTime.now().toIso8601String(),
      });
      await tx.delete('plans', where: 'id = ?', whereArgs: [planId]);
    });
  }

  /// 回收站列表（最新删除在前）。
  Future<List<Map<String, Object?>>> listDeletedPlans() async {
    final db = await database;
    return db.query('deleted_plans', orderBy: 'deleted_at DESC, id DESC');
  }

  /// 从回收站恢复计划：重建为新 id（不自动启用），删除回收站行。
  /// 返回新计划 id；回收站里没有该行时返回 null。
  /// 整段在事务里：计划重建与快照行删除原子完成，中途失败整体回滚，
  /// 不会留下半截计划+回收站行还在（重试出重复计划）的组合。
  Future<int?> restoreDeletedPlan(int deletedId) async {
    final db = await database;
    return db.transaction<int?>((tx) async {
      final rows = await tx
          .query('deleted_plans', where: 'id = ?', whereArgs: [deletedId]);
      if (rows.isEmpty) return null;
      final snap =
          jsonDecode(rows.first['snapshot'] as String) as Map<String, dynamic>;
      final planMap = Map<String, dynamic>.from(snap['plan'] as Map);
      // 恢复不自动启用：删使用中计划时已有别的计划顶上，恢复的不回来抢
      planMap['id'] = null;
      planMap['is_active'] = 0;
      final newPlanId = await tx.insert('plans', planMap);
      // day_id 在快照里是 days 数组下标，按顺序收集新 id 重建映射
      final newDayIds = <int>[];
      for (final dayEntry in (snap['days'] as List)) {
        final m = Map<String, dynamic>.from(dayEntry as Map);
        final dayMap = Map<String, dynamic>.from(m['day'] as Map);
        dayMap['id'] = null;
        dayMap['plan_id'] = newPlanId;
        final newDayId = await tx.insert('plan_days', dayMap);
        newDayIds.add(newDayId);
        for (final ex in (m['exercises'] as List)) {
          final exMap = Map<String, dynamic>.from(ex as Map);
          exMap['id'] = null;
          exMap['day_id'] = newDayId;
          await tx.insert('plan_exercises', exMap);
        }
      }
      for (final sc in (snap['schedule'] as List)) {
        final m = Map<String, dynamic>.from(sc as Map);
        final idx = m['day_id'] as int?;
        await tx.insert('plan_schedule', {
          'plan_id': newPlanId,
          'date': m['date'] as String,
          // 下标越界（快照与表结构不一致）时回退为显式休息，不指错训练日
          'day_id':
              idx != null && idx >= 0 && idx < newDayIds.length ? newDayIds[idx] : null,
        });
      }
      await tx.delete('deleted_plans', where: 'id = ?', whereArgs: [deletedId]);
      return newPlanId;
    });
  }

  /// 惰性清除超过 [keepDays] 天的回收站快照（调用方在打开回收站/计划页时触发）。
  Future<void> purgeExpiredDeletedPlans({int keepDays = 7}) async {
    final db = await database;
    final cutoff =
        DateTime.now().subtract(Duration(days: keepDays)).toIso8601String();
    await db.delete('deleted_plans',
        where: 'deleted_at < ?', whereArgs: [cutoff]);
  }

  /// 更新计划任意字段（排程模式/循环参数等；调用方负责事务语义）。
  Future<void> updatePlanFields(int planId, Map<String, Object?> fields) async {
    final db = await database;
    await db.update('plans', fields, where: 'id = ?', whereArgs: [planId]);
  }

  /// 各计划训练日/动作数（切换器展示用），一次 GROUP BY 搞定。
  Future<Map<int, int>> planDayCounts() async {
    final db = await database;
    final rows = await db.rawQuery(
        'SELECT plan_id, COUNT(*) AS n FROM plan_days GROUP BY plan_id');
    return {
      for (final r in rows) (r['plan_id'] as num).toInt(): (r['n'] as num).toInt(),
    };
  }

  Future<Map<int, int>> planExerciseCounts() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT d.plan_id AS plan_id, COUNT(*) AS n
      FROM plan_exercises e
      JOIN plan_days d ON d.id = e.day_id
      GROUP BY d.plan_id
    ''');
    return {
      for (final r in rows) (r['plan_id'] as num).toInt(): (r['n'] as num).toInt(),
    };
  }

  // ---------- plan days / exercises ----------
  Future<int> insertPlanDay(PlanDay day) async =>
      (await database).insert('plan_days', day.toMap());

  /// 更新训练日（标题/星期；切换星期由调用方保证目标日空闲）。
  Future<void> updatePlanDay(PlanDay day) async {
    final db = await database;
    await db.update('plan_days', {'title': day.title, 'weekday': day.weekday},
        where: 'id = ?', whereArgs: [day.id]);
  }

  Future<void> deletePlanDay(int dayId) async {
    final db = await database;
    await db.delete('plan_days', where: 'id = ?', whereArgs: [dayId]);
  }

  /// 清空某计划的全部训练日（动作随级联删除）——
  /// AI「替换现有计划」重建内容前调用。
  Future<void> deletePlanDaysOfPlan(int planId) async {
    final db = await database;
    await db.delete('plan_days', where: 'plan_id = ?', whereArgs: [planId]);
  }

  /// 交换两个训练日的星期（拖动计划编排用：目标日已有内容则对调）。
  Future<void> swapPlanDayWeekdays(PlanDay a, PlanDay b) async {
    final db = await database;
    await db.transaction((tx) async {
      await tx.update('plan_days', {'weekday': -1},
          where: 'id = ?', whereArgs: [a.id]);
      await tx.update('plan_days', {'weekday': b.weekday},
          where: 'id = ?', whereArgs: [a.id]);
      await tx.update('plan_days', {'weekday': a.weekday},
          where: 'id = ?', whereArgs: [b.id]);
    });
  }

  Future<void> updatePlanExercise(PlanExercise ex) async {
    final db = await database;
    await db.update('plan_exercises', ex.toMap(),
        where: 'id = ?', whereArgs: [ex.id]);
  }

  Future<void> deletePlanExercise(int exerciseId) async {
    final db = await database;
    await db.delete('plan_exercises', where: 'id = ?', whereArgs: [exerciseId]);
  }

  /// 按给定顺序重排某天的动作（order_idx = 下标）。
  Future<void> reorderPlanExercises(int dayId, List<int> idsInOrder) async {
    final db = await database;
    final batch = db.batch();
    for (var i = 0; i < idsInOrder.length; i++) {
      batch.update('plan_exercises', {'order_idx': i},
          where: 'id = ?', whereArgs: [idsInOrder[i]]);
    }
    await batch.commit(noResult: true);
  }

  /// 超级组标记一致性维护（v9）：按当前顺序重读一天的动作，把「同 tag
  /// 不再相邻（被拖散/被隔开）」与「只剩单人」的 tag 清空。重排、删除、
  /// 解除配对后都应调用。返回被解除配对的动作名（空列表 = 无变化），
  /// 调用方据此 SnackBar 提示。
  Future<List<String>> normalizeSupersetTags(int dayId) async {
    final rows = await dayExercises(dayId);
    final clears = supersetTagClears(
      rows.map((e) => e.supersetTag).toList(),
    );
    if (clears.isEmpty) return const [];
    final db = await database;
    final batch = db.batch();
    final names = <String>[];
    for (final i in clears) {
      batch.update('plan_exercises', {'superset_tag': ''},
          where: 'id = ?', whereArgs: [rows[i].id]);
      names.add(rows[i].name);
    }
    await batch.commit(noResult: true);
    return names;
  }

  /// 全部已知动作（含肌群映射），编辑器自动补全/校对用。
  Future<List<ExerciseMeta>> allExerciseMeta() async {
    final db = await database;
    final rows =
        await db.query('exercise_meta', orderBy: 'name');
    return rows.map(ExerciseMeta.fromMap).toList();
  }

  /// 动作库行数（首启播种判断用）。
  Future<int> exerciseMetaCount() async {
    final db = await database;
    final rows =
        await db.rawQuery('SELECT COUNT(*) AS n FROM exercise_meta');
    return (rows.first['n'] as num).toInt();
  }

  Future<int> insertPlanExercise(PlanExercise ex) async =>
      (await database).insert('plan_exercises', ex.toMap());

  Future<List<PlanDay>> planDays(int planId) async {
    final db = await database;
    final rows = await db.query('plan_days',
        where: 'plan_id = ?',
        whereArgs: [planId],
        orderBy: 'weekday, id');
    return rows.map(PlanDay.fromMap).toList();
  }

  Future<List<PlanExercise>> dayExercises(int dayId) async {
    final db = await database;
    final rows = await db.query('plan_exercises',
        where: 'day_id = ?',
        whereArgs: [dayId],
        orderBy: 'order_idx, id');
    return rows.map(PlanExercise.fromMap).toList();
  }

  Future<Map<int, List<PlanExercise>>> daysExercisesMap(
      List<int> dayIds) async {
    final out = <int, List<PlanExercise>>{};
    for (final id in dayIds) {
      out[id] = await dayExercises(id);
    }
    return out;
  }

  Future<void> clearPlanContent(int planId) async {
    final db = await database;
    await db.rawDelete(
        'DELETE FROM plan_exercises WHERE day_id IN '
        '(SELECT id FROM plan_days WHERE plan_id = ?)',
        [planId]);
    await db.delete('plan_days', where: 'plan_id = ?', whereArgs: [planId]);
  }

  // ---------- plan schedule（日期化排程覆盖行） ----------
  Future<int> upsertScheduleEntry(PlanScheduleEntry e) async {
    final db = await database;
    return db.insert('plan_schedule', e.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteScheduleEntry(int id) async {
    final db = await database;
    await db.delete('plan_schedule', where: 'id = ?', whereArgs: [id]);
  }

  Future<PlanScheduleEntry?> scheduleEntryOn(int planId, String date) async {
    final db = await database;
    final rows = await db.query('plan_schedule',
        where: 'plan_id = ? AND date = ?',
        whereArgs: [planId, date],
        limit: 1);
    return rows.isEmpty ? null : PlanScheduleEntry.fromMap(rows.first);
  }

  /// [from, to] 闭区间内的全部覆盖行（视图渲染用，一次查询）。
  Future<List<PlanScheduleEntry>> scheduleEntries(
      int planId, String from, String to) async {
    final db = await database;
    final rows = await db.query('plan_schedule',
        where: 'plan_id = ? AND date >= ? AND date <= ?',
        whereArgs: [planId, from, to]);
    return rows.map(PlanScheduleEntry.fromMap).toList();
  }

  /// 某计划全部覆盖行（删除模板日/计划删除前清理等用）。
  Future<List<PlanScheduleEntry>> allScheduleEntries(int planId) async {
    final db = await database;
    final rows = await db.query('plan_schedule', where: 'plan_id = ?',
        whereArgs: [planId]);
    return rows.map(PlanScheduleEntry.fromMap).toList();
  }

  Future<PlanDay?> planDayById(int dayId) async {
    final db = await database;
    final rows = await db
        .query('plan_days', where: 'id = ?', whereArgs: [dayId], limit: 1);
    return rows.isEmpty ? null : PlanDay.fromMap(rows.first);
  }

  // ---------- exercise meta ----------
  Future<void> upsertExerciseMeta(ExerciseMeta meta) async {
    final db = await database;
    await db.insert('exercise_meta', meta.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 删除动作库自定义动作（v11：动作库管理页用）。只对词表外沉淀行有意义
  /// ——内置动作的行删了也会被 UI 的「内置优先合并」无视，调用方自行把关。
  Future<void> deleteExerciseMeta(String name) async {
    final db = await database;
    await db.delete('exercise_meta', where: 'name = ?', whereArgs: [name]);
  }

  Future<ExerciseMeta?> exerciseMeta(String name) async {
    final db = await database;
    final rows = await db.query('exercise_meta',
        where: 'name = ?', whereArgs: [name], limit: 1);
    return rows.isEmpty ? null : ExerciseMeta.fromMap(rows.first);
  }

  // ---------- sessions ----------
  Future<Session> insertSession(Session s) async {
    final db = await database;
    final id = await db.insert('sessions', s.toMap());
    return Session.fromMap({...s.toMap(), 'id': id});
  }

  /// 事务内一次插入会话与其全部动作，返回带回 id 的会话与动作列表。
  /// 消除"先插会话再逐条插动作"两步之间的半写窗口（进程在间隙被杀
  /// 或某条插入失败时，DB 会留下零动作的 active 脏会话）。
  Future<(Session, List<SessionExercise>)> insertSessionWithExercises(
      Session s, List<SessionExercise> exercises) async {
    final db = await database;
    return db.transaction((tx) async {
      final sid = await tx.insert('sessions', s.toMap());
      final out = <SessionExercise>[];
      for (final e in exercises) {
        final row = e.toMap();
        row['session_id'] = sid; // 覆写为事务内拿到的会话 id
        final id = await tx.insert('session_exercises', row);
        out.add(SessionExercise.fromMap({...row, 'id': id}));
      }
      return (Session.fromMap({...s.toMap(), 'id': sid}), out);
    });
  }

  Future<void> updateSession(int id, Map<String, Object?> fields) async {
    final db = await database;
    await db.update('sessions', fields, where: 'id = ?', whereArgs: [id]);
  }

  Future<Session?> activeSession() async {
    final db = await database;
    final rows = await db
        .query('sessions', where: "status='active'", orderBy: 'id DESC', limit: 1);
    return rows.isEmpty ? null : Session.fromMap(rows.first);
  }

  Future<Session?> sessionById(int id) async {
    final db = await database;
    final rows =
        await db.query('sessions', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Session.fromMap(rows.first);
  }

  Future<List<Session>> sessionsOnDate(String date) async {
    final db = await database;
    final rows = await db.query('sessions',
        where: 'date = ? AND status != ?',
        whereArgs: [date, 'active'],
        orderBy: 'id');
    return rows.map(Session.fromMap).toList();
  }

  /// 返回 [from, to] 闭区间内已完成训练，按日期升序。
  Future<List<Session>> sessionsBetween(String from, String to) async {
    final db = await database;
    final rows = await db.query('sessions',
        where: 'date >= ? AND date <= ? AND status = ?',
        whereArgs: [from, to, 'done'],
        orderBy: 'date, id');
    return rows.map(Session.fromMap).toList();
  }

  Future<List<Session>> recentSessions({int limit = 60}) async {
    final db = await database;
    final rows = await db.query('sessions',
        where: "status = 'done'", orderBy: 'id DESC', limit: limit);
    return rows.map(Session.fromMap).toList().reversed.toList();
  }

  // ---------- session exercises / sets ----------
  Future<int> insertSessionExercise(SessionExercise se) async =>
      (await database).insert('session_exercises', se.toMap());

  /// 更新会话动作行（训练中替换动作：只换名字，规则/排序随行整体写回）。
  Future<void> updateSessionExercise(SessionExercise se) async {
    final db = await database;
    await db.update('session_exercises', se.toMap(),
        where: 'id = ?', whereArgs: [se.id]);
  }

  Future<List<SessionExercise>> sessionExercises(int sessionId) async {
    final db = await database;
    final rows = await db.query('session_exercises',
        where: 'session_id = ?',
        whereArgs: [sessionId],
        orderBy: 'order_idx, id');
    return rows.map(SessionExercise.fromMap).toList();
  }

  Future<int> insertSet(SetEntry set) async =>
      (await database).insert('sets', set.toMap());

  Future<void> deleteSet(int id) async {
    final db = await database;
    await db.delete('sets', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<SetEntry>> setsOfExercise(int sessionExerciseId) async {
    final db = await database;
    final rows = await db.query('sets',
        where: 'session_exercise_id = ?',
        whereArgs: [sessionExerciseId],
        orderBy: 'id');
    return rows.map(SetEntry.fromMap).toList();
  }

  Future<Map<int, List<SetEntry>>> setsOfSession(int sessionId) async {
    final ses = await sessionExercises(sessionId);
    final out = <int, List<SetEntry>>{};
    for (final se in ses) {
      out[se.id!] = await setsOfExercise(se.id!);
    }
    return out;
  }

  /// 某动作全部历史组（按时间正序），用于对比与渐进判定。
  /// [kindFilter] 不为空时 SQL 侧只取该 kind；最多回 2000 行防无界。
  /// SQL 侧倒序截断保留最新 2000 条，Dart 侧再反转为时间升序返回
  /// （正序截断会在超限时丢掉最新数据，PR 判定与推荐重量回退到数年前）。
  Future<List<SetEntry>> historySets(String exerciseName,
      {int? beforeSessionExerciseId, String? kindFilter}) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT s.* FROM sets s
      JOIN session_exercises se ON se.id = s.session_exercise_id
      JOIN sessions ss ON ss.id = se.session_id
      WHERE se.name = ? AND ss.status = 'done'
        AND (? IS NULL OR s.kind = ?)
      ORDER BY s.done_at DESC
      LIMIT 2000
    ''', [exerciseName, kindFilter, kindFilter]);
    var list = rows.map(SetEntry.fromMap).toList().reversed.toList();
    if (beforeSessionExerciseId != null) {
      // 截断到指定 session_exercise 之前（不含当前进行中的组）
      final cur = await db.query('sets',
          columns: ['done_at'],
          where: 'session_exercise_id = ?',
          orderBy: 'done_at',
          whereArgs: [beforeSessionExerciseId]);
      if (cur.isNotEmpty) {
        final cutoff = cur.first['done_at'] as int;
        list = list.where((e) => e.doneAt < cutoff).toList();
      }
    }
    return list;
  }

  /// 该动作历史最高重量（PR 判定用聚合查询，避免全量拉取）。
  Future<double> maxWeightOf(String exerciseName) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT MAX(s.weight_kg) AS best FROM sets s
      JOIN session_exercises se ON se.id = s.session_exercise_id
      JOIN sessions ss ON ss.id = se.session_id
      WHERE se.name = ? AND ss.status = 'done' AND s.kind = 'working'
    ''', [exerciseName]);
    return (rows.first['best'] as num?)?.toDouble() ?? 0;
  }

  /// 上次完成该动作的那次训练里的全部正式组（用于"上次成绩"与渐进推荐）。
  /// 按所属 session 定位，避免用毫秒时间戳相等分组。
  Future<List<SetEntry>> lastWorkingSets(String exerciseName) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT s.* FROM sets s
      JOIN session_exercises se ON se.id = s.session_exercise_id
      JOIN sessions ss ON ss.id = se.session_id
      WHERE se.name = ? AND ss.status = 'done'
        AND s.kind = 'working'
        AND se.session_id = (
          SELECT se2.session_id
          FROM session_exercises se2
          JOIN sessions ss2 ON ss2.id = se2.session_id
          WHERE se2.name = ? AND ss2.status = 'done'
          ORDER BY ss2.id DESC
          LIMIT 1
        )
      ORDER BY s.id ASC
    ''', [exerciseName, exerciseName]);
    return rows.map(SetEntry.fromMap).toList();
  }

  // ---------- body metrics ----------
  /// 只更新本次填写的字段，未填字段保留旧值（防止部分录入清空已有数据）。
  Future<void> upsertBodyMetric(BodyMetric bm) async {
    final db = await database;
    final update = <String, Object?>{
      if (bm.weightKg != null) 'weight_kg': bm.weightKg,
      if (bm.waistCm != null) 'waist_cm': bm.waistCm,
      if (bm.bodyFatPct != null) 'bodyfat_pct': bm.bodyFatPct,
    };
    final updated = await db.update('body_metrics', update,
        where: 'date = ?', whereArgs: [bm.date]);
    if (updated == 0) {
      await db.insert('body_metrics', bm.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<List<BodyMetric>> bodyMetrics({int limit = 180}) async {
    final db = await database;
    final rows = await db
        .query('body_metrics', orderBy: 'date DESC', limit: limit);
    return rows.map(BodyMetric.fromMap).toList().reversed.toList();
  }

  // ---------- lark sync ----------
  Future<void> upsertLarkSync(LarkSync sync) async {
    final db = await database;
    await db.insert('lark_sync', sync.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> removeLarkSync(String refType, int refId) async {
    final db = await database;
    await db.delete('lark_sync',
        where: 'ref_type = ? AND ref_id = ?', whereArgs: [refType, refId]);
  }

  Future<LarkSync?> larkSyncFor(String refType, int refId) async {
    final db = await database;
    final rows = await db.query('lark_sync',
        where: 'ref_type = ? AND ref_id = ?',
        whereArgs: [refType, refId],
        limit: 1);
    return rows.isEmpty ? null : LarkSync.fromMap(rows.first);
  }

  // ---------- sync queue（离线补写） ----------
  Future<void> enqueueSync(String op, String payload) async {
    final db = await database;
    // 去重：完全相同的 op+payload 只留一条
    // （token 失效期间逐日失败重试，同一操作反复入队不再堆积）
    await db.delete('sync_queue',
        where: 'op = ? AND payload = ?', whereArgs: [op, payload]);
    await db.insert('sync_queue',
        {'op': op, 'payload': payload, 'created_at': DateTime.now().millisecondsSinceEpoch});
    // 硬性封顶 200 行：超出丢最旧，队列永不无限增长
    await db.execute(
        'DELETE FROM sync_queue WHERE id NOT IN '
        '(SELECT id FROM sync_queue ORDER BY id DESC LIMIT 200)');
  }

  Future<List<Map<String, dynamic>>> pendingSync() async {
    final db = await database;
    return db.query('sync_queue', orderBy: 'id');
  }

  Future<void> removeSync(int id) async {
    final db = await database;
    await db.delete('sync_queue', where: 'id = ?', whereArgs: [id]);
  }

  // ---------- 聚合查询（数据页用，避免 N+1） ----------

  /// 单次 JOIN 拉出时间段内全部训练明细行。
  /// 删除单次训练（级联删除其动作与组记录）。
  Future<void> deleteSession(int sessionId) async {
    final db = await database;
    await db.delete('sessions', where: 'id = ?', whereArgs: [sessionId]);
  }

  /// 某计划全部训练日的飞书同步记录（清理残留日程用）。
  Future<List<LarkSync>> larkSyncRefsForPlan(int planId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT l.* FROM lark_sync l
      JOIN plan_days d ON d.id = l.ref_id
      WHERE l.ref_type = 'plan_day' AND d.plan_id = ?
    ''', [planId]);
    return rows.map(LarkSync.fromMap).toList();
  }

  Future<List<Map<String, Object?>>> sessionRowsBetween(
      String from, String to) async {
    final db = await database;
    return db.rawQuery('''
      SELECT ss.id AS session_id, ss.date, ss.plan_day_title,
             ss.started_at, ss.ended_at,
             se.id AS se_id, se.name, se.order_idx,
             s.weight_kg, s.reps, s.rir, s.kind, s.done_at
      FROM sessions ss
      JOIN session_exercises se ON se.session_id = ss.id
      LEFT JOIN sets s ON s.session_exercise_id = se.id
      WHERE ss.status = 'done' AND ss.date >= ? AND ss.date <= ?
      ORDER BY ss.id, se.order_idx, s.id
    ''', [from, to]);
  }

  // ---------- export ----------
  Future<Map<String, dynamic>> exportAllJson() async {
    final db = await database;
    return {
      'plans': await db.query('plans'),
      'plan_days': await db.query('plan_days'),
      'plan_exercises': await db.query('plan_exercises'),
      'plan_schedule': await db.query('plan_schedule'),
      'sessions': await db.query('sessions'),
      'session_exercises': await db.query('session_exercises'),
      'sets': await db.query('sets'),
      'body_metrics': await db.query('body_metrics'),
      'exercise_meta': await db.query('exercise_meta'),
    };
  }

  Future<void> wipeAll() async {
    final db = await database;
    await db.transaction((tx) async {
      for (final t in [
        'sets',
        'session_exercises',
        'sessions',
        'plan_exercises',
        'plan_days',
        'plans',
        'body_metrics',
        'lark_sync',
        'sync_queue',
        'deleted_plans',
      ]) {
        await tx.delete(t);
      }
    });
  }

  /// 从导出的全量 JSON 恢复（先清空再写入，事务保证要么全成要么不动）。
  /// 行按备份里的原 id 插入，训练/计划的外键关系原样保留；
  /// lark_sync / sync_queue 不在备份里，清空后留空（下次同步自动重建）。
  Future<void> restoreAll(Map<String, dynamic> data) async {
    final db = await database;
    await db.transaction((tx) async {
      for (final t in [
        'sets',
        'session_exercises',
        'sessions',
        'plan_schedule',
        'plan_exercises',
        'plan_days',
        'plans',
        'body_metrics',
        'lark_sync',
        'sync_queue',
      ]) {
        await tx.delete(t);
      }
      // 父表先插，满足外键约束；exercise_meta 主键冲突时以备份为准
      for (final t in [
        'plans',
        'plan_days',
        'plan_exercises',
        'plan_schedule',
        'sessions',
        'session_exercises',
        'sets',
        'body_metrics',
        'exercise_meta',
      ]) {
        final rows = data[t];
        if (rows is! List) continue;
        for (final row in rows) {
          if (row is! Map) continue;
          await tx.insert(
            t,
            Map<String, Object?>.from(row),
            conflictAlgorithm: t == 'exercise_meta'
                ? ConflictAlgorithm.replace
                : ConflictAlgorithm.abort,
          );
        }
      }
    });
  }
}
