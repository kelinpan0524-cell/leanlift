import 'dart:convert';
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/lang.dart';
import '../models/app_release.dart';

/// 应用设置：只存手机本地（shared_preferences）。密钥类字段永不进仓库/日志。
class Settings extends ChangeNotifier {
  Settings(this._prefs) {
    _load();
  }

  final SharedPreferences _prefs;

  // 训练偏好
  int restCompoundSec = 180;
  int restAssistanceSec = 120;
  bool vibrationOn = true;
  bool soundOn = true;

  /// 体重 kg（自重容量折算用，点名条目二）：自重动作按 系数×体重 计入容量。
  /// 默认 70kg；设为 0 时关闭折算（自重动作容量回到记 0 的旧口径）。
  double bodyWeightKg = 70;

  // AI（OpenAI 兼容）
  String aiBaseUrl = '';
  String aiApiKey = '';
  String aiModel = '';

  // 飞书
  bool larkEnabled = false;
  String larkAppId = '';
  String larkAppSecret = '';
  String larkRefreshToken = '';
  String larkCalendarId = '';
  int larkEventHour = 18; // 日历事件默认开始时刻
  int larkEventMinutes = 30;
  int larkReminderMin = 30;

  // 专注模式
  bool focusDndEnabled = true; // 训练时自动勿扰
  bool focusAppCheckEnabled = true; // 切出分心 App 提醒
  String distractingApps =
      'com.smile.gifmaker,com.kuaishou.app,com.ss.android.ugc.aweme,com.tencent.weishi,com.xingin.xhs,com.sina.weibo,tv.danmaku.bili';

  // 空闲提醒（调研条目 4）：训练态连续超阈值发一次性通知拉回
  bool idleNudgeEnabled = true;
  int idleNudgeMinutes = 10; // 可选 5/10/15/30/60

  // 休息音效四层触发（调研条目 10）：开始/半程/3-2-1 倒数/结束。
  // 整体开关（分层配置 UI 过重，暂不做）；结束音不受此开关影响——
  // 休息到点的提示沿用原有 _onRestFinished 通道（声音+震动）。
  bool restCueEnabled = true;

  // 提示音仅耳机（2026-09-26 Arono）：戴着耳机听音乐时提示音混进耳机不扰人；
  // 没接耳机（有线/蓝牙都没连）就不播，避免健身房外放打扰别人。
  // 震动与休息到点的系统提醒不受影响。默认开。
  bool restCueHeadphoneOnly = true;

  // 练前提醒（2026-09-26 Arono）：训练日到了设定时刻还没练就发本地通知。
  // trainReminderMinOfDay = 一天内的分钟数（20:00 = 1200）。
  bool trainReminderOn = true;
  int trainReminderMinOfDay = 20 * 60;

  // 错过训练日自动顺延（2026-10-04 Arono）：训练日过了 24 点还没练，
  // 下次打开 App 自动把计划往后推一天（每错一个训练日推一天），
  // 并在首页提示。默认开；关闭期间不扫描不推进检查点。
  bool autoShiftOnMiss = true;

  // 锁屏时保持显示（调研条目 6，FitoTrack showOnLockScreen）：
  // 系统锁屏后训练计时仍显示在锁屏上（Android 8.1+ setShowWhenLocked）。
  // 默认关：与常亮（训练时屏幕不灭）是两个独立维度。
  bool lockScreenKeepOn = false;

  // 应用更新（GitHub 私仓 Releases）
  String ghUpdateToken = ''; // 只读令牌，与 AI Key 同一本地存放策略
  AppRelease? pendingUpdate; // 运行时状态（发现的新版），不落盘

  // 界面语言（跟随系统 / 中文 / English）
  LangPref langPref = LangPref.system;

  /// 系统语言（服务侧解析全局语言也用它）。
  /// 走 WidgetsBinding 的派发器：测试环境可用 localeTestValue 覆盖
  /// （test/flutter_test_config.dart 钉成中文），纯 Dart 上下文回落平台实例。
  Locale? get systemLocale {
    try {
      return WidgetsBinding.instance.platformDispatcher.locale;
    } catch (_) {
      return PlatformDispatcher.instance.locale;
    }
  }

