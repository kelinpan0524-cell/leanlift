import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/engine.dart' show fmtDate, validateBodyMetric;
import '../l10n/lang.dart';
import '../models/models.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 开练前顺手记体重（2026-10 开场设置）：「开始训练」点下后、会话创建前
/// 弹的底部面板（训练中 UI 禁弹窗——本面板只在开练前出现，不碰红线）。
/// 返回 true = 继续开练（「保存并开始」或「跳过」）；null = 滑掉/返回 =
/// 取消，与开练前编辑页的取消语义一致：不开练（今天已问过，重试不再弹）。
Future<bool?> showWeightPromptSheet(
  BuildContext context, {
  required double? presetKg,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.card,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => _WeightPromptSheet(presetKg: presetKg),
  );
}

class _WeightPromptSheet extends StatefulWidget {
  const _WeightPromptSheet({required this.presetKg});

  /// 预填体重：上次 BodyMetric 记录 > 设置里的体重字段 > 空（调用方算好传入）。
  final double? presetKg;

  @override
  State<_WeightPromptSheet> createState() => _WeightPromptSheetState();
}

class _WeightPromptSheetState extends State<_WeightPromptSheet> {
  late final _weightCtrl = TextEditingController(
      text: widget.presetKg == null ? '' : _fmt(widget.presetKg!));

  /// 与设置页体重行同款显示：整数不带小数点，小数保留一位。
  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  @override
  void dispose() {
    _weightCtrl.dispose();
    super.dispose();
  }

  /// 保存今天的体重：BodyMetric 按天 upsert + 同步设置里的体重字段
  ///（自重容量折算与趋势图共用数据源）。成功后关闭并放行开练。
  Future<void> _saveAndStart() async {
    final w = double.tryParse(_weightCtrl.text.trim());
    if (w == null) {
      toast(context,
          tx('填个体重，或点「跳过」直接开练', en: 'Enter a weight, or tap Skip to start'));
      return;
    }
    // 防呆区间（wger 口径，同数据页）：超界直接拦，防手滑多敲一位
    final err = validateBodyMetric(weightKg: w);
    if (err != null) {
      toast(context, err);
      return;
    }
    HapticFeedback.selectionClick();
    final c = app(context);
    await c.db.upsertBodyMetric(
        BodyMetric(date: fmtDate(DateTime.now()), weightKg: w));
    c.settings.bodyWeightKg = w;
    await c.settings.save();
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tx('开练前记个体重', en: 'Quick weigh-in'),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
              tx('趁还没开练顺手记一条，体重趋势才连得上（不记也可以）',
                  en: 'Log it now so your trend stays connected — or skip it'),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12)),
          const SizedBox(height: 14),
          TextField(
            controller: _weightCtrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d{1,3}(\.\d?)?')),
            ],
            decoration: InputDecoration(
              labelText: tx('体重 (kg)', en: 'Body Weight (kg)'),
            ),
          ),
          const SizedBox(height: 16),
          // 拇指区双按钮：主操作「保存并开始」+ 低调出口「跳过」
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, true), // 跳过=照常开练
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                  child: Text(tx('跳过', en: 'Skip')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: _saveAndStart,
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                  child: Text(tx('保存并开始', en: 'Save & Start')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
