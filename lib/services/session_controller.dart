import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../db/db.dart';
import '../engine/engine.dart';
import '../engine/superset.dart';
import '../engine/weight_unit.dart';
import '../l10n/lang.dart';
import '../l10n/names.dart';
import '../presets/exercise_library.dart' show defaultLoadTypeFor;
import '../presets/start_weights.dart';
import 'focus_service.dart';
import 'rest_cue.dart';
import 'settings.dart';

enum WorkoutPhase { idle, lifting, resting }

/// 训练状态机（按 PRD 流程图）：
/// idle → lifting（热身/正式循环）→ resting → lifting → … → finished/quit
/// 休息用墙钟时间（restEndAt = epoch ms），锁屏/杀进程都不影响正确性；
/// 恢复逻辑：prefs 里存 sessionId + restEndAt，启动时若会话仍 active 则还原。
class SessionController extends ChangeNotifier {
  SessionController(this._db, this._settings, this._prefs, this._focus) {
    _loadDeloadSessionIds();
  }

  final Db _db;
  final Settings _settings;
  final SharedPreferences _prefs;
  final FocusService? _focus;

  /// 只读暴露设置（测试与 UI 读取休息/音效偏好用；修改走 Settings 实例）。
  Settings get settings => _settings;

  Session? session;
  List<SessionExercise> exercises = [];
  Map<int, List<SetEntry>> setsByEx = {};
  Map<String, List<SetEntry>> lastWorkout = {}; // 动作名 → 上次正式组（真实上一场）
  // 动作名 → 上次正式组（排除本机标记的减载场）：只给下次处方/平台期回溯用，
  // 不能拿来当「上次成绩」展示——用户刚做的减载组才是真正的上一场。
  final Map<String, List<SetEntry>> _progressionLastWorkout = {};
  final Map<String, int> _lastTargetSets = {}; // 动作名 → 上次训练的计划组数快照
  // 动作名 → 上次训练最后一组的记录形态 (logging, loadType)：
  // 渐进判定按上一场当时的形态解释，不跟随用户后来改的当前形态。
  final Map<String, (String, String)> _lastModes = {};
  Map<String, List<SetEntry>> historyBefore = {}; // 动作名 → 本次之前的全部历史
  // 动作稳定键 → 器械设置备注（P2-C）。开练/恢复时一次性预载，起始页与
  // 第一组前同步读取；详情弹层保存后立即更新，训练页无需再等异步查询。
  final Map<String, String> setupNotes = {};

  WorkoutPhase phase = WorkoutPhase.idle;
  int curExIdx = 0;
  int curSetIdx = 0; // 当前动作已完成组数（含热身）
  int restEndAt = 0;
  int restTotalMs = 0;
  double weightDraft = 0;
  // 切到自重前的草稿重量：切回来时优先恢复它，避免在减载周把上一场
  // 减载后的 54kg 再乘 0.9（双重减载），也避免丢掉平台期协议给的重量。
  double? _draftBeforeBodyweight;
  // 本次会话每个动作的「当时处方重量」快照（sessionExerciseId → kg）：
  // 第一组落库前定档，后续组沿用，避免平台期/减载在本场内改变目标值，
  // 出现同一场 target_weight_kg 54/62.5 打架。
  final Map<int, double> _sessionTargetWeight = {};
  int workingSetsDone = 0; // 当前动作正式组完成数
  final Set<String> prHit = {};

  // ---------- 训练块与减载（P1-C） ----------
  // 块起点 = 当前计划第一次 done 训练；块内第 N 周为减载周。
  // 只在新会话启动/恢复时计算，训练中不随日期翻周变化（处方稳定）。
  int? _blockWeek;
  int _blockWeeks = 0;
  bool _deloadWeek = false;

  /// 块内周次（1 起）；0 = 未启用/未知。
  int get trainingBlockWeek => _blockWeek ?? 0;

  /// 本周是否减载周（训练页/起始页横幅据此显示）。
  bool get inDeloadWeek => _deloadWeek;

  // ---------- 停练回归降档（P1-D） ----------
  // 距上次 done 训练 ≥14 天：本场按 85% 重量、组数 -1。与减载周
  // 同一天命中时只取更低的 0.85 系数，不叠加。开练时定档并随会话
  // 快照持久化，恢复/训练中不随日期变化。
  int _layoffDays = 0;
  bool _layoffActive = false;

  /// 本场是否处于停练回归（≥14 天没练）。
  bool get inLayoff => _layoffActive;

  /// 距上次 done 训练的天数（仅在本场停练回归生效时有意义，否则 0）。
  int get layoffDays => _layoffActive ? _layoffDays : 0;

  /// 本场会话启动时的块长（周）；0 = 关闭。训练中改设置不改变本场
  /// 横幅分母/处方，下周新会话才按新块长走。
  int get trainingBlockWeeks =>
      _blockWeeks > 0 ? _blockWeeks : _settings.trainingBlockWeeks;

  /// 减载周/停练回归会话标记（本地偏好记录）：这些会话的组不参与下次
  /// 处方/平台期回溯——主动降负荷（90%/85%）不能把线性加重的档位带低。
  ///
  /// 每条标记带 `id|date|startedAt` 指纹：备份恢复到另一台设备后，
  /// 同号会话可能是另一场真实训练；校验指纹对不上就丢弃，避免把
  /// 最多 300 场真实训练静默排除出渐进回溯。
  static const _kDeloadSessionsKey = 'block.deloadSessionIds';
  final Map<int, (String, int)> _deloadMarkers = {};
  final Set<int> _deloadSessionIds = {};

  /// 被标记为减载周 / 停练回归的会话 id（只读）。
  /// 这些场的组不参与下次处方/平台期回溯；周复盘等只读分析也要排除，
  /// 否则主动降负荷会被误判成停滞。
  Set<int> get deloadSessionIds => Set.unmodifiable(_deloadSessionIds);