  /// 已解析语言码（'zh' / 'en'），偏好为"跟随系统"时按系统语言
  String get resolvedLang => Lang.resolve(langPref, systemLocale);

  void _load() {
    restCompoundSec = _prefs.getInt('${_kprefix}restCompound') ?? 180;
    restAssistanceSec = _prefs.getInt('${_kprefix}restAssist') ?? 120;
    bodyWeightKg = _prefs.getDouble('${_kprefix}bodyWeight') ?? 70;
    vibrationOn = _prefs.getBool('${_kprefix}vibration') ?? true;
    soundOn = _prefs.getBool('${_kprefix}sound') ?? true;
    aiBaseUrl = _prefs.getString('${_kprefix}aiBaseUrl') ?? '';
    aiApiKey = _prefs.getString('${_kprefix}aiApiKey') ?? '';
    aiModel = _prefs.getString('${_kprefix}aiModel') ?? '';
    larkEnabled = _prefs.getBool('${_kprefix}larkEnabled') ?? false;
    larkAppId = _prefs.getString('${_kprefix}larkAppId') ?? '';
    larkAppSecret = _prefs.getString('${_kprefix}larkSecret') ?? '';
    larkRefreshToken = _prefs.getString('${_kprefix}larkRefresh') ?? '';
    larkCalendarId = _prefs.getString('${_kprefix}larkCalendar') ?? '';
    larkEventHour = _prefs.getInt('${_kprefix}larkHour') ?? 18;
    larkEventMinutes = _prefs.getInt('${_kprefix}larkMin') ?? 30;
    larkReminderMin = _prefs.getInt('${_kprefix}larkRemind') ?? 30;
    focusDndEnabled = _prefs.getBool('${_kprefix}focusDnd') ?? true;
    focusAppCheckEnabled = _prefs.getBool('${_kprefix}focusApp') ?? true;
    distractingApps =
        _prefs.getString('${_kprefix}distract') ?? distractingApps;
    idleNudgeEnabled = _prefs.getBool('${_kprefix}idleNudgeOn') ?? true;
    idleNudgeMinutes = _prefs.getInt('${_kprefix}idleNudgeMin') ?? 10;
    restCueEnabled = _prefs.getBool('${_kprefix}restCue') ?? true;
    restCueHeadphoneOnly = _prefs.getBool('${_kprefix}restCueHpOnly') ?? true;
    trainReminderOn = _prefs.getBool('${_kprefix}trainRemindOn') ?? true;
    trainReminderMinOfDay =
        _prefs.getInt('${_kprefix}trainRemindMin') ?? 20 * 60;
    autoShiftOnMiss = _prefs.getBool('${_kprefix}autoShiftOnMiss') ?? true;
    lockScreenKeepOn = _prefs.getBool('${_kprefix}lockScreenKeepOn') ?? false;
    ghUpdateToken = _prefs.getString('${_kprefix}ghToken') ?? '';
    larkAccessToken = _prefs.getString('${_kprefix}larkAccess') ?? '';
    larkTokenExpiry = _prefs.getInt('${_kprefix}larkExpiry') ?? 0;
    aiChatHistoryJson = _prefs.getString('${_kprefix}aiChatHistory') ?? '[]';
    lastExportJsonAt = _prefs.getInt('${_kprefix}lastExportJsonAt') ?? 0;
    langPref = switch (_prefs.getString('${_kprefix}lang')) {
      'zh' => LangPref.zh,
      'en' => LangPref.en,
      _ => LangPref.system,
    };
    // 服务侧（通知/导出/前台服务）读全局静态值，启动即与偏好同步一次
    Lang.setResolved(resolvedLang == 'en');
  }

  // token 运行时字段
  String larkAccessToken = '';
  int larkTokenExpiry = 0; // epoch ms

  /// AI 教练对话历史（最近若干轮的 user/assistant 消息 JSON）。
  /// 退出 App 再进不丢（2026-09-26 Arono）；「清空对话」时一并清掉。
  String aiChatHistoryJson = '[]';

