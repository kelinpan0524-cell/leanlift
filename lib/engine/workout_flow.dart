// 页面流状态机（调研条目 8，wger gym_mode 的"算出来的页面流"）：
// 起始页 → 每个计划正式组一个记录页（可选休息页插在两次保存之间）→ 总结页。
// 页面不靠手工导航堆栈维护，而是从「会话动作 + 已记组」的库内真值推导——
// 保存一组（校验→写库）后 SessionController 推进状态，本状态机重算当前页，
// UI 层顺势自动翻页；底部 3px 细进度条的全程完成比例同样从这里出。
//
// 与 SessionController 的推进语义逐条对齐（只读，不反向驱动）：
// - 只有正式组推进"下一组"：workingSetsDone 语义 = 该动作已完成正式组数；
// - 热身/力竭组记录后停留在原页（控制器不推进，这里同样不推进）；
// - 计划组练满后的继续记录 = 加练（extra），组号封顶在计划组数上，
//   与训练卡文案「第 N/M 组」的封顶口径一致（T-N9）。
//
// 纯 Dart 无 Flutter 依赖，便于单元测试。
import '../l10n/lang.dart';
import '../models/models.dart';

/// 页面种类：起始 / 记录 / 休息 / 总结。
enum FlowPageKind { start, record, rest, summary }

/// 页面流里的一页。字段级判等（==/hashCode）供 UI 的 AnimatedSwitcher
/// 判断"是否换了页"——同页重建不触发翻页动画，换页才触发。
class FlowPage {
  const FlowPage.start()
    : kind = FlowPageKind.start,
      exerciseIndex = -1,
      setNumber = 0,
      plannedSets = 0,
      extra = false;

  const FlowPage.summary()
    : kind = FlowPageKind.summary,
      exerciseIndex = -1,
      setNumber = 0,
      plannedSets = 0,
      extra = false;

  /// 记录页：[exerciseIndex] 动作下标；[setNumber] 本页待记录的正式组
  /// 序号（1 起，计划练满后封顶在 [plannedSets]）；[extra] = 加练态。
  const FlowPage.record({
    required this.exerciseIndex,
    required this.setNumber,
    required this.plannedSets,
    this.extra = false,
  }) : kind = FlowPageKind.record;

  /// 休息页：挂在「下一组」上（与训练卡同口径的组号），到点/跳过后
  /// 自然回到对应记录页。
  const FlowPage.rest({
    required this.exerciseIndex,
    required this.setNumber,
    required this.plannedSets,
  }) : kind = FlowPageKind.rest,
       extra = false;

  final FlowPageKind kind;
  final int exerciseIndex;
  final int setNumber;
  final int plannedSets;

  /// 计划组已练满后的追加记录页（「加练一组」）。
  final bool extra;

  /// UI 过渡的稳定键（同页相同、换页必不同）。
  String get key => switch (kind) {
    FlowPageKind.start => 'start',
    FlowPageKind.summary => 'summary',
    FlowPageKind.rest => 'rest-$exerciseIndex-$setNumber',    FlowPageKind.record =>
      'record-$exerciseIndex-$setNumber${extra ? '-extra' : ''}',
  };

  /// 顶部『第 N/M 组』文案（起始/总结页为空串）。
  /// 加练组不显示「/计划数」（第 4/3 组读不通），显示绝对组号
  /// 『第 4 组（加练）』（2026-10-08 口径统一：与跳页面板/训练卡/总结页
  /// 一个写法）。
  String setLabel() {
    if (kind == FlowPageKind.record || kind == FlowPageKind.rest) {
      return extra
          ? tx('第 $setNumber 组（加练）', en: 'Set $setNumber (extra)')
          : tx('第 $setNumber/$plannedSets 组', en: 'Set $setNumber/$plannedSets');
    }
    return '';
  }

  @override
  bool operator ==(Object other) =>
      other is FlowPage &&
      other.kind == kind &&
      other.exerciseIndex == exerciseIndex &&
      other.setNumber == setNumber &&
      other.plannedSets == plannedSets &&
      other.extra == extra;

  @override
  int get hashCode => Object.hash(kind, exerciseIndex, setNumber, plannedSets, extra);

  @override
  String toString() => 'FlowPage($key)';
}

/// 跳页面板里的一行：某动作的某个正式组页（含加练组）。
class FlowSetRef {
  const FlowSetRef({
    required this.exerciseIndex,
    required this.setNumber,
    required this.done,
    this.extra = false,
  });

