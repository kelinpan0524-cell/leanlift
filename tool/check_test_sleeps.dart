#!/usr/bin/env dart
// 测试规范检查：不许「先固定睡一段，再直接断言」。
//
// 为什么要查：固定 `Future.delayed` 的等待时长是猜出来的。本地快、CI runner
// 慢，同一段 400ms 在慢机器上不够长就偶发失败（PR #79 找不到「训练完成 💪」
// 就是这个根因）；在快机器上又是纯浪费。等待应当由「目标真的出现了」结束，
// 而不是由时钟结束。
//
// 规则：一行 `await Future.delayed(...)` / `await Future<void>.delayed(...)`
// 之后 8 行内出现 `expect(` → 违规。中间允许隔着 `});`、`tester.pump(...)`
// 这类不改变「等完就断言」性质的语句。
//
// 两个逃生口，都必须写理由：
// - 行级：等待行或它上一行写 `// test-sleep-allowed: 理由`
// - 文件级：登记在 [_fileAllowlist]，表示该文件本次尚未迁移（TODO 清单）
//
// 用法：dart tool/check_test_sleeps.dart [--verbose]
// 退出码：0 = 无违规；1 = 有违规。

import 'dart:io';

/// 往后看多少行找 `expect(`。
const int _lookahead = 8;

/// 本次只迁移了训练流程与周复盘两个最脆的文件；其余文件里的固定等待是
/// 已知 TODO（随任务报告登记），先显式列出来，避免检查一上线就全红。
/// 每迁完一个文件就从这里删一行。
const Map<String, String> _fileAllowlist = {
  'test/auto_backup_test.dart': 'TODO(2026-11-08): 7 处固定等待，待改条件轮询',
  'test/auto_backup_wiring_test.dart': 'TODO(2026-11-08): 1 处固定等待，待改条件轮询',
  'test/dual_channel_test.dart': 'TODO(2026-11-08): 8 处固定等待，双通道提醒时序待改轮询',
  'test/exercise_notes_test.dart': 'TODO(2026-11-08): 3 处固定等待，待改条件轮询',
  'test/heart_rate_test.dart': 'TODO(2026-11-08): 1 处固定等待，待改条件轮询',
  'test/layoff_controller_test.dart': 'TODO(2026-11-08): 1 处固定等待，待改条件轮询',
  'test/local_bridge_test.dart': 'TODO(2026-11-08): 4 处固定等待，待改条件轮询',
  'test/session_controller_test.dart': 'TODO(2026-11-08): 10 处固定等待，纯控制器用例待改条件轮询',
  'test/weekly_recap_reminder_test.dart': 'TODO(2026-11-08): 2 处固定等待，待改条件轮询',
  'test/weight_draft_persistence_test.dart': 'TODO(2026-11-08): 2 处固定等待，待改条件轮询',
  'test/widget_layout_test.dart': 'TODO(2026-11-08): 5 处固定等待，布局用例待改条件轮询',
};

final RegExp _sleepPattern =
    RegExp(r'await\s+Future(<[^>]*>)?\s*\.delayed\s*\(');

/// 这些行表示「新的用例/块开始了」，往后看时到此为止。
final RegExp _boundaryPattern =
    RegExp(r'^(testWidgets|test|group)\s*\(|await\s+Future(<[^>]*>)?\s*\.delayed\s*\(');

void main(List<String> args) {
  final verbose = args.contains('--verbose');
  final dir = Directory('test');
  if (!dir.existsSync()) {
    stderr.writeln('找不到 test/ 目录（请在仓库根目录运行）');
    exit(2);
  }
  final files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  var violations = 0;
  var allowlisted = 0;
  final allowlistedFiles = <String>{};

  for (final file in files) {
    final rel = file.path.replaceAll('\\', '/');
    final fileReason = _fileAllowlist[rel];
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!_sleepPattern.hasMatch(line)) continue;
      if (!_expectFollows(lines, i)) continue;
      if (_hasLineAllowance(lines, i)) {
        allowlisted++;
        continue;
      }
      if (fileReason != null) {
        allowlisted++;
        allowlistedFiles.add(rel);
        continue;
      }
      violations++;
      stdout.writeln('$rel:${i + 1}: 固定等待后直接断言');
      stdout.writeln('    ${line.trim()}');
      stdout.writeln('    → 改成 pumpUntilFound / pumpUntilGone / 条件轮询；'
          '确有需要写 // test-sleep-allowed: 理由');
    }
  }

  if (verbose) {
    for (final f in allowlistedFiles) {
      stdout.writeln('白名单 ${_fileAllowlist[f]}：$f');
    }
  }
  if (violations > 0) {
    stdout.writeln('\n❌ 共 $violations 处「固定等待后直接断言」。');
    exitCode = 1;
    return;
  }
  final todo = allowlistedFiles.isEmpty
      ? ''
      : '；另有 $allowlisted 处登记在 TODO 白名单（${allowlistedFiles.length} 个文件）';
  stdout.writeln('✅ 测试固定等待检查通过：0 处违规$todo。');
}

/// 等待行之后 [_lookahead] 行内是否出现 `expect(`（遇到新用例/下一段等待就停）。
bool _expectFollows(List<String> lines, int i) {
  for (var j = i + 1; j < lines.length && j <= i + _lookahead; j++) {
    final l = lines[j];
    if (l.trim().isEmpty || l.trimLeft().startsWith('//')) continue;
    if (_boundaryPattern.hasMatch(l.trim())) return false;
    if (l.contains('expect(')) return true;
  }
  return false;
}

bool _hasLineAllowance(List<String> lines, int i) {
  for (final j in [i, i - 1]) {
    if (j >= 0 && lines[j].contains('test-sleep-allowed:')) return true;
  }
  return false;
}
