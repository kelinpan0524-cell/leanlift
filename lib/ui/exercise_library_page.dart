import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/engine.dart';
import '../l10n/lang.dart';
import '../l10n/names.dart';
import '../presets/exercise_library.dart';
import 'exercise_detail_sheet.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 动作库浏览页：按肌群分组的内置动作表，含器械场景（健身房/居家/皆可）
/// 与次级肌群。给编排计划时参考，也是"这个动作练哪"的速查表。
class ExerciseLibraryPage extends StatefulWidget {
  const ExerciseLibraryPage({super.key});

  @override
  State<ExerciseLibraryPage> createState() => _ExerciseLibraryPageState();
}

class _ExerciseLibraryPageState extends State<ExerciseLibraryPage> {
  bool _loading = true;
  List<ExerciseMeta> _metas = [];
  String _filter = '全部'; // 全部 / 肌群 / 场景
  String _gear = '全部'; // 细分器械类目（见 _gears）

  static const _filters = ['全部', ...kMuscleRegions, '健身房', '居家'];
  // 细分器械类目：中文是数据键（与动作库 gear 标注同一口径），显示层经 gearname() 翻译
  static const _gears = [
    '全部', '杠铃', '哑铃', '龙门架绳索', '固定器械', '弹力带', '自重', '壶铃', '其他器械',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final c = app(context);
    // 词表为准（内置库含全部动作），叠加用户沉淀的词表外动作
    final fromDb = await c.db.allExerciseMeta();
    final known = {for (final m in kExerciseLibrary) m.name};
    _metas = [
      ...kExerciseLibrary,
      ...fromDb.where((m) => !known.contains(m.name)),
    ];
    if (!mounted) return;
    setState(() => _loading = false);
  }

