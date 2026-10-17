import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../l10n/lang.dart';
import '../services/heart_rate_service.dart';
import '../services/settings.dart';
import 'heart_rate_page.dart';
import 'local_bridge_page.dart';
import 'settings_subpages.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 设置主页：系统设置式分组行 + 子页面（2026-09-26 Arono 需求：
/// 旧版把全部配置铺一页要一直滑，改为「一屏看全入口，点进对应子页」——
/// 行首图标 + 标题 + 当前状态摘要 + 箭头，查找靠扫一眼分组行，不靠滚动）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = app(context);
    final s = c.settings;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _group(tx('通用', en: 'General'), [
          _langRow(context, s),
        ]),
        const SizedBox(height: 20),
        _group(tx('训练', en: 'Training'), [
          _SettingsRow(
            icon: Icons.fitness_center,
            title: tx('训练偏好', en: 'Training Preferences'),
            subtitle: tx('组间休息 · 震动 · 提示音 · 体重折算',
                en: 'Rest · Vibration · Cues · Body weight'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TrainingPrefsPage()),
            ),
          ),
          _SettingsRow(
            icon: Icons.visibility_off_outlined,
            title: tx('专注模式', en: 'Focus Mode'),
            subtitle: tx('训练中切到分心 App 会提醒', en: 'Alerts when you open distracting apps mid-workout'),
            value: s.distractingAppsList.isEmpty
                ? tx('未选择', en: 'None')
                : tx('已选 ${s.distractingAppsList.length} 个', en: '${s.distractingAppsList.length} selected'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const FocusSubPage()),
            ),
          ),
          // 心率设备（2026-10-17）：BLE 标准心率服务直连，记忆设备
          // 训练开始自动重连；value 展示连接态（绿 = 已连接）。
          ListenableBuilder(
            listenable: c.hr,
            builder: (context, _) => _SettingsRow(
              icon: Icons.monitor_heart_outlined,
              iconColor: AppTheme.danger,
              title: tx('心率设备', en: 'Heart Rate Device'),
              subtitle: tx('蓝牙手环实时心率 · 休息时显示 · 练后曲线与解析',
                  en: 'Live HR over BLE · rest display · curve & AI analysis'),
              value: c.hr.savedName ?? tx('未设置', en: 'Not set'),
              valueColor:
                  c.hr.link == HrLink.connected ? AppTheme.primary : null,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HeartRatePage()),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 20),
        _group(tx('连接与智能', en: 'Connections'), [
          _SettingsRow(
            icon: Icons.smart_toy_outlined,
            iconColor: AppTheme.violetSoft, // 紫=AI（全 App 统一）
            title: tx('AI 教练', en: 'AI Coach'),
            subtitle: tx('对话排计划 · 阶段复盘 · 计划拆解',
                en: 'Chat to plan · Phase review · Plan breakdown'),
            value: s.aiConfigured
                ? tx('已配置 ✓', en: 'Configured ✓')
                : tx('未配置', en: 'Not set'),
            valueColor: s.aiConfigured ? AppTheme.primary : AppTheme.warn,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AiSettingsPage()),
            ),
          ),
          ListenableBuilder(
            listenable: app(context).bridge,
            builder: (context, _) => _SettingsRow(
              icon: Icons.lan_outlined,
              title: tx('局域网连接', en: 'LAN Connection'),
              subtitle: tx('手机当只读数据源，电脑上的 AI 通过 MCP 读取',
                  en: 'Phone as a read-only source for an AI on your computer'),
              value: app(context).bridge.running
                  ? tx('已开启', en: 'On')
                  : tx('未开启', en: 'Off'),
              valueColor:
                  app(context).bridge.running ? AppTheme.primary : AppTheme.textDim,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LocalBridgePage()),
              ),
            ),
          ),
          ListenableBuilder(
            listenable: s,
            builder: (context, _) => _SettingsRow(
              icon: Icons.calendar_month_outlined,
              title: tx('飞书日历', en: 'Feishu Calendar'),
              subtitle: tx('训练日自动写入飞书日历', en: 'Write workout days to Feishu Calendar'),
              value: s.larkEnabled ? tx('已启用', en: 'On') : tx('未启用', en: 'Off'),
              valueColor: s.larkEnabled ? AppTheme.primary : null,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LarkSettingsPage()),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 20),
        _group(tx('系统', en: 'System'), [
          _SettingsRow(
            icon: Icons.admin_panel_settings_outlined,
            title: tx('权限', en: 'Permissions'),
            subtitle: tx('通知 · 勿扰 · 分心提醒 · 闹钟 · 电池',
                en: 'Notifications · DND · Usage · Alarm · Battery'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PermissionsSubPage()),
            ),
          ),
          ListenableBuilder(
            listenable: s,
            builder: (context, _) => _SettingsRow(
              icon: Icons.system_update_outlined,
              title: tx('应用更新', en: 'App Update'),
              subtitle: tx('当前版本', en: 'Version'),
              subtitleWidget: FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snap) => Text(
                  snap.hasData
                      ? tx('当前 v${snap.data!.version}', en: 'Current v${snap.data!.version}')
                      : tx('当前版本', en: 'Version'),
                  style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
                ),
              ),
              badge: s.pendingUpdate != null,
              badgeLabel: tx('有新版', en: 'New'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const UpdateSettingsPage()),
              ),
            ),
          ),
          _SettingsRow(
            icon: Icons.backup_outlined,
            title: tx('数据与备份', en: 'Data & Backup'),
            subtitle: tx('导出 CSV/JSON · 恢复 · 清空',
                en: 'Export CSV/JSON · Restore · Delete'),
            badge: Settings.backupNeedsAttention(s.lastExportJsonAt),
            badgeLabel: tx('建议备份', en: 'Backup'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DataBackupPage()),
            ),
          ),
        ]),
        const SizedBox(height: 28),
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snap) => Column(
            children: [
              Text(
                snap.hasData
                    ? tx('薄肌训练计时器 v${snap.data!.version}',
                        en: 'Baoji Workout Timer v${snap.data!.version}')
                    : tx('薄肌训练计时器', en: 'Baoji Workout Timer'),
                style: const TextStyle(
                    color: AppTheme.textDim,
                    fontSize: 12,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                tx('本地优先 · 无服务器 · 数据不出手机',
                    en: 'Local-first · serverless · your data never leaves the phone'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 分组：小标题 + 卡片行（行间以缩进分隔线隔开，系统设置样式）。
  Widget _group(String title, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(title,
              style: const TextStyle(
                  color: AppTheme.textDim,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
        ),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                rows[i],
                if (i < rows.length - 1)
                  const Divider(
                      height: 1, thickness: 1, color: AppTheme.cardHi, indent: 58),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 语言行：不进子页，行尾显示当前值，点按弹三选一底部弹层。
  Widget _langRow(BuildContext context, Settings s) {
    return _SettingsRow(
      icon: Icons.language,
      title: tx('语言', en: 'Language'),
      subtitle: tx('界面、通知与建议的显示语言',
          en: 'Display language for interface, notifications and advice'),
      value: _langLabel(s),
      onTap: () => _pickLanguage(context, s),
    );
  }

  /// 语言偏好的展示名（含"跟随系统"当前解析结果，让默认行为可见）。
  String _langLabel(Settings s) {
    switch (s.langPref) {
      case LangPref.zh:
        return '中文';
      case LangPref.en:
        return 'English';
      case LangPref.system:
        return s.resolvedLang == 'en'
            ? tx('跟随系统（English）', en: 'Auto (English)')
            : tx('跟随系统（中文）', en: 'Auto (Chinese)');
    }
  }

  /// 语言选择底部弹层：三选一，当前项打勾；点选即生效并关闭。
  Future<void> _pickLanguage(BuildContext context, Settings s) async {
    final chosen = await showModalBottomSheet<LangPref>(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  Text(tx('语言', en: 'Language'),
                      style: const TextStyle(
                          color: AppTheme.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            _langOption(
              sheetCtx,
              s,
              value: LangPref.system,
              title: tx('跟随系统', en: 'Follow system'),
              subtitle: s.resolvedLang == 'en'
                  ? tx('手机系统是英文，当前显示 English', en: 'System is English — showing English now')
                  : tx('手机系统是中文，当前显示中文', en: 'System is Chinese — showing Chinese now'),
            ),
            _langOption(sheetCtx, s,
                value: LangPref.zh,
                title: '中文',
                subtitle: tx('界面、通知与建议全部使用中文', en: 'Interface, notifications and advice in Chinese')),
            _langOption(sheetCtx, s,
                value: LangPref.en,
                title: 'English',
                subtitle: tx('界面、通知与建议全部使用英文', en: 'Interface, notifications and advice in English')),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen == null || chosen == s.langPref) return;
    s.set(() => s.langPref = chosen);
    await s.save();
  }

  Widget _langOption(
    BuildContext sheetCtx,
    Settings s, {
    required LangPref value,
    required String title,
    required String subtitle,
  }) {
    final selected = s.langPref == value;
    return ListTile(
      title: Text(title, style: const TextStyle(color: AppTheme.text)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: AppTheme.textDim, fontSize: 12)),
      trailing:
          selected ? const Icon(Icons.check, color: AppTheme.primary) : null,
      onTap: () => Navigator.pop(sheetCtx, value),
    );
  }
}

/// 设置主页的一行：图标块 + 标题/副标题 + 当前值 + 箭头（可挂角标）。
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.subtitleWidget,
    this.value,
    this.valueColor,
    this.iconColor,
    this.badge = false,
    this.badgeLabel,
  });

  final IconData icon;
  final String title;

  /// 副标题文案（大多数行用一句静态文案）。
  final String subtitle;

  /// 副标题需要动态构建时（如应用更新行的版本号 FutureBuilder）用它覆盖。
  final Widget? subtitleWidget;
  final VoidCallback onTap;
  final String? value;
  final Color? valueColor;

  /// 图标与图标底色（缺省用主题绿；AI 行传紫，"紫=智能"全 App 统一）。
  final Color? iconColor;
  final bool badge;
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: (iconColor ?? AppTheme.primary).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 20, color: iconColor ?? AppTheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: AppTheme.text,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 1),
                  // merge 而非裸替换：裸 DefaultTextStyle 会把字体家族一并清空
                  // （子文本脱离主题字体链），merge 只叠加颜色/字号，家族照常继承
                  DefaultTextStyle.merge(
                    style: const TextStyle(
                        color: AppTheme.textDim,
                        fontSize: 12,
                        height: 1.3),
                    child: subtitleWidget ?? Text(subtitle),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 裸 Text 不用 Flexible：Flexible 会和左边的 Expanded 平分宽度，
            // 把标题/副标题挤到一半宽折行（「Feishu Calendar」窄屏折两行）
            if (value != null)
              Text(value!,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                      color: valueColor ?? AppTheme.textDim, fontSize: 13)),
            const SizedBox(width: 4),
            Badge(
              isLabelVisible: badge,
              label: badgeLabel == null
                  ? null
                  : Text(badgeLabel!,
                      style: const TextStyle(fontSize: 9, height: 1)),
              child: const Icon(Icons.chevron_right,
                  color: AppTheme.textDim, size: 22),
            ),
          ],
        ),
      ),
    );
  }
}
