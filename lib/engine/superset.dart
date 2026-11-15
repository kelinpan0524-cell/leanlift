// 超级组（superset，2026-09-29）：同一训练日内相邻动作打同一 tag，
// 训练时按轮转交替执行（A1→B1→A2→B2…）。本文件是纯 Dart 推导层——
// 输入 tag 列表 / 计划组数 / 已完成正式组数，输出推进、恢复与清理动作，
// 不碰数据库与 UI，全部可单测（计划页、编辑页、训练中三层共用同一语义）。
//
// 语义钉死：
// - '' = 不配对；同 tag 且相邻（order 连续段）= 一个超级组；
//   被拆散的同 tag 段互不算同组（编辑层由 supersetTagClears 清理）；
// - 组内轮转：完成任一动作的一组后，轮到组内「下一个还有剩余计划组」
//   的动作（从自己之后数起、绕回，只剩自己则留在原动作）；
//   组内全部练满 → 出组，接组尾后第一个动作；
// - 不配对动作行为与旧线性推进完全一致（做完自己的组才前进，
//   练满后落到下一动作身上，即使它已被练满也照旧走加练口径）。
import 'dart:math';

/// 新建一个超级组标记：时间戳+随机尾巴，只求进程内唯一，不承载含义。
String newSupersetTag() {
  final r = Random();
  return 'ss${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
      '${r.nextInt(1 << 20).toRadixString(36).padLeft(3, '0')}';
}

/// 识别超级组：返回所有「同 tag 且相邻、人数 ≥2」的成员下标组。
List<List<int>> contiguousSupersetGroups(List<String> tags) {
  final out = <List<int>>[];
  var i = 0;
  while (i < tags.length) {
    final t = tags[i];
    if (t.isEmpty) {
      i++;
      continue;
    }
    var j = i + 1;
    while (j < tags.length && tags[j] == t) {
      j++;
    }
    if (j - i >= 2) out.add([for (var k = i; k < j; k++) k]);
    i = j;
  }
  return out;
}

/// 下标 [idx] 所属超级组的成员下标（含自己）；不在任何组内返回 null。
List<int>? supersetMembersOf(int idx, List<String> tags) {
  for (final g in contiguousSupersetGroups(tags)) {
    if (g.contains(idx)) return g;
  }
  return null;
}

/// 完成某动作一组后的下一个动作下标；null = 全部动作练满（结束会话）。
///
/// [plannedSets] 各动作计划正式组数；[doneWorking] 各动作已完成正式组数
/// （都不含热身）；[justIdx] 刚完成这组的动作下标。
int? nextExerciseIdxAfterSet({
  required List<String> tags,
  required List<int> plannedSets,
  required List<int> doneWorking,
  required int justIdx,
}) {
  assert(justIdx >= 0 && justIdx < tags.length);
  final group = supersetMembersOf(justIdx, tags);
  if (group == null) {
    // 不配对：旧线性语义——未练满留在原动作，练满 +1（末尾 = 结束）。
    if (doneWorking[justIdx] < plannedSets[justIdx]) return justIdx;
    return justIdx < tags.length - 1 ? justIdx + 1 : null;
  }
  final remaining =
      group.where((i) => doneWorking[i] < plannedSets[i]).toList();
  if (remaining.isEmpty) {
    // 组内全满：出组到组尾后第一个动作（无则整个会话结束）。
    final after = group.last + 1;
    return after < tags.length ? after : null;
  }
  // 轮转：从自己之后数起、绕回一圈，第一个还有剩余组的成员；
  // 走满一圈必然命中（remaining 非空），只剩自己时命中的就是自己。
  final pos = group.indexOf(justIdx);
  for (var step = 1; step <= group.length; step++) {
    final cand = group[(pos + step) % group.length];
    if (remaining.contains(cand)) return cand;
  }
  return justIdx; // 不可达（防御）：remaining 非空保证上面必然返回
}

/// 计划轮转序列（全部计划正式组按执行顺序展开成动作下标流）：
/// 超级组成员逐轮交替（A,B,A,B…，组数不齐的成员只出现在自己的轮里），
/// 非成员动作各自己的组连续展开。仅用于推导恢复落点。
List<int> plannedVisitSequence({
  required List<String> tags,
  required List<int> plannedSets,
}) {
  final out = <int>[];
  var i = 0;
  while (i < tags.length) {
    final t = tags[i];
    var j = i + 1;
    if (t.isNotEmpty) {
      while (j < tags.length && tags[j] == t) {
        j++;
      }
    }
    final members = [for (var k = i; k < j; k++) k];
    if (members.length >= 2) {
      final rounds = members
          .map((m) => plannedSets[m])
          .reduce((a, b) => a > b ? a : b);
      for (var r = 0; r < rounds; r++) {
        for (final m in members) {
          if (r < plannedSets[m]) out.add(m);
        }
      }
    } else {
      for (var s = 0; s < plannedSets[i]; s++) {
        out.add(i);
      }
    }
    i = j;
  }
  return out;
}

/// 被杀恢复/打开进行中会话时的落点：按计划轮转序列走位——顺序消费
/// 序列槽位（每个动作最多消费到它的 doneWorking 次），第一个没被
/// 消费掉的槽位就是接下来该练的动作；全部消费完（都进加练态）回落
/// 到最后一个动作。不配对时序列退化为线性，与旧「第一个未练满」一致。
int resumeExerciseIdx({
  required List<String> tags,
  required List<int> plannedSets,
  required List<int> doneWorking,
}) {
  if (tags.isEmpty) return 0;
  final seq = plannedVisitSequence(tags: tags, plannedSets: plannedSets);
  final taken = List<int>.filled(tags.length, 0);
  for (final idx in seq) {
    if (taken[idx] < doneWorking[idx]) {
      taken[idx]++;
      continue;
    }
    return idx;
  }
  return tags.length - 1;
}

/// 标记清理（编辑层重排/删除后调用）：同 tag 只在「连续段 ≥2 人」时
/// 保留；被拆散成单人（或被隔开）的段返回应清空 tag 的下标。
List<int> supersetTagClears(List<String> tags) {
  final clears = <int>[];
  var i = 0;
  while (i < tags.length) {
    final t = tags[i];
    if (t.isEmpty) {
      i++;
      continue;
    }
    var j = i + 1;
    while (j < tags.length && tags[j] == t) {
      j++;
    }
    if (j - i < 2) clears.add(i);
    i = j;
  }
  return clears;
}