  void _loadDeloadSessionIds() {
    final raw = _prefs.getString(_kDeloadSessionsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final v in list) {
        // 只认带指纹的新格式；老格式（纯 int）没有日期/开始时间，
        // 无法在备份恢复后校验同号会话，直接放弃（宁可少排除，
        // 不能误排除真实训练）。
        if (v is! String) continue;
        final p = v.split('|');
        if (p.length != 3) continue;
        final id = int.tryParse(p[0]);
        final startedAt = int.tryParse(p[2]);
        if (id == null || startedAt == null || p[1].isEmpty) continue;
        _deloadMarkers[id] = (p[1], startedAt);
      }
      _rebuildDeloadIds();
    } catch (_) {
      // 本地偏好损坏不影响训练：忽略即可，下一场减载会重新写入。
    }
  }

  /// 备份恢复后重读本机减载/停练标记：restoreAll 已把备份里的
  /// `block.deloadSessionIds` 写回 SharedPreferences，内存排除表要跟着
  /// 重灌（控制器是 App 级单例，构造时读过一次不会自己刷新）。恢复来的
  /// 指纹对不上库内会话的，由下一次 [_ensureDeloadMarkersValid] 剔除。
  void reloadDeloadMarkers() {
    _deloadMarkers.clear();
    _rebuildDeloadIds();
    _loadDeloadSessionIds();
  }

  void _rebuildDeloadIds() {
    _deloadSessionIds
      ..clear()
      ..addAll(_deloadMarkers.keys);
  }

  Future<void> _persistDeloadMarkers() async {
    try {
      await _prefs.setString(
        _kDeloadSessionsKey,
        jsonEncode([
          for (final e in _deloadMarkers.entries)
            '${e.key}|${e.value.$1}|${e.value.$2}',
        ]),
      );
    } catch (_) {
      // 本地偏好写失败不能挡住收工：内存里已排除，本次进程内仍然正确。
    }
  }

  /// 校验减载标记确实指向本机库里的同一场 done 训练（id+date+startedAt）。
  /// 备份恢复/换机后同号会话对不上就剔除，避免误排除。
  Future<void> _ensureDeloadMarkersValid() async {
    if (_deloadMarkers.isEmpty) return;
    var changed = false;
    for (final id in _deloadMarkers.keys.toList()) {
      final marker = _deloadMarkers[id]!;
      final s = await _db.sessionById(id);
      final ok =
          s != null &&
          s.status == 'done' &&
          s.date == marker.$1 &&
          s.startedAt == marker.$2;
      if (!ok) {
        _deloadMarkers.remove(id);
        changed = true;
      }
    }
    if (changed) {
      _rebuildDeloadIds();
      await _persistDeloadMarkers();
    }
  }

  Future<void> _markDeloadSession(Session s) async {
    final id = s.id;
    if (id == null) return;
    _deloadMarkers[id] = (s.date, s.startedAt);
    _rebuildDeloadIds();
    // 只保留最近 300 场减载；更早的减载会话早已不在历史窗口内。
    while (_deloadMarkers.length > 300) {
      _deloadMarkers.remove(_deloadMarkers.keys.first);
    }
    await _persistDeloadMarkers();
  }

  /// 本场会话的块周/减载快照（按会话 id 存本地偏好）。
  /// target_sets 是启动时快照，恢复时不能拿「当前设置」重算块周——
  /// 否则训练中改块长/杀进程后恢复，会把减载场翻成非减载（90% 组混进
  /// 下次处方回溯）或反之。会话结束即删除。
  String _sessionBlockKey(int id) => 'block.session.$id';

  Future<void> _persistSessionBlockState(Session s) async {
    final id = s.id;
    if (id == null) return;
    try {
      await _prefs.setString(
        _sessionBlockKey(id),
        jsonEncode({
          'date': s.date,
          'startedAt': s.startedAt,
          'week': _blockWeek ?? 0,
          'weeks': _blockWeeks,
          'deload': _deloadWeek,
          // P1-D：停练回归同样按本场快照，恢复后不随日期漂移。
          'layoff': _layoffActive,
          'layoffDays': _layoffDays,
        }),
      );
    } catch (_) {
      // 写失败时恢复会回落重算；不挡住开练。
    }
  }

  /// 读本场块周快照；必须与库里同 id 会话的 date/startedAt 一致。
  /// 备份恢复到另一台设备后同号会话可能是另一场训练，指纹对不上就不套用。
  bool _readSessionBlockState(
    int id, {
    required String date,
    required int startedAt,
  }) {
    final raw = _prefs.getString(_sessionBlockKey(id));
    if (raw == null || raw.isEmpty) return false;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return false;
      if (m['date'] != date || (m['startedAt'] as num?)?.toInt() != startedAt) {
        return false;
      }
      final week = (m['week'] as num?)?.toInt() ?? 0;
      final weeks = (m['weeks'] as num?)?.toInt() ?? 0;
      _blockWeek = week > 0 ? week : null;
      _blockWeeks = weeks;
      _deloadWeek = m['deload'] == true;
      final layoffDays = (m['layoffDays'] as num?)?.toInt() ?? 0;
      // 快照损坏（layoff=true 但天数 <14）时不硬套 85%，按正常处方走。
      _layoffActive = m['layoff'] == true && layoffDays >= kLayoffDaysThreshold;
      _layoffDays = _layoffActive ? layoffDays : 0;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _clearSessionBlockState(int id) async {
    try {
      await _prefs.remove(_sessionBlockKey(id));
    } catch (_) {
      // 清理失败只留下一个本地键，不影响数据。
    }
  }

  /// 读可信块起点：只认 `{"date":"yyyy-MM-dd","plan":…,"session":…}` 新格式
  ///（由「已存在 done 训练」时写入，并带来源会话指纹）。旧版纯日期/缺来源
  /// 会话指纹/脏值一律视为没有缓存——避免把「第一次开练后放弃」的日期当成
  /// 块起点，也无法确认锚点指向的会话还在。
  ///
  /// 返回 (锚点日期, 来源会话指纹 'id|date|startedAt')；指纹的**存在性校验**
  /// （该会话还在库里且 date/startedAt 相符）由调用方异步查库完成。
  (DateTime, String)? _readTrustedAnchor(String key, String planFingerprint) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      // 跨设备恢复备份后同号计划可能是另一个计划：指纹对不上一律不套用。
      if (m['plan'] != planFingerprint) return null;
      final d = m['date'];
      final sid = m['session'];
      if (d is! String || sid is! String || sid.isEmpty) return null;
      final parsed = DateTime.tryParse(d);
      return parsed == null ? null : (parsed, sid);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeTrustedAnchor(
    String key,
    DateTime date,
    String planFingerprint, {
    required ({int id, String date, int startedAt})? sourceSession,
  }) async {
    try {
      await _prefs.setString(
        key,
        jsonEncode({
          'date': fmtDate(date),
          'plan': planFingerprint,
          // 来源会话指纹（2026-10-18）：删除这场 done 会话后锚点失效重算，
          // 不再把已删会话的日期当成块起点。与减载标记同一指纹口径。
          'session': sourceSession == null
              ? ''
              : '${sourceSession.id}|${sourceSession.date}|${sourceSession.startedAt}',
        }),
      );
    } catch (_) {
      // 锚点写失败不影响本次计算；下次启动再试。
    }
  }

  /// 计算本次会话所在的块周（启动时调用；恢复走 [ _readSessionBlockState ]）。
  /// [planId] 为 null/0（临时训练）或块长 0 → 关闭减载。
  ///
  /// 块起点**只由当前计划第一次 done 训练确认**：没有 done 记录时按本次
  /// 日期算第 1 周，但不落盘——否则「开练后放弃」的日期会被当成块起点，
  /// 28 天后真正首练直接落进第 5 周减载。
  /// `block.anchor.<planId>` 只缓存已确认的 done 日期（带**来源会话指纹**
  /// id|date|startedAt），用于 plan_days 被删/重建后 `firstDoneSessionDateOfPlan`
  /// 看不到老会话时保住块周；两个失效条件任一命中就丢弃重算：
  /// - 计划指纹对不上（恢复备份的同号计划）；
  /// - 来源会话已不存在或 date/startedAt 变了（用户删掉了那场训练，
  ///   2026-10-18：唯一 done 会话被删后锚点不能继续把块周钉在旧日期上）。
  /// 一旦库里重新有 done 首场，以库为准（可前移/后移）。
  Future<void> _refreshBlockState({
    required int? planId,
    required DateTime date,
  }) async {
    _blockWeek = null;
    _deloadWeek = false;
    _blockWeeks = _settings.trainingBlockWeeks;
    final weeks = _blockWeeks;
    if (weeks <= 0 || planId == null || planId <= 0) return;
    final key = 'block.anchor.$planId';
    final plan = await _db.planById(planId);
    // 用创建日期做计划指纹（改名不失效；同号不同计划通常创建日不同）。
    final planFingerprint = plan?.createdAt ?? '';
    final first = await _db.firstDoneSessionOfPlan(planId);
    (DateTime, String)? trusted;
    if (first != null) {
      final parsed = DateTime.tryParse(first.date);
      if (parsed != null) {
        await _writeTrustedAnchor(
          key,
          parsed,
          planFingerprint,
          sourceSession: first,
        );
      }
    } else {
      // 模板日被删/重建后看不到 done 会话：用之前确认过的锚点（同名/
      // 同创建日的计划才认，防恢复备份的同号计划串用），并校验来源会话
      // 指纹——指向的 done 会话被删除后锚点失效，回退「今天 = 第 1 周」。
      final cached = _readTrustedAnchor(key, planFingerprint);
      if (cached != null) {
        final parts = cached.$2.split('|');
        final sid = parts.isEmpty ? null : int.tryParse(parts[0]);
        final s = sid == null ? null : await _db.sessionById(sid);
        final ok = s != null &&
            s.status == 'done' &&
            s.date == (parts.length > 1 ? parts[1] : '') &&
            s.startedAt ==
                (parts.length > 2 ? int.tryParse(parts[2]) ?? -1 : -1);
        if (ok) {
          trusted = cached;
        }
      }
    }
    var anchor = first != null ? DateTime.tryParse(first.date) : trusted?.$1;
    anchor ??= date; // 真正的第一场（还没有 done）：临时按今天算第 1 周，不落盘
    final week = trainingBlockWeekOf(
      blockStart: anchor,
      date: date,
      blockWeeks: weeks,
    );
    _blockWeek = week;
    _deloadWeek = week == weeks;
  }

  /// 计算本场是否停练回归（P1-D）：只看**全库最近一场 done 训练**的
  /// 日期，≥14 天触发。临时训练也计入——只要还在练就不算停练。
  /// 与块周一样只在开练时算一次，训练中/恢复都走会话快照。
  Future<void> _refreshLayoffState({required DateTime date}) async {
    _layoffDays = 0;
    _layoffActive = false;
    final lastDate = await _db.lastDoneSessionDate();
    final days = layoffDaysSince(lastDate, date);
    if (days < kLayoffDaysThreshold) return;
    _layoffDays = days;
    _layoffActive = true;
  }

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
  bool _disposed = false; // dispose 后阻止延迟回调再碰状态（预载 .then 等）
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
    // 单位感知（2026-10-17）：常驻通知卡与界面同一换算口径（kg 存储）
    final wText = w < 0
        ? tx('辅 ${fmtWithUnit(-w)}', en: 'assist ${fmtWithUnit(-w)}')
        : (w == 0 ? tx('自重', en: 'bodyweight') : fmtWithUnit(w));
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
    final planned = currentEx == null ? 1 : plannedSetsOf(currentEx!);
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
    setupNotes.clear();
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

  /// 该动作的器械设置备注（空串 = 没有，UI 据此不占空间）。
  /// 键口径与历史查询一致：会话行自带的稳定键优先，空键按动作名现算。
  String setupNoteOf(SessionExercise ex) {
    final key = exerciseIdentityKeyOf(ex.name, ex.exerciseKey);
    return key.isEmpty ? '' : (setupNotes[key] ?? '');
  }

  /// 保存器械设置（P2-C）：空串删除；写库后同步内存并通知训练页刷新。
  /// 详情弹层是唯一编辑入口，打开它属于用户主动点按，不打断计时。
  Future<void> saveSetupNote(String exerciseKey, String setupNote) async {
    final key = exerciseKey.trim();
    if (key.isEmpty) return;
    final text = setupNote.trim();
    await _db.saveExerciseNote(key, text);
    if (text.isEmpty) {
      setupNotes.remove(key);
    } else {
      setupNotes[key] = text;
    }
    notifyListeners();
  }

  /// 起始页要一次看到全部动作的设置备注，逐行异步查询会在开练前闪空。
  Future<void> _loadSetupNotes() async {
    final keys = <String>{
      for (final ex in exercises) exerciseIdentityKeyOf(ex.name, ex.exerciseKey),
    }..remove('');
    setupNotes
      ..clear()
      ..addAll(await _db.exerciseNotesByKeys(keys));
  }

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
      _blockWeek = null;
      _blockWeeks = 0;
      _deloadWeek = false;
      _layoffActive = false;
      _layoffDays = 0;
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
    await _loadSetupNotes();
    setsByEx = await _db.setsOfSession(sessionId);
    // 恢复会话：目标重量快照沿用已落库的第一组，后续组不因本场成绩漂移。
    _sessionTargetWeight.clear();
    for (final ex in exercises) {
      final list = setsByEx[ex.id] ?? const <SetEntry>[];
      for (final s in list) {
        if (s.targetWeightKg != null) {
          _sessionTargetWeight[ex.id!] = s.targetWeightKg!;
          break;
        }
      }
    }
    await _ensureDeloadMarkersValid();
    // 训练块/减载（P1-C）：优先读本场启动时落下的块周快照；没有快照
    // （老版本开练/本地偏好丢失）才按会话日期重算。不能直接重算——
    // 训练中改块长后恢复，会把减载场翻成非减载（90% 组混进回溯）。
    if (!_readSessionBlockState(
      sessionId,
      date: session!.date,
      startedAt: session!.startedAt,
    )) {
      final planDayId = session!.planDayId;
      final planDay = planDayId == null
          ? null
          : await _db.planDayById(planDayId);
      await _refreshBlockState(
        planId: planDay?.planId,
        date: DateTime.tryParse(session!.date) ?? DateTime.now(),
      );
      // 老会话/偏好丢失：把重算结果补落快照，下次恢复不再随设置漂移。
      await _persistSessionBlockState(session!);
    }
    // 恢复落点（v9 超级组）：按计划轮转序列走位到第一个未消费的槽位
    // ——不配对时序列退化为线性，与旧「第一个正式组未做完」完全一致；
    // 全部做完回落最后一个动作（加练口径）。
    curExIdx = resumeExerciseIdx(
      tags: _supersetTags,
      plannedSets: exercises.map(plannedSetsOf).toList(),
      doneWorking: _doneWorkingOfAll(),
    );
    curSetIdx = (setsByEx[currentEx!.id] ?? []).length;
    workingSetsDone = currentSets
        .where((e) => e.kind == SetKind.working)
        .length;
    await _loadContextForCurrent();
    // 恢复落点重量：本场已落库的处方（组行 target_weight_kg，上面已回灌
    // 进 _sessionTargetWeight）优先。减载/平台期减载场的 54kg 组会把
    // 60kg 的平台期回溯打断（plateauFor 把本场组接在历史后面算连续
    // 同重量），此时重算 _recommendFor 会把建议从 54kg 弹回 60kg——
    // 处方在第一组前已定档，恢复必须沿用；只有一组未做（无本场处方）
    // 才用 _recommendFor 兜底重算（减载周快照仍会给出 90% 重量）。
    final cur = currentEx!;
    weightDraft = _sessionTargetWeight[cur.id!] ?? _recommendFor(cur.name);
    _setPhase(WorkoutPhase.lifting, silent: true);
    return true;
  }

  /// 本动作的下一步处方：重量 + 一句「为什么是这个数字」。
  /// 两者共用同一份计算，避免出现「weightDraft=54kg、目标解释却写
  /// 下次目标 +1 次」或「上一场少做、解释却写减载 10%」的分裂。
  ///
  /// [ex] 缺省取当前动作（`targetWhyOf` 传入被查询的动作行）。
  ({double weight, String why}) _prescriptionFor(
    String name, {
    SessionExercise? ex,
    bool includeCurrentSets = true,
  }) {
    final target = ex ?? currentEx;
    final rule = target?.rule ?? ProgressionRule.fallback;
    final logging = target?.logging ?? LoggingMode.reps;
    // 有效负荷类型（P2-E 复核）：老计划把自重动作存成默认 weighted 时，
    // 按上一场 + 本场已记录的正式组推断，避免 verdict/目标解释继续走
    // 负重链、和训练页的「试试下一档/加练一组」互相矛盾。
    final loadType = target == null
        ? LoadMode.weighted
        : _effectiveLoadTypeOf(target, includeCurrentSets: includeCurrentSets);
    final planned = target == null ? 0 : plannedSetsOf(target);
    // 减载场排除：用 _progressionLastWorkout（真实「上次成绩」仍走
    // lastWorkout，不受影响）。加练组不参与下次处方（P0-B）。
    List<SetEntry> progressionSets() =>
        (_progressionLastWorkout[name] ?? const <SetEntry>[])
            .where((s) => !s.isExtra)
            .toList(growable: false);

    // 停练回归 / 减载周共用「按系数下调」入口：两者不叠加，
    // 同时命中时取更低的一档（0.85 < 0.9），组数也只减 1 次。
    final recoveryFactor = recoveryWeightFactor(
      layoff: _layoffActive,
      deload: _deloadWeek,
    );
    if (recoveryFactor != null) {
      // 基准取链状态的重量（上次最后正式组的实际重量），不是链推荐的
      // 「下一次」重量：上次刚顶格时链会建议 +2.5kg，按 62.5×0.9 只比
      // 60 低 6%，不算减载；按 60×0.9 = 54 才是「比平常轻一成」。
      // 停练回归同理：先回到停练前的重量档，避免「上次刚加重 → 停练
      // 回来还按更高档打折」。
      final last = progressionSets();
      final base = last.isEmpty
          ? _presetStartFor(name)
          : chainStateFromHistory(last, rule).weightKg;
      final String why;
      if (_layoffActive) {
        final dual = _deloadWeek
            ? tx(
                '（本周同时是减载周，取更低的 85% 一档，不重复打折）',
                en: ' (deload week too — the lower 85% factor applies once, no double discount)',
              )
            : '';
        if (loadType == LoadMode.bodyweight || base == 0) {
          why = tx(
            '停练 $_layoffDays 天，今天按 85% 找感觉：自重动作只少做 1 组，下次间隔正常后回到原计划。$dual',
            en: 'Back after $_layoffDays days off — today at 85% to find your groove: bodyweight lifts drop one set only; back to the plan once you train again within 14 days.$dual',
          );
        } else if (base < 0) {
          why = tx(
            '停练 $_layoffDays 天，今天按 85% 找感觉：辅助配重增加约 15%、少做 1 组，下次间隔正常后回到原档。$dual',
            en: 'Back after $_layoffDays days off — today at 85% to find your groove: ~15% more machine assist and one fewer set; back to normal once you train again within 14 days.$dual',
          );
        } else {
          why = tx(
            '停练 $_layoffDays 天，今天按 85% 找感觉：负重按约 85% 重量、少做 1 组，下次间隔正常后回到原档。$dual',
            en: 'Back after $_layoffDays days off — today at 85% to find your groove: ~85% weight and one fewer set; back to normal once you train again within 14 days.$dual',
          );
        }
      } else if (loadType == LoadMode.bodyweight || base == 0) {
        why = tx(
          '减载周：本周少做 1 组，给身体恢复；下周回到原计划。',
          en: 'Deload week: one fewer set this week to recover; back to the plan next week.',
        );
      } else if (base < 0) {
        // 辅助配重：更负 = 辅助更多 = 更省力，文案不能说「90% 重量」。
        why = tx(
          '减载周：本周辅助配重增加约 10%、少做 1 组，给身体恢复；下周回到原档继续。',
          en: 'Deload week: ~10% more machine assist and one fewer set this week to recover; back to normal next week.',
        );
      } else {
        why = tx(
          '减载周：本周建议约 90% 重量、少做 1 组，给身体恢复；下周回到原档继续。',
          en: 'Deload week: ~90% weight and one fewer set this week to recover; back to normal next week.',
        );
      }
      // 自重动作不因降档凭空出现重量：只减组，重量保持 0。
      final recoveryWeight = loadType == LoadMode.bodyweight
          ? 0.0
          : reducedWeightKg(base, recoveryFactor);
      return (weight: recoveryWeight, why: why);
    }

    final last = progressionSets();
    if (last.isEmpty) {
      final state = chainStateFromHistory(const <SetEntry>[], rule);
      return (
        // 自重动作首次训练同样不该猜 20kg：重量恒 0，渐进走次数轴。
        weight: loadType == LoadMode.bodyweight ? 0.0 : _presetStartFor(name),
        why: chainTargetWhy(
          rule: rule,
          state: state,
          loadType: loadType,
          logging: logging,
          plannedSets: planned,
        ),
      );
    }

    final state = chainStateFromHistory(last, rule);
    // 上次的计划组数一起判定（P0-B 复核）：少做不能只让总结页 hold、
    // 下次开练却继续按达标推进重量。老记录没有 target_sets 快照时
    // DB 层回退该场次 rule 的 workingSets，不拿当前规则去猜上一场。
    final lastTarget = _lastTargetSets[name] ?? 0;
    // 按上一场当时的记录形态判定（用户可能后来改成计时/自重，
    // 不能拿新形态去解释旧组的次数/链语义）。
    final modes = _lastModes[name];
    final v = evaluateChain(
      rule: rule,
      state: state,
      workingSets: last,
      targetSets: lastTarget,
      logging: modes?.$1 ?? logging,
      loadType: loadType,
    );
    // 平台期协议（P1-C）：未顶格且没有「成功加重」时，协议建议的减载
    // 重量优先于链的 hold/继续冲。少做/没记录/换档位的 hold 不触发
    // （P0-B 的保护优先）。
    // 「为什么是这个数字」用纯历史算处方解释：否则用户照着减载 54kg
    // 做完几组后，本场 54kg 会打断 60kg 平台期，解释突然变成「下次目标
    // +1 次」。本场顶格/加重的刷新由 targetWhyOf 单独判断。
    final protocol = plateauProtocolOf(
      includeCurrentSets
          ? plateauFor(name)
          : plateauOf(
              historyBefore[name] ?? const <SetEntry>[],
              repsMax: rule.repsMax,
            ),
      rule: rule,
      logging: logging,
      loadType: loadType,
    );
    final chainAddedWeight =
        v.action == 'advance' && v.next.weightKg != state.weightKg;
    final canApplyReduce =
        protocol.action == 'reduce' &&
        protocol.suggestedWeightKg != 0 &&
        !chainAddedWeight &&
        (v.action == 'decrease' ||
            v.action == 'advance' ||
            v.holdKind == 'target_miss');
    if (canApplyReduce) {
      return (
        weight: round05(protocol.suggestedWeightKg),
        why: protocol.reason,
      );
    }
    // 负重量（辅助配重）同样渐进：-30 → -27.5 = 辅助减少 2.5kg，是进步。
    // 不再做 next>0 检查——那会让辅助器械动作永远卡在原配重。
    return (
      weight: round05(v.next.weightKg),
      why: chainTargetWhy(
        rule: rule,
        state: state,
        loadType: loadType,
        logging: logging,
        plannedSets: planned,
      ),
    );
  }

  double _recommendFor(String name) => _prescriptionFor(name).weight;

  /// 有效负荷类型（P2-E 复核 / H3 统一）：判定全部收口到引擎的共用函数
  /// [effectiveLoadTypeFor]（显式负重变体名 > 显式存储 bodyweight > 0kg+
  /// 自重阶梯/动作库纯自重推断），本方法只负责拼「上一场 + 本场已记录」的
  /// 正式组集合——verdict/目标解释/处方三处调用同一入口，与训练页的
  /// 「试试下一档/加练一组」结论一致，不再各判各的。
  String _effectiveLoadTypeOf(
    SessionExercise ex, {
    bool includeCurrentSets = true,
  }) {
    final sets = <SetEntry>[
      ...(_progressionLastWorkout[ex.name] ?? const <SetEntry>[]),
      if (includeCurrentSets) ...(setsByEx[ex.id] ?? const <SetEntry>[]),
    ];
    return effectiveLoadTypeFor(
      exerciseName: ex.name,
      loadType: ex.loadType,
      workingSets: sets,
      exerciseKey: ex.exerciseKey,
    );
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

  // ---------- 目标可解释化（v14「为什么是这个数字」） ----------

  /// 动作 [exerciseIndex] 本组目标的一句话解释（「为什么是这个数字」）。
  /// 即时计算，不预载：非当前动作的 historyBefore 还没加载、预载会算错；
  /// 本场顶格/加重后也要刷新，不能冻结在开练时。
  /// 下标越界/非当前动作返回空串（UI 只查当前动作；空串不占三要素）。
  String targetWhyOf(int exerciseIndex) {
    if (exerciseIndex < 0 || exerciseIndex >= exercises.length) return '';
    if (exerciseIndex != curExIdx) return '';
    final ex = exercises[exerciseIndex];
    final base = _prescriptionFor(ex.name, ex: ex, includeCurrentSets: false);
    // 减载周/停练回归的处方就是恢复：不在本场把「顶了降档重量」
    // 改写成加重建议。
    if (_deloadWeek || _layoffActive) return base.why;
    // 本场已记录的组如果已经「成功加重/自重顶格」，用本场状态重算
    // 下一步解释；否则保留处方解释（比如减载 54kg 仍说减载 10%）。
    final current = (setsByEx[ex.id] ?? const <SetEntry>[])
        .where((s) => s.kind == SetKind.working && !s.isExtra)
        .toList(growable: false);
    if (current.isEmpty) return base.why;
    // 有效负荷类型：与本场 verdict/变式建议同一口径（旧 weighted 的
    // 0kg 自重动作按 bodyweight 解释，见 _effectiveLoadTypeOf）。
    final effective = _effectiveLoadTypeOf(ex);
    final currentState = chainStateFromHistory(current, ex.rule);
    final v = evaluateChain(
      rule: ex.rule,
      state: currentState,
      workingSets: current,
      targetSets: plannedSetsOf(ex),
      logging: ex.logging,
      loadType: effective,
    );
    final advancedWeight =
        v.action == 'advance' && v.next.weightKg != currentState.weightKg;
    final bodyweightTop =
        v.holdKind == 'chain_end' && effective == LoadMode.bodyweight;
    if (advancedWeight || bodyweightTop) {
      return chainTargetWhy(
        rule: ex.rule,
        state: currentState,
        loadType: effective,
        logging: ex.logging,
        plannedSets: plannedSetsOf(ex),
      );
    }
    return base.why;
  }

  /// 平台期提醒缓存（2026-09-26 Arono：同重量停留过久 → 训练中途
  /// 主动提示可加重）。数据源 = 本场前的 historyBefore + **本场已记录
  /// 的正式组**；按「历史条数/本场条数/末组时间重量次数」签名缓存，
  /// 每记一组自然失效，顶格/换重量后不会继续报旧停滞。
  final _plateauCache = <String, PlateauInfo?>{};

  PlateauInfo? plateauFor(String name) {
    SessionExercise? found;
    for (final ex in exercises) {
      if (ex.name == name) {
        found = ex;
        break;
      }
    }
    final repsMax = found?.rule.repsMax ?? ProgressionRule.fallback.repsMax;
    // 平台期必须把本场已记录的正式组接在历史后面一起算：训练中把次数
    // 做到上限/换了新重量后，旧的 historyBefore 会继续报「停滞」，
    // 休息页/总结页就会误劝减载。签名缓存只在组变化时重算。
    final current = found == null
        ? const <SetEntry>[]
        : (setsByEx[found.id] ?? const <SetEntry>[])
              .where((s) => s.kind == SetKind.working)
              .toList(growable: false);
    final history = historyBefore[name] ?? const <SetEntry>[];
    final last = current.isEmpty ? null : current.last;
    final sig =
        '$name|${history.length}|${current.length}|'
        '${last?.doneAt ?? 0}|${last?.weightKg ?? 0}|${last?.reps ?? 0}';
    if (_plateauCache.containsKey(sig)) return _plateauCache[sig];
    final info = plateauOf([...history, ...current], repsMax: repsMax);
    _plateauCache[sig] = info;
    return info;
  }

  Future<void> _loadContextForCurrent() async {
    final ex = currentEx;
    if (ex == null) return;
    // 换动作/开练后，上一个动作的「自重前草稿」不再适用。
    _draftBeforeBodyweight = null;
    final name = ex.name;
    // 纵向历史按会话动作行自带的稳定键查（别名/改名共享同一份历史）；
    // 空键（老记录/未分配）由 DB 按名字现算，行为与升级前一致。
    // 「上次成绩」用真实上一场（含减载/停练回归场）；下次处方用排除
    // 减载/停练回归的上一场。
    lastWorkout[name] = await _db.lastWorkingSets(
      name,
      exerciseKey: ex.exerciseKey,
    );
    _progressionLastWorkout[name] = await _db.lastWorkingSets(
      name,
      exerciseKey: ex.exerciseKey,
      excludeSessionIds: _deloadSessionIds,
    );
    _lastTargetSets[name] = await _db.lastTargetSets(
      name,
      exerciseKey: ex.exerciseKey,
      excludeSessionIds: _deloadSessionIds,
    );
    final modes = await _db.lastExerciseModes(
      name,
      exerciseKey: ex.exerciseKey,
      excludeSessionIds: _deloadSessionIds,
    );
    if (modes != null) _lastModes[name] = modes;
    final seId = ex.id;
    // PR 判定只看正式组历史（热身大重量不应抬高 PR 门槛）；
    // 减载/停练回归会话的组不参与平台期/PR 回溯（主动降负荷不是停滞）。
    historyBefore[name] = await _db.historySets(
      name,
      exerciseKey: ex.exerciseKey,
      beforeSessionExerciseId: seId,
      kindFilter: SetKind.working,
      excludeSessionIds: _deloadSessionIds,
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
    // 减载标记先按库校验（备份恢复后同号会话可能不是同一场）。
    await _ensureDeloadMarkersValid();
    // 停练回归（P1-D）：开练时定档，写进 target_sets / 处方。
    // 同一次开练只取一个「今天」，避免跨午夜时天数与会话日期不一致。
    final startedDate = DateTime.now();
    await _refreshLayoffState(date: startedDate);
    // 块周/减载在会话启动时定档：本周是减载周就按 90% 重量、组数 -1
    // 开处方（写进 target_sets 快照，页面流/进度/判定同一口径）。
    await _refreshBlockState(planId: day.planId, date: startedDate);
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
          // P1-C：减载周少做一组（最少 1 组），快照进本场，页面流与
          // 完成度判定都按减载后的组数走。sets=0 的老行按规则组数
          // 兜底后再减，不凭空造 1 组。
          // P1-D：停练回归同样少做一组；与减载同一天命中时只减一次。
          targetSets: (_deloadWeek || _layoffActive)
              ? layoffWorkingSets(pe.sets > 0 ? pe.sets : pe.rule.workingSets)
              : pe.sets,
          targetRepsMin: pe.repsMin,
          targetRepsMax: pe.repsMax,
          // 超级组标记同样快照（v9）：训练中的轮转推进按它分组，
          // 模板日后取消配对不影响进行中/历史会话。
          supersetTag: pe.supersetTag,
          // 记录形态快照（v14）：计时/单侧/自重口径随会话固化，
          // 模板日后改形态不影响进行中会话与历史回放。
          logging: pe.logging,
          loadType: pe.loadType,
          // 动作稳定键快照（v16）：计划行有键就沿用（改名不断历史），
          // 空键（临时/导入计划）由落库层按动作名现算。
          exerciseKey: pe.exerciseKey,
        ),
    ];
    final (s, withIds) = await _db.insertSessionWithExercises(
      Session(
        date: fmtDate(startedDate),
        planDayId: day.id,
        planDayTitle: day.title,
        startedAt: now,
        status: 'active',
      ),
      drafts,
    );
    session = s;
    exercises = withIds;
    await _loadSetupNotes();
    // 本场块周/减载快照：恢复/改块长都不改写本场处方（target_sets 已快照）。
    await _persistSessionBlockState(s);
    setsByEx = {};
    _sessionTargetWeight.clear();
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
  /// [durationSec]（v14 计时动作）：实际保持秒数——落 duration_sec 列，
  /// 且约定 reps 字段同样承载秒数（链判定原样复用次数语义）。
  /// 单侧动作（logging='reps_per_side'）的 reps 是两侧总数，落库前
  /// 就近取偶，保证总数可两侧均分。
  /// [rirRecorded]（P0-C）：用户是否真的点选过余力。false 时 [rir] 只是
  /// 计划默认填充值，落 rir_recorded=0——统计与渐进判定都不会把它当观测。
  /// [painLevel] / [painArea]（P2-B）：本组疼痛自评，0/'' = 未填。
  /// 等级就地夹到 0-3；等级 0 时部位一并清空，避免「无痛却带部位」的脏数据。
  /// 疼痛只做记录与提示，不参与渐进/PR/容量任何判定（安全底线不改变训练逻辑）。
  Future<bool> completeSet({
    required double weight,
    required int reps,
    required int rir,
    required String kind,
    String note = '',
    int? durationSec,
    bool rirRecorded = true,
    int painLevel = 0,
    String painArea = '',
  }) async {
    final ex = currentEx;
    if (ex == null) return false;
    final level = painLevel.clamp(0, 3).toInt();
    final area = level == 0 ? '' : painArea;
    reps = normalizeTarget(reps, ex.logging);
    // 加练标注（v12，2026-10-08）：落库前先判定——只对正式组标注
    // （kind==working 才参与判据：加练态下 kind chips 仍可选，计划满后
    // 再记热身/力竭组不该被误标「加练」）；必须在 workingSetsDone++ 与
    // insertSet 之前算，口径与 WorkoutFlow 只数正式组一致。仅展示标注，
    // 不改渐进/PR/容量统计。
    final planned = plannedSetsOf(ex);
    final doneBefore = (setsByEx[ex.id] ?? const <SetEntry>[])
        .where((s) => s.kind == SetKind.working)
        .length;
    final isExtra = kind == SetKind.working && doneBefore >= planned;
    // 「当时处方」快照（wger 的 *_target 列，v8）：完成时把引擎给的
    // 推荐重量与链目标次数一并写进组行——用户手调过的重量与它对比，
    // 历史页就能回看「计划 vs 实际」。lastWorkout/historyBefore 在
    // 同一动作的组间不变（done 过滤），快照值组间稳定。
    // 目标次数快照用渐进上一场（排除减载），与「当时处方」同源；
    // 真实上一场只负责 UI 的「上次成绩」行。
    final chainTarget = chainStateFromHistory(
      _progressionLastWorkout[ex.name] ?? const [],
      ex.rule,
    );
    // 本场第一组前定档，后续组沿用（平台期/减载在本场内不改变目标值）。
    final targetWeight = _sessionTargetWeight.putIfAbsent(
      ex.id!,
      () => _recommendFor(ex.name),
    );
    final entry = SetEntry(
      sessionExerciseId: ex.id!,
      weightKg: weight,
      reps: reps,
      rir: rir,
      kind: kind,
      doneAt: DateTime.now().millisecondsSinceEpoch,
      note: note,
      targetWeightKg: targetWeight,
      targetReps: chainTarget.targetReps,
      isExtra: isExtra,
      durationSec: durationSec,
      rirRecorded: rirRecorded,
      painLevel: level,
      painArea: area,
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
      plannedSets: exercises.map(plannedSetsOf).toList(),
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
    if (done >= plannedSetsOf(target)) return false; // 已练满：不可跳入
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
      if (_disposed || !hasActive) return;
      final next = currentEx;
      if (next == null || next.id != justFinished.id) {
        final list = setsByEx[next?.id] ?? const <SetEntry>[];
        weightDraft = list.isNotEmpty
            ? list.last.weightKg
            : _recommendFor(next?.name ?? '');
        notifyListeners();
      }
    }).catchError((Object e) {
      // 预载是尽力而为的缓存，失败静默：会话刚收工或库正被备份恢复
      // 重写时，后台查询可能扑空（库已关/表刚清）。不捕获的话未处理
      // 异常会逃出异步链——真机上是隐患，测试里则被记到已结束的用例
      // 头上造成偶发失败。
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
    // 屏内提示只在前台做：人在后台时系统精确提醒（休息提醒通道）已带
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

  /// 休息中「刚完成的动作再来一组」：回退到该动作，休息倒计时继续走
  /// （2026-10-17：加练也带休息计时——剩余时间即备场时间，到点震动/
  /// 提示音提醒开练；±30s/暂停/跳过照常，「跳过休息」= 立即进入这一组）。
  /// 再完成的组按正式组记录（同样参与渐进判定与 PR）。
  /// 重量继承该动作最后一组的实际重量（手调过的配重不从头再来），
  /// 没有历史组才回落到推荐值。
  Future<void> startExtraSet() async {
    final name = extraSetExerciseName;
    if (name == null || !hasActive) return;
    final idx = exercises.indexWhere((e) => e.name == name);
    if (idx < 0) return;
    curExIdx = idx;
    final list = setsByEx[exercises[idx].id] ?? const <SetEntry>[];
    workingSetsDone = list.where((e) => e.kind == SetKind.working).length;
    curSetIdx = list.length;
    await _loadContextForCurrent();
    weightDraft = list.isNotEmpty ? list.last.weightKg : _recommendFor(name);
    // 不结束休息：落点改为该动作的加练组，倒计时自然走完再进动作态。
    // 入口即消费（清空后按钮消失，休息页由「下一组 · 加练」文案报状态）。
    extraSetExerciseName = null;
    notifyCard();
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
      _draftBeforeBodyweight = weightDraft;
      setWeightDraft(0);
      return;
    }
    final saved = _draftBeforeBodyweight;
    if (saved != null && saved != 0) {
      setWeightDraft(saved);
      return;
    }
    // 没有可恢复的草稿（例如一开始就是自重）：按当前处方回填，
    // 减载周/平台期协议都给同一个数字，不会对减载场再次打折。
    setWeightDraft(_prescriptionFor(currentEx?.name ?? '').weight);
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
        // 临时追加也按动作库口径给自重动作落 bodyweight（P2-E 复核）。
        loadType: defaultLoadTypeFor(m.name),
        rule: ProgressionRule.fallback,
        // 减载周/停练回归临时加的动作同样少做 1 组；其余情况保持 0
        //（无快照，回退规则 workingSets），与旧行为一致。
        targetSets: (_deloadWeek || _layoffActive)
            ? layoffWorkingSets(ProgressionRule.fallback.workingSets)
            : 0,
        trace: prevName.isEmpty
            ? tx('追加于：会话开头', en: 'Added at start of session')
            : tx('追加于：$prevName', en: 'Added after $prevName'),
        // 新动作先查同名已有键（计划/历史里可能保留着改名前的旧键），
        // 查不到再按名字现算：避免同名动作被拆成第二个身份。
        exerciseKey:
            await _db.knownExerciseKey(m.name) ?? exerciseKeyOf(m.name),
      );
      final id = await _db.insertSessionExercise(draft);
      exercises.add(draft.copyWithId(id));
      prevName = m.name;
    }
    // 临时追加的动作也要在练到它时显示已存器械设置：按新键补载备注。
    await _loadSetupNotes();
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
      // 换成的新动作按动作库口径决定负荷类型（P2-E 复核）：替换成
      // 俯卧撑/引体向上等自重动作时不再沿用旧动作的 weighted。
      loadType: defaultLoadTypeFor(meta.name),
      // 条目 14：快照列原样保留——整行覆写若丢这三列会把已快照的
      // 模板目标抹成 0，老记录完成度对比就失真了。
      targetSets: ex.targetSets,
      targetRepsMin: ex.targetRepsMin,
      targetRepsMax: ex.targetRepsMax,
      trace: tx('替换自：${ex.name}', en: 'Replaced from ${ex.name}'),
      // 动作稳定键（v16）：换成了另一个动作，旧键不能沿用；先查新动作
      // 同名已有键（改名过的动作），查不到再按名字现算。
      exerciseKey:
          await _db.knownExerciseKey(meta.name) ?? exerciseKeyOf(meta.name),
    );
    await _db.updateSessionExercise(updated);
    exercises[curExIdx] = updated;
    await _loadContextForCurrent();
    // 替换成的新动作可能已有器械设置备注：重载一次，第一组前立即显示。
    await _loadSetupNotes();
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
    // 记下这场是减载/停练回归会话：下次处方/平台期回溯跳过它，
    // 避免把主动降负荷（90%/85%）的档位带低，停练回归后下一场
    // 间隔正常时能回到停练前的档位。
    if (_deloadWeek || _layoffActive) await _markDeloadSession(session!);
    await _clearSessionBlockState(session!.id!);
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
    await _clearSessionBlockState(session!.id!);
    await _exitFocus();
    WakelockPlus.disable();
    session = null;
    prHit.clear();
    truncatedEndAtMs = null;
    _blockWeek = null;
    _blockWeeks = 0;
    _deloadWeek = false;
    _layoffActive = false;
    _layoffDays = 0;
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
    // 自评是收工后才写的：通知 App 容器再补一份快照，别让最新备份缺这条。
    onSessionRated?.call();
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
      final tSets = plannedSetsOf(ex);
      final tMin = ex.targetRepsMin > 0 ? ex.targetRepsMin : ex.rule.repsMin;
      final tMax = ex.targetRepsMax > 0 ? ex.targetRepsMax : ex.rule.repsMax;
      final unit = ex.logging == LoggingMode.time ? '秒' : '次';
      // 有效负荷类型（P2-E 复核）：与目标解释/变式建议同一口径。
      // 老计划把自重动作存成默认 weighted 时，0kg 历史也按 bodyweight
      // 判定，避免总结页出现「下次加重至 2.5kg」的相反建议。
      final effective = _effectiveLoadTypeOf(ex);
      // 停练回归场次不计入渐进判定（会话 id 已记入本地排除表）：
      // 85% 只是回来找感觉，不能把下一场的档位带低。总结页直接说明，
      // 并和减载周同框时说清「取更低的 85% 一档、不重复打折」。
      if (_layoffActive) {
        final bodyweight = effective == LoadMode.bodyweight;
        final lastWorking =
            _progressionLastWorkout[ex.name] ?? const <SetEntry>[];
        final assisted =
            !bodyweight &&
            lastWorking.isNotEmpty &&
            lastWorking.last.weightKg < 0;
        final zhDetail = bodyweight
            ? '本次少做 1 组'
            : assisted
            ? '本次辅助配重增加约 15%、少做 1 组'
            : '本次按约 85% 重量、少做 1 组';
        final enDetail = bodyweight
            ? 'one fewer set'
            : assisted
            ? '~15% more machine assist and one fewer set'
            : '~85% weight and one fewer set';
        final dual = _deloadWeek ? '；本周同时是减载周，取更低的 85% 一档，不重复打折' : '';
        final enDual = _deloadWeek
            ? '; this is also a deload week — the lower 85% factor applies once, no double discount'
            : '';
        out.add(
          tx(
            '${ex.name}（计划目标 $tSets×$tMin-$tMax $unit）：停练 $_layoffDays 天回归——$zhDetail，'
            '不计入渐进判定；下次间隔正常后回到原档$dual。',
            en:
                '${exname(ex.name)} (target $tSets×$tMin-$tMax ${ex.logging == LoggingMode.time ? 's' : 'reps'}): back after $_layoffDays days off — '
                '$enDetail; this session does not affect progression, back to your usual tier once you train again within 14 days$enDual.',
          ),
        );
        continue;
      }
      // 减载周的组不计入渐进判定（会话 id 已记入本地排除表），
      // 总结页直接说明「本次不参与加重」，不诱导下一块从 90% 档位起步。
      if (_deloadWeek) {
        final bodyweight = effective == LoadMode.bodyweight;
        final lastWorking =
            _progressionLastWorkout[ex.name] ?? const <SetEntry>[];
        final assisted =
            !bodyweight &&
            lastWorking.isNotEmpty &&
            lastWorking.last.weightKg < 0;
        final zhDetail = bodyweight
            ? '本次少做 1 组'
            : assisted
            ? '本次辅助配重增加约 10%、少做 1 组'
            : '本次按约 90% 重量、少做 1 组';
        final enDetail = bodyweight
            ? 'one fewer set'
            : assisted
            ? '~10% more machine assist and one fewer set'
            : '~90% weight and one fewer set';
        out.add(
          tx(
            '${ex.name}（计划目标 $tSets×$tMin-$tMax $unit）：减载周——$zhDetail，'
            '不计入渐进判定；下周回到${bodyweight ? '原计划' : '原档'}。',
            en:
                '${exname(ex.name)} (target $tSets×$tMin-$tMax ${ex.logging == LoggingMode.time ? 's' : 'reps'}): deload week — '
                '$enDetail; this session does not affect progression, back to normal next week.',
          ),
        );
        continue;
      }
      final state = chainStateFromHistory(sets, ex.rule);
      // 计划组数一起传（P0-B）：少练的组不能用剩下的达标组换推进；
      // 计时/自重形态一并透传，否则总结页会把秒数说成次数、把加组说成加重。
      final v = evaluateChain(
        rule: ex.rule,
        state: state,
        workingSets: sets,
        targetSets: tSets,
        logging: ex.logging,
        loadType: effective,
      );
      // 停滞协议（P1-C）：平台期未顶格时，链判定只会说「继续冲」；
      // 换成有原因的下一步（减载 10% 或换变式）。已顶格保留链的加重建议。
      final protocol = plateauProtocolOf(
        plateauFor(ex.name),
        rule: ex.rule,
        logging: ex.logging,
        loadType: effective,
      );
      // 不能无条件覆盖规则链：
      // - 链已成功加重（本次顶格/换档）→ 保留链的加重建议；
      // - 少做（P0-B）/没记录/换档位的 hold → 保留链原因，
      //   不能借平台期协议把「本次只完成 X/Y 组」改写成「继续加重」。
      final chainAddedWeight =
          v.action == 'advance' && v.next.weightKg != state.weightKg;
      final canReduce =
          protocol.action == 'reduce' &&
          !chainAddedWeight &&
          (v.action == 'decrease' ||
              v.action == 'advance' ||
              v.holdKind == 'target_miss');
      final canAdd =
          protocol.action == 'add' &&
          (v.holdKind == 'target_miss' ||
              (v.holdKind == 'chain_end' &&
                  effective == LoadMode.bodyweight));
      final reason = canReduce || canAdd ? protocol.reason : v.reason;
      out.add(
        tx(
          '${ex.name}（计划目标 $tSets×$tMin-$tMax $unit）：$reason',
          en: '${exname(ex.name)} (target $tSets×$tMin-$tMax ${ex.logging == LoggingMode.time ? 's' : 'reps'}): $reason',
        ),
      );
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

  /// 训练自评（impression）写入后回调：App 容器据此再补一份自动快照
  /// （收工时先写的那份还不包含这条自评）。
  void Function()? onSessionRated;

  Future<void> _enterFocus() async {
    // 常亮开关兜底：startFromDay 里 _setPhase(_applyWakelock) 先按设置
    // 收口，随后这里不能又无条件强制亮屏（否则开关形同虚设）。
    if (_settings.wakelockEnabled) WakelockPlus.enable();
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
    // 常亮开关（2026-10 开场设置）：设置关时训练中也不再强制亮屏；
    // 暂停/结束的灭屏收口（shouldKeepScreenOn=false → disable）保持原样。
    if (!_settings.wakelockEnabled) {
      WakelockPlus.disable();
      return;
    }
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
    _disposed = true;
    _tick?.cancel();
    _hbTimer?.cancel();
    restRemainingMs.dispose();
    focusBanner.dispose();
    super.dispose();
  }
}

/// 内置起始重量查询（P2-A）：内置计划显式值 → 少量高频动作覆盖 →
/// 按「器械 + 复合/单关节」启发式 → 词表外动作仍回退 20kg。
/// 共享实现见 presets/start_weights.dart（计划仓库同口径）。
double presetStartOf(String name) => knownStartWeightOf(name) ?? 20;

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
