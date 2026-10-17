import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../l10n/lang.dart';
import '../l10n/names.dart';
import '../presets/exercise_library.dart';
import 'muscle_body_view.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 肌群恢复度卡片（调研报告候选条目「肌群恢复度热力图」）。
///
/// 口径（见 lib/engine/recovery.dart 与 docs/recovery-heatmap.md）：
/// 近 7 天 done 会话的正式组容量按肌群分摊，按 48 小时时间常数指数衰减，
/// 恢复度 = 100×(1-累积疲劳)，无记录 = 100%。
///
/// **展示位置纪律：只出现在数据页（肌肉 Tab），绝不进训练中页**——
/// 训练中屏幕只保留三要素（当前动作/本组目标/倒计时）；
/// 2026-09-25 Arono 拍板：恢复度从计划页挪到数据页，
/// 计划页只管"练什么"，恢复状态属于"练后看"的数据。
class MuscleRecoveryCard extends StatefulWidget {
  const MuscleRecoveryCard({super.key});

  @override
  State<MuscleRecoveryCard> createState() => _MuscleRecoveryCardState();
}

class _MuscleRecoveryCardState extends State<MuscleRecoveryCard> {
  Future<Map<String, int>>? _future;
  bool _front = true;

  @override
  void initState() {
    super.initState();
    // initState 里不能同步读 InheritedWidget，延后一帧
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 块体写法：箭头闭包会把 Future 返回给 setState（debug 断言抛错）
      if (mounted) {
        setState(() {
          _future = _load();
        });
      }
    });
  }

  Future<Map<String, int>> _load() async {
    final c = app(context);
    final now = DateTime.now();
    final from = fmtDate(now.subtract(const Duration(days: kRecoveryLookbackDays)));
    final sessions = await c.db.sessionsBetween(from, fmtDate(now));
    final metaMap = {for (final m in kExerciseLibrary) m.name: m};
    // 内置词表 + DB 沉淀合并（与统计页热力图同口径）
    final known = metaMap.keys.toSet();
    for (final m in await c.db.allExerciseMeta()) {
      if (!known.contains(m.name)) metaMap[m.name] = m;
    }
    final input = <RecoverySession>[];
    for (final s in sessions) {
      final ses = await c.db.sessionExercises(s.id!);
      final map = await c.db.setsOfSession(s.id!);
      final byName = <String, List<SetEntry>>{};
      for (final se in ses) {
        final sets = map[se.id!] ?? const <SetEntry>[];
        if (sets.isEmpty) continue;
        byName.putIfAbsent(se.name, () => []).addAll(sets);
      }
      input.add(RecoverySession(
        endedAtMs: s.endedAt ?? s.startedAt,
        workingByName: byName,
      ));
    }
    return muscleRecovery(
      sessions: input,
      metaByName: metaMap,
      bodyWeightKg: c.settings.bodyWeightKg,
    );
  }

  Color _heat(int recovery) => AppTheme.recoveryColor(recovery.toDouble());

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: tx('肌群恢复度', en: 'Muscle Recovery'),
      icon: Icons.spa_outlined,
      iconColor: AppTheme.primary,
      child: FutureBuilder<Map<String, int>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            // DB 打开失败/迁移异常等：明确告知不可用并给重试，
            // 不让卡片永久停在加载态
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(tx('恢复度暂不可用', en: 'Recovery unavailable'),
                        style: const TextStyle(
                            color: AppTheme.textDim, fontSize: 13)),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => setState(() {
                        _future = _load();
                      }),
                      child: Text(tx('重试', en: 'Retry')),
                    ),
                  ],
                ),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            );
          }
          final rec = snap.data!;
          final share = rec.map((k, v) => MapEntry(k, v / 100));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tx('按近 7 天训练容量与 48 小时衰减估算（启发式参考，非生理测量）',
                    en: 'Estimated from the last 7 days of training volume with 48h decay (heuristic, not a physiological measurement)'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                      value: true, label: Text(tx('正面', en: 'Front'))),
                  ButtonSegment(
                      value: false, label: Text(tx('背面', en: 'Back'))),
                ],
                selected: {_front},
                onSelectionChanged: (sel) =>
                    setState(() => _front = sel.first),
                showSelectedIcon: false,
                style: ButtonStyle(
                  backgroundColor:
                      WidgetStateProperty.resolveWith((states) =>
                          states.contains(WidgetState.selected)
                              ? AppTheme.primary
                              : AppTheme.cardHi),
                  foregroundColor:
                      WidgetStateProperty.resolveWith((states) =>
                          states.contains(WidgetState.selected)
                              ? const Color(0xFF06220F)
                              : AppTheme.textDim),
                  side: const WidgetStatePropertyAll(
                      BorderSide(color: Colors.transparent)),
                  shape: const WidgetStatePropertyAll(RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.all(Radius.circular(10)))),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 300,
                // 着色走红黄绿分级（2026-09-26 Arono：按恢复程度分色）
                child: MuscleBodyView(
                  share: share,
                  front: _front,
                  ramp: (v) => AppTheme.recoveryColor(v * 100),
                ),
              ),
              const SizedBox(height: 12),
              ...kMuscleRegions.map((r) {
                final v = rec[r] ?? 100;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      // FittedBox：大字号/窄屏下肌群名与百分比整体缩放，
                      // 绝不出现"30"被折成两行这类数字断行
                      SizedBox(
                        width: 44,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(mname(r),
                              maxLines: 1,
                              style: const TextStyle(fontSize: 14)),
                        ),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: v / 100,
                            minHeight: 10,
                            backgroundColor: AppTheme.cardHi,
                            valueColor: AlwaysStoppedAnimation(_heat(v)),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 52,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('$v%',
                              maxLines: 1,
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                color: _heat(v),
                                fontSize: 13,
                              )),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}
