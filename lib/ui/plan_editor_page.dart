import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/engine.dart';
import '../engine/superset.dart';
import '../l10n/lang.dart';
import '../l10n/names.dart';
import '../services/plan_repository.dart';
import 'exercise_picker_page.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 训练日编辑器：改标题/星期、动作增删改、拖拽排序、复制、肌群标注。
/// 所有修改即时保存；返回值 = 是否有过修改（调用方据此刷新与重同步飞书）。
/// [isCycle] = 所属计划为循环模式：此时「星期」只是槽位排序键，界面改以
/// 轮转序号「第N练」呈现（空槽位显示「空」），调整位置即调整轮转顺序。
class PlanEditorPage extends StatefulWidget {
  const PlanEditorPage(
      {super.key, required this.day, this.planName, this.isCycle = false});

  final PlanDay day;
  final String? planName;
  final bool isCycle;

  @override
  State<PlanEditorPage> createState() => _PlanEditorPageState();
}

class _PlanEditorPageState extends State<PlanEditorPage> {
  late PlanDay _day = widget.day;
  List<PlanExercise> _exercises = [];
  Map<String, ExerciseMeta> _metaByName = {};
  bool _loading = true;
  bool _dirty = false; // 本次进入是否改过内容
  // 循环模式的轮转编号（与 plan_page 模板日列表同口径）：
  // _rotation: dayId → 第几练；_slotRotation: 槽位(weekday) → 第几练（仅非空日）。
  Map<int, int> _rotation = {};
  Map<int, int> _slotRotation = {};
  late final TextEditingController _titleCtrl =
      TextEditingController(text: widget.day.title);

