import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/app.dart';
import '../engine/weight_unit.dart';
import '../l10n/lang.dart';
import '../services/ai_service.dart';
import '../services/backup_service.dart';
import '../services/focus_service.dart';
import '../services/settings.dart';
import '../services/update_service.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 设置子页面（2026-09-26 Arono：设置主页改系统设置式分组行，
/// 每个功能点进对应子页——主页一屏看全、不再一直滑）。
/// 各子页内容从旧设置大卡片原样平移，行为不变，只换了外层容器。

/// 通用子页脚手架：AppBar + 卡片列表容器，与全 App 视觉一致。
Scaffold _subScaffold(String title, List<Widget> children) {
  return Scaffold(
    backgroundColor: AppTheme.bg,
    appBar: AppBar(title: Text(title)),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: children,
      ),
    ),
  );
}

// ============ 训练偏好 ============

/// 训练偏好：组间休息 / 体重折算 / 震动与提示音 / 锁屏 / 空闲提醒。
class TrainingPrefsPage extends StatelessWidget {
  const TrainingPrefsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = app(context);
    final s = c.settings;
    return _subScaffold(tx('训练偏好', en: 'Training Preferences'), [
      SectionCard(
        title: tx('休息与负荷', en: 'Rest & Load'),
        child: Column(
          children: [
            // 重量单位（2026-10-17）：kg 唯一存储口径，lb 只在显示/输入层换算；
            // 出差/换健身房混用时全局一键切换，历史数据同步换算显示。
            _unitRow(s),
            _numRow(
                tx('复合动作休息（秒）', en: 'Rest for compound exercises (sec)'),
                s.restCompoundSec, (v) {
              s.restCompoundSec = v;
              s.save();
            }),
            _numRow(
                tx('辅助动作休息（秒）', en: 'Rest for assistance exercises (sec)'),
                s.restAssistanceSec, (v) {
              s.restAssistanceSec = v;
              s.save();
            }),
            const Divider(height: 1, thickness: 1, color: AppTheme.cardHi),
            // 训练块与减载（P1-C）：默认 5 周一块、第 5 周减载；
            // 0 = 关闭（长期线性加重）。只影响新开的训练会话。
            _blockWeeksRow(s),
            // 体重（自重容量折算用）：引体/俯卧撑类动作
            // 按 系数×体重 计入容量趋势；设 0 关闭折算。
            _weightRow(
                tx('体重（自重容量折算用）',
                    en: 'Body weight (for bodyweight volume)'),
                s.bodyWeightKg, (v) {
              s.bodyWeightKg = v;
              s.save();
            }),
            // 开练前顺手记体重（2026-10 开场设置）：与上面的体重折算共用
            // 数据源（BodyMetric + 设置里的体重字段）。
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tx('开练前记体重', en: 'Weigh-in before workout')),
              subtitle: Text(
                tx('开始训练时今天还没记体重，就先弹面板顺手记一条（可跳过）',
                    en: 'If today has no weigh-in yet, a quick sheet pops up before starting (skippable)'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
              value: s.askWeightOnStart,
              activeThumbColor: AppTheme.primary,
              onChanged: (v) {
                s.askWeightOnStart = v;
                s.save();
              },
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: tx('反馈与提醒', en: 'Feedback & Reminders'),
        child: Column(
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tx('完成组时震动', en: 'Vibrate when a set is done')),
              value: s.vibrationOn,
              activeThumbColor: AppTheme.primary,
              onChanged: (v) {
                s.vibrationOn = v;
                s.save();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tx('休息提示音', en: 'Rest sound cues')),
              subtitle: Text(
                tx('组间休息的开始/半程/最后3秒提示音',
                    en: 'Cue sounds at rest start, halfway, and the last 3 seconds'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
              value: s.restCueEnabled,
              activeThumbColor: AppTheme.primary,
              onChanged: (v) {
                s.restCueEnabled = v;
                s.save();
              },
            ),
            if (s.restCueEnabled)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tx('仅耳机播放', en: 'Headphones only')),
                subtitle: Text(
                  tx('戴着耳机听音乐时提示音进耳机；没接耳机就不播，不外放扰人',
                      en: 'Cues play into your headphones; with none connected they stay silent instead of playing out loud'),
                  style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
                ),
                value: s.restCueHeadphoneOnly,
                activeThumbColor: AppTheme.primary,
                onChanged: (v) {
                  s.restCueHeadphoneOnly = v;
                  s.save();
                },
              ),
            const Divider(height: 1, thickness: 1, color: AppTheme.cardHi),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tx('训练中屏幕常亮', en: 'Keep screen on during workout')),
              subtitle: Text(
                tx('训练计时期间屏幕不灭，抬眼即见；暂停/结束照常灭屏',
                    en: 'The screen stays on while the timer runs; it sleeps as usual on pause or finish'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
              value: s.wakelockEnabled,
              activeThumbColor: AppTheme.primary,
              onChanged: (v) {
                s.wakelockEnabled = v;
                s.save();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tx('锁屏时保持显示', en: 'Keep on lock screen')),
              subtitle: Text(
                tx('锁屏后训练计时仍显示在锁屏上，下次开始训练生效',
                    en: 'The workout timer stays visible on the lock screen; takes effect from the next workout'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
              value: s.lockScreenKeepOn,
              activeThumbColor: AppTheme.primary,
              onChanged: (v) {
                s.lockScreenKeepOn = v;
                s.save();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tx('空闲提醒', en: 'Idle Reminder')),
              subtitle: Text(
                tx('训练中放下手机太久，发通知拉你回来',
                    en: 'If you put the phone down too long mid-workout, a notification brings you back'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
              value: s.idleNudgeEnabled,
              activeThumbColor: AppTheme.primary,
              onChanged: (v) {
                s.idleNudgeEnabled = v;
                s.save();
              },
            ),
            if (s.idleNudgeEnabled)
              _nudgeRow(tx('放下手机多久后提醒', en: 'Idle time before nudge'),
                  s.idleNudgeMinutes, (v) {
                s.idleNudgeMinutes = v;
                s.save();
              }),
            const Divider(height: 1, thickness: 1, color: AppTheme.cardHi),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tx('错过训练日自动顺延', en: 'Auto-shift missed days')),
              subtitle: Text(
                tx('训练日过了还没练，下次打开 App 计划自动往后推一天（每错一天推一天），并会提示',
                    en: 'If a training day passes without a workout, the plan shifts a day later (one day per miss) with a note when you open the app'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
              value: s.autoShiftOnMiss,
              activeThumbColor: AppTheme.primary,
              onChanged: (v) {
                s.autoShiftOnMiss = v;
                s.save();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tx('练前提醒', en: 'Training day reminder')),
              subtitle: Text(
                tx('训练日到了设定时刻还没练，发通知叫一声（不配飞书也有兜底）',
                    en: 'If a training day comes and you have not trained by the set time, a notification nudges you (works without Feishu)'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
              value: s.trainReminderOn,
              activeThumbColor: AppTheme.primary,
              onChanged: (v) {
                s.trainReminderOn = v;
                s.save();
                c.trainReminders.reschedule();
              },
            ),
            if (s.trainReminderOn)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tx('提醒时刻', en: 'Reminder time')),
                trailing: Text(
                  _fmtMinutesOfDay(s.trainReminderMinOfDay),
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w600),
                ),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(
                        hour: s.trainReminderMinOfDay ~/ 60,
                        minute: s.trainReminderMinOfDay % 60),
                  );
                  if (picked == null) return;
                  s.trainReminderMinOfDay = picked.hour * 60 + picked.minute;
                  s.save();
                  c.trainReminders.reschedule();
                },
              ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      // 每周复盘提醒（P1-E2）：只排本地通知；AI 自动写周报默认关，
      // 且只在配了 AI 时露出开关（没 Key 的开关点了也没用）。
      SectionCard(
        title: tx('每周复盘', en: 'Weekly Recap'),
        child: Column(
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tx('每周复盘提醒', en: 'Weekly recap reminder')),
              subtitle: Text(
                tx('每周固定时刻提醒你花两分钟看复盘（默认周日 20:00）',
                    en: 'A weekly nudge to spend two minutes on your recap (Sunday 20:00 by default)'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
              value: s.weeklyRecapReminderOn,
              activeThumbColor: AppTheme.primary,
              onChanged: (v) {
                s.weeklyRecapReminderOn = v;
                s.save();
                c.rescheduleWeeklyRecap();
              },
            ),
            if (s.weeklyRecapReminderOn) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tx('提醒日', en: 'Reminder day')),
                trailing: DropdownButton<int>(
                  value: s.weeklyRecapWeekday,
                  dropdownColor: AppTheme.card,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (var d = 1; d <= 7; d++)
                      DropdownMenuItem(
                        value: d,
                        child: Text(_weekdayLabel(d)),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    s.weeklyRecapWeekday = v;
                    s.save();
                    c.rescheduleWeeklyRecap();
                  },
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tx('提醒时刻', en: 'Reminder time')),
                trailing: Text(
                  _fmtMinutesOfDay(s.weeklyRecapMinOfDay),
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w600),
                ),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(
                        hour: s.weeklyRecapMinOfDay ~/ 60,
                        minute: s.weeklyRecapMinOfDay % 60),
                  );
                  if (picked == null) return;
                  s.weeklyRecapMinOfDay = picked.hour * 60 + picked.minute;
                  s.save();
                  c.rescheduleWeeklyRecap();
                },
              ),
            ],
            if (s.aiConfigured)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tx('AI 自动写周报', en: 'AI weekly note')),
                subtitle: Text(
                  tx('打开周复盘页时用 AI 写一段总结；只在页面打开时前台请求，不会后台联网',
                      en: 'When you open the weekly recap, AI writes a short note — only in the foreground, never in the background'),
                  style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
                ),
                value: s.aiWeeklyRecapOn,
                activeThumbColor: AppTheme.primary,
                onChanged: (v) {
                  s.aiWeeklyRecapOn = v;
                  s.save();
                },
              ),
          ],
        ),
      ),
    ]);
  }

  String _weekdayLabel(int weekday) => switch (weekday) {
        1 => tx('周一', en: 'Mon'),
        2 => tx('周二', en: 'Tue'),
        3 => tx('周三', en: 'Wed'),
        4 => tx('周四', en: 'Thu'),
        5 => tx('周五', en: 'Fri'),
        6 => tx('周六', en: 'Sat'),
        _ => tx('周日', en: 'Sun'),
      };

  String _fmtMinutesOfDay(int m) =>
      '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  /// 训练块长度（P1-C）：每 N 周 1 周减载，0 = 关闭。
  /// 选项按常用周期给（4/5/6/8 周），存了其他值时原样作为一项显示，
  /// 不做静默改写。
  Widget _blockWeeksRow(Settings s) {
    final options = <int>{0, 4, 5, 6, 8, s.trainingBlockWeeks}.toList()
      ..sort();
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tx('训练块长度', en: 'Training block')),
              Text(
                tx('每 N 周安排 1 周减载（重量 ×0.9、少 1 组）；0 = 关闭',
                    en: 'One deload week every N weeks (90% weight, one fewer set); 0 = off'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        DropdownButton<int>(
          value: s.trainingBlockWeeks,
          dropdownColor: AppTheme.card,
          underline: const SizedBox.shrink(),
          items: [
            for (final n in options)
              DropdownMenuItem(
                value: n,
                child: Text(
                  n == 0 ? tx('关', en: 'Off') : tx('$n 周', en: '$n wk'),
                ),
              ),
          ],
          onChanged: (v) {
            if (v == null) return;
            s.trainingBlockWeeks = v;
            s.save();
          },
        ),
      ],
    );
  }

  Widget _numRow(String label, int value, ValueChanged<int> onChanged) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          onPressed: () => onChanged((value - 15).clamp(30, 600)),
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text('$value', style: const TextStyle(fontSize: 17)),
        IconButton(
          onPressed: () => onChanged((value + 15).clamp(30, 600)),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }

  /// 重量单位行（2026-10-17）：kg/lb 二选一，切换即全局生效
  /// （含训练中大数字旁的同款开关），历史数据同步换算显示。
  Widget _unitRow(Settings s) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tx('重量单位', en: 'Weight unit')),
              Text(
                tx('出差/换健身房混用 kg、lb 器械时一键切换，历史数据同步换算',
                    en: 'For travel or a mixed kg/lb gym; history converts too'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
            ],
          ),
        ),
        for (final u in WeightUnit.values)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: OutlinedButton(
              onPressed: u == s.weightUnit
                  ? null
                  : () {
                      s.toggleWeightUnit();
                      s.save();
                    },
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(56, 40),
                padding: EdgeInsets.zero,
                backgroundColor:
                    u == s.weightUnit ? AppTheme.accent : AppTheme.cardHi,
                side: BorderSide.none,
              ),
              child: Text(
                u.name,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: u == s.weightUnit
                      ? const Color(0xFF06220F)
                      : AppTheme.textDim,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _weightRow(String label, double value, ValueChanged<double> onChanged) {
    final lb = WeightUnits.isLb;
    // lb 模式：显示换算值、步长 ±1lb、上限 440lb；存储口径始终 kg
    String disp(double kg) => kg <= 0
        ? tx('关', en: 'Off')
        : '${_fmtWeight(lb ? lbSnap(kgToLb(kg)) : kg)} ${unitLabel()}';
    double step(double kg, int sign) {
      if (!lb) return (kg + sign).clamp(0.0, 200.0);
      return lbToKg((lbSnap(kgToLb(kg)) + sign).clamp(0.0, 440.0));
    }

    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          onPressed: () => onChanged(step(value, -1)),
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text(disp(value), style: const TextStyle(fontSize: 17)),
        IconButton(
          onPressed: () => onChanged(step(value, 1)),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }

  String _fmtWeight(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  /// 空闲提醒阈值：离散档位 5/10/15/30/60 分钟（步进沿档位移动）。
  Widget _nudgeRow(String label, int value, ValueChanged<int> onChanged) {
    const choices = [5, 10, 15, 30, 60];
    var i = choices.indexOf(value);
    if (i < 0) i = 1; // 脏值回落到默认档 10
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          onPressed: i > 0 ? () => onChanged(choices[i - 1]) : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text(tx('${choices[i]} 分钟', en: '${choices[i]} min'),
            style: const TextStyle(fontSize: 17)),
        IconButton(
          onPressed: i < choices.length - 1
              ? () => onChanged(choices[i + 1])
              : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}

// ============ 专注模式 ============

/// 专注模式：分心 App 名单（带应用图标与名称的列表，支持搜索勾选）。
class FocusSubPage extends StatefulWidget {
  const FocusSubPage({super.key});

  @override
  State<FocusSubPage> createState() => _FocusSubPageState();
}

class _FocusSubPageState extends State<FocusSubPage> {
  List<AppEntry>? _apps;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // initState 里不能同步读 InheritedWidget（_load 首句 app(context)），
    // 延后一帧
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final c = app(context);
    final list = await c.focus.installedAppsWithIcons();
    // 过滤掉自己
    final filtered = list
        .where((a) => a.packageName != 'com.arono.baoji_timer')
        .toList();
    if (mounted) setState(() => _apps = filtered);
  }

  void _toggle(String pkg, bool on) {
    final s = app(context).settings;
    final set = s.distractingAppsList.toSet();
    on ? set.add(pkg) : set.remove(pkg);
    s.distractingApps = set.join(',');
    s.save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = app(context).settings;
    final selected = s.distractingAppsList.toSet();
    final apps = _apps;
    final q = _query.trim();
    final filtered = (apps ?? const <AppEntry>[])
        .where(
          (a) =>
              q.isEmpty ||
              a.label.toLowerCase().contains(q.toLowerCase()) ||
              a.packageName.toLowerCase().contains(q.toLowerCase()),
        )
        .toList();
    return _subScaffold(tx('专注模式', en: 'Focus Mode'), [
      SectionCard(
        title: tx('分心 App 名单', en: 'Distracting Apps'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tx('勾选训练中不想刷的 App，切过去再回来会提醒你。',
                  en: 'Check the apps you do not want to open mid-workout; switching over and back will remind you.'),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: tx('搜索应用名…', en: 'Search apps…'),
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            if (apps == null)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  tx('没有匹配的应用', en: 'No matching apps'),
                  style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
                ),
              )
            else
            // 列表带图标：默认只铺前 12 行防卡片过长，搜索时展开全部匹配
            ...[
              const SizedBox(height: 2),
              for (final a in filtered.take(q.isEmpty ? 12 : filtered.length))
                _appRow(a, selected.contains(a.packageName)),
              if (q.isEmpty && filtered.length > 12)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 4),
                  child: Text(
                    tx('还有 ${filtered.length - 12} 个，输入名称搜索',
                        en: '${filtered.length - 12} more — type a name to search'),
                    style:
                        const TextStyle(color: AppTheme.textDim, fontSize: 12),
                  ),
                ),
            ],
          ],
        ),
      ),
    ]);
  }

  Widget _appRow(AppEntry a, bool selected) {
    final icon = a.icon;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _toggle(a.packageName, !selected),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 38,
              height: 38,
              child: icon != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: Image.memory(
                        icon,
                        width: 38,
                        height: 38,
                        fit: BoxFit.cover,
                      ),
                    )
                  : const Icon(
                      Icons.android_outlined,
                      size: 30,
                      color: AppTheme.textDim,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    a.packageName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textDim,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Checkbox(
              value: selected,
              activeColor: AppTheme.primary,
              onChanged: (on) => _toggle(a.packageName, on == true),
            ),
          ],
        ),
      ),
    );
  }
}

