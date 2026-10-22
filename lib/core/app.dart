import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/db.dart';
import '../l10n/lang.dart';
import '../presets/exercise_library.dart';
import '../services/ai_service.dart';
import '../services/auto_shift.dart';
import '../services/backup_service.dart';
import '../services/diagnostic_log.dart';
import '../services/export_service.dart';
import '../services/focus_service.dart';
import '../services/heart_rate_service.dart';
import '../services/lark_service.dart';
import '../services/local_bridge.dart';
import '../services/notify_service.dart';
import '../services/plan_repository.dart';
import '../services/session_controller.dart';
import '../services/settings.dart';
import '../services/training_reminder.dart';

/// 全局容器：App 启动时构造一次，经 AppScope 注入整棵 Widget 树。
class AppContainer {
  AppContainer({
    required this.prefs,
    Db? db,
    AiService? aiOverride,
    LocalBridgeService? bridgeOverride,
    AutoBackupService? backupOverride,
    DiagnosticLog? diagOverride,
  })  : settings = Settings(prefs),
        db = db ?? Db.instance,
        diag = diagOverride ?? DiagnosticLog(prefs),
        notify = NotifyService() {
    // 本机偏好标记随备份走（2026-10-18）：全量导出/恢复把减载/停练标记
    // 与训练块锚点带上。挂到 Db 实例上，exportAllJson/restoreAll 读写。
    this.db.attachSessionPrefs(prefs);
    focus = FocusService(settings);
    planRepo = PlanRepository(this.db, settings);
    session = SessionController(this.db, settings, prefs, focus);
    // [aiOverride] 仅测试注入（MockClient 模拟 AI 回复做端到端渲染验证）
    ai = aiOverride ?? AiService(settings);
    lark = LarkService(settings, this.db);
    export = ExportService(this.db);
    // 自动快照：每次训练正常结束写一份全量 JSON；启动时超 24 小时补档。
    // [backupOverride] 仅测试注入（临时目录，避免碰 path_provider 插件）。
    autoBackup = backupOverride ?? AutoBackupService(this.db);
    // 局域网只读桥（方案 B）：构造即挂容器，但**默认不自动启动**——
    // 开关状态不落盘，每次都要用户在设置页主动开，空闲超时自动关；
    // 已配对设备（令牌摘要）落盘，所以"配对一次"成立，重开无需重配。
    // 用户显式开过「常驻」的除外：在记住的那个局域网内启动 App 时
    // 自动拉起（见 init 里的 maybeAutoStart），换网/流量一律不自启。
    // [bridgeOverride] 仅测试注入（自定义端口/IP，免依赖跑测机器的网卡）。
    bridge = bridgeOverride ??
        LocalBridgeService(
          db: this.db,
          prefs: prefs,
          planRepo: planRepo,
          bodyWeightKg: () => settings.bodyWeightKg,
        );
    hr = HeartRateService(prefs);
    hr.addListener(_onHrChanged);
    diag.log('app', 'container created');

    // 训练开始/结束 → 专注模式动作
    session.onEnterFocus = _onEnterFocus;
    session.onExitFocus = _onExitFocus;
    // 休息时间源 → 精确闹钟（开始/加时/继续重挂，暂停取消，恢复会话补挂）
    session.onRestAlarmChanged = _onRestAlarmChanged;
    // 训练卡 → 前台服务常驻通知（会话进行中常驻，结束自动停）
    // + 心率直连窗口（2026-10-17）：卡出现 = 会话活跃，自动重连已存
    // 设备并开始采样；卡消失 = 会话关闭，采样落库 + 断连省电。
    // 2026-10-22：startRecording 带上会话 id，采样按天落盘并能在进程
    // 被杀后按同一场次读回；连接/断开由 _onHrChanged 联动前台服务。
    int? hrSessionId;
    Future<void>? hrFlush;
    session.onCardChanged = (card) {
      if (card.active) {
        unawaited(notify.showTrainingCard(card));
        if (hrSessionId == null) {
          hrSessionId = session.session?.id;
          hr.startRecording(sessionId: hrSessionId);
          diag.log(
            'hr',
            'recording start session=$hrSessionId '
                'restored=${hr.samples.length}',
          );
          unawaited(hr.connectSaved());
        }
      } else {
        unawaited(notify.stopTrainingCard());
        final sid = hrSessionId;
        if (sid != null) {
          hrSessionId = null;
          hr.stopRecording();
          diag.log(
            'hr',
            'recording stop session=$sid samples=${hr.samples.length}',
          );
          // quit 会话也落库（历史不展示但数据不丢）；失败静默不阻塞收工。
          // 自动快照会先等这个 Future，避免备份缺最后一截心率。
          hrFlush = hr.flushSamples(this.db, sid);
          unawaited(hrFlush);
          hr.disconnect();
        }
      }
    };
    // 通知栏遥控按钮（暂停/继续/±10 秒）→ 会话状态机
    notify.onNotifAction = _onNotifAction;
    // 点击「周复盘」通知 → 请求 UI 打开周复盘页（冷启动先挂起，
    // 由 BaojiApp 首帧消费；导航层不在容器里）。
    notify.onWeeklyRecapTap = requestWeeklyRecap;
    // 空闲提醒：人在屏上走 App 内横幅，离开前台才发系统通知
    session.onIdleNudge = (minutes) async {
      if (_inForeground) {
        session.showFocusBanner(
          tx('你已运动 $minutes 分钟了，回来继续！',
              en: "You've worked out for $minutes minutes — come back!"),
        );
      } else {
        await notify.showIdleNudge(minutes);
      }
    };
    // 休息音效四层（条目 10）：调度由 SessionController（RestCueScheduler
    // 区间阈值判断），这里只负责播——原生 ToneGenerator 按层选音调。
    // 仅耳机偏好在这里读（Settings 实时值），没接耳机时原生侧静默跳过。
    session.onRestCue = (cue) {
      unawaited(
          notify.playRestCue(cue, headphoneOnly: settings.restCueHeadphoneOnly));
    };
    // 练前提醒（2026-09-26）：训练日傍晚未练的本地兜底通知。
    // 训练结束/放弃、计划或排程变化都会触发全量重排（幂等，失败静默）。
    trainReminders = TrainingReminderService(this.db, planRepo, settings);
    // 错过训练日自动顺延（2026-10-04）：扫描昨天及更早错过的训练日并顺延；
    // 结果留给首页弹一次提示（pendingAutoShiftDates）。
    autoShift = AutoShiftService(planRepo, prefs);
    session.onSessionClosed = () {
      diag.log('session', 'closed');
      unawaited(trainReminders.reschedule());
      // 收工/放弃后补排周复盘提醒（训练中曾被抑制）。
      unawaited(rescheduleWeeklyRecap());
      // 正常收工与中途放弃都算会话结束，各留一份快照。
      // 预约式写入：先等心率落库，失败只在服务里记录，不打断收工。
      if (settings.autoBackupEnabled) {
        autoBackup.scheduleSnapshot(waitFor: hrFlush);
      }
    };
    session.onSessionRated = () {
      // 自评是收工后才点的：稍等 2 秒合并连点，再补一份带自评的快照。
      if (settings.autoBackupEnabled) {
        autoBackup.scheduleSnapshot(delay: const Duration(seconds: 2));
      }
    };
    planRepo.addListener(() {
      unawaited(trainReminders.reschedule());
      // AI 词表同步（2026-09-29）：计划变化（AI 保存/编辑器增删）会让
      // exercise_meta 沉淀动作变化，重灌一次让 AI 引用到最新动作库。
      unawaited(_syncAiSedimentLibrary());
    });
    // 生命周期：条目 2 双通道互斥——人在屏上时休息到点只走屏内提示，
    // 离开前台才交回系统精确提醒；两通道互不重复。
    WidgetsBinding.instance.addObserver(_LifecycleHook(this));
  }

