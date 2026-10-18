import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/db.dart';
import 'export_service.dart';

/// 本地自动快照（P0-A）：每次训练结束写一份全量 JSON 到
/// `<应用文档目录>/backups/`，启动时距上次快照超过 24 小时也补一份。
///
/// 轮转口径（GFS 的简化版）：保留最近 7 个「日内最新」快照 + 4 个
/// 「周内最新」快照，按文件去重后最多 11 份。等价上限，避免只按数量
/// 截断时同一天的多次训练把上周唯一一份挤掉。
///
/// 全程只读写本机文件：不联网、不引入新依赖、不上传任何数据。
class AutoBackupService extends ChangeNotifier {
  AutoBackupService(this._db, {Future<Directory> Function()? directoryProvider})
    : _directoryProvider =
          directoryProvider ?? getApplicationDocumentsDirectory;

  final Db _db;
  final Future<Directory> Function() _directoryProvider;

  static const String filePrefix = 'leanlift_backup_';
  static const int dailyKeep = 7;
  static const int weeklyKeep = 4;
  static const Duration launchGap = Duration(hours: 24);
  static final RegExp _namePattern = RegExp(r'^leanlift_backup_(\d+)\.json$');

  Timer? _pendingTimer;
  Future<void>? _pendingWait;
  bool _disposed = false;

  /// 预约代次：取消时 +1，让已经触发但还在等前置写入的任务作废。
  int _generation = 0;

  /// 串行队列：快照、恢复、清空互不穿插（清空能等到 in-flight 快照结束再删）。
  Future<void> _tail = Future.value();

  String? _lastError;

  /// 最近一次自动快照失败的原因（运行时状态，不落盘）。
  /// 变化会 notifyListeners，数据页据此刷新提示；成功后清空。
  String? get lastError => _lastError;

  void _setLastError(String? value) {
    if (_lastError == value) return;
    _lastError = value;
    _notify();
  }

  /// App 容器/测试上报失败（启动补档等非预约路径）。
  void recordError(Object error) => _setLastError(error.toString());