// ============ AI 配置 ============

/// AI 配置：OpenAI 兼容接口 + 测试连接（AI 教练与计划拆解共用）。
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  late final _ctrlUrl = TextEditingController(text: app(context).settings.aiBaseUrl);
  late final _ctrlKey = TextEditingController(text: app(context).settings.aiApiKey);
  late final _ctrlModel = TextEditingController(text: app(context).settings.aiModel);
  bool _testing = false;
  String? _testResult; // null=没测过；成功文案 / 失败原因都放这

  @override
  void dispose() {
    _ctrlUrl.dispose();
    _ctrlKey.dispose();
    _ctrlModel.dispose();
    super.dispose();
  }

  /// 测试连接：先保存当前输入，再发一条最小请求。
  /// 成功/失败都在页内直接反馈给用户。
  Future<void> _testConnection() async {
    final c = app(context); // 先取容器：await 之后不再碰 context（use_build_context_synchronously）
    final s = c.settings;
    s.aiBaseUrl = _ctrlUrl.text.trim();
    s.aiApiKey = _ctrlKey.text.trim();
    s.aiModel = _ctrlModel.text.trim();
    await s.save();
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final (ms, reply) = await c.ai.testConnection();
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testResult =
            '连接成功 ✓${reply.isEmpty ? '' : '（模型回复：${_brief(reply)}）'} · 用时 ${(ms / 1000).toStringAsFixed(1)} 秒';
      });
    } on AiException catch (e) {
      if (mounted) {
        setState(() {
          _testing = false;
          _testResult =
            tx('连接失败：${e.message}', en: 'Connection failed: ${e.message}');
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testing = false;
          _testResult = tx('连接失败：$e', en: 'Connection failed: $e');
        });
      }
    }
  }

  String _brief(String s) =>
      s.length <= 24 ? s : '${s.substring(0, 24)}…';

  @override
  Widget build(BuildContext context) {
    final s = app(context).settings;
    final configured = s.aiConfigured;
    return _subScaffold(
        tx('AI 教练', en: 'AI Coach'),
        [
          SectionCard(
            title: tx('AI 配置（计划拆解 · AI 教练）',
                en: 'AI Settings (Plan Breakdown · AI Coach)'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  configured
                      ? tx('状态：已配置 ✓（AI 教练与计划拆解可用）',
                          en: 'Status: configured ✓ (AI Coach and Plan Breakdown available)')
                      : tx('状态：未配置（计划拆解与 AI 教练不可用）',
                          en: 'Status: not configured (Plan Breakdown and AI Coach unavailable)'),
                  style: TextStyle(
                    color: configured ? AppTheme.primary : AppTheme.warn,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  tx('兼容 OpenAI 接口。Base URL 填到版本路径为止，结尾不带 /chat/completions：'
                          'Moonshot 填 https://api.moonshot.cn/v1 · DeepSeek 填 https://api.deepseek.com · '
                          '智谱填 https://open.bigmodel.cn/api/paas/v4。模型名如 kimi-k2。Key 只存手机本地。',
                      en: 'Works with any OpenAI-compatible API. The Base URL goes up to the version path, without /chat/completions at the end: '
                          'Moonshot: https://api.moonshot.cn/v1 · DeepSeek: https://api.deepseek.com · '
                          'Zhipu: https://open.bigmodel.cn/api/paas/v4. Model name e.g. kimi-k2. The key is stored on this phone only.'),
                  style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _ctrlUrl,
                  decoration: const InputDecoration(labelText: 'Base URL'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _ctrlKey,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'API Key'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _ctrlModel,
                  decoration:
                      InputDecoration(labelText: tx('模型名', en: 'Model Name')),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: _testing ? null : () {
                          s.aiBaseUrl = _ctrlUrl.text.trim();
                          s.aiApiKey = _ctrlKey.text.trim();
                          s.aiModel = _ctrlModel.text.trim();
                          s.save();
                          toast(context, tx('AI 配置已保存', en: 'AI settings saved'));
                        },
                        child: Text(tx('保存 AI 配置', en: 'Save AI Settings')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _testing ? null : _testConnection,
                        child: Text(_testing
                            ? tx('测试中…', en: 'Testing…')
                            : tx('测试连接', en: 'Test Connection')),
                      ),
                    ),
                  ],
                ),
                if (_testResult != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _testResult!,
                      style: TextStyle(
                        color: _testResult!.startsWith('连接成功')
                            ? AppTheme.primary
                            : AppTheme.danger,
                        fontSize: 13,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                // AI 教练入口已统一到首页顶部卡片（2026-09-26）：这里只留指路，
                // 配置完成后不再提供第二个入口按钮。
                Text(
                  tx('配置成功后，回首页点顶部「AI 教练」卡片即可开始对话与排计划。',
                      en: 'Once connected, tap the "AI Coach" card at the top of the Home tab to chat and build plans.'),
                  style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
                ),
              ],
            ),
          ),
        ]);
  }
}

