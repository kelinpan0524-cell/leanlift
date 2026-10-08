import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../engine/superset.dart';
import '../l10n/lang.dart';
import '../l10n/names.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 日历表头星期缩写（仅展示用；中文单字为键）。
const _weekdayEn = {
  '一': 'Mon',
  '二': 'Tue',
  '三': 'Wed',
  '四': 'Thu',
  '五': 'Fri',
  '六': 'Sat',
  '日': 'Sun',
};

IconData _impressionIcon(int v) => switch (v) {
      1 => Icons.sentiment_dissatisfied,
      3 => Icons.sentiment_satisfied_alt,
      _ => Icons.sentiment_neutral,
    };

Color _impressionColor(int v) => switch (v) {
      1 => AppTheme.warn,
      3 => AppTheme.primary,
      _ => AppTheme.textDim,
    };

/// 历史页：月历 + 当日训练明细。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month, 1);
  Map<String, List<Session>> _byDate = {};
  bool _loading = true;
  String? _selected;
  // 明细 future 按 session id 缓存：点日期切换不再重查全部卡片
  final Map<int, Future<List<Widget>>> _detailFutures = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final c = app(context);
    final first = _month;
    final last = DateTime(_month.year, _month.month + 1, 0);
    final sessions = await c.db.sessionsBetween(fmtDate(first), fmtDate(last));
    final map = <String, List<Session>>{};
    for (final s in sessions) {
      map.putIfAbsent(s.date, () => []).add(s);
    }
    if (!mounted) return;
    setState(() {
      _byDate = map;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final firstWeekday = DateTime(_month.year, _month.month, 1).weekday;
    final today = fmtDate(DateTime.now());

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: () {
                setState(() {
                  _month = DateTime(_month.year, _month.month - 1, 1);
                  _selected = null; // 切月清空选中，避免跨月残留
                  _loading = true;
                });
                _load();
              },
              icon: const Icon(Icons.chevron_left),
            ),
            const SizedBox(width: 8),
            Text(
              tx('${_month.year} 年 ${_month.month} 月',
                  en: '${_month.year}-${_month.month}'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () {
                setState(() {
                  _month = DateTime(_month.year, _month.month + 1, 1);
                  _selected = null;
                  _loading = true;
                });
                _load();
              },
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    for (final w in ['一', '二', '三', '四', '五', '六', '日'])
                      Expanded(
                        child: Center(
                          child: Text(
                            tx('周$w', en: _weekdayEn[w]),
                            style: const TextStyle(
                              color: AppTheme.textDim,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                ..._calendarRows(daysInMonth, firstWeekday, today),
                const SizedBox(height: 6),
                Text(
                  tx('点日期看当天明细 · 长按下方训练卡可删除误记的记录',
                      en: 'Tap a date for details · Long-press a workout card below to delete it'),
                  style: const TextStyle(color: AppTheme.textDim, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        ..._dayDetailSections(),
      ],
    );
  }

  List<Widget> _calendarRows(int daysInMonth, int firstWeekday, String today) {
    final rows = <Widget>[];
    var cell = 1 - (firstWeekday - 1);
    while (cell <= daysInMonth) {
      final cells = <Widget>[];
      for (var i = 0; i < 7; i++, cell++) {
        if (cell < 1 || cell > daysInMonth) {
          cells.add(const Expanded(child: SizedBox(height: 44)));
          continue;
        }
        final d = fmtDate(DateTime(_month.year, _month.month, cell));
        final has = _byDate.containsKey(d);
        final isToday = d == today;
        cells.add(
          Expanded(
            child: GestureDetector(
              onTap: has ? () => _selectDate(d) : null,
              child: Container(
                height: 44,
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: has
                      ? AppTheme.primary.withValues(alpha: 0.18)
                      : (isToday ? AppTheme.cardHi : null),
                  borderRadius: BorderRadius.circular(10),
                  border: isToday
                      ? Border.all(color: AppTheme.accent, width: 1)
                      : null,
                ),
                child: Center(
                  child: Text(
                    '$cell',
                    style: TextStyle(
                      color: has
                          ? AppTheme.primary
                          : (isToday ? AppTheme.accent : AppTheme.textDim),
                      fontWeight: has || isToday ? FontWeight.w700 : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
      rows.add(Row(children: cells));
    }
    return rows;
  }

  void _selectDate(String d) {
    setState(() => _selected = d);
  }

  List<Widget> _dayDetailSections() {
    final dates = (_selected != null) ? [_selected!] : _byDate.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    final out = <Widget>[];
    for (final date in dates.take(_selected == null ? 10 : 1)) {
      final sessions = _byDate[date];
      if (sessions == null) continue;
      for (final s in sessions) {
        out.add(_sessionCard(s));
      }
    }
    if (out.isEmpty) {
      out.add(
        Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text(tx('本月还没有训练记录', en: 'No workouts logged this month yet'),
                style: const TextStyle(color: AppTheme.textDim)),
          ),
        ),
      );
    }
    return out;
  }

  Widget _sessionCard(Session s) {
    return FutureBuilder<List<Widget>>(
      future: _detailFutures.putIfAbsent(s.id!, () => _sessionDetailWidgets(s)),
      builder: (context, snap) {
        return SectionCard(
          // 标题只放日期（定长不折行）：日期+计划题拆两行后，
          // 长标题不会再把「2026-09-26」从中间折断（2026-09-26 Arono）
          title: s.date,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 主观自评（v8 起总结页可选填）：一眼看出那天的状态
              if (s.impression != null)
                Icon(
                  _impressionIcon(s.impression!),
                  size: 16,
                  color: _impressionColor(s.impression!),
                ),
              if (s.impression != null) const SizedBox(width: 4),
              Text(
                s.status == 'quit'
                    ? tx('已中断', en: 'Interrupted')
                    : tx('${s.durationMin} 分钟', en: '${s.durationMin} min'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
              ),
            ],
          ),
          // 长按删除误开的训练（配合训练页"放弃本次"，P1-12）；
          // 读屏语义：标签完整朗读 + "双击并按住"提示作为长按的替代路径
          semanticsLabel: tx(
              '${s.date} ${dname(s.planDayTitle)} 的训练记录${s.status == 'quit' ? '，已中断' : ''}',
              en: 'Workout record: ${s.date} ${dname(s.planDayTitle)}${s.status == 'quit' ? ' (interrupted)' : ''}'),
          longPressHint: tx('双击并按住，删除这条训练记录',
              en: 'Double-tap and hold to delete this workout record'),
          onLongPress: () => _deleteSession(s),
          child: snap.hasData
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: snap.data!,
                )
              : const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
        );
      },
    );
  }

  /// 长按删除单次训练记录（含全部组记录，不可恢复）。
  Future<void> _deleteSession(Session s) async {
    final ok = await confirmDialog(
      context,
      tx('删除这次训练？', en: 'Delete This Workout?'),
      tx(
          '${s.date} · ${dname(s.planDayTitle)} 的全部记录将被删除，用于清理误开的训练。此操作无法撤销。',
          en: 'All records of ${s.date} · ${dname(s.planDayTitle)} will be deleted, to clean up a workout started by mistake. This cannot be undone.'),
      okLabel: tx('删除', en: 'Delete'),
    );
    if (!ok || !mounted) return;
    final c = app(context);
    await c.db.deleteSession(s.id!);
    _detailFutures.remove(s.id!);
    await _load();
    if (mounted) toast(context, tx('已删除', en: 'Deleted'));
  }

  Future<List<Widget>> _sessionDetailWidgets(Session s) async {
    final c = app(context);
    final ses = await c.db.sessionExercises(s.id!);
    final map = await c.db.setsOfSession(s.id!);
    final widgets =
        buildSessionDetailRows(s, ses, map, bodyWeightKg: c.settings.bodyWeightKg);
    return widgets;
  }
}

/// 单次训练的明细行（2026-09-26 Arono：历史卡排版改格子）。
/// 顶层公开函数便于直接单测：传查好的数据，返回纯布局行。
/// 结构 = 计划标题行 + 训练/休息行（新记录才有）+ 每动作一张
/// 「组 | 重量 kg | 次数 | 余力」小表 + 备注行。
List<Widget> buildSessionDetailRows(
  Session s,
  List<SessionExercise> ses,
  Map<int, List<SetEntry>> map, {
  required double bodyWeightKg,
}) {
  final widgets = <Widget>[];
  // 计划标题（日期下方第一行，加粗）：标题位只放日期后挪到这里
  widgets.add(
    Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        dname(s.planDayTitle),
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
  );
  // 训练/休息净时长（新版本记录才有；老记录 rest/active 为 0 不显示）
  if (s.restMs > 0 || s.activeMs > 0) {
    widgets.add(
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          tx(
            '训练 ${((s.activeMs) / 60000).ceil()} 分 · 休息 ${((s.restMs) / 60000).ceil()} 分'
            '${s.restMs + s.activeMs > 0 ? '（休息占 ${(s.restMs * 100 / (s.restMs + s.activeMs)).round()}%）' : ''}',
            en: 'Workout ${((s.activeMs) / 60000).ceil()} min · Rest ${((s.restMs) / 60000).ceil()} min'
                '${s.restMs + s.activeMs > 0 ? ' (rest ${(s.restMs * 100 / (s.restMs + s.activeMs)).round()}%)' : ''}',
          ),
          style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
        ),
      ),
    );
  }
  // 超级组成员行加 ⇄ 前缀（v9，与轮转引擎同口径：同 tag 相邻成组）
  final tags = [for (final se in ses) se.supersetTag];
  for (var k = 0; k < ses.length; k++) {
    final se = ses[k];
    final sets = map[se.id!] ?? [];
    if (sets.isEmpty) continue;
    // 加练组数（v12，2026-10-08）：「计划目标 3 组」下挂 4 行时，
    // 多出来的那行要有解释——有加练就单列一行灰字。
    final extraCount = sets.where((x) => x.isExtra).length;
    // 每个动作一张小表（别再一条长文字流）：列 = 组 | 重量 kg | 次数 | 余力；
    // 余力列头写明含义，不再用 "R2" 缩写。热身=热 / 力竭=竭。
    widgets.add(
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${supersetMembersOf(k, tags) != null ? '⇄ ' : ''}${exname(se.name)}',
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            // 「目标 vs 实际」行（wger 的 target 快照思路）：
            // 新记录（v8+）显示完成当时引擎给的处方（推荐重量 × 链目标次数），
            // 老记录回退显示动作行上的模板目标快照（v6 起有），再老回退规则参数。
            Builder(builder: (_) {
              final snap = sets
                  .where((x) => x.targetWeightKg != null || x.targetReps != null)
                  .toList();
              final String line;
              if (snap.isNotEmpty) {
                final t = snap.first;
                final w = t.targetWeightKg;
                line = tx(
                  '目标 ${w == null ? '' : '${fmtKg(w)}kg × '}${t.targetReps} 次',
                  en: 'Target ${w == null ? '' : '${fmtKg(w)}kg × '}${t.targetReps} reps',
                );
              } else {
                final tSets =
                    se.targetSets > 0 ? se.targetSets : se.rule.workingSets;
                final tMin =
                    se.targetRepsMin > 0 ? se.targetRepsMin : se.rule.repsMin;
                final tMax =
                    se.targetRepsMax > 0 ? se.targetRepsMax : se.rule.repsMax;
                line = tx('计划目标 $tSets 组 × $tMin-$tMax 次',
                    en: 'Target $tSets sets × $tMin-$tMax reps');
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  line,
                  style:
                      const TextStyle(color: AppTheme.textDim, fontSize: 12),
                ),
              );
            }),
            // 有加练：紧跟「目标 vs 实际」行下面单列一行灰字说明
            if (extraCount > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  tx('含加练 $extraCount 组',
                      en: 'Includes $extraCount extra set(s)'),
                  style:
                      const TextStyle(color: AppTheme.textDim, fontSize: 12),
                ),
              ),
            Table(
              border: const TableBorder(
                horizontalInside: BorderSide(color: AppTheme.cardHi, width: 1),
              ),
              // 加练组号带「（加练）」括注，第一列放宽（34↔64），无加练维持原宽
              columnWidths: {
                0: FixedColumnWidth(extraCount > 0 ? 64 : 34),
                1: const FlexColumnWidth(3),
                2: const FlexColumnWidth(3),
                3: const FlexColumnWidth(3),
              },
              children: [
                TableRow(
                  children: [
                    for (final h in [
                      tx('组', en: 'Set'),
                      tx('重量 kg', en: 'Weight kg'),
                      tx('次数', en: 'Reps'),
                      tx('余力', en: 'RIR'),
                    ])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          h,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: AppTheme.textDim, fontSize: 12),
                        ),
                      ),
                  ],
                ),
                for (var i = 0; i < sets.length; i++)
                  TableRow(
                    children: [
                      for (final cell in [
                        sets[i].isExtra ? '${i + 1}（加练）' : '${i + 1}',
                        fmtKg(sets[i].weightKg),
                        '${sets[i].reps}',
                        sets[i].kind == SetKind.warmup
                            ? tx('热', en: 'W')
                            : sets[i].kind == SetKind.failure
                                ? tx('竭', en: 'F')
                                : '${sets[i].rir}',
                      ])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            cell,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    // 单组备注逐条带出（记了就要看得到）
    final noted = sets.where((x) => x.note.trim().isNotEmpty).toList();
    if (noted.isNotEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(left: 14, bottom: 2),
          child: Text(
            tx(
              '备注：${noted.map((x) => '${fmtKg(x.weightKg)}kg：${x.note.trim()}').join('；')}',
              en: 'Notes: ${noted.map((x) => '${fmtKg(x.weightKg)}kg: ${x.note.trim()}').join('; ')}',
            ),
            style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
          ),
        ),
      );
    }
  }
  return widgets;
}
