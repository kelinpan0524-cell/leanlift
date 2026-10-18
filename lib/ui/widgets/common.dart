import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app.dart';
import '../../engine/muscle_insights.dart';
import '../../engine/weight_unit.dart';
import '../../l10n/lang.dart';
import '../theme.dart';

/// 通用小组件。

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.title,
    this.icon,
    this.iconColor,
    this.trailing,
    this.padding,
    this.onLongPress,
    this.semanticsLabel,
    this.longPressHint,
  });

  final Widget child;
  final String? title;

  /// 标题前的小图标（可选）：统计页统一用带色块的小图标建立卡片识别，
  /// 长页面里纯文字标题的扫读成本高。
  final IconData? icon;
  final Color? iconColor;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onLongPress;

  /// 读屏语义（调研条目 5/历史页 P1-12 长按删除的替代路径）：
  /// TalkBack 下长按手势难触发，"双击并按住"提示 + 完整朗读标签补足。
  final String? semanticsLabel;
  final String? longPressHint;

  @override
  Widget build(BuildContext context) {
    final card = Card(
      child: Padding(
        padding: padding ?? const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null)
              Row(
                children: [
                  if (icon != null) ...[
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: (iconColor ?? AppTheme.primary)
                            .withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon,
                          size: 16, color: iconColor ?? AppTheme.primary),
                    ),
                    const SizedBox(width: 10),
                  ],
                  // Expanded：标题吃满除 trailing 外的宽度；系统大字号下长标题
                  // 允许换行，不会把 Row 顶出横向溢出。不能用 Flexible+Spacer——
                  // 两者都是弹性子项会平分剩余空间，长英文标题被硬限一半宽度
                  // 折成两行（「Last Workout」「Rest Between Sets Trend」，
                  // 2026-09-28 审查）
                  Expanded(
                    child: Text(
                      title!,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.text,
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            if (title != null) const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
    // 长按删除等场景（历史页训练卡）
    if (onLongPress == null) return card;
    return Semantics(
      label: semanticsLabel,
      onLongPressHint: longPressHint,
      onLongPress: onLongPress,
      child: InkWell(onLongPress: onLongPress, child: card),
    );
  }
}

/// 训练页超大按钮（≥88dp）。
class BigButton extends StatelessWidget {
  const BigButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.color = AppTheme.primary,
    this.height = 88,
    this.fontSize = 24,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final double height;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      // 主色光晕只给可用态：禁用/进行中变灰时无光，光晕本身就是"可按"的信号
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow:
              onPressed == null ? null : AppTheme.glow(color, alpha: 0.25),
        ),
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: color,
            foregroundColor: const Color(0xFF06220F),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          child: FittedBox(
            // 大字体缩放下长标签放不下：整体等比缩小而不是折行
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ),
    );
  }
}

/// 重量步进大按钮。
class WeightStepButton extends StatelessWidget {
  const WeightStepButton({super.key, required this.delta, required this.onTap});

  final double delta;
  final VoidCallback onTap;