// ============ 飞书日历 ============

/// 飞书日历联动：凭证 + 测试连接（训练日写入飞书日历）。
class LarkSettingsPage extends StatefulWidget {
  const LarkSettingsPage({super.key});

  @override
  State<LarkSettingsPage> createState() => _LarkSettingsPageState();
}

class _LarkSettingsPageState extends State<LarkSettingsPage> {
  late final _ctrlId = TextEditingController(text: app(context).settings.larkAppId);
  late final _ctrlSecret =
      TextEditingController(text: app(context).settings.larkAppSecret);
  late final _ctrlRefresh = TextEditingController(
    text: app(context).settings.larkRefreshToken,
  );

  @override
  void dispose() {
    _ctrlId.dispose();
    _ctrlSecret.dispose();
    _ctrlRefresh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = app(context);
    final s = c.settings;
    return _subScaffold(tx('飞书日历联动', en: 'Feishu Calendar Sync'), [
      SectionCard(
        title: tx('飞书账号', en: 'Feishu Account'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tx('启用（训练日写入飞书日历）',
                  en: 'Enable (write workouts to Feishu Calendar)')),
              value: s.larkEnabled,
              activeThumbColor: AppTheme.primary,
              onChanged: (v) {
                s.larkEnabled = v;
                s.save();
              },
            ),
            Text(
              tx('首次配置：在飞书开放平台创建自建应用（开日历权限），用电脑 lark-cli 授权拿到 refresh_token，粘贴到这里。详见 README。',
                  en: 'First-time setup: create a custom app on the Feishu Open Platform (with Calendar permission), authorize with lark-cli on a computer to get the refresh_token, then paste it here. See README for details.'),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _ctrlId,
              decoration: const InputDecoration(labelText: 'App ID'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrlSecret,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'App Secret'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrlRefresh,
              obscureText: true,
              decoration: InputDecoration(
                labelText: tx('Refresh Token（授权码）', en: 'Refresh Token (auth code)'),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      s.larkAppId = _ctrlId.text.trim();
                      s.larkAppSecret = _ctrlSecret.text.trim();
                      s.larkRefreshToken = _ctrlRefresh.text.trim();
                      s.save();
                      toast(context, tx('飞书配置已保存', en: 'Feishu settings saved'));
                    },
                    child: Text(tx('保存', en: 'Save')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      s.larkAppId = _ctrlId.text.trim();
                      s.larkAppSecret = _ctrlSecret.text.trim();
                      s.larkRefreshToken = _ctrlRefresh.text.trim();
                      await s.save();
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(tx('测试中…', en: 'Testing…')),
                          backgroundColor: AppTheme.cardHi,
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                      try {
                        final cid = await c.lark.fetchPrimaryCalendar();
                        s.larkCalendarId = cid;
                        await s.save();
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(tx('连接成功 ✓ 日历已绑定',
                                en: 'Connected ✓ Calendar linked')),
                            backgroundColor: AppTheme.cardHi,
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      } catch (e) {
                        final msg = e.toString();
                        final friendly =
                            msg.contains('TimeoutException') ||
                                msg.contains('ClientException')
                            ? tx('网络不可用或超时，请检查网络',
                                en: 'Network unavailable or timed out. Check your connection.')
                            : (msg.length > 80
                                  ? '${msg.substring(0, 80)}…'
                                  : msg);
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(tx('连接失败：$friendly',
                                en: 'Connection failed: $friendly')),
                            backgroundColor: AppTheme.cardHi,
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    },
                    child: Text(tx('测试连接', en: 'Test Connection')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ]);
  }
}

// ============ 权限 ============

/// 权限：逐项说明、可跳过；离 App 授权回来状态即时刷新。
class PermissionsSubPage extends StatefulWidget {
  const PermissionsSubPage({super.key});

  @override
  State<PermissionsSubPage> createState() => _PermissionsSubPageState();
}

class _PermissionsSubPageState extends State<PermissionsSubPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 勿扰/使用情况等特殊权限必须离 App 去系统设置授权，
    // 返回 resumed 时重建各行 FutureBuilder，状态即时刷新
    if (state == AppLifecycleState.resumed) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = app(context);
    final focus = c.focus;
    return _subScaffold(
        tx('权限（逐项说明，可跳过）', en: 'Permissions (each explained; all optional)'),
        [
          SectionCard(
            title: tx('建议按顺序开启', en: 'Enable in order'),
            child: Column(
              children: [
                _permRow(
                  title: tx('通知', en: 'Notifications'),
                  desc: tx('锁屏/切后台时显示组间休息倒计时和结束提醒。不给则训练时需留在 App 内看计时。',
                      en: 'Shows the rest countdown and end-of-workout alert on the lock screen or in background. Without it, keep the app in the foreground to see the timer.'),
                  check: () async => await Permission.notification.isGranted,
                  request: () async {
                    await Permission.notification.request();
                    return Permission.notification.isGranted;
                  },
                ),
                _permRow(
                  title: tx('勿扰模式访问', en: 'Do Not Disturb Access'),
                  desc: tx('训练开始自动开勿扰（屏蔽消息），结束自动恢复。不给则需手动开勿扰。',
                      en: 'Turns on Do Not Disturb (mutes messages) when a workout starts and restores it when it ends. Without it, enable DND manually.'),
                  check: () => focus.isDndAccessGranted(),
                  request: () async {
                    await focus.openDndAccessSettings();
                    return focus.isDndAccessGranted();
                  },
                ),
                _permRow(
                  title: tx('使用情况访问', en: 'Usage Access'),
                  desc: tx('训练中切到抖音等分心 App 后回来自动提醒。不给则没有分心提醒，其他功能不受影响。',
                      en: 'Reminds you when you return from distracting apps like TikTok mid-workout. Without it, no distraction reminders; everything else works.'),
                  check: () => focus.isUsageAccessGranted(),
                  request: () async {
                    await focus.openUsageAccessSettings();
                    return focus.isUsageAccessGranted();
                  },
                ),
                _permRow(
                  title: tx('精确闹钟', en: 'Exact Alarm'),
                  desc: tx('让休息结束的提醒准时响。不给则提醒可能晚几秒到几十秒。',
                      en: 'Makes the rest-end alert ring on time. Without it, alerts may be a few seconds to tens of seconds late.'),
                  check: () => focus.canExactAlarm(),
                  request: () async {
                    await focus.openExactAlarmSettings();
                    return focus.canExactAlarm();
                  },
                ),
                _permRow(
                  title: tx('电池优化白名单', en: 'Battery Optimization Exemption'),
                  desc: tx('防止系统在后台杀掉计时。不给则锁屏久了计时仍准确（墙钟），但提醒可能延迟。',
                      en: 'Keeps the system from killing the timer in the background. Without it, timing stays accurate over long lock-screen sessions (wall clock), but alerts may be delayed.'),
                  check: () => focus.isIgnoringBatteryOptimizations(),
                  request: () async {
                    await focus.requestIgnoreBattery();
                    return focus.isIgnoringBatteryOptimizations();
                  },
                ),
              ],
            ),
          ),
        ]);
  }

  Widget _permRow({
    required String title,
    required String desc,
    required Future<bool> Function() check,
    required Future<bool> Function() request,
  }) {
    return FutureBuilder<bool>(
      future: check(),
      builder: (context, snap) {
        final granted = snap.data == true;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                granted ? Icons.check_circle : Icons.info_outline,
                color: granted ? AppTheme.primary : AppTheme.warn,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          granted
                              ? tx('已授权', en: 'Granted')
                              : tx('未授权', en: 'Not granted'),
                          style: TextStyle(
                            fontSize: 12,
                            color: granted
                                ? AppTheme.primary
                                : AppTheme.textDim,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      desc,
                      style: const TextStyle(
                        color: AppTheme.textDim,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (!granted)
                TextButton(
                  onPressed: () async {
                    await request();
                  },
                  child: Text(tx('去开启', en: 'Enable')),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ============ 应用更新 ============

/// 应用更新：GitHub Releases 自更新（公开仓库免令牌；私有部署可配只读令牌）。
class UpdateSettingsPage extends StatefulWidget {
  const UpdateSettingsPage({super.key});

  @override
  State<UpdateSettingsPage> createState() => _UpdateSettingsPageState();
}

class _UpdateSettingsPageState extends State<UpdateSettingsPage>
    with WidgetsBindingObserver {
  late final _ctrlToken =
      TextEditingController(text: app(context).settings.ghUpdateToken);
  bool _checking = false;
  bool _upToDate = false;
  bool _needInstallPerm = false;
  String? _error;
  int? _received;
  int? _total;
  String? _apkPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrlToken.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从"允许安装未知应用"系统页返回时自动继续安装
    if (state == AppLifecycleState.resumed &&
        _needInstallPerm &&
        _apkPath != null) {
      _tryInstall();
    }
  }

  Future<void> _check() async {
    final c = app(context);
    final s = c.settings;
    // 检查前先把输入框里的令牌存下（与 AI 配置一致的本地保存策略）
    s.ghUpdateToken = _ctrlToken.text.trim();
    await s.save();
    setState(() {
      _checking = true;
      _error = null;
      _upToDate = false;
    });
    try {
      final release = await UpdateService(s).checkLatest();
      s.set(() => s.pendingUpdate = release);
      if (mounted) {
        setState(() => _upToDate = release == null);
      }
    } on UpdateException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Exception catch (e) {
      if (mounted) setState(() => _error = tx('检查失败：$e', en: 'Check failed: $e'));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _downloadAndInstall() async {
    final s = app(context).settings;
    final release = s.pendingUpdate;
    if (release == null) return;
    setState(() {
      _error = null;
      _received = 0;
      _total = release.apkSize;
    });
    try {
      final path = await UpdateService(s).downloadApk(
        release,
        onProgress: (r, t) {
          if (mounted) {
            setState(() {
              _received = r;
              _total = t;
            });
          }
        },
      );
      if (!mounted) return;
      setState(() => _apkPath = path);
      await _tryInstall();
    } on UpdateException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Exception catch (e) {
      if (mounted) setState(() => _error = tx('下载失败：$e', en: 'Download failed: $e'));
    }
  }

  Future<void> _tryInstall() async {
    final path = _apkPath;
    if (path == null) return;
    final svc = UpdateService(app(context).settings);
    try {
      if (await svc.canRequestInstall()) {
        await svc.installApk(path);
      } else if (mounted) {
        setState(() => _needInstallPerm = true);
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _error =
            tx('无法启动安装：$e', en: 'Could not start installation: $e'));
      }
    }
  }

  String _briefNotes(String notes) {
    // GitHub 的 alert 语法（> [!NOTE]）不是标准 Markdown，剥掉标记行保留内容
    final cleaned = cleanReleaseNotes(notes);
    final lines = cleaned.split('\n').take(8).join('\n');
    return lines.length > 240 ? '${lines.substring(0, 240)}…' : lines;
  }

  @override
  Widget build(BuildContext context) {
    final s = app(context).settings;
    return _subScaffold(tx('应用更新', en: 'App Update'), [
      SectionCard(
        title: tx('检查与安装', en: 'Check & Install'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snap) => Text(
                snap.hasData
                    ? tx('当前版本 v${snap.data!.version}（构建 ${snap.data!.buildNumber}）',
                        en: 'Current version v${snap.data!.version} (build ${snap.data!.buildNumber})')
                    : tx('当前版本 …', en: 'Current version …'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              tx('更新包发布在 GitHub Releases：开源公开仓库免令牌，直接检查更新即可。'
                      '仅当你把仓库 fork 成私有仓库自用时，才需要粘贴只读令牌'
                      '（Fine-grained tokens，只勾选该仓库，权限 Contents: Read-only）。令牌只存手机本地。',
                  en: 'Updates are published on GitHub Releases: public open-source repos need no token, just check for updates. '
                      'You only need a read-only token if you forked the repo into a private one for personal use '
                      '(Fine-grained token, select only this repo, permission Contents: Read-only). The token is stored on this phone only.'),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _ctrlToken,
              obscureText: true,
              decoration: InputDecoration(
                labelText: tx('GitHub 只读令牌（公开仓库可留空）',
                    en: 'GitHub read-only token (leave empty for public repos)'),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _checking ? null : _check,
                    child: Text(_checking
                        ? tx('正在检查…', en: 'Checking…')
                        : tx('检查更新', en: 'Check for Updates')),
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppTheme.danger, fontSize: 13),
                ),
              ),
            if (_upToDate && s.pendingUpdate == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tx('已是最新版本 ✓', en: 'Already up to date ✓'),
                  style: const TextStyle(color: AppTheme.primary, fontSize: 13),
                ),
              ),
            ListenableBuilder(
              listenable: s,
              builder: (context, _) {
                final release = s.pendingUpdate;
                if (release == null) return const SizedBox.shrink();
                final received = _received;
                final total = _total;
                final downloading = received != null;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Divider(height: 24),
                    Text(
                      tx('发现新版 ${release.title.isEmpty ? '构建 ${release.buildNumber}' : release.title}',
                          en: 'New version available: ${release.title.isEmpty ? 'build ${release.buildNumber}' : release.title}'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                      if (release.notes.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: MarkdownBody(
                            data: _briefNotes(release.notes),
                            styleSheet: MarkdownStyleSheet.fromTheme(
                                    Theme.of(context))
                                .copyWith(
                              p: const TextStyle(
                                  color: AppTheme.textDim, fontSize: 12),
                              h1: const TextStyle(
                                  color: AppTheme.text, fontSize: 14),
                              h2: const TextStyle(
                                  color: AppTheme.text, fontSize: 14),
                              h3: const TextStyle(
                                  color: AppTheme.text, fontSize: 13),
                              listBullet: const TextStyle(
                                  color: AppTheme.textDim, fontSize: 12),
                              blockquote: const TextStyle(
                                  color: AppTheme.textDim, fontSize: 12),
                            ),
                          ),
                        ),
                        // 2026-09-27 Arono 报障：b93 起说明变长，卡片里只截 8 行
                        // 又没有入口看全文。简短预览保持卡片紧凑，全文进
                        // 独立可滚动页查看（设置页操作，无训练中弹窗顾虑）。
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    ReleaseNotesPage(notes: release.notes),
                              ),
                            ),
                            child: Text(tx('查看完整说明', en: 'View Full Notes')),
                          ),
                        ),
                      ],
                    if (downloading) ...[
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: (total != null && total > 0)
                            ? received / total
                            : null,
                        backgroundColor: AppTheme.cardHi,
                        color: AppTheme.primary,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        tx('下载中 ${(received / 1048576).toStringAsFixed(1)}MB'
                            '${(total != null && total > 0) ? ' / ${(total / 1048576).toStringAsFixed(1)}MB' : ''}',
                            en: 'Downloading ${(received / 1048576).toStringAsFixed(1)}MB'
                                '${(total != null && total > 0) ? ' / ${(total / 1048576).toStringAsFixed(1)}MB' : ''}'),
                        style: const TextStyle(
                          color: AppTheme.textDim,
                          fontSize: 12,
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 10),
                      FilledButton(
                        onPressed: _downloadAndInstall,
                        child: Text(tx('下载并安装', en: 'Download & Install')),
                      ),
                    ],
                    if (_needInstallPerm && _apkPath != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        tx('系统要求先允许本应用"安装未知应用"（只需授权一次）',
                            en: 'The system requires allowing "Install unknown apps" for this app first (one-time only)'),
                        style:
                            const TextStyle(color: AppTheme.warn, fontSize: 12),
                      ),
                      TextButton(
                        onPressed: () =>
                            UpdateService(s).openInstallPermissionSettings(),
                        child: Text(tx('去系统授权', en: 'Open System Settings')),
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    ]);
  }
}

// ============ 更新说明全文页 ============

/// GitHub 的 alert 语法（> [!NOTE]）不是标准 Markdown，剥掉标记行保留内容。
@visibleForTesting
String cleanReleaseNotes(String notes) =>
    notes.replaceFirst('> [!NOTE]', '**ℹ️**');

/// 更新说明全文页（2026-09-27）：卡片里只放 8 行预览，全文在这里滚动查看。
/// 顶层公开便于单测（同 buildSessionDetailRows 的直测思路）。
class ReleaseNotesPage extends StatelessWidget {
  const ReleaseNotesPage({super.key, required this.notes});

  final String notes;

  @override
  Widget build(BuildContext context) {
    final md = MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: const TextStyle(fontSize: 14, height: 1.5),
      h1: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      h2: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      h3: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      listBullet: const TextStyle(fontSize: 14),
      blockquote: const TextStyle(fontSize: 13),
    );
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: Text(tx('更新说明', en: 'Release Notes'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: MarkdownBody(data: cleanReleaseNotes(notes), styleSheet: md),
      ),
    );
  }
}

// ============ 数据与备份 ============

String _lastExportSummary(int lastMs) {
  if (lastMs <= 0) {
    return tx('还没有导出过 JSON 存档，建议每 14 天导出一次',
        en: 'No JSON archive yet — export every 14 days');
  }
  final d = DateTime.fromMillisecondsSinceEpoch(lastMs);
  final day =
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  return '${tx('上次导出', en: 'Last export')}: $day';
}

/// 数据与备份：自动快照、导出 CSV/JSON、剪贴板恢复、AI 分析包、清空全部。
class DataBackupPage extends StatefulWidget {
  const DataBackupPage({super.key});

  @override
  State<DataBackupPage> createState() => _DataBackupPageState();
}

class _DataBackupPageState extends State<DataBackupPage> {
  Future<List<BackupInfo>>? _backups;
  AutoBackupService? _backupService;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = app(context).autoBackup;
    if (!identical(_backupService, service)) {
      _backupService?.removeListener(_onBackupChanged);
      _backupService = service;
      service.addListener(_onBackupChanged);
    }
    _backups ??= service.listBackups();
  }

  @override
  void dispose() {
    _backupService?.removeListener(_onBackupChanged);
    super.dispose();
  }

  /// 后台快照落盘/失败/清空后刷新页面，不用退出重进。
  void _onBackupChanged() {
    if (!mounted) return;
    final service = _backupService;
    if (service == null) return;
    setState(() {
      _backups = service.listBackups();
    });
  }

  void _reloadBackups() {
    setState(() {
      _backups = app(context).autoBackup.listBackups();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = app(context);
    return _subScaffold(tx('数据与备份', en: 'Data & Backup'), [
      // 非打断式提醒：仅在页面顶部占一行；会话仍 active 时不出现
      // （系统返回离开训练页不会 quit，但训练仍在进行中）。
      if (!c.session.hasActive &&
          Settings.backupNeedsAttention(c.settings.lastExportJsonAt))
        _backupReminder(c.settings.lastExportJsonAt),
      SectionCard(
        title: tx('自动备份', en: 'Auto Backup'),
        child: _autoBackupSection(c),
      ),
      SectionCard(
        title: tx('导出与恢复', en: 'Export & Restore'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tx('手机本地存储是唯一数据源，建议每 14 天导出存档。存档含训练记录、计划、身体数据与动作标注；换手机或误清数据时可用 JSON 存档一键恢复。',
                  en: 'Phone-local storage is the only data source. Export an archive every 14 days. It includes workout records, plans, body data, and exercise notes; if you switch phones or lose data, a JSON archive restores everything in one tap.'),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Text(
              _lastExportSummary(c.settings.lastExportJsonAt),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () async {
                final csv = await c.export.buildCsv();
                await c.export.shareText(
                  tx('训练记录 CSV', en: 'Workout Records CSV'),
                  csv,
                  filename: 'training_export.csv',
                );
              },
              child: Text(tx('导出 CSV（备份/表格）',
                  en: 'Export CSV (backup / spreadsheet)')),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () async {
                final json = await c.export.buildJson();
                await c.export.shareText(
                  tx('训练记录 JSON', en: 'Workout Records JSON'),
                  json,
                  filename: 'training_export.json',
                );
                c.settings.lastExportJsonAt =
                    DateTime.now().millisecondsSinceEpoch;
                await c.settings.save();
              },
              child: Text(tx('导出 JSON（存档）', en: 'Export JSON (archive)')),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _restoreFromJson(context, c),
              child: Text(tx('从 JSON 存档恢复', en: 'Restore from JSON archive')),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () async {
                final pack = await c.export.buildAiPack(
                    bodyWeightKg: c.settings.bodyWeightKg,
                    planRepo: c.planRepo);
                await c.export.shareText(
                  tx('AI 分析包', en: 'AI Analysis Pack'),
                  pack,
                  filename: 'ai_analysis_pack.md',
                );
              },
              child: Text(tx('生成 AI 分析包（给 AI 做总结）',
                  en: 'Generate AI analysis pack (for AI summary)')),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1, thickness: 1, color: AppTheme.cardHi),
            const SizedBox(height: 16),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.danger,
              ),
              onPressed: () async {
                final ok = await confirmDialog(
                  context,
                  tx('清空全部数据？', en: 'Delete All Data?'),
                  tx(
                    '所有训练记录、计划、身体数据以及本机的自动备份文件都会删除且无法恢复。强烈建议先导出一份到手机外。',
                    en: 'All workout records, plans, body data, and the auto backup files on this phone will be permanently deleted. Export a copy off-device first — strongly recommended.',
                  ),
                  okLabel: tx('全部删除', en: 'Delete All'),
                );
                if (!ok) return;
                final hadActive = c.session.hasActive;
                try {
                  if (hadActive) await c.session.quit();
                  // quit 会预约一份快照：取消并把已触发的等待任务作废。
                  c.autoBackup.cancelScheduled();
                } catch (_) {
                  if (context.mounted) {
                    toast(context,
                        tx('清空失败：无法结束进行中的训练，请重试',
                            en: 'Clear failed: could not end the in-progress workout; please retry'));
                  }
                  return;
                }
                try {
                  // 先删备份再删库：备份删除失败时宁可中止，也不留下完整数据副本。
                  await c.autoBackup.deleteAll();
                } catch (_) {
                  if (context.mounted) {
                    toast(
                      context,
                      hadActive
                          ? tx('清空失败：进行中的训练已结束，部分自动备份未能删除，训练数据未清空，请重试',
                              en: 'Clear failed: the in-progress workout was ended, some auto backups could not be deleted, and workout data was not cleared. Please retry')
                          : tx('清空失败：部分自动备份未能删除，训练数据未清空，请重试',
                              en: 'Clear failed: some auto backups could not be deleted; workout data was not cleared. Please retry'),
                    );
                  }
                  return;
                }
                try {
                  await c.db.wipeAll();
                } catch (_) {
                  if (context.mounted) {
                    toast(
                      context,
                      hadActive
                          ? tx('进行中的训练已结束、自动备份已删除，但训练数据清空失败，请重试',
                              en: 'The in-progress workout was ended and auto backups were deleted, but clearing workout data failed. Please retry')
                          : tx('自动备份已删除，但训练数据清空失败，请重试',
                              en: 'Auto backups were deleted, but clearing workout data failed. Please retry'),
                    );
                  }
                  return;
                }
                var refreshFailed = false;
                try {
                  c.settings.lastExportJsonAt = 0;
                  await c.settings.save();
                } catch (_) {
                  refreshFailed = true;
                }
                try {
                  await c.planRepo.reload();
                } catch (_) {
                  refreshFailed = true;
                }
                if (context.mounted) {
                  toast(
                    context,
                    refreshFailed
                        ? tx('已清空（含自动备份）；部分设置刷新失败，建议重开应用',
                            en: 'Cleared (including auto backups); some settings failed to refresh — please reopen the app')
                        : tx('已清空（含自动备份）',
                            en: 'Cleared (including auto backups)'),
                  );
                  _reloadBackups();
                }
              },
              child: Text(tx('清空全部数据', en: 'Delete All Data')),
            ),
          ],
        ),
      ),
    ]);
  }

  /// 自动快照卡片：最近时间 + 从最近备份恢复（先预览再确认）。
  Widget _autoBackupSection(AppContainer c) {
    return FutureBuilder<List<BackupInfo>>(
      future: _backups,
      builder: (context, snap) {
        final all = snap.data ?? const <BackupInfo>[];
        final latest = all.isEmpty ? null : all.first;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tx('启用自动备份', en: 'Enable auto backup')),
              subtitle: Text(
                tx('关闭后不再写新快照；已有备份仍可查看和恢复。',
                    en: 'When off, no new snapshots are written; existing backups can still be viewed and restored.'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
              value: c.settings.autoBackupEnabled,
              onChanged: (v) async {
                c.settings.autoBackupEnabled = v;
                if (!v) {
                  c.autoBackup.cancelScheduled();
                  c.autoBackup.clearError();
                }
                await c.settings.save();
                if (mounted) setState(() {});
              },
            ),
            Text(
              tx(
                '每次训练结束自动备份到手机本地；启动时距上次超过 24 小时也会补一份。只保留最近 7 个有备份日期的最新一份，以及最近 4 周每周的最新一份。',
                en: 'A full snapshot is saved on this phone after every workout, and on launch when the last snapshot is over 24 hours old. Keeps the latest snapshot for each of the 7 most recent backup dates, plus the latest for each of the 4 most recent weeks.',
              ),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
            ),
            if (c.settings.autoBackupEnabled &&
                !c.session.hasActive &&
                c.autoBackup.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                tx('上次自动备份失败（可能是存储空间不足），下次会话结束会重试。',
                    en: 'The last auto backup failed (possibly low storage); it will retry when the next session ends.'),
                style: const TextStyle(color: AppTheme.warn, fontSize: 12),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              latest == null
                  ? tx('还没有自动备份（完成一次训练后自动生成）',
                      en: 'No auto backups yet (created after your first workout)')
                  : '${tx('最近自动备份', en: 'Latest auto backup')}: '
                      '${_fmtBackupTime(latest.createdAt)}'
                      '${all.length > 1 ? tx(' · 共 ${all.length} 份', en: ' · ${all.length} total') : ''}',
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: latest == null ||
                      snap.connectionState != ConnectionState.done
                  ? null
                  : () => _restoreLatest(c, latest),
              icon: const Icon(Icons.restore, size: 18),
              label: Text(tx('从最近自动备份恢复',
                  en: 'Restore from latest auto backup')),
            ),
          ],
        );
      },
    );
  }

  Widget _backupReminder(int lastExportMs) {
    final never = lastExportMs <= 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.warn.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: AppTheme.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tx(
                never
                    ? '还没有手动导出过备份。自动备份只在本机（卸载应用会一起消失），建议导出一份到手机外。'
                    : '已经超过 14 天没有手动导出存档。自动备份只在本机（卸载应用会一起消失），建议导出一份到手机外。',
                en: never
                    ? 'You have not exported a manual backup yet. Auto backups stay on this phone (uninstalling the app removes them), so export a copy off-device.'
                    : 'It has been over 14 days since your last manual export. Auto backups stay on this phone (uninstalling the app removes them), so export a copy off-device.',
              ),
              style: const TextStyle(color: AppTheme.warn, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreLatest(AppContainer c, BackupInfo latest) async {
    final BackupPreview preview;
    try {
      preview = await c.autoBackup.preview(latest);
    } catch (_) {
      if (mounted) {
        toast(
          context,
          tx('读取自动备份失败：文件可能不完整或已损坏',
              en: 'Could not read the auto backup: the file may be incomplete or corrupted'),
        );
      }
      return;
    }
    if (!mounted) return;
    final when = _fmtBackupTime(latest.createdAt);
    final hadActive = c.session.hasActive;
    final activeNote = hadActive
        ? tx('当前进行中的训练会先结束。\n\n',
            en: 'The workout currently in progress will be ended first.\n\n')
        : '';
    final ok = await confirmDialog(
      context,
      tx('从最近自动备份恢复？', en: 'Restore from latest auto backup?'),
      tx(
        '备份时间：$when\n'
        '包含 ${preview.sessions} 次训练、${preview.plans} 个计划、${preview.bodyMetrics} 条身体数据。\n\n'
        '$activeNote恢复会先清空手机上的现有数据，再导入这份备份。此操作无法撤销。',
        en: 'Backup time: $when\n'
            'Contains ${preview.sessions} workouts, ${preview.plans} plans, ${preview.bodyMetrics} body entries.\n\n'
            '${hadActive ? 'The workout currently in progress will be ended first.\n\n' : ''}'
            'Restoring erases the current data on this phone first, then imports this backup. This cannot be undone.',
      ),
      okLabel: tx('恢复', en: 'Restore'),
    );
    if (!ok || !mounted) return;
    try {
      // 恢复会清空会话表：先结束进行中的训练；quit 预约的快照一并取消。
      if (hadActive) await c.session.quit();
      c.autoBackup.cancelScheduled();
      await c.autoBackup.restore(latest);
      // 备份里的减载/停练标记已写回偏好：内存排除表跟着重灌，
      // 否则本进程内统计回溯仍用恢复前的旧标记。
      c.session.reloadDeloadMarkers();
    } catch (_) {
      if (mounted) {
        toast(
          context,
          hadActive
              ? tx('恢复失败：进行中的训练已结束，其余数据未改动',
                  en: 'Restore failed: the in-progress workout was ended; other data was not changed')
              : tx('恢复失败：自动备份可能不完整，数据未改动',
                  en: 'Restore failed: the auto backup may be incomplete; no data was changed'),
        );
      }
      return;
    }
    var reloadFailed = false;
    try {
      await c.planRepo.reload();
    } catch (_) {
      // 数据已恢复，只是计划缓存刷新失败；提示用户重开应用刷一下。
      reloadFailed = true;
    }
    if (mounted) {
      toast(
        context,
        reloadFailed
            ? tx('已从自动备份恢复 ${preview.sessions} 次训练记录 ✓（计划刷新失败，请重开应用）',
                en: 'Restored ${preview.sessions} workouts from auto backup ✓ (plan refresh failed; please reopen the app)')
            : tx('已从自动备份恢复 ${preview.sessions} 次训练记录 ✓',
                en: 'Restored ${preview.sessions} workouts from auto backup ✓'),
      );
      _reloadBackups();
    }
  }

  static String _fmtBackupTime(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  /// 从 JSON 存档恢复：先清空再导入（恢复 = 回到备份时点）。
  /// 备份内容走剪贴板（分享出去的 .json 文件打开后全选复制即可）。
  Future<void> _restoreFromJson(BuildContext context, AppContainer c) async {
    final ok = await confirmDialog(
      context,
      tx('从 JSON 存档恢复？', en: 'Restore from JSON archive?'),
      tx(
        '手机上的现有数据会先清空，再导入备份内容。\n\n'
        '步骤：先打开之前导出的 JSON 存档文件，全选复制全部内容到剪贴板，再回来点「恢复」。此操作无法撤销。',
        en: 'Existing data on this phone will be erased first, then the backup will be imported.\n\n'
            'Steps: open the previously exported JSON archive file, select all and copy its contents to the clipboard, then come back and tap "Restore". This cannot be undone.',
      ),
      okLabel: tx('恢复', en: 'Restore'),
    );
    if (!ok || !context.mounted) return;
    final clip = await Clipboard.getData('text/plain');
    final text = (clip?.text ?? '').trim();
    if (!context.mounted) return;
    if (text.isEmpty) {
      toast(context,
          tx('剪贴板是空的：请先复制 JSON 存档的全部内容',
              en: 'Clipboard is empty: copy the entire JSON archive first'));
      return;
    }
    dynamic data;
    try {
      data = jsonDecode(text);
    } catch (_) {
      toast(context,
          tx('恢复失败：剪贴板内容不是有效的 JSON',
              en: 'Restore failed: clipboard content is not valid JSON'));
      return;
    }
    if (data is! Map<String, dynamic>) {
      toast(context,
          tx('恢复失败：内容不是本应用导出的备份格式',
              en: 'Restore failed: this is not a backup exported by this app'));
      return;
    }
    try {
      // 恢复前先结束进行中的训练（恢复会清空会话表）
      if (c.session.hasActive) await c.session.quit();
      final n = await c.export.restoreFromJson(data);
      // 备份里的减载/停练标记已写回偏好：内存排除表跟着重灌。
      c.session.reloadDeloadMarkers();
      await c.planRepo.reload();
      if (context.mounted) {
        toast(context,
            tx('已恢复 $n 次训练记录 ✓', en: 'Restored $n workout records ✓'));
      }
    } on FormatException catch (e) {
      if (context.mounted) {
        toast(context,
            tx('恢复失败：${e.message}', en: 'Restore failed: ${e.message}'));
      }
    } catch (_) {
      if (context.mounted) {
        toast(context,
            tx('恢复失败：存档可能不完整，数据未改动',
                en: 'Restore failed: the archive may be incomplete; no data was changed'));
      }
    }
  }
}
