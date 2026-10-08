import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../db/db.dart';
import '../engine/engine.dart';
import '../engine/superset.dart';
import '../l10n/lang.dart';
import '../l10n/names.dart';
import '../presets/baoji_plan.dart';
import 'focus_service.dart';
import 'rest_cue.dart';
import 'settings.dart';

enum WorkoutPhase { idle, lifting, resting }

/// 训练状态机（按 PRD 流程图）：
/// idle → lifting（热身/正式循环）→ resting → lifting → … → finished/quit
/// 休息用墙钟时间（restEndAt = epoch ms），锁屏/杀进程都不影响正确性；
/// 恢复逻辑：prefs 里存 sessionId + restEndAt，启动时若会话仍 active 则还原。
class SessionController extends ChangeNotifier {
  SessionController(this._db, this._settings, this._prefs, this._focus);

  final Db _db;
  final Settings _settings;
  final SharedPreferences _prefs;
  final FocusService? _focus;

  /// 只读暴露设置（测试与 UI 读取休息/音效偏好用；修改走 Settings 实例）。
  Settings get settings => _settings;

  Session? session;
  List<SessionExercise> exercises = [];
  Map<int, List<SetEntry>> setsByEx = {};
  Map<String, List<SetEntry>> lastWorkout = {}; // 动作名 → 上次正式组
  Map<String, List<SetEntry>> historyBefore = {}; // 动作名 → 本次之前的全部历史

  WorkoutPhase phase = WorkoutPhase.idle;
  int curExIdx = 0;
  int curSetIdx = 0; // 当前动作已完成组数（含热身）
  int restEndAt = 0;
  int restTotalMs = 0;
  double weightDraft = 0;
  int workingSetsDone = 0; // 当前动作正式组完成数
  final Set<String> prHit = {};

  /// 休息中可加练的"刚完成的动作"名（null = 无加练入口）。
  /// 每次进入休息都会置位（组间休息也能"再来一组"），
  /// 休息结束/结束训练时清除。
  String? extraSetExerciseName;

  /// 本次训练净时长（毫秒）：休息桶 / 训练桶，随相位切换累计，
  /// 结束时写入 sessions（总结页、历史、AI 分析评估休息长短用）。
  int restMs = 0;
  int activeMs = 0;
  DateTime? _phaseSince;

  /// 忘停表守护的截断点（epoch ms，非 null = finish 落库时用它当 ended_at）。
  /// 由 truncateDurationToLastSet 设置；新会话/放弃时清零。
  int? truncatedEndAtMs;

  void _accrueTime() {
    final since = _phaseSince;
    if (since == null) return;
    final dt = DateTime.now().difference(since).inMilliseconds;
    if (dt <= 0) return;
    if (phase == WorkoutPhase.resting) {
      restMs += dt;
    } else if (phase == WorkoutPhase.lifting) {
      activeMs += dt;
    }
    _phaseSince = DateTime.now();
  }

  Timer? _tick;
  Timer? _hbTimer; // 心跳：进度持久化 + 空闲检测（会话进行中每 2 秒）
  final ValueNotifier<int> restRemainingMs = ValueNotifier(0);
  final ValueNotifier<String> focusBanner = ValueNotifier('');
  bool _restNotified = false;
  int _lastCardSec = -1; // 训练卡每秒去重（只在秒变化时推送）
  final RestCueScheduler _cueScheduler = RestCueScheduler();

  // 心跳持久化（LibreFit 的 RUNNING 行思路，写 prefs 不写库）：
  // 训练态被杀后恢复时按墙钟差值接续时长，不被清零。
  DateTime? _lastPersist;
  bool _idleNotified = false;

  // ---------- 训练卡 / 空闲提醒回调（由 App 容器接线） ----------

  /// 人是否在屏上（App 容器按生命周期接线）。休息到点的屏内提示
  /// （震动+提示音）只在前台做：后台时系统提醒通道已带声音震动，
  /// 再走一遍就是双重打扰。
  bool inForeground = true;

  void setForeground(bool fg) => inForeground = fg;

  /// 训练卡状态变化：App 容器接 NotifyService（active=false 时停前台服务）。
  void Function(TrainingCard card)? onCardChanged;

  /// 空闲提醒触发：App 容器决定屏内横幅还是系统通知。
  Future<void> Function(int minutes)? onIdleNudge;

  /// 休息音效四层触发（调研条目 10）：App 容器接 NotifyService 播系统提示音。
  /// 结束层不从这里走（双通道互斥沿用 _onRestFinished 原有通道）。
  void Function(RestCue cue)? onRestCue;

  /// 计划内最后一组完成后的收尾确认（2026-10-07 结束确认弹窗）：
  /// 返回 true = 结束并保存（走原 finish 收尾）；false = 继续训练
  /// （不清场，按原推进语义起加练态休息页）。属「结束时点」弹窗豁免
  /// （先例 workout_page.dart _forgottenStopGuard 注释），不碰训练中禁弹窗。
  /// null = 保持原自动结束语义（无 UI 宿主/旧测试路径不受影响）。
  /// 由 WorkoutPage 挂载接线，dispose 时成对清空。
  Future<bool> Function()? confirmAutoFinish;

  void notifyCard() => onCardChanged?.call(buildCard());

  /// 训练卡状态（从会话状态派生，对齐训练中三要素：当前动作/本组目标/剩余时间）。
  TrainingCard buildCard() {
    final s = session;
    if (s == null || s.status != 'active') return const TrainingCard.inactive();
    final rule = currentEx?.rule;
    final reps = (rule == null || rule.repsMin == rule.repsMax)
        ? tx('${rule?.repsMin ?? 0} 次', en: '${rule?.repsMin ?? 0} reps')
        : tx('${rule.repsMin}-${rule.repsMax} 次',
            en: '${rule.repsMin}-${rule.repsMax} reps');
    final w = weightDraft;
    final wText = w < 0
        ? tx('辅 ${_fmtKg(-w)}kg', en: 'assist ${_fmtKg(-w)}kg')
        : (w == 0 ? tx('自重', en: 'bodyweight') : '${_fmtKg(w)}kg');
    if (phase == WorkoutPhase.resting) {
      final remainSec = restRemainingMs.value <= 0
          ? 0
          : (restRemainingMs.value / 1000).ceil();
      final remainText = remainSec >= 60
          ? tx('${remainSec ~/ 60}分${remainSec % 60}秒',
              en: '${remainSec ~/ 60}m${remainSec % 60}s')
          : tx('$remainSec 秒', en: '${remainSec}s');
      return TrainingCard(
        active: true,
        resting: true,
        paused: _restPaused,
        title: tx('组间休息中', en: 'Rest between sets'),
        // 下一组带动作名（2026-09-26 Arono：休息中要知道接下来练什么）：
        // 休息时 currentEx 已推进到下一个动作（或原动作的下一组）。
        text:
            '${_restPaused ? tx('已暂停 · ', en: 'Paused · ') : ''}'
            '${tx('还剩 $remainText · 下一组 ${exname(currentEx?.name ?? '')} $wText×$reps', en: '$remainText left · next ${exname(currentEx?.name ?? '')} $wText×$reps')}',
        remaining: restTotalMs > 0 ? remainSec : -1,
        total: (restTotalMs / 1000).round(),
        chronoStartMs: s.startedAt,
        // 暂停态无到点可数（剩余冻结在 Dart 侧），传 0 关掉原生倒数
        restEndAtMs: _restPaused ? 0 : restEndAt,
      );
    }
    // 组号语义与页面流同口径（workout_flow.currentPage）：计划内第 N/M 组，
    // 加练组不封顶——绝对组号「第 N 组（加练）」（2026-10-08 口径统一：
    // 与跳页面板/总结页一个写法），不再出现夹回「第 3/3 组」的旧 bug。
    final planned = rule?.workingSets ?? 1;
    final doneRaw = workingSetsDone;
    final setPart = doneRaw >= planned
        ? tx('第 ${doneRaw + 1} 组（加练）', en: 'Set ${doneRaw + 1} (extra)')
        : tx('第 ${doneRaw + 1}/$planned 组', en: 'Set ${doneRaw + 1}/$planned');
    return TrainingCard(
      active: true,
      resting: false,
      paused: false,
      title: currentEx?.name ?? tx('训练中', en: 'Workout in progress'),
      text: tx(
        '本组 $wText×$reps · $setPart',
        en: 'This set $wText×$reps · $setPart',
      ),
      remaining: -1,
      total: 0,
      chronoStartMs: s.startedAt,
    );
  }

