import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../engine/exercise_identity.dart';
import '../engine/metrics.dart' show fmtDate;
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
/// - **动作身份**：纵向历史查询（historySets / maxWeightOf / lastWorkingSets /
///   lastTargetSets / lastExerciseModes）按 `session_exercises.exercise_key`
///   归并——同义名/改名/导入共享同一份历史，不再按显示名拆散；
/// - **计划目标快照**：session_exercises.target_sets / target_reps_min /
///   target_reps_max（v6 起）是"本次训练当时"的模板参数，用于完成度
///   对比；模板表本身被修改不影响老记录。
class Db {
  Db._() : _override = null;
  static final Db instance = Db._();

  /// 当前 schema 版本（fresh create 与升级共用；迁移测试锁定版本号）。
  static const int schemaVersion = 17;

  /// 测试缝：注入已打开的内存库（sqflite_common_ffi）。
  @visibleForTesting
  Db.forTesting(this._override);

  final Database? _override;
  Future<Database>? _overrideFuture;

  Future<Database>? _dbFuture;

  // ---------- 本机偏好标记随备份走（2026-10-18） ----------
  //
  // 训练统计回溯依赖三类 SharedPreferences 标记（SQLite 库外状态）：
  // - block.deloadSessionIds：减载周/停练回归会话标记（id|date|startedAt 指纹）；
  // - block.anchor.<planId>：训练块锚点（已确认的块起点 + 来源会话指纹）。
  // 全量导出把它们带上、恢复时写回——否则备份恢复/换机后这些标记丢失，
  // 统计回溯错位（已标记的减载场重新混进渐进回溯、块周静默重置）。
  // App 启动时由容器 attach；未 attach（老测试路径）时导出/恢复安静跳过。
  SharedPreferences? _sessionPrefs;

  /// 挂上本机偏好（App 启动接线；测试也可注入）。null = 卸下，
  /// exportAllJson/restoreAll 随即跳过偏好标记段。
  void attachSessionPrefs(SharedPreferences? prefs) =>
      _sessionPrefs = prefs;