  List<ExerciseMeta> get _filtered {
    Iterable<ExerciseMeta> r = _metas;
    if (_gear != '全部') r = r.where((m) => m.gear == _gear);
    if (_filter == '健身房') {
      r = r.where((m) => m.equipment != 'home');
    } else if (_filter == '居家') {
      r = r.where((m) => m.equipment != 'gym');
    } else if (_filter != '全部') {
      r = r.where((m) => m.muscles.main == _filter);
    }
    return r.toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Text(tx('动作库', en: 'Exercise Library')),
        actions: [
          // 自定义动作（2026-09-29）：手动添加进动作库（落 exercise_meta），
          // AI 排计划时可引用（沉淀同步链路自动进词表）。
          IconButton(
            tooltip: tx('添加自定义动作', en: 'Add custom exercise'),
            onPressed: () => _showCustomSheet(null),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 筛选
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Row(
                    children: [
                      for (final f in _filters)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(
                                f == '全部'
                                    ? tx('全部', en: 'All')
                                    : f == '健身房'
                                        ? tx('健身房', en: 'Gym')
                                        : f == '居家'
                                            ? tx('居家', en: 'Home')
                                            : mname(f), // 肌群名是数据，显示层翻译
                                style: const TextStyle(fontSize: 12)),
                            selected: _filter == f,
                            onSelected: (_) => setState(() => _filter = f),
                            labelStyle: TextStyle(
                                fontSize: 12,
                                color: _filter == f
                                    ? const Color(0xFF06220F)
                                    : AppTheme.text),
                            selectedColor: AppTheme.primary,
                            backgroundColor: AppTheme.cardHi,
                            side: BorderSide.none,
                          ),
                        ),
                    ],
                  ),
                ),
                // 细分器械筛选（与上方肌群/场景筛选可叠加）
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      for (final g in _gears)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(
                                g == '全部'
                                    ? tx('全部', en: 'All')
                                    : gearname(g), // 器械名是数据，显示层翻译
                                style: const TextStyle(fontSize: 12)),
                            selected: _gear == g,
                            onSelected: (_) => setState(() => _gear = g),
                            labelStyle: TextStyle(
                                fontSize: 12,
                                color: _gear == g
                                    ? const Color(0xFF06220F)
                                    : AppTheme.text),
                            selectedColor: AppTheme.primary,
                            backgroundColor: AppTheme.cardHi,
                            side: BorderSide.none,
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    itemCount: _filtered.isEmpty ? 1 : _filtered.length + 1,
                    itemBuilder: (ctx, i) {
                      if (_filtered.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 48),
                          child: Text(
                              tx('这个筛选下没有动作，换个器械或肌群试试。',
                                  en: 'No exercises match these filters — try another equipment or muscle.'),
                              textAlign: TextAlign.center,
                              style:
                                  const TextStyle(color: AppTheme.textDim)),
                        );
                      }
                      // 列表尾：素材来源致谢（free-exercise-db 为 Unlicense
                      // 公有领域、本无署名义务，此处为对上游的尊重与溯源）
                      if (i == _filtered.length) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            tx(
                                '动作示意图来自 free-exercise-db（Unlicense 公有领域）；动作要点为本项目原创。',
                                en: 'Exercise photos from free-exercise-db (Unlicense, public domain); form cues written for this project.'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: AppTheme.textDim, fontSize: 11),
                          ),
                        );
                      }
                      final m = _filtered[i];
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => _showDetail(m),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 2,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(exname(m.name),
                                              style: const TextStyle(
                                                  fontSize: 15,
                                                  fontWeight:
                                                      FontWeight.w600)),
                                          if (_isCustom(m))
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2),
                                              decoration: BoxDecoration(
                                                color: AppTheme.violet
                                                    .withValues(alpha: 0.15),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                tx('自定义', en: 'Custom'),
                                                style: const TextStyle(
                                                    fontSize: 10,
                                                    color: AppTheme.violet),
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        tx(
                                          '主练 ${mname(m.muscles.main)}'
                                          '${m.muscles.secondary.isEmpty ? '' : ' · 兼练 ${m.muscles.secondary.map(mname).join('/')}'}'
                                          ' · ${m.isCompound ? '复合' : '单关节'}'
                                          '${m.gear.isEmpty ? '' : ' · ${gearname(m.gear)}'}',
                                          en: 'Main ${mname(m.muscles.main)}'
                                              '${m.muscles.secondary.isEmpty ? '' : ' · Secondary ${m.muscles.secondary.map(mname).join('/')}'}'
                                              ' · ${m.isCompound ? 'Compound' : 'Isolation'}'
                                              '${m.gear.isEmpty ? '' : ' · ${gearname(m.gear)}'}',
                                        ),
                                        style: const TextStyle(
                                            color: AppTheme.textDim,
                                            fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                                _equipmentTag(m),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  /// 是否自定义动作（词表外沉淀行）：内置动作来自静态词表不可删改，
  /// 自定义动作可编辑标注/删除。
  bool _isCustom(ExerciseMeta m) => libraryMetaByName(m.name) == null;

  Widget _equipmentTag(ExerciseMeta m) {
    final color = switch (m.equipment) {
      'gym' => AppTheme.accent,
      'home' => AppTheme.warn,
      _ => AppTheme.textDim,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(eqname(m.equipmentLabel),
          style: TextStyle(fontSize: 11, color: color)),
    );
  }

  /// 动作详情：元信息 + 历史最佳（1RM/最大重量）+ 最近几次训练记录。
  Future<void> _showDetail(ExerciseMeta m) async {
    final c = app(context);
    // 器械设置（P2-C）按已落库的稳定键读写：改名后的动作在计划/会话行里
    // 仍保留旧键，动作库若按当前显示名现算会与训练页各写一份备注。
    final noteKey = await c.db.knownExerciseKey(m.name) ?? '';
    final rows = await c.db.sessionRowsBetween(
        '0000-01-01', fmtDate(DateTime.now()));
    // 该动作按日期分组的正式组（同一 session 只取一次日期）
    final byDate = <String, List<SetEntry>>{};
    var curSid = -1;
    var curDate = '';
    double bestRm = 0, bestW = 0;
    String bestRmDesc = '';
    // 历史匹配与 SetupNoteEditor 用同一个稳定键（noteKey）：改名保留旧键的
    // 动作，按新显示名现算会得到新键、而历史行的 exercise_key 还是旧键，
    // 会误判成「有备注但没练过」。knownExerciseKey 先查落库行的键（计划/
    // 会话行同名行保留旧键），查不到才现算——别名归一能力不丢。
    final identity =
        noteKey.trim().isNotEmpty ? noteKey.trim() : exerciseKeyOf(m.name);
    for (final r in rows) {
      final rowKey = ((r['exercise_key'] as String?) ?? '').trim();
      final rowIdentity = rowKey.isNotEmpty
          ? rowKey
          : exerciseKeyOf((r['name'] as String?) ?? '');
      if (identity.isEmpty || rowIdentity != identity) continue;
      final sid = (r['session_id'] as num).toInt();
      if (sid != curSid) {
        curSid = sid;
        curDate = (r['date'] as String?) ?? '';
      }
      final w = (r['weight_kg'] as num?)?.toDouble();
      final reps = (r['reps'] as num?)?.toInt();
      if (w == null || reps == null) continue;
      if (((r['kind'] as String?) ?? '') != SetKind.working) continue;
      byDate.putIfAbsent(curDate, () => []).add(SetEntry(
        sessionExerciseId: 0,
        weightKg: w,
        reps: reps,
        rir: (r['rir'] as num?)?.toInt() ?? 2,
        kind: SetKind.working,
        doneAt: (r['done_at'] as num?)?.toInt() ?? 0,
      ));
      final rm = estimate1RM(w, reps);
      if (rm > bestRm) {
        bestRm = rm;
        bestRmDesc =
            tx('${fmtWt(w)} × $reps 次', en: '${fmtWt(w)} × $reps reps');
      }
      if (w > bestW) bestW = w;
    }
    final dates = byDate.keys.toList()..sort((a, b) => b.compareTo(a));
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          children: [
            Text(exname(m.name),
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              tx(
                '主练 ${mname(m.muscles.main)}'
                '${m.muscles.secondary.isEmpty ? '' : ' · 兼练 ${m.muscles.secondary.map(mname).join('/')}'}'
                ' · ${m.isCompound ? '复合动作' : '单关节动作'} · ${eqname(m.equipmentLabel)}'
                '${m.gear.isEmpty ? '' : ' · ${gearname(m.gear)}'}',
                en: 'Main ${mname(m.muscles.main)}'
                    '${m.muscles.secondary.isEmpty ? '' : ' · Secondary ${m.muscles.secondary.map(mname).join('/')}'}'
                    ' · ${m.isCompound ? 'Compound' : 'Isolation'} · ${eqname(m.equipmentLabel)}'
                    '${m.gear.isEmpty ? '' : ' · ${gearname(m.gear)}'}',
              ),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
            ),
            // 器械设置（P2-C）：动作库详情也能记录座椅/靠背等固定设置。
            SetupNoteEditor(name: m.name, exerciseKey: noteKey),
            // 图文解析段（示意图 + 要点）与训练中共用同一组件
            ...exerciseMediaSection(m.name, m),
            const SizedBox(height: 14),
            if (dates.isEmpty)
              Text(
                  tx('还没练过这个动作——加进计划后，这里会显示历史最好成绩。',
                      en: 'Never trained this exercise yet — add it to a plan and your bests will show up here.'),
                  style: const TextStyle(color: AppTheme.textDim))
            else ...[
              Row(children: [
                _bestCell(tx('估算 1RM', en: 'Est. 1RM'), fmtWt(bestRm)),
                _bestCell(tx('最佳一组', en: 'Best set'), bestRmDesc),
                _bestCell(tx('最大重量', en: 'Max weight'), fmtWt(bestW)),
              ]),
              const SizedBox(height: 14),
              Text(tx('最近训练', en: 'Recent Workouts'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (final d in dates.take(3))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(
                    tx(
                        '$d：${byDate[d]!.map((x) => '${fmtWt(x.weightKg)}×${x.reps}').join('  ')}',
                        en: '$d: ${byDate[d]!.map((x) => '${fmtWt(x.weightKg)}×${x.reps}').join('  ')}'),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              if (dates.length > 3)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    tx('共 ${dates.length} 次练过，更多见历史页',
                        en: 'Trained ${dates.length} times in total — see History for more'),
                    style: const TextStyle(
                        color: AppTheme.textDim, fontSize: 12)),
                  ),
            ],
            // 自定义动作管理（2026-09-29）：编辑标注 / 从动作库删除。
            // 内置动作不提供（静态词表为权威源，AI/筛选/详情都以内置为准）。
            if (_isCustom(m)) ...[
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showCustomSheet(m);
                    },
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: Text(tx('编辑标注', en: 'Edit tags')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.danger),
                    onPressed: () async {
                      final ok = await confirmDialog(
                        ctx,
                        tx('删除「${exname(m.name)}」？',
                            en: 'Delete "${exname(m.name)}"?'),
                        tx(
                            '只从动作库移除这个自定义动作（AI 不再引用）；已写进计划与历史记录的训练不受影响。',
                            en: 'Removes this custom exercise from the library only (AI will stop using it); plans and workout history that already use it are unaffected.'),
                        okLabel: tx('删除', en: 'Delete'),
                      );
                      if (!ok) return;
                      await c.db.deleteExerciseMeta(m.name);
                      // 既有惯例：改 exercise_meta 后经 planRepo.reload 触发
                      // AI 词表沉淀同步（AppContainer 监听）与提醒重排。
                      await c.planRepo.reload();
                      await _load();
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                      }
                      if (mounted) {
                        toast(context,
                            tx('已删除', en: 'Deleted'));
                      }
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text(tx('删除', en: 'Delete')),
                  ),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  /// 添加/编辑自定义动作（2026-09-29）：表单落 exercise_meta（词表外沉淀
  /// 行），保存后经 planRepo.reload 触发 AI 词表同步——AI 排计划即可引用。
  /// [initial] 非空 = 编辑既有自定义动作。
  Future<void> _showCustomSheet(ExerciseMeta? initial) async {
    final c = app(context);
    final result = await showModalBottomSheet<ExerciseMeta>(
      context: context,
      backgroundColor: AppTheme.cardHi,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _CustomExerciseSheet(initial: initial),
    );
    if (result == null) return;
    await c.db.upsertExerciseMeta(result);
    await c.planRepo.reload();
    await _load();
    if (mounted) {
      toast(
        context,
        initial == null
            ? tx('已添加「${exname(result.name)}」，AI 排计划可引用',
                en: 'Added "${exname(result.name)}" — AI can now use it in plans')
            : tx('已更新「${exname(result.name)}」', en: 'Updated "${exname(result.name)}"'),
      );
    }
  }

  Widget _bestCell(String label, String value) {    return Expanded(
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value,
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary)),
          ),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12)),
        ],
      ),
    );
  }
}

