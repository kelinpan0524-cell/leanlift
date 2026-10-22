import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条本地诊断记录（不带任何训练内容，只记状态与错误摘要）。
class DiagEntry {
  const DiagEntry({required this.at, required this.tag, required this.message});

  /// 墙钟毫秒 epoch。
  final int at;
  final String tag;
  final String message;

  Map<String, Object?> toJson() => {'t': at, 'tag': tag, 'msg': message};

  static DiagEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = (raw['t'] as num?)?.toInt();
    final tag = raw['tag'];
    final msg = raw['msg'];
    if (at == null || tag is! String || msg is! String) return null;
    return DiagEntry(at: at, tag: tag, message: msg);
  }
}

/// 本地滚动诊断日志（2026-10-22）：
/// - 未捕获异常（Flutter 框架 / 异步平台错误）与关键生命周期事件写进
///   手机本地 SharedPreferences，只保留最近 [maxEntries] 条；
/// - 只读本地、不上传、不记录任何训练数据或密钥；用于「App 自动退出」
///   之后回来看退出前发生了什么。
class DiagnosticLog {
  DiagnosticLog(this._prefs, {this.maxEntries = 200}) {
    _load();
  }

  static const String prefsKey = 'diag.log.v1';
  static const int _maxMessageChars = 800;

  final SharedPreferences _prefs;
  final int maxEntries;
  final List<DiagEntry> _entries = [];

  /// 只读快照（按时间正序，最后一条最新）。
  List<DiagEntry> get entries => List.unmodifiable(_entries);

  void log(String tag, String message) {
    final entry = DiagEntry(
      at: DateTime.now().millisecondsSinceEpoch,
      tag: tag.length > 24 ? tag.substring(0, 24) : tag,
      message: message.length > _maxMessageChars
          ? message.substring(0, _maxMessageChars)
          : message,
    );
    _entries.add(entry);
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    unawaited(_persist());
  }

  void logError(String tag, Object error, [StackTrace? stack]) {
    final buffer = StringBuffer(error.toString());
    if (stack != null) {
      // 只留栈顶几行：足够定位，又不会让 prefs 膨胀。
      final lines = stack.toString().split('\n');
      buffer.write('\n');
      buffer.write(lines.take(8).join('\n'));
    }
    log(tag, buffer.toString());
  }

  /// 装上全局异常钩子（只在 main 里调用一次；测试不要装，
  /// 否则框架会认为每个用例的异常都被处理了）。
  static bool _installed = false;

  void install() {
    if (_installed) return;
    _installed = true;
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      logError('flutter', details.exception, details.stack);
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    final previousAsync = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (error, stack) {
      logError('async', error, stack);
      return previousAsync?.call(error, stack) ?? false;
    };
    log('app', 'diagnostic handlers installed');
  }

  /// 等当前这轮写盘落地（测试用；正式代码不等待）。
  Future<void> flush() => _persist();

  Future<void> _persist() async {
    try {
      await _prefs.setString(
        prefsKey,
        jsonEncode([for (final e in _entries) e.toJson()]),
      );
    } catch (_) {
      // 诊断日志写失败不能反过来影响 App。
    }
  }

  void _load() {
    final raw = _prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final v in list) {
        final e = DiagEntry.fromJson(v);
        if (e != null) _entries.add(e);
      }
      while (_entries.length > maxEntries) {
        _entries.removeAt(0);
      }
    } catch (_) {
      // 日志损坏直接当没有，不影响启动。
    }
  }
}