  @override
  void initState() {
    super.initState();
    // initState 里不能同步读 InheritedWidget，延后一帧再加载
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final c = app(context);
    _exercises = await c.db.dayExercises(_day.id!);
    final metas = await c.db.allExerciseMeta();
    _metaByName = {for (final m in metas) m.name: m};
    await _loadRotation();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  /// 重算循环轮转编号：动作增删会让某天从「未排内容」变「第N练」（或反之），
  /// 槽位对调后编号也会变，所以编辑与移动后都要刷新。
  Future<void> _loadRotation() async {
    if (!widget.isCycle) return;
    final c = app(context);
    final all = await c.db.planDays(_day.planId);
    final exMap = await c.db.daysExercisesMap(all.map((d) => d.id!).toList());
    if (!mounted) return;
    setState(() {
      _rotation = cycleRotationIndex(all, exMap);
      _slotRotation = {
        for (final d in all)
          if (_rotation.containsKey(d.id)) d.weekday: _rotation[d.id]!,
      };
    });
  }

  Future<void> _saveTitle() async {
    final t = _titleCtrl.text.trim();
    if (t.isEmpty || t == _day.title) return;
    final c = app(context);
    _day = PlanDay(
        id: _day.id, planId: _day.planId, weekday: _day.weekday, title: t);
    await c.db.updatePlanDay(_day);
    _dirty = true;
  }

  /// 切星期/槽位：目标空闲则移动；被占则确认后两日内容对调。
  /// weekly = 换到周几；cycle = 换到轮转第几位（底层同是 weekday 槽位互换）。
  Future<void> _moveToWeekday(int weekday) async {
    if (weekday == _day.weekday) return;
    final c = app(context);
    final messenger = ScaffoldMessenger.of(context);
    final all = await c.db.planDays(_day.planId);
    if (!mounted) return;
    final occupant =
        all.where((d) => d.weekday == weekday && d.id != _day.id).firstOrNull;
    // 循环模式下对调方的轮转编号（移动前口径，弹窗与提示用）
    final occN = occupant == null ? null : _rotation[occupant.id];
    if (occupant != null) {
      final bool ok;
      if (widget.isCycle) {
        ok = occN != null
            ? await confirmDialog(
                context,
                tx('与第$occN练对调？', en: 'Swap with Workout $occN?'),
                tx('「${dname(occupant.title)}」在轮转第 $occN 位，确认后两练的内容将互相交换。',
                    en: '"${dname(occupant.title)}" is at rotation position $occN; confirming will swap the contents of the two workouts.'))
            : await confirmDialog(
                context,
                tx('移到这个空位？', en: 'Move to this empty slot?'),
                tx('「${dname(occupant.title)}」未排内容、不参与轮转；确认后本练移到该位置。',
                    en: '"${dname(occupant.title)}" has no exercises and is not in the rotation; confirming moves this workout to that slot.'));
      } else {
        ok = await confirmDialog(
            context,
            tx('与周${'一二三四五六日'[weekday - 1]}对调？',
                en: 'Swap with ${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][weekday - 1]}?'),
            tx('「${dname(occupant.title)}」已安排在周${'一二三四五六日'[weekday - 1]}，确认后两天的内容将互相交换。',
                en: '"${dname(occupant.title)}" is already on ${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][weekday - 1]}; confirming will swap the contents of the two days.'));
      }
      if (!ok || !mounted) return;
    }
    if (occupant == null) {
      if (!mounted) return;
      // setState 让 AppBar 标题与槽位 chips 选中态即时刷新
      setState(() {
        _day = PlanDay(
            id: _day.id,
            planId: _day.planId,
            weekday: weekday,
            title: _day.title);
      });
      await c.db.updatePlanDay(_day);
    } else {
      await c.db.swapPlanDayWeekdays(_day, occupant);
      if (!mounted) return;
      setState(() {
        _day = PlanDay(
            id: _day.id,
            planId: _day.planId,
            weekday: weekday,
            title: _day.title);
      });
    }
    _dirty = true;
    await _loadRotation(); // 对调/移动后各练的编号变了，重算再提示
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(widget.isCycle
          ? (occupant != null && occN != null
              ? tx('已与第$occN练「${dname(occupant.title)}」对调',
                  en: 'Swapped with Workout $occN "${dname(occupant.title)}"')
              : tx('已移到空位', en: 'Moved to an empty slot'))
          : occupant == null
              ? tx('已调整到周${'一二三四五六日'[weekday - 1]}',
                  en: 'Moved to ${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][weekday - 1]}')
              : tx('已与周${'一二三四五六日'[weekday - 1]}「${dname(occupant.title)}」对调',
                  en: 'Swapped with ${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][weekday - 1]} "${dname(occupant.title)}"')),
      backgroundColor: AppTheme.cardHi,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  /// 从动作库挑选：搜索/筛选/多选，确认后批量追加到当天（参数用合理默认，
  /// 之后点开单个动作微调）。
  Future<void> _pickFromLibrary() async {
    final picked = await Navigator.of(context).push<List<ExerciseMeta>>(
      MaterialPageRoute(
        builder: (_) => ExercisePickerPage(
          existingNames: _exercises.map((e) => e.name).toSet(),
        ),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final c = app(context);
    var order = _exercises.length;
    for (final m in picked) {
      final isCompound = m.isCompound;
      await c.db.insertPlanExercise(PlanExercise(
        dayId: _day.id!,
        name: m.name,
        orderIdx: order++,
        sets: isCompound ? 4 : 3,
        repsMin: isCompound ? 6 : 8,
        repsMax: isCompound ? 10 : 12,
        restSec: isCompound ? 150 : 90,
        kind: isCompound ? 'compound' : 'assistance',
        rule: ProgressionRule(
          repsMin: isCompound ? 6 : 8,
          repsMax: isCompound ? 10 : 12,
          incrementKg: isCompound ? 2.5 : 1.25,
          workingSets: isCompound ? 4 : 3,
        ),
      ));
    }
    _dirty = true;
    await _reload();
    if (mounted) {
      toast(context,
          tx('已添加 ${picked.length} 个动作，点开可微调组数',
              en: 'Added ${picked.length} exercises; tap one to adjust sets'));
    }
  }

  Future<void> _openExerciseSheet([PlanExercise? existing]) async {
    final result = await showModalBottomSheet<ExerciseFormResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => ExerciseEditSheet(
        initial: existing,
        knownMetas: _metaByName.values.toList(),
        initialMuscle:
            existing == null ? null : _metaByName[existing.name]?.muscles.main,
      ),
    );
    if (result == null || !mounted) return;
    final c = app(context);
    final rule = ProgressionRule(
      repsMin: result.repsMin,
      repsMax: result.repsMax,
      incrementKg: result.kind == 'compound' ? 2.5 : 1.25,
      workingSets: result.sets,
      desc: result.kind == 'compound'
          ? tx('全部正式组达 ${result.repsMax} 次且末组余力≥1 → 加 2.5kg；有组低于 ${result.repsMin} 次 → 减 5%',
              en: 'All working sets reach ${result.repsMax} reps with ≥1 in reserve on the last set → add 2.5kg; any set below ${result.repsMin} reps → reduce 5%')
          : tx('全部正式组达 ${result.repsMax} 次且末组余力≥1 → 加 1.25kg',
              en: 'All working sets reach ${result.repsMax} reps with ≥1 in reserve on the last set → add 1.25kg'),
    );

    // 肌群/场景标注写回动作库（保留既有次要肌群），热力图与动作库才正确
    Future<void> saveMeta() async {
      final old = _metaByName[result.name];
      final meta = ExerciseMeta(
        result.name,
        MuscleGroups(
            main: result.muscle, secondary: old?.muscles.secondary ?? []),
        result.kind == 'compound',
        result.equipment,
        '',
        old?.gear ?? '',
      );
      await c.db.upsertExerciseMeta(meta);
      _metaByName[result.name] = meta;
    }

    if (existing == null) {
      final draft = PlanExercise(
        dayId: _day.id!,
        name: result.name,
        orderIdx: _exercises.length,
        sets: result.sets,
        repsMin: result.repsMin,
        repsMax: result.repsMax,
        restSec: result.restSec,
        kind: result.kind,
        rule: rule,
      );
      await c.db.insertPlanExercise(draft);
      await saveMeta();
    } else {
      // 编辑时同步重建渐进规则：改组数/次数要影响训练引擎的判定
      final updated = existing.copyWith(
        name: result.name,
        sets: result.sets,
        repsMin: result.repsMin,
        repsMax: result.repsMax,
        restSec: result.restSec,
        kind: result.kind,
        rule: rule,
      );
      await c.db.updatePlanExercise(updated);
      await saveMeta();
    }
    _dirty = true;
    await _reload();
    if (mounted) setState(() {});
  }

  /// 复制动作：同配置插到末尾，名字加「副本」提示改名。
  /// 超级组标记不带过去——副本落在末尾，带着旧 tag 会变成悬空标记。
  Future<void> _copyExercise(PlanExercise ex) async {
    final c = app(context);
    await c.db.insertPlanExercise(
      ex.copyWith(
          id: null,
          name: tx('${ex.name}（副本）', en: '${ex.name} (copy)'),
          orderIdx: _exercises.length,
          supersetTag: ''),
    );
    _dirty = true;
    await _reload();
    if (mounted) {
      toast(context,
          tx('已复制「${exname(ex.name)}」，记得改动作名',
              en: '"${exname(ex.name)}" copied; remember to rename it'));
    }
  }

  /// 删除动作：立即生效 + 可撤销（比确认弹窗顺手）。
  Future<void> _removeExercise(PlanExercise ex) async {
    final c = app(context);
    final index = _exercises.indexOf(ex);
    final snapshot = ex.copyWith();
    await c.db.deletePlanExercise(ex.id!);
    final rest =
        _exercises.where((e) => e.id != ex.id).map((e) => e.id!).toList();
    if (rest.isNotEmpty) {
      await c.db.reorderPlanExercises(_day.id!, rest);
    }
    _dirty = true;
    await _normalizeAfterMutation();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: Text(tx('已删除「${exname(snapshot.name)}」', en: '"${exname(snapshot.name)}" deleted')),
      backgroundColor: AppTheme.cardHi,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
      action: SnackBarAction(
        label: tx('撤销', en: 'Undo'),
        onPressed: () async {
          final restored = snapshot.copyWith(id: null, orderIdx: 0);
          final newId = await c.db.insertPlanExercise(restored);
          final ids = _exercises.map((e) => e.id!).toList();
          ids.insert(index.clamp(0, ids.length), newId);
          await c.db.reorderPlanExercises(_day.id!, ids);
          _dirty = true;
          await _normalizeAfterMutation();
        },
      ),
    ));
  }

  /// 拖拽排序落库（onReorderItem 的 newIndex 已由框架修正）。
  Future<void> _onReorderItem(int oldIndex, int newIndex) async {
    final list = [..._exercises];
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    setState(() => _exercises = list);
    final c = app(context);
    await c.db.reorderPlanExercises(_day.id!, list.map((e) => e.id!).toList());
    _dirty = true;
    // 超级组成员被拖离同伴 → 自动解除配对并提示。
    await _normalizeAfterMutation();
  }

  // ---------- 超级组（v9）：配对 / 解除 / 徽标 ----------

  List<String> get _supersetTagsNow =>
      [for (final e in _exercises) e.supersetTag];

  /// i 所属的连续超级组（同 tag 相邻、≥2 人）；null = 未配对。
  List<int>? _supersetGroupOf(int i) =>
      supersetMembersOf(i, _supersetTagsNow);

  /// 变更（重排/删除/解除）后的一致性维护：被拆散或只剩单人的 tag 自动
  /// 清掉，SnackBars/Toast 提示被解除的动作。
  Future<void> _normalizeAfterMutation() async {
    final c = app(context);
    final detached = await c.db.normalizeSupersetTags(_day.id!);
    await _reload();
    if (!mounted) return;
    if (detached.isNotEmpty) {
      toast(
        context,
        tx('顺序变化已自动解除超级组：${detached.map(exname).join('、')}',
            en: 'Superset auto-unpaired after reorder: '
                '${detached.map(exname).join(', ')}'),
      );
    }
  }

  /// 配对/解除超级组。
  /// 解除：清当前动作的 tag（剩余成员是否还成组由 normalize 收敛——
  /// 两人组直接散，三人组去掉首/尾后余下两人仍相邻则保留）。
  /// 配对：与下一个动作打同 tag（下一个已在自己组里则并入成连组），
  /// 可顺带把第一个动作的组间休息设为转换休息（A 做完转 B 前歇多久）。
  Future<void> _toggleSuperset(int i) async {
    final c = app(context);
    final ex = _exercises[i];
    final group = _supersetGroupOf(i);
    if (group != null) {
      await c.db.updatePlanExercise(ex.copyWith(supersetTag: ''));
      _dirty = true;
      await _normalizeAfterMutation();
      if (mounted) {
        toast(
          context,
          tx('已解除「${exname(ex.name)}」的超级组',
              en: 'Superset unpaired for "${exname(ex.name)}"'),
        );
      }
      return;
    }
    if (i + 1 >= _exercises.length) {
      toast(
        context,
        tx('这是最后一个动作，没有可配对的下一个',
            en: 'This is the last exercise; nothing after it to pair with'),
      );
      return;
    }
    final next = _exercises[i + 1];
    final sec = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppTheme.cardHi,
      isScrollControlled: true,
      builder: (_) => _SupersetPairSheet(first: ex, second: next),
    );
    if (sec == null || !mounted) return; // 用户取消
    final tag =
        next.supersetTag.isNotEmpty ? next.supersetTag : newSupersetTag();
    await c.db.updatePlanExercise(ex.copyWith(
      supersetTag: tag,
      restSec: sec > 0 ? sec : ex.restSec,
    ));
    if (next.supersetTag.isEmpty) {
      await c.db.updatePlanExercise(next.copyWith(supersetTag: tag));
    }
    _dirty = true;
    await _reload();
    if (mounted) {
      toast(
        context,
        tx('已组成超级组：${exname(ex.name)} ⇄ ${exname(next.name)}',
            en: 'Superset paired: ${exname(ex.name)} ⇄ ${exname(next.name)}'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        await _saveTitle(); // 返回前兜底保存标题
        if (!mounted) return;
        navigator.pop(_dirty);
      },
      child: Scaffold(
        backgroundColor: AppTheme.bg,
        appBar: AppBar(
          leading: BackButton(onPressed: () async {
            final navigator = Navigator.of(context);
            await _saveTitle();
            if (!mounted) return;
            navigator.pop(_dirty);
          }),
          title: Text(widget.isCycle
              ? (_rotation.containsKey(_day.id)
                  ? tx('第${_rotation[_day.id]}练 · 编辑训练日',
                      en: 'Workout ${_rotation[_day.id]} · Edit training day')
                  : tx('未排内容 · 编辑训练日',
                      en: 'Unfilled · Edit training day'))
              : tx('周${'一二三四五六日'[_day.weekday - 1]} · 编辑训练日',
                  en: '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][_day.weekday - 1]} · Edit training day')),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      children: [
                        TextField(
                          controller: _titleCtrl,
                          decoration: InputDecoration(
                              labelText: tx('训练日标题（自动保存）',
                                  en: 'Training day title (auto-saves)')),
                          onSubmitted: (_) => _saveTitle(),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                                tx(widget.isCycle ? '轮转位置' : '安排在',
                                    en: widget.isCycle
                                        ? 'Rotation slot'
                                        : 'Scheduled on'),
                                style: const TextStyle(
                                    color: AppTheme.textDim, fontSize: 13)),
                            for (var wd = 1; wd <= 7; wd++)
                              ChoiceChip(
                                label: Text(widget.isCycle
                                    ? (_slotRotation[wd] != null
                                        ? tx('第${_slotRotation[wd]}练',
                                            en: 'Workout ${_slotRotation[wd]}')
                                        : tx('空', en: 'Empty'))
                                    : tx('周${'一二三四五六日'[wd - 1]}',
                                        en: const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][wd - 1])),
                                selected: _day.weekday == wd,
                                onSelected: (_) => _moveToWeekday(wd),
                                labelStyle: TextStyle(
                                    fontSize: 12,
                                    color: _day.weekday == wd
                                        ? const Color(0xFF06220F)
                                        : AppTheme.text),
                                selectedColor: AppTheme.primary,
                                backgroundColor: AppTheme.cardHi,
                                side: BorderSide.none,
                              ),
                          ],
                        ),
                        if (widget.isCycle)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                                tx('循环模式下这里不是星期几：位置就是轮转顺序，点「第N练」与之对调；「空」位不参与轮转。',
                                    en: 'In cycle mode these are not weekdays: the position is the rotation order; tapping "Workout N" swaps with it. "Empty" slots are not in the rotation.'),
                                style: const TextStyle(
                                    color: AppTheme.textDim, fontSize: 12)),
                          ),
                        const Divider(height: 28),
                        Row(
                          children: [
                            Text(
                                tx('动作（${_exercises.length}）',
                                    en: 'Exercises (${_exercises.length})'),
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(width: 8),
                            Text(tx('长按拖动排序', en: 'Long-press to reorder'),
                                style: const TextStyle(
                                    color: AppTheme.textDim, fontSize: 12)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if (_exercises.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                                widget.isCycle
                                    ? tx('这一天还没有动作；加入后会自动以「第N练」参与轮转，点下方「添加动作」开始编排。',
                                        en: 'No exercises yet; once added, this day joins the rotation automatically. Tap "Add exercise" below to start.')
                                    : tx('这一天还没有动作，点下方「添加动作」开始编排。',
                                        en: 'No exercises yet for this day; tap "Add exercise" below to start.'),
                                style: const TextStyle(
                                    color: AppTheme.textDim)),
                          )
                        else
                          ReorderableListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            buildDefaultDragHandles: false,
                            onReorderItem: _onReorderItem,
                            proxyDecorator: (child, index, animation) =>
                                Material(
                              elevation: 4,
                              borderRadius: BorderRadius.circular(16),
                              color: AppTheme.cardHi,
                              child: child,
                            ),
                            itemCount: _exercises.length,
                            itemBuilder: (BuildContext ctx, int i) =>
                                _exerciseRow(i,
                                    key: ValueKey(_exercises[i].id)),
                          ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                  // 底部常驻：拇指区双入口（从动作库挑选 / 手动填写）
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _pickFromLibrary(),
                              icon: const Icon(Icons.library_books, size: 18),
                              label: Text(tx('从动作库选', en: 'Pick from library')),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(52),
                                backgroundColor: AppTheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _openExerciseSheet(),
                              icon: const Icon(Icons.edit, size: 18),
                              label: Text(tx('手动填写', en: 'Enter manually')),
                              style: OutlinedButton.styleFrom(
                                  minimumSize: const Size.fromHeight(52)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _exerciseRow(int i, {required Key key}) {
    final e = _exercises[i];
    final muscle = _metaByName[e.name]?.muscles.main;
    return Card(
      key: key,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ReorderableDelayedDragStartListener(
        index: i,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openExerciseSheet(e),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: Row(
              children: [
                const SizedBox(
                    width: 32,
                    height: 44,
                    child: Icon(Icons.drag_indicator,
                        size: 20, color: AppTheme.textDim)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(exname(e.name),
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600)),
                            if (_supersetGroupOf(i) != null)
                              _supersetBadge(i),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                            '${e.sets}×${e.repsMin}-${e.repsMax} · ${tx('休 ${e.restSec}s', en: 'Rest ${e.restSec}s')} · ${e.kind == 'compound' ? tx('复合', en: 'Compound') : tx('辅助', en: 'Assistance')}'
                            '${muscle != null ? ' · ${mname(muscle)}' : ''}',
                            style: const TextStyle(
                                color: AppTheme.textDim, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: _supersetGroupOf(i) != null
                      ? tx('解除超级组', en: 'Unpair superset')
                      : tx('与下一动作组成超级组',
                          en: 'Pair with next as superset'),
                  onPressed: () => _toggleSuperset(i),
                  icon: Icon(
                    _supersetGroupOf(i) != null ? Icons.link : Icons.add_link,
                    size: 19,
                    color: _supersetGroupOf(i) != null
                        ? AppTheme.primary
                        : AppTheme.textDim,
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: tx('复制', en: 'Copy'),
                  onPressed: () => _copyExercise(e),
                  icon: const Icon(Icons.content_copy,
                      size: 19, color: AppTheme.textDim),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: tx('删除', en: 'Delete'),
                  onPressed: () => _removeExercise(e),
                  icon: const Icon(Icons.delete_outline,
                      size: 20, color: AppTheme.danger),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 超级组徽标：⇄ + 同组伙伴名（自己的名字不重复出现）。
  Widget _supersetBadge(int i) {
    final group = _supersetGroupOf(i)!;
    final partners =
        [for (final j in group) if (j != i) exname(_exercises[j].name)]
            .join('+');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        tx('⇄ 超级组·$partners', en: '⇄ superset · $partners'),
        style: const TextStyle(fontSize: 10, color: AppTheme.primary),
      ),
    );
  }
}

// ================= 动作编辑表单 =================

class ExerciseFormResult {
  final String name;
  final int sets;
  final int repsMin;
  final int repsMax;
  final int restSec;
  final String kind;
  final String muscle; // 主肌群（写回动作库，供热力图归类）
  final String equipment; // 器械场景 gym/home/both（写回动作库）
  const ExerciseFormResult({
    required this.name,
    required this.sets,
    required this.repsMin,
    required this.repsMax,
    required this.restSec,
    required this.kind,
    required this.muscle,
    this.equipment = 'both',
  });
}

/// 动作编辑表单（2026-10-07 提为公有）：计划编辑器与今日开练编辑页
/// （today_edit_sheet.dart）共用——表单只返回 ExerciseFormResult 数据，
/// 写库发生在各调用方，天然可复用于「只影响当天」的编辑。
class ExerciseEditSheet extends StatefulWidget {
  const ExerciseEditSheet({
    super.key,
    this.initial,
    required this.knownMetas,
    this.initialMuscle,
  });

  final PlanExercise? initial;
  final List<ExerciseMeta> knownMetas;
  final String? initialMuscle;

  @override
  State<ExerciseEditSheet> createState() => _ExerciseEditSheetState();
}

class _ExerciseEditSheetState extends State<ExerciseEditSheet> {
  late final _nameCtrl =
      TextEditingController(text: widget.initial?.name ?? '');
  late int _sets = widget.initial?.sets ?? 3;
  late int _repsMin = widget.initial?.repsMin ?? 8;
  late int _repsMax = widget.initial?.repsMax ?? 12;
  late int _restSec = (widget.initial?.restSec ?? 0) > 0
      ? widget.initial!.restSec
      : 120;
  late String _kind = widget.initial?.kind ?? 'assistance';
  late String? _muscle =
      widget.initialMuscle ?? widget.initial?.name ?? '';
  String? _nameError;
  late String _equipment =
      widget.knownMetas.firstWhere((m) => m.name == widget.initial?.name,
              orElse: () => const ExerciseMeta('', MuscleGroups(main: '其他'), false))
          .equipment;

  List<String> get _suggestions {
    final q = _nameCtrl.text.trim();
    // 空时展示词表前几个，帮助发现与统一命名
    if (q.isEmpty) {
      return widget.knownMetas.take(8).map((m) => m.name).toList();
    }
    return widget.knownMetas
        .map((m) => m.name)
        .where((n) => n != q && n.contains(q))
        .take(6)
        .toList();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = _suggestions;
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
            Text(widget.initial == null
                ? tx('添加动作', en: 'Add exercise')
                : tx('编辑动作', en: 'Edit exercise'),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtrl,
              autofocus: widget.initial == null,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: tx('动作名', en: 'Exercise name'),
                errorText: _nameError,
              ),
            ),
            if (suggestions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final n in suggestions)
                      ActionChip(
                        label:
                            Text(exname(n), style: const TextStyle(fontSize: 12)),
                        backgroundColor: AppTheme.cardHi,
                        side: BorderSide.none,
                        onPressed: () {
                          _nameCtrl.text = n;
                          // 选词表动作时带出其肌群
                          final meta = widget.knownMetas
                              .where((m) => m.name == n)
                              .firstOrNull;
                          setState(
                              () => _muscle = meta?.muscles.main ?? _muscle);
                        },
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            // 快捷预设：一键填组数/次数/休息
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final preset in [
                  (tx('力量 3×5', en: 'Strength 3×5'), 3, 5, 5, 180),
                  (tx('增肌 3×8-12', en: 'Hypertrophy 3×8-12'), 3, 8, 12, 120),
                  (tx('耐力 2×15', en: 'Endurance 2×15'), 2, 15, 20, 75),
                ])
                  ActionChip(
                    label: Text(preset.$1,
                        style: const TextStyle(fontSize: 12)),
                    backgroundColor: AppTheme.cardHi,
                    side: BorderSide.none,
                    onPressed: () => setState(() {
                      _sets = preset.$2;
                      _repsMin = preset.$3;
                      _repsMax = preset.$4;
                      _restSec = preset.$5;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _stepper(tx('组数', en: 'Sets'), _sets, 1, 8, 1,
                (v) => setState(() => _sets = v)),
            _stepper(tx('次数下限', en: 'Min reps'), _repsMin, 1, _repsMax, 1,
                (v) => setState(() => _repsMin = v)),
            _stepper(tx('次数上限', en: 'Max reps'), _repsMax, _repsMin, 30, 1,
                (v) => setState(() => _repsMax = v)),
            _stepper(tx('组间休息（秒）', en: 'Rest between sets (s)'), _restSec,
                15, 600, 15, (v) => setState(() => _restSec = v)),
            // 休息快捷档：不用从 15 一档一档点到 180
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final sec in const [45, 60, 90, 120, 180, 240, 300])
                  ActionChip(
                    label: Text(
                        sec >= 60
                            ? tx('${sec ~/ 60} 分${sec % 60 == 0 ? '' : ' ${sec % 60} 秒'}',
                                en: '${sec ~/ 60} min${sec % 60 == 0 ? '' : ' ${sec % 60} s'}')
                            : tx('$sec 秒', en: '$sec s'),
                        style: TextStyle(
                            fontSize: 12,
                            color: _restSec == sec
                                ? AppTheme.primary
                                : AppTheme.textDim,
                            fontWeight: _restSec == sec
                                ? FontWeight.w700
                                : FontWeight.w400)),
                    backgroundColor:
                        _restSec == sec ? AppTheme.primary.withValues(alpha: 0.15) : AppTheme.cardHi,
                    side: BorderSide.none,
                    onPressed: () =>
                        setState(() => _restSec = sec),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(tx('主肌群', en: 'Main muscle'),
                      style: const TextStyle(
                          color: AppTheme.textDim, fontSize: 13)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Wrap(
                    spacing: 5,
                    runSpacing: 4,
                    children: [
                      for (final m in kMuscleRegions)
                        GestureDetector(
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() => _muscle = m);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: _muscle == m
                                  ? AppTheme.accent
                                  : AppTheme.cardHi,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                                tx(m,
                                    en: const {
                                      '胸': 'Chest',
                                      '肩': 'Shoulders',
                                      '背': 'Back',
                                      '手臂': 'Arms',
                                      '腿': 'Legs',
                                      '核心': 'Core',
                                      '其他': 'Other',
                                    }[m] ?? m),
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: _muscle == m
                                        ? const Color(0xFF06220F)
                                        : AppTheme.textDim)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(tx('场景', en: 'Setting'),
                      style: const TextStyle(
                          color: AppTheme.textDim, fontSize: 13)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Wrap(
                    spacing: 5,
                    runSpacing: 4,
                    children: [
                      for (final eq in [
                        ('both', tx('都可以', en: 'Both')),
                        ('gym', tx('健身房', en: 'Gym')),
                        ('home', tx('居家', en: 'Home')),
                      ])
                        GestureDetector(
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() => _equipment = eq.$1);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: _equipment == eq.$1
                                  ? AppTheme.accent
                                  : AppTheme.cardHi,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(eq.$2,
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: _equipment == eq.$1
                                        ? const Color(0xFF06220F)
                                        : AppTheme.textDim)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _kindChip(tx('复合', en: 'Compound'), 'compound'),
                const SizedBox(width: 8),
                _kindChip(tx('辅助', en: 'Assistance'), 'assistance'),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                final name = _nameCtrl.text.trim();
                if (name.isEmpty) {
                  setState(() =>
                      _nameError = tx('请填写动作名', en: 'Please enter an exercise name'));
                  return;
                }
                HapticFeedback.selectionClick();
                Navigator.pop(
                  context,
                  ExerciseFormResult(
                    name: name,
                    sets: _sets,
                    repsMin: _repsMin,
                    repsMax: _repsMax,
                    restSec: _restSec,
                    kind: _kind,
                    muscle: (_muscle == null || _muscle!.isEmpty)
                        ? '其他'
                        : _muscle!,
                    equipment: _equipment,
                  ),
                );
              },
              child: Text(tx('保存', en: 'Save')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepper(String label, int value, int min, int max, int step,
      ValueChanged<int> on) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          onPressed: value - step < min ? null : () => on(value - step),
          icon: const Icon(Icons.remove_circle_outline),
        ),
        SizedBox(
            width: 52,
            child: Text('$value',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16))),
        IconButton(
          onPressed: value + step > max ? null : () => on(value + step),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }

  Widget _kindChip(String label, String kind) {
    final sel = _kind == kind;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _kind = kind);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: sel ? AppTheme.accent : AppTheme.cardHi,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: sel ? const Color(0xFF06220F) : AppTheme.textDim)),
      ),
    );
  }
}

/// 超级组配对确认弹层（v9）：展示 A ⇄ B 的轮转执行方式，让用户选
/// 「转换休息」（A 做完一组转 B 前歇多久 = 第一个动作的组间休息秒数）。
/// 返回值：null = 取消；0 = 保持第一个动作当前休息不动；>0 = 选定的秒数。
class _SupersetPairSheet extends StatefulWidget {
  const _SupersetPairSheet({required this.first, required this.second});

  final PlanExercise first;
  final PlanExercise second;

  @override
  State<_SupersetPairSheet> createState() => _SupersetPairSheetState();
}

class _SupersetPairSheetState extends State<_SupersetPairSheet> {
  static const _choices = [15, 30, 45, 60];
  late int _selected;

  @override
  void initState() {
    super.initState();
    // 当前休息本来就是快捷档之一 → 预选它；否则预选 0（保持不变）。
    _selected = _choices.contains(widget.first.restSec)
        ? widget.first.restSec
        : 0;
  }

  @override
  Widget build(BuildContext context) {
    final a = exname(widget.first.name);
    final b = exname(widget.second.name);
    return Padding(
      padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tx('组成超级组', en: 'Pair as superset'),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Text(
            tx('$a ⇄ $b', en: '$a ⇄ $b'),
            style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700, color: AppTheme.primary),
          ),
          const SizedBox(height: 8),
          Text(
            tx(
                '训练时交替执行：$a 第1组 → $b 第1组 → $a 第2组 → ……直到都练满。'
                '\n$b 的组间休息照旧（每轮结束的完整休息）；$a 做完转 $b 前歇多久由 $a 的休息秒数决定，建议 15-60 秒：',
                en:
                    'Alternating order: $a set 1 → $b set 1 → $a set 2 → … until all sets are done.'
                    '\n$b keeps its rest (full rest between rounds); how long to rest after $a before switching to $b is $a\'s rest seconds — 15-60s recommended:'),
            style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip(0, tx('保持 ${widget.first.restSec}s', en: 'Keep ${widget.first.restSec}s')),
              for (final v in _choices) _chip(v, '$v${tx('秒', en: 's')}'),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52)),
              onPressed: () => Navigator.pop(context, _selected),
              child: Text(tx('配对', en: 'Pair')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(int value, String label) {
    final sel = _selected == value;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _selected = value);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: sel ? AppTheme.accent : AppTheme.cardHi,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: sel ? const Color(0xFF06220F) : AppTheme.textDim)),
      ),
    );
  }
}