  final int exerciseIndex;

  /// 1 起的组序号（页内展示口径）。
  final int setNumber;

  /// 该组已记录（正式组口径）→ 面板里划线标记、不可跳。
  final bool done;

  /// 超出计划组数的加练组（展示用「第 N 组（加练）」，仍划线锁定）。
  final bool extra;
}

/// 一次会话的页面流推导器。构造廉价（小列表），可随控制器状态反复重建。
class WorkoutFlow {
  WorkoutFlow({required this.exercises, required this.setsByEx});

  final List<SessionExercise> exercises;
  final Map<int, List<SetEntry>> setsByEx;

  int _doneWorkingOf(SessionExercise e) =>
      (setsByEx[e.id] ?? const <SetEntry>[])
          .where((s) => s.kind == SetKind.working)
          .length;

  /// 全程计划正式组总数（加练不计入：进度条到 1 即计划完成）。
  int get totalPlannedSets =>
      exercises.fold(0, (n, e) => n + e.rule.workingSets);

  /// 已完成的计划正式组数（逐动作封顶在各自计划组数上，加练不超 1）。
  int get donePlannedSets {
    var done = 0;
    for (final e in exercises) {
      done += _doneWorkingOf(e).clamp(0, e.rule.workingSets);
    }
    return done;
  }

  /// 底部 3px 细进度条的 value（wger gym_mode 的 ratioCompleted）。
  double get ratioCompleted {
    if (totalPlannedSets <= 0) return 0;
    return (donePlannedSets / totalPlannedSets).clamp(0.0, 1.0);
  }

  /// 动作 [i] 的计划正式组是否已记满。
  bool exerciseDone(int i) =>
      i >= 0 &&
      i < exercises.length &&
      _doneWorkingOf(exercises[i]) >= exercises[i].rule.workingSets;

  /// 自动当前页（起始页是 UI 入口态，不在这里推导；会话已结束时的
  /// 总结页由 UI 层在收尾流程里给，不经这里——那里还带着总结数据）。
  /// [resting] = 控制器处于休息相位；[curExIdx] = 控制器当前动作下标。
  FlowPage currentPage({required bool resting, required int curExIdx}) {
    if (exercises.isEmpty) return const FlowPage.summary();
    final i = curExIdx.clamp(0, exercises.length - 1);
    final ex = exercises[i];
    final planned = ex.rule.workingSets;
    // 加练组计数不封顶（2026-09-26 Arono：加练没显示加的这一组的 bug 根因
    // 就是这里把已完成数 clamp 到计划数，加练第 2、3 组永远显示 3/3）。
    // 记录页组号 = 已完成 + 1，加练时继续涨（第 4、5…组）；
    // 休息页组号语义是"计划内下一组"，练满后维持计划数封顶。
    final rawDone = _doneWorkingOf(ex);
    final done = rawDone.clamp(0, planned);
    final setNo =
        (!resting && rawDone >= planned) ? rawDone + 1 : done + 1;
    final extra = !resting && rawDone >= planned;
    if (resting) {
      return FlowPage.rest(
        exerciseIndex: i,
        setNumber: setNo.clamp(1, planned),
        plannedSets: planned,
      );
    }
    return FlowPage.record(
      exerciseIndex: i,
      setNumber: setNo,
      plannedSets: planned,
      extra: extra,
    );
  }

  /// 跳页面板的全部记录页（按动作、组序）。已完成的组带 done 标记，
  /// UI 层划线展示且不可跳（防把已记满的动作再跳回去打乱计数）。
  /// 加练组也列入（2026-09-26 Arono：加练了要显示出来）——
  /// 行数 = max(计划数, 已完成数)，超出计划的部分带 extra 标记。
  List<FlowSetRef> setRefs() {
    final out = <FlowSetRef>[];
    for (var i = 0; i < exercises.length; i++) {
      final planned = exercises[i].rule.workingSets;
      final rawDone = _doneWorkingOf(exercises[i]);
      final shown = rawDone > planned ? rawDone : planned;
      for (var k = 1; k <= shown; k++) {
        out.add(FlowSetRef(
          exerciseIndex: i,
          setNumber: k,
          done: k <= rawDone,
          extra: k > planned,
        ));
      }
    }
    return out;
  }
}