  String get label =>
      '${delta > 0 ? '+' : '-'}${delta.abs() == delta.abs().roundToDouble() ? delta.abs().toStringAsFixed(0) : delta.abs().toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')}';

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: SizedBox(
          height: 60,
          child: OutlinedButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 60),
              backgroundColor: AppTheme.cardHi,
              side: BorderSide.none,
              padding: EdgeInsets.zero,
            ),
            child: FittedBox(
              // 大字体缩放下标签放不下：整体等比缩小而不是折行
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String fmtKg(double v) => v == v.roundToDouble()
    ? v.toStringAsFixed(0)
    : v
          .toStringAsFixed(2)
          .replaceAll(RegExp(r'0+$'), '')
          .replaceAll(RegExp(r'\.$'), '');

/// 当前单位下的重量数值（不带后缀，2026-10-17 单位支持）：
/// kg 模式与 fmtKg 同值；lb 模式换算并 snap 到 0.5lb 网格。
String fmtKgDisp(double kg) => fmtVal(kg);

/// 「数值+单位」串（100kg / 220.5lb）：统一替换各处 `${fmtKg(x)}kg` 拼接。
String fmtWt(double kg) => fmtWithUnit(kg);

/// 自重动作（0kg）显示"自重"而不是"0"。
String fmtWeight(double v) =>
    v <= 0 ? tx('自重', en: 'Bodyweight') : fmtKgDisp(v);

/// 训练页重量口径（不带单位后缀，2026-10-17 单位支持）：
/// 负值 = 辅助器械配重（辅30 = 辅助 30kg，配重越大越轻），
/// 0 = 自重，正值 = 常规负重；数值按当前单位换算显示。
String fmtLoad(double v) {
  if (v < 0) return tx('辅 ${fmtKgDisp(-v)}', en: 'Assist ${fmtKgDisp(-v)}');
  if (v == 0) return tx('自重', en: 'Bodyweight');
  return fmtKgDisp(v);
}

/// 同 [fmtLoad] 但非零值自带单位后缀（辅 30kg / 自重 / 220.5lb），
/// 供行内文案使用（大数字旁另有单位标签，用 [fmtLoad] 免重复）。
String fmtLoadU(double v) {
  if (v < 0) return tx('辅 ${fmtWt(-v)}', en: 'Assist ${fmtWt(-v)}');
  if (v == 0) return tx('自重', en: 'Bodyweight');
  return fmtWt(v);
}

String fmtDuration(int totalSeconds) {
  final m = totalSeconds ~/ 60;
  final s = totalSeconds % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String fmtVolume(double v) {
  // 吨是公制口径、与显示单位无关；小容量在 lb 模式按整数 lb 显示。
  if (v >= 10000) return '${(v / 1000).toStringAsFixed(1)}t';
  if (WeightUnits.isLb) return '${kgToLb(v).round()}lb';
  return '${v.toStringAsFixed(0)}kg';
}

/// App 级确认弹窗（非训练页使用）。
/// [okLabel] 缺省时按当前语言显示「确认/Confirm」
/// （默认参数须为编译期常量，故声明为可空、在函数体内回落）。
Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String content, {
  String? okLabel,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      backgroundColor: AppTheme.card,
      title: Text(title),
      content: Text(content, style: const TextStyle(color: AppTheme.textDim)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: Text(tx('取消', en: 'Cancel'),
              style: const TextStyle(color: AppTheme.textDim)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child: Text(okLabel ?? tx('确认', en: 'Confirm'),
              style: const TextStyle(color: AppTheme.danger)),
        ),
      ],
    ),
  );
  return r == true;
}

/// 通用轻提示。
void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      // 抬高到底部导航/常驻按钮之上，避免遮挡可点区域
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 100),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// 读取容器快捷方式。
AppContainer app(BuildContext context) => AppScope.of(context);

/// 每周组数展示：整数不带小数点，半组保留一位（3 / 3.5）。
/// 数据页肌肉 tab 与计划编辑页命中预览共用，保证两处数字格式一致。
/// 循环折算会产生 13.999999999999998 这类浮点尾差，先按 1e-9 归整，
/// 否则本该显示「14」的组数会显示成「14.0」。
String fmtSetDose(double sets) {
  final rounded = sets.roundToDouble();
  return (sets - rounded).abs() < 1e-9
      ? rounded.toStringAsFixed(0)
      : sets.toStringAsFixed(1);
}

/// 每周组数目标状态文案（P1-B 剂量口径，两处共用）。
String weeklySetStatusText(WeeklySetStatus status) => switch (status) {
      WeeklySetStatus.low => tx('不足', en: 'Below target'),
      WeeklySetStatus.onTarget => tx('达标', en: 'On target'),
      WeeklySetStatus.high => tx('过量', en: 'Above target'),
    };

/// 每周组数目标状态配色：不足=警示黄、达标=主绿、过量=红。
Color weeklySetStatusColor(WeeklySetStatus status) => switch (status) {
      WeeklySetStatus.low => AppTheme.warn,
      WeeklySetStatus.onTarget => AppTheme.primary,
      WeeklySetStatus.high => AppTheme.danger,
    };