  /// 关闭自动备份时清掉旧的失败提示，避免重新打开时先亮一条过时警告。
  void clearError() => _setLastError(null);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    // 队列本身吞掉错误继续往下走，错误仍由 result 交给调用方。
    _tail = result.then<void>((_) {}, onError: (Object e) {});
    return result;
  }

  /// 预约一次后台快照（合并短时间内的多次触发）。
  /// [waitFor] 用于等心率采样落库等前置写入；重复调用时保留已有的等待项。
  void scheduleSnapshot({
    Duration delay = const Duration(milliseconds: 500),
    Future<void>? waitFor,
  }) {
    _pendingWait = waitFor ?? _pendingWait;
    _pendingTimer?.cancel();
    final generation = _generation;
    _pendingTimer = Timer(delay, () {
      final wait = _pendingWait;
      _pendingWait = null;
      unawaited(_runScheduled(wait, generation));
    });
  }

  /// 取消尚未触发的预约（清空数据/关闭自动备份时用）。
  /// 已触发但还在等前置写入（如心率落库）的任务也一并作废。
  void cancelScheduled() {
    _generation++;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingWait = null;
  }

  @override
  void dispose() {
    _disposed = true;
    cancelScheduled();
    super.dispose();
  }

  Future<void> _runScheduled(Future<void>? wait, int generation) async {
    if (wait != null) {
      try {
        await wait;
      } catch (_) {}
    }
    // 等待期间被取消（清空/关开关/恢复）：别再写回一份。
    if (generation != _generation || _disposed) return;
    try {
      await snapshotNow();
    } catch (e) {
      // 后台快照失败不能打断任何用户操作；记下原因供数据页提示。
      _setLastError(e.toString());
    }
  }

  /// 删除全部自动快照（「清空全部数据」/卖机前隐私清理）。
  /// 进串行队列：排在已开始的快照之后，等它落盘再一起删；
  /// 同时取消尚未触发的预约，避免刚删完又写回一份。
  Future<void> deleteAll() {
    return _serialized(() async {
      cancelScheduled();
      final all = await listBackups();
      for (final b in all) {
        await b.file.delete();
      }
      // 清空是隐私操作：连正在写/中断留下的 .tmp（可能含完整数据）一起删。
      await _cleanTmp(force: true);
      // 有文件没删掉时不能报"已清空"：交给 UI 提示重试。
      final leftovers = await _residualFiles();
      if (leftovers.isNotEmpty) {
        throw FileSystemException(
          '未能删除 ${leftovers.length} 个自动备份文件',
          leftovers.first.path,
        );
      }
      _setLastError(null);
      _notify();
    });
  }

  Future<List<File>> _residualFiles() async {
    final dir = await backupDir();
    final out = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.endsWith('.tmp') || _namePattern.hasMatch(name)) {
        out.add(entity);
      }
    }
    return out;
  }

  /// 备份目录（不存在时创建）。
  Future<Directory> backupDir() async {
    final base = await _directoryProvider();
    final dir = Directory(p.join(base.path, 'backups'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 全部自动快照，按时间从新到旧。
  Future<List<BackupInfo>> listBackups() async {
    final dir = await backupDir();
    final out = <BackupInfo>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        final info = await _infoOf(entity);
        if (info != null) out.add(info);
      } catch (_) {
        // 并发轮转/外部删除导致 stat 失败：跳过这一个，不影响其余备份。
      }
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<BackupInfo?> latestBackup() async {
    final all = await listBackups();
    return all.isEmpty ? null : all.first;
  }

  /// 立即写一份全量快照并执行轮转。返回写出的文件信息。
  /// 失败向上抛（调用方决定是否静默），不留下半截文件（先写 .tmp 再改名）。
  Future<BackupInfo> snapshotNow({DateTime? at}) {
    return _serialized(() async {
      final now = (at ?? DateTime.now()).toLocal();
      final data = await _db.exportAllJson();
      return _writeSnapshot(data, now);
    });
  }

  Future<BackupInfo> _writeSnapshot(
    Map<String, dynamic> data,
    DateTime now,
  ) async {
    final dir = await backupDir();
    // 自动快照用紧凑 JSON（不给人看，体积优先）；手动导出的存档仍带缩进。
    final json = jsonEncode(data);
    final file = File(
      p.join(dir.path, '$filePrefix${now.millisecondsSinceEpoch}.json'),
    );
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(file.path);
    final info = BackupInfo(
      file: file,
      createdAt: now,
      sizeBytes: await file.length(),
    );
    await _prune();
    _lastError = null; // 成功即清掉旧错误，避免页面继续亮警告。
    _notify(); // 数据页若正开着，最近备份时间/列表立即刷新。
    return info;
  }

  /// 启动补档：没有快照、或距最近快照 ≥24 小时才写。
  /// 空库（首次启动/还没练过）不写无意义的空快照。
  /// 返回新快照；不需要补档时返回 null。
  ///
  /// 「读最近备份 + 导出全库 + 写盘」整体走串行队列：导出可能耗时几百毫秒，
  /// 若只有写盘进队列，期间的 deleteAll/restore 先跑完，补档会把删掉/被
  /// 恢复覆盖前的旧数据当作一份新快照写回去。
  Future<BackupInfo?> maybeSnapshotOnLaunch({
    DateTime? at,
    Duration gap = launchGap,
  }) {
    return _serialized(() async {
      final now = (at ?? DateTime.now()).toLocal();
      final latest = await latestBackup();
      if (latest != null && now.difference(latest.createdAt) < gap) {
        return null;
      }
      // 只导出一次：既用来判断空库，也直接写盘，避免重复读全库。
      final data = await _db.exportAllJson();
      if (!_hasUserData(data)) return null;
      return _writeSnapshot(data, now);
    });
  }

  /// 有会话（含 quit/active）、有任意计划、或有身体数据才算"有数据"；
  /// 空库启动不写空快照。
  static bool _hasUserData(Map<String, dynamic> data) {
    for (final key in const ['sessions', 'plans', 'body_metrics']) {
      final rows = data[key];
      if (rows is List && rows.isNotEmpty) return true;
    }
    return false;
  }

  /// 恢复前预览：解析并校验备份，给出可展示的数据量。
  /// 训练次数只算 status='done'（放弃/进行中的会话不算一次训练）。
  Future<BackupPreview> preview(BackupInfo info) async {
    final data = await _read(info);
    final sessions = data['sessions'] as List;
    final done = sessions
        .where((s) => s is Map && s['status'] == 'done')
        .length;
    return BackupPreview(
      info: info,
      sessions: done,
      plans: (data['plans'] as List).length,
      bodyMetrics: (data['body_metrics'] as List?)?.length ?? 0,
      sets: (data['sets'] as List?)?.length ?? 0,
    );
  }

  /// 从指定自动备份恢复（清空后写入，事务兜底）。返回恢复的训练次数。
  /// 走串行队列：先等已开始的快照落盘，避免恢复写到一半又被导出。
  Future<int> restore(BackupInfo info) {
    return _serialized(() async {
      final data = await _read(info);
      final n = await ExportService(_db).restoreFromJson(data);
      _setLastError(null);
      _notify();
      return n;
    });
  }

  Future<Map<String, dynamic>> _read(BackupInfo info) async {
    final raw = jsonDecode(await info.file.readAsString());
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('备份内容不是有效的 JSON 对象');
    }
    ExportService.validateBackupData(raw);
    return raw;
  }

  Future<BackupInfo?> _infoOf(File file) async {
    final name = p.basename(file.path);
    final match = _namePattern.firstMatch(name);
    if (match == null) return null;
    final ms = int.tryParse(match.group(1)!);
    if (ms == null) return null;
    final stat = await file.stat();
    return BackupInfo(
      file: file,
      createdAt: DateTime.fromMillisecondsSinceEpoch(ms),
      sizeBytes: stat.size,
    );
  }

  /// 日内（同日多次只留最新）+ 周内（同周只留最新）双桶轮转。
  Future<void> _prune() async {
    final all = await listBackups();
    if (all.isEmpty) return;

    final keep = <String>{};
    final days = <String>{};
    for (final b in all) {
      if (days.add(_dayKey(b.createdAt))) {
        keep.add(b.file.path);
        if (days.length >= dailyKeep) break;
      }
    }
    final weeks = <String>{};
    for (final b in all) {
      if (weeks.add(_weekKey(b.createdAt))) {
        keep.add(b.file.path);
        if (weeks.length >= weeklyKeep) break;
      }
    }
    for (final b in all) {
      if (keep.contains(b.file.path)) continue;
      try {
        await b.file.delete();
      } catch (_) {
        // 单个文件删不掉（被占用等）不阻塞本次备份，下次轮转再试。
      }
    }
    await _cleanTmp();
  }

  /// 清理中断写入留下的 .tmp（不参与轮转，也不会被当成备份列出）。
  /// 日常轮转只删一小时前的——并发的另一份快照可能正在写它的 .tmp；
  /// [force]（清空全部数据）时一律删除，避免留下含数据的临时文件。
  Future<void> _cleanTmp({bool force = false}) async {
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    final dir = await backupDir();
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.tmp')) {
        try {
          final stat = await entity.stat();
          if (force || stat.modified.isBefore(cutoff)) await entity.delete();
        } catch (_) {}
      }
    }
  }

  static String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  /// 以周一日期作周键，避开 ISO 跨年周的边界问题。
  static String _weekKey(DateTime d) {
    final monday = DateTime(
      d.year,
      d.month,
      d.day,
    ).subtract(Duration(days: d.weekday - 1));
    return _dayKey(monday);
  }
}

/// 一份自动快照的元信息（时间取自文件名，不依赖文件 mtime）。
class BackupInfo {
  const BackupInfo({
    required this.file,
    required this.createdAt,
    required this.sizeBytes,
  });

  final File file;
  final DateTime createdAt;
  final int sizeBytes;
}

/// 恢复前预览（数据量来自备份 JSON 本身）。
class BackupPreview {
  const BackupPreview({
    required this.info,
    required this.sessions,
    required this.plans,
    required this.bodyMetrics,
    required this.sets,
  });

  final BackupInfo info;
  final int sessions;
  final int plans;
  final int bodyMetrics;
  final int sets;
}