/// 自定义动作表单（添加/编辑，2026-09-29）：名称 + 主肌群 + 细分器械 +
/// 复合/单关节 + 场景。保存返回 ExerciseMeta（由调用方落库并同步 AI 词表）。
/// 与内置动作重名会被拦截——静态词表在各消费方优先，同名落库不生效。
class _CustomExerciseSheet extends StatefulWidget {
  const _CustomExerciseSheet({this.initial});

  final ExerciseMeta? initial;

  @override
  State<_CustomExerciseSheet> createState() => _CustomExerciseSheetState();
}

class _CustomExerciseSheetState extends State<_CustomExerciseSheet> {
  late final _nameCtrl =
      TextEditingController(text: widget.initial?.name ?? '');
  late String _muscle = widget.initial?.muscles.main ?? '胸';
  late String _gear = _gears.contains(widget.initial?.gear) &&
          (widget.initial?.gear ?? '').isNotEmpty
      ? widget.initial!.gear
      : '自重';
  late bool _compound = widget.initial?.isCompound ?? true;
  late String _equipment = widget.initial?.equipment ?? 'both';
  String? _nameError;

  static const _gears = [
    '杠铃', '哑铃', '龙门架绳索', '固定器械', '弹力带', '自重', '壶铃', '其他器械',
  ];

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                widget.initial == null
                    ? tx('添加自定义动作', en: 'Add custom exercise')
                    : tx('编辑自定义动作', en: 'Edit custom exercise'),
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              tx('保存后进动作库，AI 排计划时可以引用它。',
                  en: 'Saved into the library; AI can reference it when planning.'),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtrl,
              autofocus: widget.initial == null,
              decoration: InputDecoration(
                labelText: tx('动作名', en: 'Exercise name'),
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 14),
            _label(tx('主肌群', en: 'Primary muscle')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in kMuscleRegions)
                  _chip(muscle: m, selected: _muscle == m, onTap: () => setState(() => _muscle = m), label: mname(m)),
              ],
            ),
            const SizedBox(height: 14),
            _label(tx('器械', en: 'Equipment')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final g in _gears)
                  _chip(muscle: g, selected: _gear == g, onTap: () => setState(() => _gear = g), label: gearname(g)),
              ],
            ),
            const SizedBox(height: 14),
            _label(tx('类型', en: 'Type')),
            Wrap(
              spacing: 8,
              children: [
                _chip(muscle: 'compound', selected: _compound, onTap: () => setState(() => _compound = true), label: tx('复合动作', en: 'Compound')),
                _chip(muscle: 'assistance', selected: !_compound, onTap: () => setState(() => _compound = false), label: tx('单关节动作', en: 'Isolation')),
              ],
            ),
            const SizedBox(height: 14),
            _label(tx('场景', en: 'Setting')),
            Wrap(
              spacing: 8,
              children: [
                _chip(muscle: 'both', selected: _equipment == 'both', onTap: () => setState(() => _equipment = 'both'), label: tx('皆可', en: 'Both')),
                _chip(muscle: 'gym', selected: _equipment == 'gym', onTap: () => setState(() => _equipment = 'gym'), label: tx('健身房', en: 'Gym')),
                _chip(muscle: 'home', selected: _equipment == 'home', onTap: () => setState(() => _equipment = 'home'), label: tx('居家', en: 'Home')),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52)),
                onPressed: _save,
                child: Text(tx('保存', en: 'Save')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600)),
      );

  Widget _chip(
      {required String muscle,
      required bool selected,
      required VoidCallback onTap,
      required String label}) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppTheme.accent : AppTheme.card,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: selected ? const Color(0xFF06220F) : AppTheme.textDim)),
      ),
    );
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = tx('给动作起个名字', en: 'Give it a name'));
      return;
    }
    if (libraryMetaByName(name) != null) {
      setState(() => _nameError =
          tx('与内置动作重名，请换一个名字', en: 'Same name as a built-in exercise — pick another'));
      return;
    }
    Navigator.pop(
      context,
      ExerciseMeta(
        name,
        MuscleGroups(main: _muscle, secondary: widget.initial?.muscles.secondary ?? const []),
        _compound,
        _equipment,
        '',
        _gear,
      ),
    );
  }
}