  final SharedPreferences prefs;
  final Settings settings;
  final Db db;
  final NotifyService notify;
  final DiagnosticLog diag;
  late final FocusService focus;
  late final PlanRepository planRepo;
  late final SessionController session;
  late final AiService ai;
  late final LarkService lark;
  late final ExportService export;
  late final AutoBackupService autoBackup;
  late final LocalBridgeService bridge;
  late final TrainingReminderService trainReminders;
  late final AutoShiftService autoShift;
  late final HeartRateService hr;

  /// 本次启动自动顺延掉的训练日（首页读过一次即清空；空 = 无提示）。
  List<DateTime> pendingAutoShiftDates = const [];

  /// 周复盘导航请求（UI 层设置；容器只负责挂起/转交，不依赖页面）。
  VoidCallback? onWeeklyRecapRequested;
  bool _pendingWeeklyRecap = false;

  /// 通知点击/冷启动详情都走这里：UI 已挂好就立刻打开，否则先挂起。
  void requestWeeklyRecap() {
    _pendingWeeklyRecap = true;
    onWeeklyRecapRequested?.call();
  }

  /// UI 首帧/回到前台时消费一次挂起的打开请求（true = 需要打开）。
  bool takePendingWeeklyRecap() {
    final pending = _pendingWeeklyRecap;
    _pendingWeeklyRecap = false;
    return pending;
  }