  /// 当前相位起点 epoch ms（测试断言恢复接续用）。
  @visibleForTesting
  int get phaseSinceMs => _phaseSince?.millisecondsSinceEpoch ?? 0;

  /// 空闲提醒检测（调研条目 4）：lifting 相位连续超阈值时回调一次，
  /// 每段只提醒一次；休息/暂停/结束离开 lifting 即停，回到 lifting 重新起算。
  /// [nowMs] 注入便于测试。
  @visibleForTesting
  void checkIdleNudge(int nowMs) {
    if (phase != WorkoutPhase.lifting || _idleNotified || !hasActive) return;
    if (!_settings.idleNudgeEnabled) return;
    final since = _phaseSince;
    if (since == null) return;
    final thresholdMs = _settings.idleNudgeMinutes * 60000;
    if (thresholdMs <= 0) return;
    final elapsed = nowMs - since.millisecondsSinceEpoch;
    if (elapsed >= thresholdMs) {
      _idleNotified = true;
      onIdleNudge?.call(elapsed ~/ 60000);
    }
  }

  void _ensureHbTimer() {
    _hbTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      _persistProgress();
      checkIdleNudge(DateTime.now().millisecondsSinceEpoch);
    });
  }

  /// 心跳写 prefs（2 秒防抖）：会话、当前相位起点与已累计时长桶。
  /// 被杀恢复时按墙钟差值接续（与 _accrueTime 同口径），精度损失 ≤2 秒。
  void _persistProgress({bool force = false}) {
    final sid = session?.id;
    if (sid == null || session!.status != 'active') return;
    final since = _phaseSince;
    if (since == null) return;
    final now = DateTime.now();
    if (!force &&
        _lastPersist != null &&
        now.difference(_lastPersist!) < const Duration(seconds: 2)) {
      return;
    }
    _lastPersist = now;
    _prefs.setInt('sess.sid', sid);
    _prefs.setInt('sess.since', since.millisecondsSinceEpoch);
    _prefs.setInt('sess.phase', phase == WorkoutPhase.resting ? 1 : 0);
    _prefs.setInt('sess.restMs', restMs);
    _prefs.setInt('sess.activeMs', activeMs);
  }

  void _clearProgress() {
    _lastPersist = null;
    _idleNotified = false;
    _prefs.setInt('sess.sid', 0);
    _prefs.setInt('sess.since', 0);
    _prefs.setInt('sess.phase', 0);
    _prefs.setInt('sess.restMs', 0);
    _prefs.setInt('sess.activeMs', 0);
  }

  bool get hasActive => session != null && session!.status == 'active';
  SessionExercise? get currentEx =>
      exercises.isEmpty ? null : exercises[curExIdx];
  List<SetEntry> get currentSets =>
      currentEx == null ? [] : (setsByEx[currentEx!.id] ?? []);

  // ---------- 启动 / 恢复 ----------

  /// App 启动时调用：还原进行中的会话（含休息中状态）。
  /// 任何异常（脏数据/半写会话）都不允许锁死启动：回退到空闲态并吞掉。
  Future<void> restore() async {
    try {
      final active = await _db.activeSession();
      if (active == null) {
        _clearProgress();
        return;
      }
      final ok = await _loadSession(active.id!);
      if (!ok) {
        _clearProgress();
        return;
      }
      // 训练态被杀恢复（LibreFit 的 RUNNING 行思路）：读最后心跳，
      // 按墙钟差值把被杀期间漏计的时长接回对应桶（休息/训练）。
      final hbSid = _prefs.getInt('sess.sid') ?? 0;
      final hbSince = _prefs.getInt('sess.since') ?? 0;
      final hbPhase = _prefs.getInt('sess.phase') ?? 0;
      if (hbSid == active.id && hbSince > 0) {
        // 先取回心跳里已入桶的累计值（新实例内存桶从 0 起），再补被杀段
        restMs = _prefs.getInt('sess.restMs') ?? 0;
        activeMs = _prefs.getInt('sess.activeMs') ?? 0;
        final extra = DateTime.now().millisecondsSinceEpoch - hbSince;
        if (extra > 0) {
          if (hbPhase == 1) {
            restMs += extra;
          } else {
            activeMs += extra;
          }
        }
      } else {
        // 无有效心跳（老版本升级/脏数据）：维持旧行为从零起表
        restMs = 0;
        activeMs = 0;
      }
      _phaseSince = DateTime.now();
      final restEnd = _prefs.getInt('rest.endAt') ?? 0;
      final sid = _prefs.getInt('rest.sessionId') ?? 0;
      // 暂停态被杀：还原冻结倒计时（不挂闹钟不启 tick，等用户点继续）。
      // 心跳接续已把被杀段按暂停前相位入桶（口径与未死时一致）。
      final pausedFlag = _prefs.getInt('rest.paused') ?? 0;
      final pausedRemaining = _prefs.getInt('rest.remainingAtPause') ?? 0;
      if (sid == active.id &&
          pausedFlag == 1 &&
          pausedRemaining > 0 &&
          phase == WorkoutPhase.lifting) {
        // _loadSession 默认落在 lifting，这里切回冻结的休息态
        restEndAt = 0;
        restTotalMs = pausedRemaining;
        _restPaused = true;
        _restRemainingWhenPaused = pausedRemaining;
        restRemainingMs.value = pausedRemaining;
        _setPhase(WorkoutPhase.resting, silent: false);
      } else if (sid == active.id &&
          restEnd > DateTime.now().millisecondsSinceEpoch) {
        _startRestAt(restEnd, notifyUi: false);
      } else {
        _setPhase(WorkoutPhase.lifting);
      }
    } catch (_) {
      session = null;
      exercises = [];
      phase = WorkoutPhase.idle;
    }
  }

  Future<bool> _loadSession(int sessionId) async {
    final s = await _db.sessionById(sessionId);
    if (s == null || s.status != 'active') return false;
    session = s;
    exercises = await _db.sessionExercises(sessionId);
    if (exercises.isEmpty) {
      // 零动作的孤儿会话（半写/进程被杀残留）：自动作废，
      // 否则 currentEx! 解引用会让 App 启动即崩（restore 已把 session 置回 null，
      // 避免回落后 hasActive 仍为 true 造成二次崩溃）。
      session = null;
      await _db.updateSession(sessionId, {
        'ended_at': DateTime.now().millisecondsSinceEpoch,
        'status': 'quit',
      });
      return false;
    }
    setsByEx = await _db.setsOfSession(sessionId);
    // 恢复落点（v9 超级组）：按计划轮转序列走位到第一个未消费的槽位
    // ——不配对时序列退化为线性，与旧「第一个正式组未做完」完全一致；
    // 全部做完回落最后一个动作（加练口径）。
    curExIdx = resumeExerciseIdx(
      tags: _supersetTags,
      plannedSets: exercises.map((e) => e.rule.workingSets).toList(),
      doneWorking: _doneWorkingOfAll(),
    );
    curSetIdx = (setsByEx[currentEx!.id] ?? []).length;
    workingSetsDone = currentSets
        .where((e) => e.kind == SetKind.working)
        .length;
    await _loadContextForCurrent();
    weightDraft = _recommendFor(currentEx!.name);
    _setPhase(WorkoutPhase.lifting, silent: true);
    return true;
  }

  double _recommendFor(String name) {
    // 上次该动作那次训练的正式组 → 走规则链判定（调研条目 15）：
    // 达标推进「第一条还有空间的规则」（次数轴爬升 / 重量轴加重归下限），
    // 未达下限减重 5%，其余保持。
    // 「有历史」只看 last.isNotEmpty：0kg 是自重动作的合法历史档位
    // （hold 保持 0、顶格进位负重 2.5kg，与旧引擎一致），
    // 不能把重量 0 当作「无历史」回退到预设起始重量。
    final last = lastWorkout[name] ?? const <SetEntry>[];
    if (last.isNotEmpty) {
      final rule = currentEx?.rule ?? ProgressionRule.fallback;
      final state = chainStateFromHistory(last, rule);
      final v = evaluateChain(rule: rule, state: state, workingSets: last);
      // 负重量（辅助配重）同样渐进：-30 → -27.5 = 辅助减少 2.5kg，是进步。
      // 不再做 next>0 检查——那会让辅助器械动作永远卡在原配重。
      return round05(v.next.weightKg);
    }
    return _presetStartFor(name);
  }

  double _presetStartFor(String name) => presetStartOf(name);

  /// 上次该动作的首个正式组（调研条目 7"上次成绩行"数据源）：
  /// 上次训练的第一组是"照上次练"的重现起点（lastWorkingSets 按 id 升序）；
  /// 无历史返回 null。与渐进引擎的建议值（weightDraft 初始值，基于最后一组
  /// 渐进）并列，两个起点互不替换。
  SetEntry? lastPerformance(String name) {
    final list = lastWorkout[name] ?? const <SetEntry>[];
    return list.isEmpty ? null : list.first;
  }

  /// 平台期提醒缓存（2026-09-26 Arono：同重量停留过久 → 训练中途
  /// 主动提示可加重）。数据源 historyBefore 是"本会话开始前"的历史，
  /// 训练期间不变，按动作名缓存安全；新会话重建控制器/重新装载时
  /// 随 historyBefore 重灌自然失效。
  final _plateauCache = <String, PlateauInfo?>{};

  PlateauInfo? plateauFor(String name) {
    if (_plateauCache.containsKey(name)) return _plateauCache[name];
    var repsMax = ProgressionRule.fallback.repsMax;
    for (final ex in exercises) {
      if (ex.name == name) {
        repsMax = ex.rule.repsMax;
        break;
      }
    }
    final info =
        plateauOf(historyBefore[name] ?? const [], repsMax: repsMax);
    _plateauCache[name] = info;
    return info;
  }

  Future<void> _loadContextForCurrent() async {
    if (currentEx == null) return;
    final name = currentEx!.name;
    lastWorkout[name] = await _db.lastWorkingSets(name);
    final seId = currentEx!.id;
    // PR 判定只看正式组历史（热身大重量不应抬高 PR 门槛）
    historyBefore[name] = await _db.historySets(
      name,
      beforeSessionExerciseId: seId,
      kindFilter: SetKind.working,
    );
  }

  /// 从计划日开始训练（或继续）。已有进行中的会话时直接返回，防止双击产生孤儿会话。
  Future<void> startFromDay({
    required PlanDay day,
    required List<PlanExercise> planExercises,
  }) async {
    if (planExercises.isEmpty) return; // 空计划日不允许开会话（防零动作孤儿）
    if (hasActive) return;
    // 双击竞态兜底：内存态置 active 之前再查一次库，只放行一个并发调用
    if (await _db.activeSession() != null) return;
    prHit.clear();
    // 平台期缓存随新会话失效：控制器是 App 级单例，同进程第二次训练
    // 时 historyBefore 会重灌，旧缓存（尤其 null 值）会静默挡住提醒
    _plateauCache.clear();
    truncatedEndAtMs = null;
    final now = DateTime.now().millisecondsSinceEpoch;
    // 会话与动作一个事务落库（sessionId 先占位，事务内回填真实 id），
    // 消除"会话已落库、动作未落库"的半写窗口。
    final drafts = [
      for (final pe in planExercises)
        SessionExercise(
          sessionId: 0,
          name: pe.name,
          orderIdx: pe.orderIdx,
          kind: pe.kind,
          restSec: pe.restSec,
          rule: pe.rule,
          // 条目 14：模板目标参数全套快照进训练记录——模板日后修改
          // 不影响老记录的完成度对比（v6 前老记录 target=0 走回退语义）。
          targetSets: pe.sets,
          targetRepsMin: pe.repsMin,
          targetRepsMax: pe.repsMax,
          // 超级组标记同样快照（v9）：训练中的轮转推进按它分组，
          // 模板日后取消配对不影响进行中/历史会话。
          supersetTag: pe.supersetTag,
        ),
    ];
    final (s, withIds) = await _db.insertSessionWithExercises(
      Session(
        date: fmtDate(DateTime.now()),
        planDayId: day.id,
        planDayTitle: day.title,
        startedAt: now,
        status: 'active',
      ),
      drafts,
    );
    session = s;
    exercises = withIds;
    setsByEx = {};
    curExIdx = 0;
    curSetIdx = 0;
    workingSetsDone = 0;
    restMs = 0;
    activeMs = 0;
    _phaseSince = DateTime.now(); // 时长统计从这里起表
    await _loadContextForCurrent();
    weightDraft = _recommendFor(currentEx!.name);
    _setPhase(WorkoutPhase.lifting);
    await _enterFocus();
  }

  /// 临时训练（2026-09-29 出差/酒店场景）：AI 给的动作清单直接开练——
  /// 不落计划模板（sessions.plan_day_id=null）、不同步飞书日历、不影响
  /// 首页「今天已练完」判定（按计划日标题匹配，临时标题不撞）。
  /// 复用 startFromDay 全链路（防双击/事务落库/被杀恢复/周历点亮）。
  Future<void> startAdHoc({
    required String title,
    required List<PlanExercise> planExercises,
  }) async {
    await startFromDay(
      day: PlanDay(
        planId: 0, // 不入库的占位：id 为 null → 会话行 plan_day_id=null
        weekday: DateTime.now().weekday,
        title: title,
      ),
      planExercises: planExercises,
    );
  }

  // ---------- 记录 ----------

  /// 完成一组（kind: warmup/working/failure）。返回是否触发 PR。
  Future<bool> completeSet({
    required double weight,
    required int reps,
    required int rir,
    required String kind,
    String note = '',
  }) async {
    final ex = currentEx;
    if (ex == null) return false;
    // 加练标注（v12，2026-10-08）：落库前先判定——只对正式组标注
    // （kind==working 才参与判据：加练态下 kind chips 仍可选，计划满后
    // 再记热身/力竭组不该被误标「加练」）；必须在 workingSetsDone++ 与
    // insertSet 之前算，口径与 WorkoutFlow 只数正式组一致。仅展示标注，
    // 不改渐进/PR/容量统计。
    final planned = ex.rule.workingSets;
    final doneBefore = (setsByEx[ex.id] ?? const <SetEntry>[])
        .where((s) => s.kind == SetKind.working)
        .length;
    final isExtra = kind == SetKind.working && doneBefore >= planned;
    // 「当时处方」快照（wger 的 *_target 列，v8）：完成时把引擎给的
    // 推荐重量与链目标次数一并写进组行——用户手调过的重量与它对比，
    // 历史页就能回看「计划 vs 实际」。lastWorkout/historyBefore 在
    // 同一动作的组间不变（done 过滤），快照值组间稳定。
    final chainTarget = chainStateFromHistory(
        lastWorkout[ex.name] ?? const [], ex.rule);
    final entry = SetEntry(
      sessionExerciseId: ex.id!,
      weightKg: weight,
      reps: reps,
      rir: rir,
      kind: kind,
      doneAt: DateTime.now().millisecondsSinceEpoch,
      note: note,
      targetWeightKg: _recommendFor(ex.name),
      targetReps: chainTarget.targetReps,
      isExtra: isExtra,
    );
    final id = await _db.insertSet(entry);
    setsByEx
        .putIfAbsent(ex.id!, () => [])
        .add(SetEntry.fromMap({...entry.toMap(), 'id': id}));
    curSetIdx++;
    var pr = false;
    if (kind == SetKind.working) {
      workingSetsDone++;
      pr = isPrWeight(weight, historyBefore[ex.name] ?? []);
      if (pr) prHit.add(ex.name);
    }
    await _vibrate();
    notifyCard();
    notifyListeners();

    // 判断下一步：休息 or 换动作 or 结束
    // 热身组不触发休息计时（调研条目 9，Flexify 规则）：留在动作态
    // 直接做下一组，不给"再来一组"入口（本来就在该动作上）。
    if (kind == SetKind.warmup) return pr;
    // 下一步动作推导（v9 超级组轮转）：不配对动作与旧线性推进完全
    // 一致——未练满留在原动作、练满进下一动作；全部练满返回 null
    // = 结束会话。超级组成员每组后轮转到组内下一个还有剩余计划组的
    // 动作（A1→B1→A2→B2…）。
    final nextIdx = nextExerciseIdxAfterSet(
      tags: _supersetTags,
      plannedSets: exercises.map((e) => e.rule.workingSets).toList(),
      doneWorking: _doneWorkingOfAll(),
      justIdx: curExIdx,
    );
    if (nextIdx == null) {
      // 收尾确认（2026-10-07 结束确认弹窗）：计划内最后一组完成、即将
      // 自动结束前先问一次「现在结束吗」。回答「继续训练」（false）时
      // 不清场，按原推进语义起休息页（落在刚练满动作的加练态，自然给出
      // 「再来一组/跳过休息」入口）；回答「结束并保存」（true）或回调
      // 未挂（null = 保持原自动结束语义）走原收尾。弹窗 await 期间会话
      // 仍 active（训练卡/常亮/心跳照常）。
      final confirm = confirmAutoFinish;
      if (confirm != null && !await confirm()) {
        extraSetExerciseName = ex.name;
        _beginRestFor(ex);
        return pr;
      }
      // 最后一个动作完成：直接结束会话；UI 检测到 !hasActive 后
      // 走 endTraining 展示总结页并回填飞书
      await finish();
      return pr;
    }
    if (nextIdx != curExIdx) {
      await _applyExerciseSwitch(nextIdx);
    }
    // 无论组间还是练满推进：休息页都能"再来一组"回到刚完成的动作。
    // 组间时 currentEx 未变，startExtraSet 回退到自身是无害幂等操作。
    extraSetExerciseName = ex.name;
    _beginRestFor(ex);
    return pr;
  }

  // ---------- 超级组（v9）：派生与切换 ----------

  List<String> get _supersetTags =>
      exercises.map((e) => e.supersetTag).toList();

  /// 各动作已完成正式组数（从库内真值派生，含非当前动作——
  /// 超级组轮转判据要看全组进度，不能只盯当前动作的计数器）。
  List<int> _doneWorkingOfAll() => [
        for (final e in exercises)
          (setsByEx[e.id] ?? const <SetEntry>[])
              .where((s) => s.kind == SetKind.working)
              .length
      ];

  /// 把当前动作切到 [exIdx]：计数按库内真值重算，上下文重载；重量起点 =
  /// 该动作本会话最后一组的实际值（超级组 A/B 交替时 A2 自动接 A1 的
  /// 手感，两个动作的重量互不覆盖），无实际组才回落推荐值。
  /// 练满推进、超级组轮转、跳页（jumpToExercise）共用。
  Future<void> _applyExerciseSwitch(int exIdx) async {
    curExIdx = exIdx;
    final target = exercises[exIdx];
    final list = setsByEx[target.id] ?? const <SetEntry>[];
    workingSetsDone = list.where((e) => e.kind == SetKind.working).length;
    curSetIdx = list.length;
    await _loadContextForCurrent();
    weightDraft =
        list.isNotEmpty ? list.last.weightKg : _recommendFor(target.name);
  }

  void _advanceToNextExercise() {
    curExIdx++;
    curSetIdx = 0;
    workingSetsDone = 0;
  }

  /// 跳过当前动作（未完成的组不记录）。最后一个动作时跳过 = 结束训练的替代入口。
  Future<void> skipExercise() async {
    if (session == null || exercises.isEmpty) return;
    if (curExIdx < exercises.length - 1) {
      _advanceToNextExercise();
      await _loadContextForCurrent();
      weightDraft = _recommendFor(currentEx!.name);
      _setPhase(WorkoutPhase.lifting);
      notifyCard();
    }
  }

  /// 跳页（调研条目 8 页面流的"跳页走收起面板"）：把当前动作切到 [exIdx]，
  /// 该动作剩余的第一个未完成正式组成为当前记录页。已记的组原样保留。
  /// 只允许跳到未练满的动作（练满的加练走休息页「再来一组」，防误触打乱
  /// 计数）；目标即当前动作时为幂等 no-op。休息中跳页会先结束本段休息
  /// （取消精确闹钟，与跳过休息同口径）。
  Future<bool> jumpToExercise(int exIdx) async {
    if (session == null || exercises.isEmpty) return false;
    if (exIdx < 0 || exIdx >= exercises.length) return false;
    if (exIdx == curExIdx) return false;
    final target = exercises[exIdx];
    final done = (setsByEx[target.id] ?? const <SetEntry>[])
        .where((e) => e.kind == SetKind.working)
        .length;
    if (done >= target.rule.workingSets) return false; // 已练满：不可跳入
    if (phase == WorkoutPhase.resting) _finishRest(cancelAlarm: true);
    await _applyExerciseSwitch(exIdx);
    _setPhase(WorkoutPhase.lifting);
    notifyCard();
    notifyListeners();
    return true;
  }

  /// 完成后未休息先看下一动作（下一组自动带入上次重量）。
  /// 休息时长（调研条目 9 分档规则）：
  /// ① 逐动作覆盖优先——计划里该动作配置的 restSec（>0 生效）；
  /// ② 全局基础值按 compound/assistance 取用户偏好；
  /// ③ 按「刚完成那组的结果」分档：达标给标准休息，未达标/力竭组给
  ///    ×1.5 的更长休息（engine.restSecondsAfterSet）；热身组 0（不触发）。
  void _beginRestFor(SessionExercise justFinished) {
    final sets = setsByEx[justFinished.id] ?? const <SetEntry>[];
    final last = sets.isEmpty ? null : sets.last;
    final base = justFinished.restSec > 0
        ? justFinished.restSec
        : (justFinished.kind == 'compound'
              ? _settings.restCompoundSec
              : _settings.restAssistanceSec);
    final sec = restSecondsAfterSet(
      kind: last?.kind ?? SetKind.working,
      reps: last?.reps ?? justFinished.rule.repsMax,
      repsMax: justFinished.rule.repsMax,
      baseSec: base, // base 已融合逐动作覆盖（restSec>0）与全局偏好
    );
    if (sec <= 0) return; // 双保险：热身组不触发计时
    final end = DateTime.now().millisecondsSinceEpoch + sec * 1000;
    // totalMs 直接用处方秒数：两次读真实时钟相减会随机差出 1ms
    //（119999ms → 119s），恢复/暂停路径不传则维持「按剩余重新起表」语义。
    _startRestAt(end, notifyUi: true, totalMs: sec * 1000);
    // 预载（下一）动作上下文。重量只在换动作时刷新——同一动作继续时
    // 保留用户手动调过的重量，不再每组被冲回推荐值。换动作时起点与
    // _applyExerciseSwitch 同口径：该动作本会话已有实际组就接最后一组
    // 的实际值（超级组 A2 接 A1），否则推荐值。
    _loadContextForCurrent().then((_) {
      if (!hasActive) return;
      final next = currentEx;
      if (next == null || next.id != justFinished.id) {
        final list = setsByEx[next?.id] ?? const <SetEntry>[];
        weightDraft = list.isNotEmpty
            ? list.last.weightKg
            : _recommendFor(next?.name ?? '');
        notifyListeners();
      }
    });
  }

  void _startRestAt(int endAtMs, {required bool notifyUi, int? totalMs}) {
    restEndAt = endAtMs;
    restTotalMs = (totalMs ?? (endAtMs - DateTime.now().millisecondsSinceEpoch)).clamp(
      0,
      1 << 31,
    );
    _restNotified = false;
    _lastCardSec = -1;
    // 先刷剩余时间再切相位：_setPhase 会同步推训练卡，拿的是新值
    _updateRemaining();
    _setPhase(WorkoutPhase.resting, silent: !notifyUi);
    _prefs.setInt('rest.endAt', endAtMs);
    _prefs.setInt('rest.sessionId', session?.id ?? 0);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => _tickFn());
    // 音效四层（条目 10）：进入/恢复/加时都重置各层，重新经过触发窗口即播
    _cueScheduler.reset();
    _fireRestCues();
    // 时间源统一：精确闹钟跟随 restEndAt（含恢复会话后补挂闹钟的场景）
    onRestAlarmChanged?.call(endAtMs);
  }

  void _tickFn() {
    _updateRemaining();
    _fireRestCues();
    // 训练卡只在秒变化时推送（后台不必每 250ms 打扰通知栈）
    final sec = restRemainingMs.value ~/ 1000;
    if (sec != _lastCardSec) {
      _lastCardSec = sec;
      notifyCard();
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (restEndAt <= now && !_restNotified) {
      _restNotified = true;
      _onRestFinished();
    }
  }

  /// 音效四层触发（调研条目 10）：区间阈值判断见 RestCueScheduler。
  /// 每层触发 = 播一声提示音 + 震一次（到点只震一次，跟随震动开关）。
  /// 结束层跳过——休息到点的提示走 _onRestFinished 原有通道
  /// （前台震动+系统提示音 / 后台系统精确提醒，双通道互斥不重复）。
  void _fireRestCues() {
    if (!hasActive || phase != WorkoutPhase.resting || _restPaused) return;
    if (!_settings.restCueEnabled) return;
    final cues = _cueScheduler.evaluate(restRemainingMs.value, restTotalMs);
    for (final cue in cues) {
      if (cue == RestCue.end) continue;
      onRestCue?.call(cue);
      unawaited(_vibrate());
    }
  }

  void _updateRemaining() {
    final now = DateTime.now().millisecondsSinceEpoch;
    restRemainingMs.value = (restEndAt - now).clamp(0, 1 << 31);
  }

  Future<void> _onRestFinished() async {
    // 屏内提示只在前台做：人在后台时系统精确提醒（rest_timer 通道）已带
    // 声音+震动，这里再来一遍就是双重打扰。
    if (inForeground) {
      await _vibrate();
      if (_settings.soundOn) {
        // 系统提示音（无需音频资源，前台可闻）
        SystemSound.play(SystemSoundType.alert);
      }
    }
    // 自然到点：不取消精确闹钟——人在后台时系统提醒是唯一通道，
    // 屏内/系统双通道互斥由生命周期钩子（App 容器）保证。
    _finishRest();
    notifyListeners();
  }

  /// [cancelAlarm]：用户主动跳过休息（跳过/加练）时取消精确闹钟；
  /// 自然到点不取消（见 _onRestFinished）。
  void _finishRest({bool cancelAlarm = false}) {
    _tick?.cancel();
    _tick = null;
    _lastCardSec = -1;
    _prefs.setInt('rest.endAt', 0);
    _prefs.setInt('rest.paused', 0);
    extraSetExerciseName = null;
    if (cancelAlarm) onRestAlarmChanged?.call(null);
    _setPhase(WorkoutPhase.lifting);
    restRemainingMs.value = 0;
  }

  void skipRest() => _finishRest(cancelAlarm: true);

  /// 休息中「刚完成的动作再来一组」：回退到该动作进入动作态，
  /// 再完成的组按正式组记录（同样参与渐进判定与 PR）。
  /// 重量继承该动作最后一组的实际重量（手调过的配重不从头再来），
  /// 没有历史组才回落到推荐值。
  Future<void> startExtraSet() async {
    final name = extraSetExerciseName;
    if (name == null || !hasActive) return;
    final idx = exercises.indexWhere((e) => e.name == name);
    if (idx < 0) return;
    _restPaused = false; // 暂停态回退前先解除，避免 resume 语义错乱
    curExIdx = idx;
    final list = setsByEx[exercises[idx].id] ?? const <SetEntry>[];
    workingSetsDone = list.where((e) => e.kind == SetKind.working).length;
    curSetIdx = list.length;
    await _loadContextForCurrent();
    weightDraft = list.isNotEmpty ? list.last.weightKg : _recommendFor(name);
    _finishRest(cancelAlarm: true);
    notifyListeners();
  }

  // ---- 休息暂停/继续 ----
  bool _restPaused = false;
  int _restRemainingWhenPaused = 0;

  bool get isRestPaused => _restPaused;

  /// 暂停：冻结剩余时间（记下剩余毫秒并停表）。
  void pauseRest() {
    if (phase != WorkoutPhase.resting || _restPaused) return;
    _restPaused = true;
    _restRemainingWhenPaused = restRemainingMs.value;
    _tick?.cancel();
    _tick = null;
    _applyWakelock(); // 暂停即灭屏：只有真在计时才耗电（条目 6）
    // 暂停即取消精确闹钟（否则暂停期间到点照响）
    onRestAlarmChanged?.call(null);
    // 暂停态落盘：暂停中被杀后 restore 能还原冻结倒计时（不然暂停被吞）
    _prefs.setInt('rest.paused', 1);
    _prefs.setInt('rest.remainingAtPause', _restRemainingWhenPaused);
    _persistProgress(force: true);
    notifyCard();
    notifyListeners();
  }

  /// 继续：从剩余时间重新起表（经 _startRestAt 自动重挂闹钟；
  /// _setPhase 里的 _applyWakelock 随 lifting/resting 未暂停态重新常亮）。
  void resumeRest() {
    if (phase != WorkoutPhase.resting || !_restPaused) return;
    _restPaused = false;
    _prefs.setInt('rest.paused', 0);
    final end =
        DateTime.now().millisecondsSinceEpoch + _restRemainingWhenPaused;
    restTotalMs = _restRemainingWhenPaused;
    _startRestAt(end, notifyUi: true);
  }

  void extendRest(int sec) {
    if (phase != WorkoutPhase.resting || sec == 0) return;
    if (_restPaused) {
      // 暂停态加/减时：只动冻结值与总时长，不写 prefs、不改 restEndAt
      // （否则 resume 用冻结值重算时，加的秒数会被静默丢弃）；
      // 地板 5 秒，减时不把休息直接减没。冻结值变化同步进暂停落盘，
      // 暂停中被杀恢复才能拿到加/减后的剩余时间。
      _restRemainingWhenPaused = (_restRemainingWhenPaused + sec * 1000).clamp(
        5000,
        1 << 31,
      );
      restTotalMs = (restTotalMs + sec * 1000).clamp(1000, 1 << 31);
      restRemainingMs.value = _restRemainingWhenPaused;
      _prefs.setInt('rest.remainingAtPause', _restRemainingWhenPaused);
      notifyCard();
      return;
    }
    // 非暂停态：地板 5 秒，防止 -30 把剩余时间减成已过期
    final floorEnd = DateTime.now().millisecondsSinceEpoch + 5000;
    restEndAt = (restEndAt + sec * 1000) < floorEnd
        ? floorEnd
        : restEndAt + sec * 1000;
    restTotalMs = (restTotalMs + sec * 1000).clamp(1000, 1 << 31);
    _prefs.setInt('rest.endAt', restEndAt);
    _updateRemaining();
    // 音效层重置（条目 10）：只在加时（重新获得一段等待）时清层，
    // 半程按新总长重新计算、重新经过窗口即重播；减时保留已播状态——
    // 跳过的窗口不补播、已过的层不重播（避免 -30 秒重播开始音）。
    if (sec > 0) _cueScheduler.reset();
    _fireRestCues();
    onRestAlarmChanged?.call(restEndAt);
    notifyCard();
  }

  /// 撤销最后一组（记错时用）。目标是「全会话最新的一组」——按完成
  /// 时间找全局最后一组删除，再切回它所属的动作。超级组轮转下当前
  /// 动作未必是刚记录的动作（A1 后已切到 B），旧的 curExIdx-- 线性
  /// 回退会撤错对象；不配对时全局最后一组就是当前/上一动作的尾组，
  /// 行为与旧实现一致。回退跨动作时重量 = 该动作剩余最后一组的实际
  /// 重量（重记这组时手感不从头再来）。
  Future<void> undoLastSet() async {
    if (session == null || exercises.isEmpty) return;
    SessionExercise? ex;
    List<SetEntry>? list;
    var lastDoneAt = -1;
    var lastId = -1;
    for (var i = 0; i < exercises.length; i++) {
      final l = setsByEx[exercises[i].id];
      if (l == null || l.isEmpty) continue;
      final tail = l.last;
      final id = tail.id ?? 0;
      if (tail.doneAt > lastDoneAt || (tail.doneAt == lastDoneAt && id > lastId)) {
        lastDoneAt = tail.doneAt;
        lastId = id;
        ex = exercises[i];
        list = l;
      }
    }
    if (ex == null || list == null) return;
    final last = list.last;
    final wasCurrent = ex.id == currentEx?.id;
    await _db.deleteSet(last.id!);
    list.removeLast();
    if (!wasCurrent) {
      curExIdx = exercises.indexOf(ex);
      await _loadContextForCurrent();
      // 回退动作的重量 = 它剩余最后一组的实际重量（重记这组时手感不从头再来）
      weightDraft = list.isNotEmpty
          ? list.last.weightKg
          : _recommendFor(ex.name);
    }
    curSetIdx = list.length;
    // 计数收敛到 DB 真值：同动作撤销与跨动作回退统一按剩余正式组重算。
    workingSetsDone = list.where((e) => e.kind == SetKind.working).length;
    // PR 标记不随单组撤销丢项：仅当剩余正式组中已没有任何一组仍是
    // 历史新高时才清除（逐组重判，任一剩余组仍超历史最佳就保留）。
    if (prHit.contains(ex.name)) {
      final history = historyBefore[ex.name] ?? const <SetEntry>[];
      final anyStillPr = list.any(
        (e) => e.kind == SetKind.working && isPrWeight(e.weightKg, history),
      );
      if (!anyStillPr) prHit.remove(ex.name);
    }
    notifyCard();
    notifyListeners();
  }

  void setWeightDraft(double w) {
    weightDraft = (w * 100).round() / 100;
    // 允许负值 = 辅助器械配重（引体向上/双杠臂屈伸辅助机，配重越大负荷越轻）；
    // 下限 -300kg 防手抖连点把数值打到无意义区间。
    if (weightDraft < -300) weightDraft = -300;
    if (weightDraft > 1000) weightDraft = 1000;
    notifyCard();
    notifyListeners();
  }

  /// 自重/负重一键切换：有重量（含辅助配重负值）→ 归零（自重）；
  /// 已是自重→回到上次用的重量（无历史则用推荐值），不用记步进点回去。
  void toggleBodyweightDraft() {
    if (weightDraft != 0) {
      setWeightDraft(0);
      return;
    }
    final name = currentEx?.name ?? '';
    final last = lastWorkout[name];
    final w = (last != null && last.isNotEmpty)
        ? last.last.weightKg
        : _recommendFor(name);
    setWeightDraft(w);
  }

  /// 训练中临时加动作：从动作库挑的动作追加到队尾（只进本次会话，不改计划）。
  /// 规则用默认（5-8 次 × 3 组），休息跟随全局偏好（restSec=0）。
  /// 每行带『追加于：前一动作』痕迹（点名条目三），便于统计追溯。
  Future<void> appendExercises(List<ExerciseMeta> metas) async {
    if (!hasActive || metas.isEmpty) return;
    var order = exercises.length;
    var prevName =
        exercises.isEmpty ? '' : exercises.last.name; // 痕迹：追加在谁后面
    for (final m in metas) {
      final draft = SessionExercise(
        sessionId: session!.id!,
        name: m.name,
        orderIdx: order++,
        kind: m.isCompound ? 'compound' : 'assistance',
        restSec: 0,
        rule: ProgressionRule.fallback,
        trace: prevName.isEmpty
            ? tx('追加于：会话开头', en: 'Added at start of session')
            : tx('追加于：$prevName', en: 'Added after $prevName'),
      );
      final id = await _db.insertSessionExercise(draft);
      exercises.add(draft.copyWithId(id));
      prevName = m.name;
    }
    notifyCard();
    notifyListeners();
  }

  /// 训练中替换当前动作（仅限还没记过组的动作）：沿用原组次规则/休息/排序，
  /// 只换名字，行上留『替换自：原动作』痕迹（点名条目三）。
  /// 已记组或队列里已有同名动作时不动作（返回 false）。
  Future<bool> replaceCurrentExercise(ExerciseMeta meta) async {
    final ex = currentEx;
    if (!hasActive || ex == null) return false;
    if (currentSets.isNotEmpty) return false;
    if (meta.name == ex.name) return false;
    if (exercises.any((e) => e.name == meta.name)) return false;
    final updated = SessionExercise(
      id: ex.id,
      sessionId: ex.sessionId,
      name: meta.name,
      orderIdx: ex.orderIdx,
      kind: ex.kind,
      restSec: ex.restSec,
      rule: ex.rule,
      // 条目 14：快照列原样保留——整行覆写若丢这三列会把已快照的
      // 模板目标抹成 0，老记录完成度对比就失真了。
      targetSets: ex.targetSets,
      targetRepsMin: ex.targetRepsMin,
      targetRepsMax: ex.targetRepsMax,
      trace: tx('替换自：${ex.name}', en: 'Replaced from ${ex.name}'),
    );
    await _db.updateSessionExercise(updated);
    exercises[curExIdx] = updated;
    await _loadContextForCurrent();
    weightDraft = _recommendFor(meta.name);
    notifyCard();
    notifyListeners();
    return true;
  }

  /// 本次训练里最后一次记录组的时刻（epoch ms）；一组没记返回 null。
  /// 忘停表守护 UI 展示"截到几点"用。
  int? get lastSetDoneAtMs {
    int? last;
    for (final list in setsByEx.values) {
      for (final e in list) {
        if (last == null || e.doneAt > last) last = e.doneAt;
      }
    }
    return last;
  }

  int get setCount {
    var n = 0;
    for (final list in setsByEx.values) {
      n += list.length;
    }
    return n;
  }

  /// 把会话时长截到最后一次记录组 + 2 分钟缓冲（忘停表守护，只减不增）。
  /// 超时发生在退出前所处的相位里（练完挂着 → active 桶；组间挂着 → rest 桶），
  /// 超出部分从对应桶里扣（地板 0），ended_at 截到 [truncatedEndAtMs]。
  /// finish 时按真实墙钟补记最后一段（_accrueTime），扣掉的量正好抵消挂机段。
  void truncateDurationToLastSet() {
    final last = lastSetDoneAtMs;
    if (last == null) return;
    final cap = last + 2 * 60000;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (cap >= now) return;
    final excess = now - cap;
    if (phase == WorkoutPhase.resting) {
      restMs = (restMs - excess).clamp(0, 1 << 31);
    } else {
      activeMs = (activeMs - excess).clamp(0, 1 << 31);
    }
    truncatedEndAtMs = cap;
  }

  // ---------- 结束 ----------

  Future<void> finish() async {
    if (session == null) return;
    if (session!.status != 'active') return; // 幂等：自动结束+手动结束不重复
    _finishRest();
    onRestAlarmChanged?.call(null); // 会话结束：精确提醒一并取消
    await _db.updateSession(session!.id!, {
      'ended_at': truncatedEndAtMs ?? DateTime.now().millisecondsSinceEpoch,
      'status': 'done',
      'rest_ms': restMs,
      'active_ms': activeMs,
    });
    await _exitFocus();
    session = await _db.sessionById(session!.id!);
    WakelockPlus.disable();
    prHit.clear();
    _setPhase(WorkoutPhase.idle);
    onSessionClosed?.call();
  }

  Future<void> quit() async {
    if (session == null) return;
    if (session!.status != 'active') return;
    _finishRest();
    onRestAlarmChanged?.call(null);
    await _db.updateSession(session!.id!, {
      'ended_at': DateTime.now().millisecondsSinceEpoch,
      'status': 'quit',
      'rest_ms': restMs,
      'active_ms': activeMs,
    });
    await _exitFocus();
    WakelockPlus.disable();
    session = null;
    prHit.clear();
    truncatedEndAtMs = null;
    _setPhase(WorkoutPhase.idle);
    onSessionClosed?.call();
  }

  /// 训练后主观自评（wger 的 impression 三档：1=差/2=一般/3=好）。
  /// 总结页点选即存、可反悔改选；已 finish（status=done）的会话照样可写。
  Future<void> setImpression(int v) async {
    if (session == null) return;
    if (v < 1 || v > 3) return;
    await _db.updateSession(session!.id!, {'impression': v});
    session = await _db.sessionById(session!.id!);
    notifyListeners();
  }

  /// 本次训练汇总（用于结束页与飞书回填）。
  Future<SessionStats> stats() async {
    if (session == null) {
      return const SessionStats(
        volume: 0,
        totalSets: 0,
        workingSets: 0,
        reps: 0,
        exercises: [],
      );
    }
    final order = await _db.sessionExercises(session!.id!);
    final map = await _db.setsOfSession(session!.id!);
    // 自重动作按 系数×体重 折算进容量（点名条目二；体重 0 时自动回旧口径）
    return sessionStatsFrom(map, order, bodyWeightKg: _settings.bodyWeightKg);
  }

  /// 渐进判定建议（结束时展示 + AI 分析包引用）。
  /// 走规则链引擎（调研条目 15）；文案带上条目 14 的模板目标快照
  /// （计划目标 N组×a-b 次），老记录无快照（target=0）时回退规则参数。
  Future<List<String>> verdicts() async {
    final out = <String>[];
    for (final ex in exercises) {
      final sets = setsByEx[ex.id!] ?? [];
      final state = chainStateFromHistory(sets, ex.rule);
      final v = evaluateChain(rule: ex.rule, state: state, workingSets: sets);
      final tSets = ex.targetSets > 0 ? ex.targetSets : ex.rule.workingSets;
      final tMin = ex.targetRepsMin > 0 ? ex.targetRepsMin : ex.rule.repsMin;
      final tMax = ex.targetRepsMax > 0 ? ex.targetRepsMax : ex.rule.repsMax;
      out.add(tx(
        '${ex.name}（计划目标 $tSets×$tMin-$tMax 次）：${v.reason}',
        en: '${exname(ex.name)} (target $tSets×$tMin-$tMax reps): ${v.reason}',
      ));
    }
    return out;
  }

  // ---------- 专注模式钩子（由 FocusService 在 UI 层接线） ----------

  Future<void> Function()? onEnterFocus;
  Future<void> Function()? onExitFocus;

  /// 休息精确闹钟的时间源回调：endAtMs 非 null = （重）挂 endAtMs 的闹钟，
  /// null = 取消。由 App 容器接 NotifyService（开始休息/加时/继续时重挂，
  /// 暂停时取消，恢复会话时补挂）。人在屏上时容器会跳过挂钟、只走屏内
  /// 提醒（双通道互斥，离开前台由生命周期钩子重挂）。
  Future<void> Function(int? endAtMs)? onRestAlarmChanged;

  /// 会话关闭（结束/放弃）后回调：App 容器接练前提醒重排——
  /// 今天已练完，当天未到的练前提醒随即取消。
  void Function()? onSessionClosed;

  Future<void> _enterFocus() async {
    WakelockPlus.enable();
    await onEnterFocus?.call();
  }

  Future<void> _exitFocus() async {
    await onExitFocus?.call();
  }

  Future<void> _vibrate() async {
    if (!_settings.vibrationOn) return;
    await _focus?.vibrate();
  }

  void _setPhase(WorkoutPhase p, {bool silent = false}) {
    if (phase != p) _accrueTime(); // 相位切换前把上一段时长入桶
    phase = p;
    // 空闲提醒随相位切换重置（回到 lifting 重新起算，每段只提醒一次）
    if (p == WorkoutPhase.lifting) _idleNotified = false;
    if (p == WorkoutPhase.idle) {
      _hbTimer?.cancel();
      _hbTimer = null;
      _clearProgress();
    } else {
      _ensureHbTimer();
      _persistProgress(force: true);
    }
    _applyWakelock(); // 常亮随相位收口（条目 6，含恢复会话的各分支）
    notifyCard();
    if (!silent) notifyListeners();
  }

  /// 是否应保持屏幕常亮（调研条目 6 常亮三件套）：
  /// 会话进行中且不在"已暂停的休息"里才常亮——暂停/结束即灭屏，
  /// 恢复（继续/跳过/到点/加练）回到计时态再亮。提取纯函数便于单测。
  static bool shouldKeepScreenOn({
    required bool hasActive,
    required WorkoutPhase phase,
    required bool restPaused,
  }) => hasActive && (phase != WorkoutPhase.resting || !restPaused);

  void _applyWakelock() {
    if (shouldKeepScreenOn(
      hasActive: hasActive,
      phase: phase,
      restPaused: _restPaused,
    )) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  // 分心提醒（由 FocusService 检测后调用）
  void showFocusBanner(String text) {
    focusBanner.value = text;
    Timer(const Duration(seconds: 5), () {
      if (focusBanner.value == text) focusBanner.value = '';
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _hbTimer?.cancel();
    restRemainingMs.dispose();
    focusBanner.dispose();
    super.dispose();
  }
}

/// 内置起始重量查询。
double presetStartOf(String name) {
  for (final list in kBaojiExercisesByWeekday.values) {
    for (final pe in list) {
      if (pe.name == name) return pe.startWeightKg;
    }
  }
  return 20;
}

/// 重量显示（与 UI 层 fmtKg 同规则；controller 不 import UI，这里留私有副本）。
String _fmtKg(double v) => v == v.roundToDouble()
    ? v.toStringAsFixed(0)
    : v
          .toStringAsFixed(2)
          .replaceAll(RegExp(r'0+$'), '')
          .replaceAll(RegExp(r'\.$'), '');

/// 训练卡通知内容（原生前台服务展示，调研条目 1/3）。
/// [remaining]/[total] 休息剩余秒与总秒（进度条，-1 = 无进度）；
/// [chronoStartMs] 动作态 chronometer 起点（系统自己走秒，无需推送）。
class TrainingCard {
  const TrainingCard({
    required this.active,
    required this.resting,
    required this.paused,
    required this.title,
    required this.text,
    required this.remaining,
    required this.total,
    required this.chronoStartMs,
    this.restEndAtMs = 0,
  });

  const TrainingCard.inactive()
    : active = false,
      resting = false,
      paused = false,
      title = '',
      text = '',
      remaining = -1,
      total = 0,
      chronoStartMs = 0,
      restEndAtMs = 0;

  final bool active; // 会话进行中（false = 停前台服务）
  final bool resting; // 休息态：带暂停/±10 秒按钮与进度条
  final bool paused;
  final String title;
  final String text;
  final int remaining;
  final int total;
  final int chronoStartMs;

  /// 休息到点时刻（epoch ms；0=无）。原生侧用它渲染系统 chronometer
  /// 倒数（锁屏上自己走秒），暂停态传 0（冻结值无到点可数）。
  final int restEndAtMs;

  Map<String, Object?> toMap() => {
    'phase': resting ? 1 : 0,
    'title': title,
    'text': text,
    'paused': paused,
    'remaining': remaining,
    'total': total,
    'chronoBase': chronoStartMs,
    'restEndAt': restEndAtMs,
  };
}
