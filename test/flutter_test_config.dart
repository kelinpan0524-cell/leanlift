// 全量测试的统一前置（flutter test 自动套用；每个测试文件一个 isolate、
// 各执行一次 testExecutable）：
//
// 1. 测试平台语言钉成中文——项目测试基线是中文界面断言，而 Flutter 测试
//    环境默认系统语言是 en_US，「跟随系统」会被解析成英文导致批量假失败。
//    注意：框架在每个用例结束后会清掉测试平台的 override 值，所以必须在
//    setUp 里逐用例重新钉，不能只在入口钉一次。
//
// 2. 数据库目录按测试文件隔离（2026-10-22）：此前十几个测试文件各自在
//    setUpAll 里删除并重建同一个磁盘库文件 baoji_timer.db，全量跑时多个
//    suite 并发/相继互删同一文件，随机爆 SqliteException(1032)（写只读
//    库）与 FOREIGN KEY 失败——每次挂的用例都不同，纯测试隔离问题。
//    这里给每个 suite 换上独立的临时数据库目录：
//    - factory 用 createDatabaseFactoryFfi(ffiInit: ...)：ffiInit 回调在
//      专属 worker isolate 里执行，在那里替换 sqfliteFfiHandler 把数据库
//      根目录指到本 suite 专属目录（直接在主 isolate 替换对 isolate 版
//      factory 无效——worker 有自己的全局 handler 副本）。
//    - handler 只重定向 getDatabasesPathPlatform()，其余行为原样转发默认
//      IO 实现。测试代码 getDatabasesPath() 拼出的 baoji_timer.db、生产
//      代码 AppDatabase 打开的库，都落在本 suite 专属目录里——suite 之间
//      从磁盘层面彻底隔离。不要在测试文件里再给 databaseFactory 赋值，
//      会把这个定向 factory 换回共享目录的默认实现。
//    - 主 isolate 先建好目录再交给 worker（worker 端不建目录）；suite
//      跑完尽力删除临时目录（收尾异步仍在写时可能删不掉，重试两次，
//      仍删不掉的由下一次任意 suite 启动时清扫，不长期堆积）。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:sqflite_common_ffi/src/sqflite_ffi_impl.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:sqlite3/common.dart' as common;

/// 每个测试文件（suite）专属目录版 handler：只改数据库根目录，其余
/// 全部转发默认 IO handler。在 worker isolate 里装配（见 testExecutable）。
class _SuiteDirFfiHandler implements SqfliteFfiHandler {
  _SuiteDirFfiHandler(this._inner, this._dir);

  final SqfliteFfiHandler _inner;
  final String _dir;

  @override
  String getDatabasesPathPlatform() => _dir;

  @override
  Future<common.CommonDatabase> openPlatform(Map argumentsMap) =>
      _inner.openPlatform(argumentsMap);

  @override
  Future<void> deleteDatabasePlatform(String path) =>
      _inner.deleteDatabasePlatform(path);

  @override
  Future<void> writeDatabaseBytesPlatform(String path, Uint8List bytes) =>
      _inner.writeDatabaseBytesPlatform(path, bytes);

  @override
  Future<Uint8List> readDatabaseBytesPlatform(String path) =>
      _inner.readDatabaseBytesPlatform(path);

  @override
  Future<bool> handleDatabaseExistsPlatform(String path) =>
      _inner.handleDatabaseExistsPlatform(path);

  @override
  Future<void> handleOptionsPlatform(Map argumentMap) =>
      _inner.handleOptionsPlatform(argumentMap);
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  _sweepStaleSuiteDirs();
  final dir = Directory.systemTemp.createTempSync('leanlift_suite_db_');
  databaseFactory = createDatabaseFactoryFfi(
    // 这段跑在专属 worker isolate 里：worker 有自己的全局 handler 副本，
    // 必须在这里换（主 isolate 换不到）。ffiInit 非 null 时 worker 不再
    // 跑默认初始化，sqfliteFfiInit() 要显式补上。
    ffiInit: () {
      sqfliteFfiInit();
      sqfliteFfiHandler = _SuiteDirFfiHandler(sqfliteFfiHandler, dir.path);
    },
  );
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue =
        const Locale('zh');
  });
  try {
    await testMain();
  } finally {
    // 收尾异步（延迟落库等）可能还在写目录：重试两次；仍删不掉就留着，
    // 下一次任何 suite 启动时由 _sweepStaleSuiteDirs 清扫。
    for (var i = 0; i < 3; i++) {
      try {
        await dir.delete(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  }
}

/// 清扫上一轮运行残留的 suite 临时目录（收尾异步写文件导致删除失败的
/// 那部分）。只清 1 小时前的——进行中的本次运行目录不会被误删。
void _sweepStaleSuiteDirs() {
  final cutoff = DateTime.now().subtract(const Duration(hours: 1));
  for (final d in Directory.systemTemp.listSync(followLinks: false)) {
    if (d is! Directory) continue;
    final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (!name.startsWith('leanlift_suite_db_')) continue;
    final stat = d.statSync();
    if (stat.modified.isBefore(cutoff)) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {
        // 删不掉就等下一轮。
      }
    }
  }
}