  static const String _kDeloadPrefsKey = 'block.deloadSessionIds';
  static const String _kAnchorPrefsPrefix = 'block.anchor.';

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
    final future = dir.then(
      (d) => openDatabase(
        p.join(d, 'baoji_timer.db'),
        // v9=超级组（superset_tag），v10=全计划顺延（plans.shift_*），
        // v11=动作库 gear，v12=加练标注（sets.is_extra），
        // v13=心率采样（hr_sample），
        // v14=动作记录形态（logging/load_type/duration_sec），
        // v15=数据模型地基（rir_recorded/pain_*、exercise_key、
        //     exercise_notes 表）；v16=动作稳定身份（按别名归一后的
        //     exercise_key 回填 + 纵向查询索引）；
        // v17=计划启用时间（plans.activated_at，周复盘按启用日截止）。
        version: schemaVersion,
        onConfigure: _onConfigure,
        onCreate: (db, v) => createSchema(db),
        onUpgrade: _onUpgrade,
      ),
    );
    // 失败自清理：首次打开瞬时失败（磁盘满/IO 抖动）后，
    // 下一次调用重新尝试打开，不让同一个 failed Future 缓存到进程结束。
    _dbFuture = future.catchError((Object e) {
      _dbFuture = null;
      throw e;
    });
    return _dbFuture!;
  }

  /// 连接级配置：外键 + 忙等窗口。busy_timeout 让瞬时锁（如 macOS
  /// fileproviderd 对新建库文件的同步扫描，测试库就在文稿目录下）
  /// 变成「等它释放」而不是立刻 SQLITE_BUSY(5) 报错——实测释放窗口
  /// <300ms，3 秒足够；对真实断锁场景也只是多等 3 秒再报同样的错。
  ///
  /// 平台差异（2026-10-18 真机升级冒烟抓到的启动阻断）：Android sqflite
  /// 对 execute 跑 PRAGMA 一律抛 "Queries can be performed using query or
  /// rawQuery methods only"（哪怕 SQLITE_OK），busy_timeout 必须走
  /// rawQuery；foreign_keys 是赋值型 PRAGMA，execute 在 Android 上一直
  /// 可用（b150 前就在用）。外面再兜 try/catch——busy_timeout 只是抗瞬
  /// 时锁的优化，任何平台不支持都不能挡住 App 启动。
  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
    try {
      await db.rawQuery('PRAGMA busy_timeout = 3000');
    } catch (_) {
      // 拿不到忙等窗口就退回默认行为：瞬时锁直接报 SQLITE_BUSY。
    }
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
    if (oldV < 13) {
      await upgradeV12to13(db);
    }
    if (oldV < 14) {
      await upgradeV13to14(db);
    }
    if (oldV < 15) {
      await upgradeV14to15(db);
    }
    if (oldV < 16) {
      await upgradeV15to16(db);
    }
    if (oldV < 17) {
      await upgradeV16to17(db);
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

  /// v13：心率采样（2026-10-17）——BLE 标准心率服务（0x180D/0x2A37）
  /// 会话期间 ~1Hz 采样，会话结束一次性落库。一场训练几百到几千行，
  /// 按 session_id 级联删除（删训练记录时心率曲线一并清掉）。
  @visibleForTesting
  Future<void> upgradeV12to13(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS hr_sample(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        ts INTEGER NOT NULL,
        bpm INTEGER NOT NULL
      )''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_hr_session ON hr_sample(session_id)');
  }

  /// v14：动作记录形态（2026-10-17）——动作可按时间记录（平板支撑等，
  /// 链状态「次数」字段承载秒数）、可标单侧动作（目标取偶）、可标自重
  /// 负荷（渐进只走次数轴）。plan_exercises / session_exercises 各加
  /// logging（'reps'|'time'|'reps_per_side'）与 load_type
  /// （'weighted'|'bodyweight'），sets 加 duration_sec（计时组实际保持
  /// 秒数，可空 = 老记录/非计时）。三列全带默认值，老库（v12/v13 直升
  /// v14 均走本函数）与老备份缺键平滑回默认，行为与升级前完全一致。
  @visibleForTesting
  Future<void> upgradeV13to14(Database db) async {
    await db.execute(
        "ALTER TABLE plan_exercises ADD COLUMN logging TEXT NOT NULL DEFAULT 'reps'");
    await db.execute(
        "ALTER TABLE plan_exercises ADD COLUMN load_type TEXT NOT NULL DEFAULT 'weighted'");
    await db.execute(
        "ALTER TABLE session_exercises ADD COLUMN logging TEXT NOT NULL DEFAULT 'reps'");
    await db.execute(
        "ALTER TABLE session_exercises ADD COLUMN load_type TEXT NOT NULL DEFAULT 'weighted'");
    await db.execute('ALTER TABLE sets ADD COLUMN duration_sec INTEGER');
  }

  /// v15：数据模型地基（2026-10-17）——为后续功能预留 schema，不改现有
  /// 行为：
  /// - sets 加 rir_recorded（RIR 是否实际记录，默认 1 = 老行视为已记录）、
  ///   pain_level（疼痛等级，默认 0 = 未填）、pain_area（疼痛部位，默认 ''）；
  /// - plan_exercises / session_exercises 各加 exercise_key（动作稳定键，
  ///   默认 ''），并把老行回填为 name（当前没有独立键，名字即身份）；
  /// - 新建 exercise_notes：按 exercise_key 存一条动作级长期备注。
  /// 全带默认值，v12/v13/v14 直升 v15 均走本函数；老备份缺键平滑回默认。
  @visibleForTesting
  Future<void> upgradeV14to15(Database db) async {
    await db.execute(
      'ALTER TABLE sets ADD COLUMN rir_recorded INTEGER NOT NULL DEFAULT 1',
    );
    await db.execute(
      'ALTER TABLE sets ADD COLUMN pain_level INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      "ALTER TABLE sets ADD COLUMN pain_area TEXT NOT NULL DEFAULT ''",
    );
    await db.execute(
      "ALTER TABLE plan_exercises ADD COLUMN exercise_key TEXT NOT NULL DEFAULT ''",
    );
    await db.execute(
      "ALTER TABLE session_exercises ADD COLUMN exercise_key TEXT NOT NULL DEFAULT ''",
    );
    // 老行回填：升级前没有独立键，用动作名充当（只填空值，不动已有键）。
    await db.execute(
      "UPDATE plan_exercises SET exercise_key = name WHERE exercise_key = ''",
    );
    await db.execute(
      "UPDATE session_exercises SET exercise_key = name WHERE exercise_key = ''",
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS exercise_notes(
        exercise_key TEXT PRIMARY KEY,
        setup_note TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL DEFAULT 0
      )''');
  }

  /// v16：动作稳定身份（2026-10-17）——把 v15 的「名字即键」升级为
  /// [exerciseKeyOf] 归一后的稳定键：去空白/标点、英文小写、中英别名
  /// 归一到规范名。只改写「空键」与「键 == 名字」的老行；用户/导入
  /// 显式写入的定制键保持不动（例如 `barbell_bench_press`）。
  ///
  /// 用 Dart 逐名回填而不是一条 SQL：别名归一是 Dart 逻辑，SQL 里
  /// 无法表达；按 distinct name 更新，每个动作名只算一次。回填目标键
  /// 以行上已有的 exercise_key 为准（同名行已有显式定制键就沿用），
  /// 不重新按名字归一。exercise_notes 若存在按旧名字写入的行，一并迁到
  /// 新键（同键冲突取 updated_at 较新的一条），避免备注在升级后失联。
  /// 同时补 session_exercises(exercise_key) 索引，纵向历史查询不再全表扫。
  /// 无新列，fresh create 与老库升级后的结构一致。
  @visibleForTesting
  Future<void> upgradeV15to16(Database db) async {
    // 旧名字 → 新稳定键；同时用于迁移 exercise_notes。
    final nameToKey = <String, String>{};
    for (final table in const ['plan_exercises', 'session_exercises']) {
      final names = await db.rawQuery(
        'SELECT DISTINCT name FROM $table WHERE name != ?',
        [''],
      );
      for (final row in names) {
        final name = (row['name'] as String?) ?? '';
        if (name.isEmpty) continue;
        // 以行上已有的 exercise_key 为准：同名行里有显式定制键（非空且
        // 不等于名字）就直接采用，不重新按名字归一 —— `Barbell Bench
        // Press` 这类名字若已带自建键 `barbell_bench_press`，按名字现算
        // 会撞上别名 'barbell bench press'，把备注迁错到规范键。
        final stored = await db.query(
          table,
          columns: ['exercise_key'],
          where: "name = ? AND exercise_key != '' AND exercise_key != ?",
          whereArgs: [name, name],
          orderBy: 'id DESC',
          limit: 1,
        );
        final explicit = stored.isEmpty
            ? ''
            : ((stored.first['exercise_key'] as String?) ?? '').trim();
        final key = explicit.isNotEmpty ? explicit : exerciseKeyOf(name);
        if (key.isEmpty) continue;
        // 先计划后会话，同名取先到（与 storedExerciseKey 的口径一致）。
        if (!nameToKey.containsKey(name)) nameToKey[name] = key;
        // 只回填 v15 的默认值（空 或 键==名字），保留显式定制键；
        // 同名无键的行沿用该名字已有的键，不再按名字另算一个身份。
        await db.update(
          table,
          {'exercise_key': key},
          where: "name = ? AND (exercise_key = '' OR exercise_key = ?)",
          whereArgs: [name, name],
        );
      }
    }
    await _migrateExerciseNotes(db, nameToKey);
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_se_exercise_key '
      'ON session_exercises(exercise_key)',
    );
  }

  /// v17：plans 加激活时间（activated_at）。
  /// 纯加列，无表重建；老行默认空串，页面回退 createdAt。
  @visibleForTesting
  Future<void> upgradeV16to17(Database db) async {
    await db.execute(
      "ALTER TABLE plans ADD COLUMN activated_at TEXT NOT NULL DEFAULT ''",
    );
  }

  /// 备注表按旧名字写了 key 的行迁到新键；目标键已有备注时取较新一条。
  /// 备注行不一定能在当前 plan/session 里找到同名动作，所以遍历整张表，
  /// 由 [_noteKeyAfterNormalization] 判断旧键是不是动作名/别名。
  Future<void> _migrateExerciseNotes(
    Database db,
    Map<String, String> nameToKey,
  ) async {
    final hasTable = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='exercise_notes'",
    );
    if (hasTable.isEmpty) return;
    final notes = await db.query('exercise_notes', columns: ['exercise_key']);
    for (final note in notes) {
      final oldKey = (note['exercise_key'] as String?) ?? '';
      final newKey = _noteKeyAfterNormalization(oldKey, nameToKey);
      if (newKey == null) continue;
      await _moveNoteToKey(db, oldKey, newKey);
    }
  }

  /// 备注旧键 → 新键；返回 null = 不需要/不应该迁移。
  /// 优先级：当前 plan/session 里的同名动作 → 别名表 → 带中文的名字。
  /// 显式定制键（`custom_squat` / `barbell_bench_press` 这类无空格、
  /// 下划线混杂、非中文的机生键）原样保留：归一会把 `barbell_bench_press`
  /// 撞上别名 'barbell bench press'，但原始键带下划线，不是人手输入的
  /// 名字，不能迁 —— 否则备注与自建键的行失联。restoreAll 共用本规则。
  String? _noteKeyAfterNormalization(
    String oldKey,
    Map<String, String> nameToKey,
  ) {
    final key = oldKey.trim();
    if (key.isEmpty) return null;
    final direct = nameToKey[key];
    if (direct != null && direct.isNotEmpty && direct != key) return direct;
    final normalized = exerciseKeyOf(key);
    if (normalized.isEmpty || normalized == key) return null;
    final hasCjk = RegExp(r'[\u4e00-\u9fff]').hasMatch(key);
    if (key.contains('_') &&
        !RegExp(r'\s').hasMatch(key) &&
        !hasCjk) {
      return null; // 机生定制键：原样保留。
    }
    if (isExerciseAliasName(key) || (hasCjk && !key.contains('_'))) {
      return normalized;
    }
    return null;
  }

  /// 把一条备注从 [oldKey] 挪到 [newKey]；目标已有备注时保留 updated_at 较新的一条。
  Future<void> _moveNoteToKey(
    DatabaseExecutor db,
    String oldKey,
    String newKey,
  ) async {
    if (oldKey.isEmpty || newKey.isEmpty || oldKey == newKey) return;
    final oldRows = await db.query(
      'exercise_notes',
      where: 'exercise_key = ?',
      whereArgs: [oldKey],
      limit: 1,
    );
    if (oldRows.isEmpty) return;
    final newRows = await db.query(
      'exercise_notes',
      where: 'exercise_key = ?',
      whereArgs: [newKey],
      limit: 1,
    );
    if (newRows.isEmpty) {
      await db.update(
        'exercise_notes',
        {'exercise_key': newKey},
        where: 'exercise_key = ?',
        whereArgs: [oldKey],
      );
      return;
    }
    final oldUpdated = (oldRows.first['updated_at'] as num?)?.toInt() ?? 0;
    final newUpdated = (newRows.first['updated_at'] as num?)?.toInt() ?? 0;
    if (oldUpdated > newUpdated) {
      await db.update(
        'exercise_notes',
        {
          'setup_note': (oldRows.first['setup_note'] as String?) ?? '',
          'updated_at': oldUpdated,
        },
        where: 'exercise_key = ?',
        whereArgs: [newKey],
      );
    }
    await db.delete(
      'exercise_notes',
      where: 'exercise_key = ?',
      whereArgs: [oldKey],
    );
  }

  /// 查询时的有效稳定键：显式键优先（会话动作行自带），空键按名字现算。
  String _effectiveExerciseKey(String name, String? key) =>
      exerciseIdentityKeyOf(name, key);

  /// 精确同名行里已经落库的稳定键（先计划后会话，取最新一行）。
  /// 不按名字现算；没有同名行返回 null。用于改名时判断「是不是换动作」。
  Future<String?> storedExerciseKey(String name) async {
    final exact = name.trim();
    if (exact.isEmpty) return null;
    final db = await database;
    for (final table in const ['plan_exercises', 'session_exercises']) {
      final rows = await db.query(
        table,
        columns: ['exercise_key'],
        where: 'name = ? AND exercise_key != ?',
        whereArgs: [exact, ''],
        orderBy: 'id DESC',
        limit: 1,
      );
      if (rows.isEmpty) continue;
      final key = ((rows.first['exercise_key'] as String?) ?? '').trim();
      if (key.isNotEmpty) return key;
    }
    return null;
  }

  /// 按动作名反查已有的稳定键：
  /// 1. 精确同名行（改名时保留的旧键 / 导入的定制键）优先——先计划后会话；
  /// 2. 没有同名行才按 [exerciseKeyOf] 归一。
  ///
  /// 新行/临时追加/桥接查询用它，避免同名动作被现算成第二个身份。
  /// 空名返回 null。
  Future<String?> knownExerciseKey(String name) async {
    final stored = await storedExerciseKey(name);
    if (stored != null) return stored;
    final key = exerciseKeyOf(name.trim());
    return key.isEmpty ? null : key;
  }

  /// 新写入行的键：显式键原样保留；空键先查同名已有行，再按名字现算。
  Future<String> _writeKeyFor(String name, String key) async {
    if (key.trim().isNotEmpty) return key.trim();
    return await knownExerciseKey(name) ?? exerciseKeyOf(name);
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

  /// 测试缝：用与 [database] 完全相同的打开选项（version / 外键 / 建表 /
  /// 升级回调）打开指定 [path] 的库。不走 [_dbFuture] 单例缓存，迁移分发
  /// 测试可用独立路径，避免与其它测试互删共享的 baoji_timer.db。
  @visibleForTesting
  Future<Database> openWithProductionOptions(String path) => openDatabase(
    path,
    version: schemaVersion,
    onConfigure: _onConfigure,
    onCreate: (db, v) => createSchema(db),
    onUpgrade: _onUpgrade,
  );

  Future<void> _onCreate(Database db, int v) async {
    await db.execute('''
      CREATE TABLE plans(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        source TEXT NOT NULL,
        created_at TEXT NOT NULL,
        activated_at TEXT NOT NULL DEFAULT '',
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
        logging TEXT NOT NULL DEFAULT 'reps',
        load_type TEXT NOT NULL DEFAULT 'weighted',
        superset_tag TEXT NOT NULL DEFAULT '',
        exercise_key TEXT NOT NULL DEFAULT ''
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
      CREATE TABLE exercise_notes(
        exercise_key TEXT PRIMARY KEY,
        setup_note TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL DEFAULT 0
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
        logging TEXT NOT NULL DEFAULT 'reps',
        load_type TEXT NOT NULL DEFAULT 'weighted',
        superset_tag TEXT NOT NULL DEFAULT '',
        exercise_key TEXT NOT NULL DEFAULT ''
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
        is_extra INTEGER NOT NULL DEFAULT 0,
        duration_sec INTEGER,
        rir_recorded INTEGER NOT NULL DEFAULT 1,
        pain_level INTEGER NOT NULL DEFAULT 0,
        pain_area TEXT NOT NULL DEFAULT ''
      )''');
    await db.execute('CREATE INDEX idx_sets_se ON sets(session_exercise_id)');
    await db.execute('CREATE INDEX idx_se_name ON session_exercises(name)');
    await db.execute(
      'CREATE INDEX idx_se_session ON session_exercises(session_id)',
    );
    await db.execute(
      'CREATE INDEX idx_se_exercise_key ON session_exercises(exercise_key)',
    );
    await db.execute('CREATE INDEX idx_sessions_date ON sessions(date)');
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
    await db.execute('''
      CREATE TABLE hr_sample(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        ts INTEGER NOT NULL,
        bpm INTEGER NOT NULL
      )''');
    await db
        .execute('CREATE INDEX idx_hr_session ON hr_sample(session_id)');
  }

  // ---------- plans ----------
  Future<Plan> insertPlan(Plan plan) async {
    final db = await database;
    final id = await db.insert('plans', plan.toMap());
    return Plan.fromMap({...plan.toMap(), 'id': id});
  }

  Future<Plan?> activePlan() async {
    final db = await database;
    final rows = await db.query('plans', where: 'is_active=1', limit: 1);
    return rows.isEmpty ? null : Plan.fromMap(rows.first);
  }

  /// 按 id 取计划（块起点锚点的计划指纹用，不依赖是否 active）。
  Future<Plan?> planById(int id) async {
    final db = await database;
    final rows = await db.query(
      'plans',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
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
      final rows = await tx.query(
        'plans',
        columns: ['is_active', 'activated_at'],
        where: 'id = ?',
        whereArgs: [planId],
        limit: 1,
      );
      final wasActive =
          rows.isNotEmpty &&
          ((rows.first['is_active'] as num?)?.toInt() ?? 0) == 1;
      final prev = rows.isEmpty
          ? ''
          : ((rows.first['activated_at'] as String?) ?? '');
      String? activatedAt;
      if (!wasActive) {
        // 语义（2026-10-18）：activated_at 记录该计划的**最早启用日**，
        // 不是「最近一次启用日」。重复点同一个已启用计划不刷新（启用日
        // 不被抹掉更早的缺勤）；切到别的计划再切回来，也不把计划起点推后
        // ——已有启用日不晚于今天就保留它，只有空值/异常的未来日期才写今天。
        final today = fmtDate(DateTime.now());
        activatedAt =
            prev.isNotEmpty && prev.compareTo(today) <= 0 ? prev : today;
      }
      await tx.update('plans', {'is_active': 0});
      await tx.update(
        'plans',
        {
          'is_active': 1,
          'activated_at': ?activatedAt,
        },
        where: 'id = ?',
        whereArgs: [planId],
      );
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
          // 回收站快照可能是 v15 及更早写的（键=名字/无键）：恢复时按 v16
          // 口径补/归一，避免恢复出的计划在历史查询里换一个身份。
          final name = (exMap['name'] as String?) ?? '';
          final key = (exMap['exercise_key'] as String?) ?? '';
          if (key.isEmpty || key == name) {
            exMap['exercise_key'] = exerciseKeyOf(name);
          }
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
    final row = ex.toMap();
    // 改名时调用方保留旧键（历史不断）；复制/替换传空键 → 先查同名已有键，
    // 再按新名字取键（避免同名动作被拆成第二个身份）。
    row['exercise_key'] = await _writeKeyFor(ex.name, ex.exerciseKey);
    await db.update('plan_exercises', row, where: 'id = ?', whereArgs: [ex.id]);
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

  Future<int> insertPlanExercise(PlanExercise ex) async {
    final row = ex.toMap();
    row['exercise_key'] = await _writeKeyFor(ex.name, ex.exerciseKey);
    return (await database).insert('plan_exercises', row);
  }

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

  // ---------- exercise notes（器械设置，v15 表） ----------

  /// 读某个动作的长期设置备注（器械座椅/靠背等）。
  /// 键按稳定身份传（见 [exerciseIdentityKeyOf]）；空键与空备注一律返回
  /// null —— 展示端据此不占空间。
  Future<ExerciseNote?> exerciseNote(String exerciseKey) async {
    final key = exerciseKey.trim();
    if (key.isEmpty) return null;
    final db = await database;
    final rows = await db.query(
      'exercise_notes',
      where: 'exercise_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final note = ExerciseNote.fromMap(rows.first);
    return note.setupNote.trim().isEmpty ? null : note;
  }

  /// 写某个动作的设置备注：非空 upsert（一门一条），空串/纯空白删除整行，
  /// 不留下占位的空壳。`updated_at` 留 epoch ms，供备份合并取较新一条。
  Future<void> saveExerciseNote(String exerciseKey, String setupNote) async {
    final key = exerciseKey.trim();
    if (key.isEmpty) return;
    final db = await database;
    final text = setupNote.trim();
    if (text.isEmpty) {
      await db.delete(
        'exercise_notes',
        where: 'exercise_key = ?',
        whereArgs: [key],
      );
      return;
    }
    await db.insert(
      'exercise_notes',
      ExerciseNote(
        exerciseKey: key,
        setupNote: text,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 批量读：训练起始页一次取齐当天全部动作的备注，避免逐行查询。
  /// 只返回非空备注；输入会去重/去空白，占位符按数量生成、值走参数绑定。
  Future<Map<String, String>> exerciseNotesByKeys(
    Iterable<String> exerciseKeys,
  ) async {
    final keys = <String>{
      for (final k in exerciseKeys)
        if (k.trim().isNotEmpty) k.trim(),
    }.toList(growable: false);
    if (keys.isEmpty) return const {};
    final db = await database;
    final placeholders = List.filled(keys.length, '?').join(',');
    final rows = await db.query(
      'exercise_notes',
      columns: ['exercise_key', 'setup_note'],
      where: 'exercise_key IN ($placeholders)',
      whereArgs: keys,
    );
    final notes = <String, String>{};
    for (final row in rows) {
      final text = ((row['setup_note'] as String?) ?? '').trim();
      if (text.isEmpty) continue;
      final key = ((row['exercise_key'] as String?) ?? '').trim();
      if (key.isEmpty) continue;
      notes[key] = text;
    }
    return notes;
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
    Session s,
    List<SessionExercise> exercises,
  ) async {
    final db = await database;
    // 事务外先算好键（要查同名已有键），事务内只写，避免事务里再开查询。
    // 同批里同名动作也复用先算出的键，防止同一天两行被拆成两个身份。
    final keys = <String>[];
    final keyByName = <String, String>{};
    for (final e in exercises) {
      final name = e.name.trim();
      final explicit = e.exerciseKey.trim();
      final key = explicit.isNotEmpty
          ? explicit
          : (keyByName[name] ??
                await knownExerciseKey(e.name) ??
                exerciseKeyOf(e.name));
      keys.add(key);
      if (name.isNotEmpty && key.isNotEmpty) keyByName[name] = key;
    }
    return db.transaction((tx) async {
      final sid = await tx.insert('sessions', s.toMap());
      final out = <SessionExercise>[];
      for (var i = 0; i < exercises.length; i++) {
        final e = exercises[i];
        final row = e.toMap();
        row['session_id'] = sid; // 覆写为事务内拿到的会话 id
        // 开练快照：计划行有键就沿用（改名不断历史）；空键先查同名已有键。
        row['exercise_key'] = keys[i];
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

  /// 当前计划第一次已完成训练的日期（P1-C 训练块起点），无记录返回 null。
  /// 只认 status='done'：active/quit 不算块起点；临时训练
  /// （plan_day_id=null）不属于任何计划，自然不进结果。
  Future<String?> firstDoneSessionDateOfPlan(int planId) async =>
      (await firstDoneSessionOfPlan(planId))?.date;

  /// 当前计划第一次已完成训练的整行指纹（id/date/startedAt）：
  /// 训练块锚点（`block.anchor.<planId>`）用它做「来源会话指纹」——
  /// 用户删掉这场唯一 done 会话后，锚点能识别出自己指向的会话已不存在，
  /// 失效重算，而不是把已删会话的日期当成块起点继续用。
  Future<({int id, String date, int startedAt})?> firstDoneSessionOfPlan(
      int planId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT ss.id, ss.date, ss.started_at
      FROM sessions ss
      JOIN plan_days pd ON pd.id = ss.plan_day_id
      WHERE pd.plan_id = ? AND ss.status = 'done'
      ORDER BY ss.date ASC, ss.id ASC
      LIMIT 1
    ''', [planId]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    final date = (r['date'] as String?) ?? '';
    if (date.isEmpty) return null;
    return (
      id: (r['id'] as num?)?.toInt() ?? 0,
      date: date,
      startedAt: (r['started_at'] as num?)?.toInt() ?? 0,
    );
  }

  /// 全库最近一场已完成训练的日期（P1-D 停练回归判定），无记录返回 null。
  /// 只认 status='done'：active/quit 不算「练过」；临时训练也算一次
  /// done 训练——只要还在练，就不算停练。
  /// 两道防线（2026-10-18）：
  /// - **忽略未来日期**：设备时间被拨快/脏数据留下未来场时，MAX(date)
  ///   会长期悬在未来，停练判定被永久压住（永远"最近练过"）；
  /// - **只认有正式组（kind='working'）的 done 会话**：零正式组的空场
  ///   （半写残留/一组没记就收工）不算"练过"，否则用户空挂了一场
  ///   done 会话，停练降档就再也不触发。
  Future<String?> lastDoneSessionDate() async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT MAX(ss.date) AS d
      FROM sessions ss
      WHERE ss.status = 'done'
        AND ss.date <= ?
        AND EXISTS (
          SELECT 1
          FROM sets s
          JOIN session_exercises se ON se.id = s.session_exercise_id
          WHERE se.session_id = ss.id AND s.kind = 'working'
        )
    ''',
      [fmtDate(DateTime.now())],
    );
    final d = rows.first['d'] as String?;
    return (d == null || d.isEmpty) ? null : d;
  }

  // ---------- session exercises / sets ----------
  Future<int> insertSessionExercise(SessionExercise se) async {
    final row = se.toMap();
    row['exercise_key'] = await _writeKeyFor(se.name, se.exerciseKey);
    return (await database).insert('session_exercises', row);
  }

  /// 更新会话动作行（训练中替换动作：只换名字，规则/排序随行整体写回）。
  Future<void> updateSessionExercise(SessionExercise se) async {
    final db = await database;
    final row = se.toMap();
    // 替换动作时调用方传空键 → 先查同名已有键，再按新名字取键；
    // 改名沿用旧键时保留。
    row['exercise_key'] = await _writeKeyFor(se.name, se.exerciseKey);
    await db.update(
      'session_exercises',
      row,
      where: 'id = ?',
      whereArgs: [se.id],
    );
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
  /// 按稳定身份键 [exercise_key] 归并：同义名（「平板卧推」与「杠铃卧推」）
  /// 共享同一份历史，不再因为改名/导入被拆散。
  /// [exerciseKey] 显式给定时优先（会话动作行自带的键），否则按
  /// [exerciseName] 现算。
  /// [kindFilter] 不为空时 SQL 侧只取该 kind；最多回 2000 行防无界。
  /// SQL 侧倒序截断保留最新 2000 条，Dart 侧再反转为时间升序返回
  /// （正序截断会在超限时丢掉最新数据，PR 判定与推荐重量回退到数年前）。
  Future<List<SetEntry>> historySets(
    String exerciseName, {
    String? exerciseKey,
    int? beforeSessionExerciseId,
    String? kindFilter,
    Set<int>? excludeSessionIds,
  }) async {
    final key = _effectiveExerciseKey(exerciseName, exerciseKey);
    if (key.isEmpty) return const [];
    final db = await database;
    final excluded = excludeSessionIds ?? const <int>{};
    final exSql = excluded.isEmpty
        ? ''
        : ' AND ss.id NOT IN (${List.filled(excluded.length, '?').join(',')})';
    final rows = await db.rawQuery('''
      SELECT s.* FROM sets s
      JOIN session_exercises se ON se.id = s.session_exercise_id
      JOIN sessions ss ON ss.id = se.session_id
      WHERE se.exercise_key = ? AND ss.status = 'done'
        AND (? IS NULL OR s.kind = ?)
        $exSql
      ORDER BY s.done_at DESC
      LIMIT 2000
    ''',
      [key, kindFilter, kindFilter, ...excluded],
    );
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
  /// 按稳定身份键归并同义名；[exerciseKey] 显式给定时优先。
  Future<double> maxWeightOf(String exerciseName, {String? exerciseKey}) async {
    final key = _effectiveExerciseKey(exerciseName, exerciseKey);
    if (key.isEmpty) return 0;
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT MAX(s.weight_kg) AS best FROM sets s
      JOIN session_exercises se ON se.id = s.session_exercise_id
      JOIN sessions ss ON ss.id = se.session_id
      WHERE se.exercise_key = ? AND ss.status = 'done' AND s.kind = 'working'
    ''',
      [key],
    );
    return (rows.first['best'] as num?)?.toDouble() ?? 0;
  }

  /// 上次完成该动作的那次训练里的全部正式组（用于"上次成绩"与渐进推荐）。
  /// 按稳定身份键归并同义名；[exerciseKey] 显式给定时优先。
  /// 按所属 session 定位，避免用毫秒时间戳相等分组。
  Future<List<SetEntry>> lastWorkingSets(
    String exerciseName, {
    String? exerciseKey,
    Set<int>? excludeSessionIds,
  }) async {
    final key = _effectiveExerciseKey(exerciseName, exerciseKey);
    if (key.isEmpty) return const [];
    final db = await database;
    final excluded = excludeSessionIds ?? const <int>{};
    final exSql = excluded.isEmpty
        ? ''
        : ' AND ss.id NOT IN (${List.filled(excluded.length, '?').join(',')})';
    final exSubSql = excluded.isEmpty
        ? ''
        : ' AND ss2.id NOT IN (${List.filled(excluded.length, '?').join(',')})';
    final rows = await db.rawQuery(
      '''
      SELECT s.* FROM sets s
      JOIN session_exercises se ON se.id = s.session_exercise_id
      JOIN sessions ss ON ss.id = se.session_id
      WHERE se.exercise_key = ? AND ss.status = 'done'
        AND s.kind = 'working'
        $exSql
        AND se.session_id = (
          SELECT se2.session_id
          FROM session_exercises se2
          JOIN sessions ss2 ON ss2.id = se2.session_id
          WHERE se2.exercise_key = ? AND ss2.status = 'done'
          $exSubSql
          ORDER BY ss2.id DESC
          LIMIT 1
        )
      ORDER BY s.id ASC
    ''',
      [key, ...excluded, key, ...excluded],
    );
    return rows.map(SetEntry.fromMap).toList();
  }

  /// 上次完成该动作的那次训练里的计划组数（用于下次处方少做判定）。
  /// 与 [lastWorkingSets] 同一场次口径：同一场次同键动作（含同义名）有多行时逐行相加。
  /// 每行优先 target_sets 快照；老记录没有快照时回退**该行当时的 rule**
  /// （session_exercises.rule JSON）里的 workingSets——不能拿用户后来改的
  /// 当前规则去猜上一场。无历史返回 0。
  ///
  /// 只统计**计划行**（2026-10-18）：`target_sets > 0`（v6+ 模板快照）
  /// 或 `trace = ''`（v5 前老行，全是计划原样）/ `trace LIKE '替换自：%|
  /// Replaced from %'`（替换行占用计划槽位且保留快照）。训练中临时追加的
  /// 行（trace='追加于：…' / 'Added …'）不计入计划组数——它不是计划的一部分，
  /// 否则下一场的「上次计划 N 组」会把临时加练当成计划目标（少做判定失真）。
  /// 减载/停练回归里追加行的 target_sets 也被写成 2（>0），同样被 trace
  /// 白名单排除。trace 是落库时的本地化文案，白名单枚举 zh/en 两种写法。
  Future<int> lastTargetSets(
    String exerciseName, {
    String? exerciseKey,
    Set<int>? excludeSessionIds,
  }) async {
    final key = _effectiveExerciseKey(exerciseName, exerciseKey);
    if (key.isEmpty) return 0;
    final db = await database;
    final excluded = excludeSessionIds ?? const <int>{};
    final exSubSql = excluded.isEmpty
        ? ''
        : ' AND ss2.id NOT IN (${List.filled(excluded.length, '?').join(',')})';
    final rows = await db.rawQuery(
      '''
      SELECT se.target_sets, se.rule
      FROM session_exercises se
      JOIN sessions ss ON ss.id = se.session_id
      WHERE se.exercise_key = ? AND ss.status = 'done'
        AND (se.trace = '' OR se.trace LIKE '替换自：%' OR se.trace LIKE 'Replaced from %')
        AND se.session_id = (
          SELECT se2.session_id
          FROM session_exercises se2
          JOIN sessions ss2 ON ss2.id = se2.session_id
          WHERE se2.exercise_key = ? AND ss2.status = 'done'
          $exSubSql
          ORDER BY ss2.id DESC
          LIMIT 1
        )
    ''',
      [key, key, ...excluded],
    );
    var total = 0;
    for (final r in rows) {
      final snapshot = (r['target_sets'] as num?)?.toInt() ?? 0;
      total += snapshot > 0 ? snapshot : ruleFromJson(r['rule']).workingSets;
    }
    return total;
  }

  /// 上次完成该动作的那次训练里，最后一组正式组所属动作行的记录形态
  /// （logging, load_type）；无历史返回 null。
  /// 渐进判定要用**上一场当时的形态**解释上一场的次数/链，而不是用户
  /// 后来改成的当前形态（按次 ↔ 计时、自重 ↔ 负重）。
  Future<(String, String)?> lastExerciseModes(
    String exerciseName, {
    String? exerciseKey,
    Set<int>? excludeSessionIds,
  }) async {
    final key = _effectiveExerciseKey(exerciseName, exerciseKey);
    if (key.isEmpty) return null;
    final db = await database;
    final excluded = excludeSessionIds ?? const <int>{};
    final exSubSql = excluded.isEmpty
        ? ''
        : ' AND ss2.id NOT IN (${List.filled(excluded.length, '?').join(',')})';
    final rows = await db.rawQuery(
      '''
      SELECT se.logging, se.load_type
      FROM sets s
      JOIN session_exercises se ON se.id = s.session_exercise_id
      JOIN sessions ss ON ss.id = se.session_id
      WHERE se.exercise_key = ? AND ss.status = 'done'
        AND s.kind = 'working'
        AND se.session_id = (
          SELECT se2.session_id
          FROM session_exercises se2
          JOIN sessions ss2 ON ss2.id = se2.session_id
          WHERE se2.exercise_key = ? AND ss2.status = 'done'
          $exSubSql
          ORDER BY ss2.id DESC
          LIMIT 1
        )
      ORDER BY s.id DESC
      LIMIT 1
    ''',
      [key, key, ...excluded],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return (
      (r['logging'] as String?) ?? 'reps',
      (r['load_type'] as String?) ?? 'weighted',
    );
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

  /// 某一天的身体记录（开练前体重面板判定「今天记过没」用）；没有返回 null。
  Future<BodyMetric?> bodyMetricOn(String date) async {
    final db = await database;
    final rows = await db.query('body_metrics',
        where: 'date = ?', whereArgs: [date], limit: 1);
    return rows.isEmpty ? null : BodyMetric.fromMap(rows.first);
  }

  // ---------- hr samples（v13 心率采样） ----------
  /// 会话结束一次性批量写入（~1Hz 一场几百到几千行，batch 一次事务）。
  Future<void> insertHrSamples(int sessionId, List<HrPoint> points) async {
    if (points.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final p in points) {
      batch.insert('hr_sample', {
        'session_id': sessionId,
        'ts': p.ts,
        'bpm': p.bpm,
      });
    }
    await batch.commit(noResult: true);
  }

  /// 某场训练的心率曲线（按时间正序）；无采样（没连设备/老记录）返回空。
  Future<List<HrPoint>> hrSamplesOfSession(int sessionId) async {
    final db = await database;
    final rows = await db.query('hr_sample',
        where: 'session_id = ?',
        whereArgs: [sessionId],
        orderBy: 'ts, id');
    return rows.map(HrPoint.fromMap).toList();
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
    final rows = await db.rawQuery(
      '''
      SELECT l.* FROM lark_sync l
      JOIN plan_days d ON d.id = l.ref_id
      WHERE l.ref_type = 'plan_day' AND d.plan_id = ?
    ''',
      [planId],
    );
    return rows.map(LarkSync.fromMap).toList();
  }

  Future<List<Map<String, Object?>>> sessionRowsBetween(
      String from, String to) async {
    final db = await database;
    return db.rawQuery('''
      SELECT ss.id AS session_id, ss.date, ss.plan_day_title,
             ss.started_at, ss.ended_at,
             se.id AS se_id, se.name, se.exercise_key, se.order_idx,
             se.logging,
             s.weight_kg, s.reps, s.rir, s.kind, s.done_at, s.rir_recorded
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
    final sp = _sessionPrefs;
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
      'exercise_notes': await db.query('exercise_notes'),
      'hr_sample': await db.query('hr_sample'),
      // 本机偏好标记（减载/停练 + 训练块锚点）：随快照带走，恢复时写回。
      // 未 attach SharedPreferences（老测试路径）时为 null，恢复侧跳过。
      'prefs': sp == null
          ? null
          : {
              'deload_sessions': sp.getString(_kDeloadPrefsKey),
              'block_anchors': {
                for (final k in sp.getKeys())
                  if (k.startsWith(_kAnchorPrefsPrefix)) k: sp.getString(k),
              },
            },
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
        'exercise_notes',
        'lark_sync',
        'sync_queue',
        'deleted_plans',
        'hr_sample',
      ]) {
        await tx.delete(t);
      }
    });
  }

  /// 从导出的全量 JSON 恢复（先清空再写入，事务保证要么全成要么不动）。
  /// 行按备份里的原 id 插入，训练/计划的外键关系原样保留；
  /// lark_sync / sync_queue 不在备份里，清空后留空（下次同步自动重建）。
  ///
  /// 备份里的 `prefs` 段（减载/停练标记 + 训练块锚点）在数据库事务成功后
  /// 写回本机 SharedPreferences（2026-10-18）：恢复 = 回到备份时点，统计
  /// 回溯的标记也要跟着回去。锚点先清后写，不留指向已不存在计划的旧键。
  /// 老备份没有 `prefs` 段时不动本机标记——两类标记都自带指纹校验
  ///（对不上库内会话会被自动剔除），宁可少排除、不误排除真实训练。
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
        'exercise_notes',
        'hr_sample',
      ]) {
        await tx.delete(t);
      }
      // 父表先插，满足外键约束；exercise_meta 主键冲突时以备份为准
      final restoredNameToKey = <String, String>{};
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
        'exercise_notes',
        'hr_sample',
      ]) {
        final rows = data[t];
        if (rows is! List) continue;
        for (final row in rows) {
          if (row is! Map) continue;
          final m = Map<String, Object?>.from(row);
          // 老备份没有 exercise_key（v14-），或 v15 备份的键还是原始名字：
          // 恢复时按 v16 口径补/归一，避免恢复后历史查询漏行。显式定制键保留。
          if (t == 'plan_exercises' || t == 'session_exercises') {
            final name = (m['name'] as String?) ?? '';
            final key = (m['exercise_key'] as String?) ?? '';
            if (key.isEmpty || key == name) {
              m['exercise_key'] = exerciseKeyOf(name);
            }
            if (name.isNotEmpty) {
              restoredNameToKey[name] = (m['exercise_key'] as String?) ?? '';
            }
          }
          // 备注：按恢复出来的动作名/别名把旧 key 归一；同键冲突取较新一条。
          if (t == 'exercise_notes') {
            final oldKey = (m['exercise_key'] as String?) ?? '';
            final newKey =
                _noteKeyAfterNormalization(oldKey, restoredNameToKey) ?? oldKey;
            final existing = await tx.query(
              'exercise_notes',
              where: 'exercise_key = ?',
              whereArgs: [newKey],
              limit: 1,
            );
            if (existing.isNotEmpty) {
              final oldUpdated = (m['updated_at'] as num?)?.toInt() ?? 0;
              final existingUpdated =
                  (existing.first['updated_at'] as num?)?.toInt() ?? 0;
              if (oldUpdated > existingUpdated) {
                await tx.update(
                  'exercise_notes',
                  {
                    'setup_note': (m['setup_note'] as String?) ?? '',
                    'updated_at': oldUpdated,
                  },
                  where: 'exercise_key = ?',
                  whereArgs: [newKey],
                );
              }
              continue; // 已合并，不再插重复主键
            }
            m['exercise_key'] = newKey;
          }
          await tx.insert(
            t,
            m,
            conflictAlgorithm: t == 'exercise_meta'
                ? ConflictAlgorithm.replace
                : ConflictAlgorithm.abort,
          );
        }
      }
    });
    // 数据库事务成功后再写偏好标记：事务失败时本机标记保持原样。
    final sp = _sessionPrefs;
    final prefsSection = data['prefs'];
    if (sp == null || prefsSection is! Map) return;
    // 训练块锚点：先清本机全部，再写入备份里的（防旧键指向已不存在的计划）。
    for (final k in sp
        .getKeys()
        .where((k) => k.startsWith(_kAnchorPrefsPrefix))
        .toList()) {
      await sp.remove(k);
    }
    final anchors = prefsSection['block_anchors'];
    if (anchors is Map) {
      for (final e in anchors.entries) {
        final k = e.key;
        final v = e.value;
        if (k is String && v is String) {
          await sp.setString(k, v);
        }
      }
    }
    // 减载周/停练回归标记：备份里有就原样带回；备份时点没有（null）则清掉。
    final deload = prefsSection['deload_sessions'];
    if (deload is String) {
      await sp.setString(_kDeloadPrefsKey, deload);
    } else {
      await sp.remove(_kDeloadPrefsKey);
    }
  }
}

/// 一条心率采样（v13 hr_sample 行）：ts = epoch ms，bpm 已在服务层
/// 过滤非法值（0 / >250 / 短包不采样）。放在 db 层让服务、UI、测试
/// 共用同一定义，db.dart 不反向依赖 services。
class HrPoint {
  const HrPoint(this.ts, this.bpm);

  final int ts;
  final int bpm;

  factory HrPoint.fromMap(Map<String, Object?> m) => HrPoint(
        m['ts'] as int,
        m['bpm'] as int,
      );

  @override
  bool operator ==(Object other) =>
      other is HrPoint && other.ts == ts && other.bpm == bpm;

  @override
  int get hashCode => Object.hash(ts, bpm);
}