  /// 上次成功导出 JSON 存档的时间（epoch ms，0=从未导出）。
  /// 数据与备份行据此亮「建议备份」（2026-09-26 体检清单遗留项）。
  int lastExportJsonAt = 0;

  void set(void Function() change, {bool persist = true}) {
    change();
    if (persist) notifyListeners();
  }

  Future<void> save() async {
    await _prefs.setInt('${_kprefix}restCompound', restCompoundSec);
    await _prefs.setInt('${_kprefix}restAssist', restAssistanceSec);
    await _prefs.setDouble('${_kprefix}bodyWeight', bodyWeightKg);
    await _prefs.setBool('${_kprefix}vibration', vibrationOn);
    await _prefs.setBool('${_kprefix}sound', soundOn);
    await _prefs.setString('${_kprefix}aiBaseUrl', aiBaseUrl);
    await _prefs.setString('${_kprefix}aiApiKey', aiApiKey);
    await _prefs.setString('${_kprefix}aiModel', aiModel);
    await _prefs.setBool('${_kprefix}larkEnabled', larkEnabled);
    await _prefs.setString('${_kprefix}larkAppId', larkAppId);
    await _prefs.setString('${_kprefix}larkSecret', larkAppSecret);
    await _prefs.setString('${_kprefix}larkRefresh', larkRefreshToken);
    await _prefs.setString('${_kprefix}larkCalendar', larkCalendarId);
    await _prefs.setInt('${_kprefix}larkHour', larkEventHour);
    await _prefs.setInt('${_kprefix}larkMin', larkEventMinutes);
    await _prefs.setInt('${_kprefix}larkRemind', larkReminderMin);
    await _prefs.setBool('${_kprefix}focusDnd', focusDndEnabled);
    await _prefs.setBool('${_kprefix}focusApp', focusAppCheckEnabled);
    await _prefs.setString('${_kprefix}distract', distractingApps);
    await _prefs.setBool('${_kprefix}idleNudgeOn', idleNudgeEnabled);
    await _prefs.setInt('${_kprefix}idleNudgeMin', idleNudgeMinutes);
    await _prefs.setBool('${_kprefix}restCue', restCueEnabled);
    await _prefs.setBool('${_kprefix}restCueHpOnly', restCueHeadphoneOnly);
    await _prefs.setBool('${_kprefix}trainRemindOn', trainReminderOn);
    await _prefs.setInt('${_kprefix}trainRemindMin', trainReminderMinOfDay);
    await _prefs.setBool('${_kprefix}autoShiftOnMiss', autoShiftOnMiss);
    await _prefs.setBool('${_kprefix}lockScreenKeepOn', lockScreenKeepOn);
    await _prefs.setString('${_kprefix}ghToken', ghUpdateToken);
    await _prefs.setString('${_kprefix}larkAccess', larkAccessToken);
    await _prefs.setInt('${_kprefix}larkExpiry', larkTokenExpiry);
    await _prefs.setString('${_kprefix}aiChatHistory', aiChatHistoryJson);
    await _prefs.setInt('${_kprefix}lastExportJsonAt', lastExportJsonAt);
    await _prefs.setString('${_kprefix}lang', langPref.name);
    Lang.setResolved(resolvedLang == 'en');
    notifyListeners();
  }

  bool get aiConfigured => aiBaseUrl.isNotEmpty && aiApiKey.isNotEmpty;

  /// 从未导出、或上次导出已超 7 天 → 数据与备份行亮「建议备份」。
  static bool backupNeedsAttention(int lastExportJsonAtMs, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return lastExportJsonAtMs <= 0 ||
        now - lastExportJsonAtMs > const Duration(days: 7).inMilliseconds;
  }

  List<String> get distractingAppsList => distractingApps
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  String debugSummary() => jsonEncode({
    'aiConfigured': aiConfigured,
    'larkEnabled': larkEnabled,
    'larkCalendarConfigured': larkCalendarId.isNotEmpty,
  });
}

// 避免拼错：内部统一用小写前缀常量
const _kprefix = 'set.';
