import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/db.dart';
import '../l10n/lang.dart';
import '../presets/exercise_library.dart';
import '../services/ai_service.dart';
import '../services/auto_shift.dart';
import '../services/export_service.dart';
import '../services/focus_service.dart';
import '../services/lark_service.dart';
import '../services/notify_service.dart';
import '../services/plan_repository.dart';
import '../services/session_controller.dart';
import '../services/settings.dart';
import '../services/training_reminder.dart';

/// 全局容器：App 启动时构造一次，经 AppScope 注入整棵 Widget 树。
class AppContainer {
  AppContainer({required this.prefs, Db? db, AiService? aiOverride})
    : settings = Settings(prefs),
      db = db ?? Db.instance,
      notify = NotifyService() {
    focus = FocusService(settings);
    planRepo = PlanRepository(this.db, settings);
    session = SessionController(this.db, settings, prefs, focus);
    // [aiOverride] 仅测试注入（MockClient 模拟 AI 回复做端到端渲染验证）
    ai = aiOverride ?? AiService(settings);
    lark = LarkService(settings, this.db);
    export = ExportService(this.db);

    // 训练开始/结束 → 专注模式动作
    session.onEnterFocus = _onEnterFocus;
    session.onExitFocus = _onExitFocus;
    // 休息时间源 → 精确闹钟（开始/加时/继续重挂，暂停取消，恢复会话补挂）
    session.onRestAlarmChanged = _onRestAlarmChanged;
    // 训练卡 → 前台服务常驻通知（会话进行中常驻，结束自动停）
    session.onCardChanged = (card) {
      if (card.active) {
        unawaited(notify.showTrainingCard(card));
      } else {
        unawaited(notify.stopTrainingCard());
      }
    };
    // 通知栏遥控按钮（暂停/继续/±10 秒）→ 会话状态机
    notify.onNotifAction = _onNotifAction;
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
      unawaited(trainReminders.reschedule());
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
  late final FocusService focus;
  late final PlanRepository planRepo;
  late final SessionController session;
  late final AiService ai;
  late final LarkService lark;
  late final ExportService export;
  late final TrainingReminderService trainReminders;
  late final AutoShiftService autoShift;

  /// 本次启动自动顺延掉的训练日（首页读过一次即清空；空 = 无提示）。
  List<DateTime> pendingAutoShiftDates = const [];

  bool _inForeground = true;

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
    await ensureFirstRunSeeded();
    await planRepo.reload();
    await _syncAiSedimentLibrary();
    await session.restore();
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
    session.dispose();
    settings.dispose();
    planRepo.dispose();
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