  /// 周复盘提醒（P1-E2）：按设置重排未来 8 周；训练进行中不排
  /// （避免通知打断训练），收工后由 onSessionClosed 补排。
  /// 设置变更时由设置页直接调用；失败静默，下次触发再排。
  ///
  /// 串行化：设置页连续改星期/时刻会连发多次重排，取消与预约若并发
  /// 交错，可能出现「开关已关却又排上」；用一条 Future 链保证按调用
  /// 顺序执行（每次都是先取消旧 id 段再排新）。
  Future<void> _weeklyRecapChain = Future<void>.value();

  Future<void> rescheduleWeeklyRecap() {
    final next =
        _weeklyRecapChain.then((_) => _applyWeeklyRecapSchedule());
    _weeklyRecapChain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _applyWeeklyRecapSchedule() async {
    if (!settings.weeklyRecapReminderOn || session.hasActive) {
      await notify.cancelWeeklyRecap();
      return;
    }
    await notify.scheduleWeeklyRecap(
      weekday: settings.weeklyRecapWeekday,
      minutesOfDay: settings.weeklyRecapMinOfDay,
    );
  }

  bool _inForeground = true;
  HrLink _lastHrLink = HrLink.idle;
  String _lastLifecycle = '';

  /// 心率连接状态 → 前台服务（2026-10-22）：
  /// - 连上：拉起「LeanLift 正在记录心率」常驻通知（训练中由训练卡接管，
  ///   原生侧按模式保活，不会两张卡打架）；
  /// - 断开：训练中由原生保留训练卡、只去掉 connectedDevice 类型；
  ///   不在训练中才真正停服务，不留僵尸通知。
  /// 用户主动断开的判断在 HeartRateService 内，这里只跟状态。
  void _onHrChanged() {
    final link = hr.link;
    if (link == _lastHrLink) return;
    final previous = _lastHrLink;
    _lastHrLink = link;
    final error = hr.lastError.isEmpty ? '' : ' · ${hr.lastError}';
    diag.log('hr', 'link ${previous.name} -> ${link.name}$error');
    if (link == HrLink.connected) {
      unawaited(notify.startHrForeground());
    } else if (link == HrLink.idle && previous != HrLink.idle) {
      // 训练中由原生保留训练卡、只去掉 connectedDevice 类型；
      // 不在训练中才真正停服务（判断在 Kotlin 侧）。
      unawaited(notify.stopHrForeground());
    }
  }

  void _onNotifAction(String action) {
    final s = session;
    if (!s.hasActive) return;
    switch (action) {
      case 'pause':
        s.pauseRest();
      case 'resume':
        s.resumeRest();
      case 'minus10':
        s.extendRest(-10);
      case 'plus10':
        s.extendRest(10);
    }
  }

  void onAppLifecycleChanged(AppLifecycleState state) {
    if (state.name != _lastLifecycle) {
      _lastLifecycle = state.name;
      diag.log('lifecycle', state.name);
    }
    // 回到前台：如果之前连过心率、现在断了，静默补连一次
    // （用户主动断开过的不会补——判断在服务内部）。
    if (state == AppLifecycleState.resumed) {
      unawaited(hr.handleAppResumed());
    }
    final fg = state == AppLifecycleState.resumed;
    if (fg == _inForeground) return;
    _inForeground = fg;
    // 会话层同步前台标记：休息到点的屏内提示（震动/提示音）只在前台做
    session.setForeground(fg);
    final s = session;
    if (s.hasActive &&
        s.phase == WorkoutPhase.resting &&
        !s.isRestPaused &&
        s.restEndAt > 0) {
      // 屏内提示接管 / 交回系统提醒（暂停态闹钟本就取消，不重复处理）
      s.onRestAlarmChanged?.call(fg ? null : s.restEndAt);
    }
  }

  Future<void> init() async {
    // 通知插件初始化不挡首帧（只有进休息倒计时才需要），失败静默重试
    unawaited(notify.init().catchError((Object e) {}));
    // 局域网桥常驻自启：只在「用户开过常驻 且 当前就在记住的局域网」时生效，
    // 其余情况安静跳过。失败也不挡启动（用户手动开时会看到具体报错）。
    unawaited(bridge.maybeAutoStart().catchError((Object e) => false));
    await ensureFirstRunSeeded();
    await planRepo.reload();
    await _syncAiSedimentLibrary();
    await session.restore();
    diag.log(
      'session',
      session.hasActive
          ? 'restored active #${session.session?.id}'
          : 'no active session',
    );
    // 错过训练日自动顺延：扫描失败不挡启动（下次打开再补扫）。
    // 有跨天恢复中的会话先不扫：那天的会话还没定性（active 不算练过），
    // 等收工/放弃后下次打开再按最终状态判断。
    if (!session.hasActive) {
      try {
        final missed =
            await autoShift.run(enabled: settings.autoShiftOnMiss);
        if (missed.isNotEmpty) pendingAutoShiftDates = missed;
      } catch (_) {}
    }
    // 练前提醒：计划加载完成后排一轮（planRepo 监听会覆盖后续变化）
    unawaited(trainReminders.reschedule());
    // 周复盘提醒：会话恢复后再排（有活跃训练时 reschedule 会跳过，
    // 避免训练中弹出的周复盘通知打断训练）。
    unawaited(rescheduleWeeklyRecap());
    // 自动备份补档：距上次快照满 24 小时（或从未备份）就在启动时补一份。
    // 失败只在服务里记录——磁盘暂时不可写也不挡启动。
    if (settings.autoBackupEnabled) {
      unawaited(autoBackup.maybeSnapshotOnLaunch().catchError((Object e) {
        autoBackup.recordError(e);
        return null;
      }));
    }
    // 联网补写飞书离线队列（失败静默，下轮再试）
    unawaited(lark.retryPending());
  }

  /// 首启播种：动作库为空时写入全量内置动作的肌群/器械标注。
  /// 只按"表为空"判断、不做每次启动重写——exercise_meta 的 upsert 是整行
  /// REPLACE，老用户在编辑器里改过的肌群标注不能被启动时静默重置；
  /// 引导页选了「先不选」的用户也由此拿到完整动作库（挑选页/热力图可用）。
  Future<void> ensureFirstRunSeeded() async {
    if (await db.exerciseMetaCount() == 0) {
      await planRepo.seedExerciseLibrary();
    }
  }

  /// AI 词表同步（2026-09-29）：把 exercise_meta 里内置词表之外的用户沉淀
  /// 动作灌进 AiService——AI 排计划时与动作挑选页同一套动作库（不再换名
  /// 重造沉淀过的动作），六级匹配也能精确命中沉淀名。失败静默（词表退回
  /// 内置库，不影响功能）。
  Future<void> _syncAiSedimentLibrary() async {
    try {
      final all = await db.allExerciseMeta();
      ai.sedimentLibrary = [
        for (final m in all)
          if (libraryMetaByName(m.name) == null) m,
      ];
    } catch (_) {}
  }

  Future<void> _onEnterFocus() async {
    // 训练进行中抑制周复盘提醒：留在通知栏里到点弹出会打断训练，
    // 训练开始即取消；收工/放弃后由 onSessionClosed 补排下一次。
    // 走同一条重排链，避免与设置变更触发的预约交错。
    unawaited(rescheduleWeeklyRecap());
    // 锁屏时保持显示（条目 6）：按设置开关，训练期间生效，结束还原。
    // 失败静默（测试环境/低版本系统）。
    unawaited(notify.setLockScreenDisplay(settings.lockScreenKeepOn));
    final f = focus;
    if (settings.focusDndEnabled && await f.isDndAccessGranted()) {
      await f.setDnd(true);
    }
  }

  Future<void> _onExitFocus() async {
    unawaited(notify.setLockScreenDisplay(false));
    final f = focus;
    if (settings.focusDndEnabled && await f.isDndAccessGranted()) {
      await f.setDnd(false);
    }
  }

  Future<void> _onRestAlarmChanged(int? endAtMs) async {
    if (endAtMs == null) {
      await notify.cancelRestEnd();
    } else if (_inForeground) {
      // 人在屏上：屏内提示接管，不挂系统提醒（否则休息页等到自然到点时，
      // heads-up 系统通知先于屏内 tick 到达，两通道同时触发）。
      // 顺带清掉可能残留的已预约闹钟；离开前台时由生命周期钩子重挂。
      await notify.cancelRestEnd();
    } else {
      await notify.scheduleRestEnd(endAtMs);
      // 剩 30 秒预警（2026-10-11）：人刷别的 App 时提前拉回准备下一组；
      // 剩余不足 30 秒时内部静默跳过（只剩结束提醒一条）。
      await notify.scheduleRestPre(endAtMs);
    }
  }

  void dispose() {
    autoBackup.dispose();
    hr.removeListener(_onHrChanged);
    hr.dispose();
    session.dispose();
    settings.dispose();
    planRepo.dispose();
    bridge.dispose();
  }
}

/// App 全局生命周期探针：前台/后台状态供提醒双通道互斥使用。
class _LifecycleHook with WidgetsBindingObserver {
  _LifecycleHook(this._c);

  final AppContainer _c;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _c.onAppLifecycleChanged(state);
  }
}

class AppScope extends InheritedNotifier {
  // ignore: prefer_const_constructors_in_immutables
  AppScope({super.key, required AppContainer container, required super.child})
    : _container = container,
      super(notifier: container.settings);

  final AppContainer _container;

  static AppContainer of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found');
    return scope!._container;
  }
}
