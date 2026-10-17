import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../db/db.dart';
import '../engine/engine.dart';
import '../l10n/lang.dart';
import '../services/ai_service.dart';
import '../services/heart_rate_service.dart';
import '../services/settings.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 休息页简约心率小标（2026-10-17 Arono 拍板：只进休息页、不进训练
/// 主界面——三要素红线不破，心率是第四类信息，只在"等待"时可见）。
/// 已连接才出现：♥ + 当前 bpm，点按进设备管理页；未连接零占位。
class HrRestChip extends StatelessWidget {
  const HrRestChip({super.key});

  @override
  Widget build(BuildContext context) {
    final hr = app(context).hr;
    return ListenableBuilder(
      listenable: hr,
      builder: (context, _) {
        if (hr.link != HrLink.connected) return const SizedBox.shrink();
        final bpm = hr.bpm;
        return GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const HeartRatePage()),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.cardHi,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.favorite, size: 13, color: AppTheme.danger),
                const SizedBox(width: 5),
                Text(
                  bpm == null ? '--' : '$bpm',
                  style: const TextStyle(
                    color: AppTheme.textDim,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 2),
                Text(
                  tx('bpm', en: 'bpm'),
                  style: const TextStyle(
                      color: AppTheme.textDim, fontSize: 11),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 心率设备管理页：状态卡 + 扫描配对 + 忘记设备 + 提示文案。
class HeartRatePage extends StatefulWidget {
  const HeartRatePage({super.key});

  @override
  State<HeartRatePage> createState() => _HeartRatePageState();
}

class _HeartRatePageState extends State<HeartRatePage> {
  String _statusText(HrLink link) => switch (link) {
        HrLink.idle => tx('未连接', en: 'Disconnected'),
        HrLink.scanning => tx('扫描中…', en: 'Scanning…'),
        HrLink.connecting => tx('连接中…', en: 'Connecting…'),
        HrLink.connected => tx('已连接', en: 'Connected'),
      };

  @override
  Widget build(BuildContext context) {
    final c = app(context);
    final hr = c.hr;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: Text(tx('心率设备', en: 'Heart Rate Device')),
      ),
      body: ListenableBuilder(
        listenable: hr,
        builder: (context, _) {
          final connected = hr.link == HrLink.connected;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 状态卡
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.monitor_heart_outlined,
                          size: 20,
                          color: connected ? AppTheme.danger : AppTheme.textDim,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _statusText(hr.link),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                        const Spacer(),
                        if (hr.savedName != null)
                          Flexible(
                            child: Text(
                              hr.savedName!,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: AppTheme.textDim, fontSize: 13),
                            ),
                          ),
                      ],
                    ),
                    if (connected && hr.bpm != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            '${hr.bpm}',
                            style: AppTheme.bigNum(48, color: AppTheme.danger),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            tx('bpm', en: 'bpm'),
                            style: const TextStyle(
                                color: AppTheme.textDim, fontSize: 14),
                          ),
                        ],
                      ),
                    ],
                    if (hr.lastError.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        hr.lastError,
                        style: const TextStyle(
                            color: AppTheme.warn, fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 主操作：扫描 / 停止 / 断开
              BigButton(
                label: hr.link == HrLink.scanning
                    ? tx('停止扫描', en: 'Stop Scan')
                    : (connected
                        ? tx('断开连接', en: 'Disconnect')
                        : tx('扫描心率设备', en: 'Scan Devices')),
                height: 64,
                fontSize: 18,
                color: hr.link == HrLink.scanning
                    ? AppTheme.warn
                    : AppTheme.primary,
                onPressed: () {
                  if (hr.link == HrLink.scanning) {
                    hr.stopScan();
                  } else if (connected) {
                    hr.disconnect();
                  } else {
                    hr.startScan();
                  }
                },
              ),
              if (hr.savedId != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.link, size: 18),
                        label: Text(tx('重连已保存设备', en: 'Reconnect')),
                        onPressed: hr.link == HrLink.connecting
                            ? null
                            : () => hr.connectSaved(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.link_off, size: 18),
                        label: Text(tx('忘记设备', en: 'Forget')),
                        onPressed: () => hr.forget(),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              _LoadParamsCard(s: c.settings),
              if (hr.found.isNotEmpty) ...[
                const SizedBox(height: 16),
                SectionCard(
                  title: tx('发现的设备', en: 'Found Devices'),
                  child: Column(
                    children: [
                      for (final r in hr.found)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(_name(r),
                              style: const TextStyle(fontSize: 15)),
                          subtitle: Text(r.device.remoteId.str,
                              style: const TextStyle(
                                  color: AppTheme.textDim, fontSize: 12)),
                          trailing: Text(
                            '${r.rssi} dBm',
                            style: const TextStyle(
                                color: AppTheme.textDim, fontSize: 12),
                          ),
                          onTap: () => hr.connectResult(r),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                tx(
                  '· WHOOP 默认开放标准心率服务，零设置直读；小米/华米等手环需在官方 App 里开启「心率广播」\n'
                  '· 走标准蓝牙心率协议（0x180D），无需配对，官方 App 同时读也不冲突\n'
                  '· 开始训练时自动连接已保存的设备；组间休息时页面上会显示实时心率，结束后生成心率曲线\n'
                  '· Android 12+ 需要「附近的设备」权限，旧系统需要定位权限（仅用于扫描，不记录位置）',
                  en:
                      '· WHOOP broadcasts standard heart rate by default — no setup needed; Xiaomi/Amazfit bands need "Heart Rate Broadcast" enabled in their app\n'
                      '· Standard Bluetooth Heart Rate profile (0x180D) — no pairing needed, official apps can read at the same time\n'
                      '· Auto-connects at workout start; live HR shows on the rest page and a curve is saved after the session\n'
                      '· Android 12+ needs Nearby Devices; older versions need Location (for scanning only, never recorded)',
                ),
                style: const TextStyle(
                    color: AppTheme.textDim, fontSize: 13, height: 1.6),
              ),
            ],
          );
        },
      ),
    );
  }

  String _name(ScanResult r) {
    final n = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : r.device.platformName;
    return n.isNotEmpty ? n : r.device.remoteId.str;
  }
}

// ================= 心率曲线（总结页 / 历史详情共用） =================

/// 单条曲线块（不带卡片壳）：均值/峰值行 + LineChart。
/// x 轴 = 开练起第几分钟，y 轴 = bpm；<2 个采样不渲染（调用方过滤）。
class HrChartBlock extends StatelessWidget {
  const HrChartBlock({super.key, required this.points});

  final List<HrPoint> points;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) return const SizedBox.shrink();
    final sum = summarizeHr(points)!;
    // 循环负荷（Edwards TRIMP）：按设置里的年龄/静息/最大心率估算，
    // 没填年龄用本场实测峰值兜底——有负荷数值才显示这一行。
    final s = app(context).settings;
    final load = computeHrLoad(
      [for (final p in points) (ts: p.ts, bpm: p.bpm)],
      age: s.hrAge,
      hrRest: s.hrRest,
      hrMaxOverride: s.hrMaxOverride,
    );
    final loadLine = load.trimp >= 1 && load.zoneSummary().isNotEmpty
        ? tx('循环负荷 ${load.trimp.round()} · ${load.zoneSummary()}',
            en: 'Cardio Load ${load.trimp.round()} · ${load.zoneSummary()}')
        : '';
    final t0 = points.first.ts;
    final spots = [
      for (final p in points)
        FlSpot((p.ts - t0) / 60000.0, p.bpm.toDouble()),
    ];
    final spanMin = spots.last.x - spots.first.x;
    var lo = spots.map((s) => s.y).reduce(math.min);
    var hi = spots.map((s) => s.y).reduce(math.max);
    lo = (lo / 10).floorToDouble() * 10;
    hi = (hi / 10).ceilToDouble() * 10;
    if (hi - lo < 20) hi = lo + 20;
    final xInterval = spanMin <= 10
        ? 2.0
        : spanMin <= 30
            ? 5.0
            : 10.0;
    final yInterval = hi - lo <= 60 ? 20.0 : 40.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tx('平均 ${sum.avg.round()} bpm · 峰值 ${sum.max} bpm',
              en: 'Avg ${sum.avg.round()} bpm · Peak ${sum.max} bpm'),
          style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
        ),
        if (loadLine.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(loadLine,
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13)),
        ],
        const SizedBox(height: 8),
        SizedBox(
          height: 180,
          child: LineChart(
            LineChartData(
              minX: spots.first.x,
              maxX: spots.last.x,
              minY: lo,
              maxY: hi,
              gridData: FlGridData(
                show: true,
                horizontalInterval: yInterval,
                verticalInterval: xInterval,
                getDrawingHorizontalLine: (v) => const FlLine(
                    color: AppTheme.cardHi, strokeWidth: 1),
                getDrawingVerticalLine: (v) => const FlLine(
                    color: AppTheme.cardHi, strokeWidth: 0),
              ),
              borderData: FlBorderData(show: false),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => AppTheme.cardHi,
                  tooltipPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  getTooltipItems: (spots) => [
                    for (final s in spots)
                      LineTooltipItem(
                        '${_mmss(s.x)}\n${s.y.round()} ${tx('bpm', en: 'bpm')}',
                        const TextStyle(
                            color: AppTheme.text,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                      ),
                  ],
                ),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 22,
                    interval: xInterval,
                    getTitlesWidget: (v, _) => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        tx('${v.toInt()} 分', en: '${v.toInt()}m'),
                        style: const TextStyle(
                            color: AppTheme.textDim, fontSize: 10),
                      ),
                    ),
                  ),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 34,
                    interval: yInterval,
                    getTitlesWidget: (v, _) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        '${v.toInt()}',
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            color: AppTheme.textDim, fontSize: 10),
                      ),
                    ),
                  ),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true,
                  preventCurveOverShooting: true,
                  color: AppTheme.danger,
                  barWidth: 2,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    color: AppTheme.danger.withValues(alpha: 0.10),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _mmss(double minutes) {
    final s = (minutes * 60).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

/// 会话心率卡：FutureBuilder 拉采样 → 曲线卡（总结页带 AI 解析按钮，
/// 历史页纯曲线）。不足 2 个采样（没连设备/老记录）整卡不出现。
class HrSessionCard extends StatelessWidget {
  const HrSessionCard({
    super.key,
    required this.samplesFuture,
    this.aiButton = true,
  });

  final Future<List<HrPoint>> samplesFuture;
  final bool aiButton;

  @override
  Widget build(BuildContext context) {
    final c = app(context);
    return FutureBuilder<List<HrPoint>>(
      future: samplesFuture,
      builder: (context, snap) {
        final pts = snap.data;
        if (pts == null || pts.length < 2) {
          return const SizedBox.shrink();
        }
        return SectionCard(
          title: tx('心率', en: 'Heart Rate'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HrChartBlock(points: pts),
              if (aiButton && c.settings.aiConfigured) ...[
                const SizedBox(height: 12),
                HrAiPanel(points: pts),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// AI 心率解析（2026-10-17）：按需触发不自动、结果不落库——
/// 历史记录随时可重新生成。曲线降采样到 ≤60 点再发，控制 token 量。
class HrAiPanel extends StatefulWidget {
  const HrAiPanel({super.key, required this.points});

  final List<HrPoint> points;

  @override
  State<HrAiPanel> createState() => _HrAiPanelState();
}

class _HrAiPanelState extends State<HrAiPanel> {
  bool _loading = false;
  String? _result;
  String? _error;

  Future<void> _run() async {
    final c = app(context);
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });
    try {
      final pts = downsampleHr(widget.points, 60);
      final durationMin =
          ((widget.points.last.ts - widget.points.first.ts) / 60000).round();
      // 循环负荷随采样一并发给 AI，让解析有量化锚点（不算 token 大头）
      final s = c.settings;
      final load = computeHrLoad(
        [for (final p in widget.points) (ts: p.ts, bpm: p.bpm)],
        age: s.hrAge,
        hrRest: s.hrRest,
        hrMaxOverride: s.hrMaxOverride,
      );
      final loadNote = load.trimp >= 1
          ? '本场循环负荷（Edwards TRIMP）约 ${load.trimp.round()}，区间停留：${load.zoneSummary()}（最大心率按 ${load.hrMaxUsed} / 静息 ${load.hrRestUsed} 估算）'
          : null;
      final reply = await c.ai.chat([
        AiMessage(
            'user',
            buildHrAnalysisPrompt(pts,
                durationMin: durationMin, loadNote: loadNote)),
      ]);
      if (!mounted) return;
      setState(() => _result = reply);
    } on AiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_result == null && !_loading && _error == null)
          OutlinedButton.icon(
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: Text(tx('AI 解析心率', en: 'AI Analyze Heart Rate')),
            onPressed: _run,
          ),
        if (_loading)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(tx('解析中…', en: 'Analyzing…'),
                  style:
                      const TextStyle(color: AppTheme.textDim, fontSize: 13)),
            ],
          ),
        if (_error != null)
          Text(
            _error!,
            style: const TextStyle(color: AppTheme.warn, fontSize: 13),
          ),
        if (_result != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.cardHi,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  _result!,
                  style: const TextStyle(fontSize: 14, height: 1.6),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _loading ? null : _run,
                    child: Text(tx('重新解析', en: 'Re-run')),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 循环负荷参数卡（2026-10-17 Arono：填几个数没关系）：年龄/静息/最大
/// 心率，点行弹数字输入框即改即存，不做表单页。最大心率 0 = 自动
/// （220-年龄，年龄也没填则用本场实测峰值，再兜底 190）。
class _LoadParamsCard extends StatelessWidget {
  const _LoadParamsCard({required this.s});

  final Settings s;

  Future<void> _edit(
    BuildContext context,
    String title,
    int current,
    int lo,
    int hi,
    ValueChanged<int> onSave,
  ) async {
    final ctrl = TextEditingController(text: '$current');
    final v = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(tx('取消', en: 'Cancel'),
                style: const TextStyle(color: AppTheme.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, int.tryParse(ctrl.text)),
            child: Text(tx('保存', en: 'Save'),
                style: const TextStyle(color: AppTheme.primary)),
          ),
        ],
      ),
    );
    if (v == null) return;
    onSave(v < lo ? lo : (v > hi ? hi : v));
  }

  Widget _row(String label, String value, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 15))),
              Text(value,
                  style:
                      const TextStyle(color: AppTheme.textDim, fontSize: 14)),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 18, color: AppTheme.textDim),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    void save() => unawaited(s.save());
    return SectionCard(
      title: tx('循环负荷参数', en: 'Cardio Load Parameters'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(
            tx('年龄', en: 'Age'),
            s.hrAge > 0
                ? '${s.hrAge} ${tx('岁', en: 'yrs')}'
                : tx('未填', en: 'Not set'),
            () => _edit(context, tx('年龄', en: 'Age'), s.hrAge, 10, 99,
                (v) {
              s.hrAge = v;
              save();
            }),
          ),
          _row(
            tx('静息心率', en: 'Resting HR'),
            '${s.hrRest} bpm',
            () => _edit(context, tx('静息心率', en: 'Resting HR'), s.hrRest,
                30, 110, (v) {
              s.hrRest = v;
              save();
            }),
          ),
          _row(
            tx('最大心率', en: 'Max HR'),
            s.hrMaxOverride > 0
                ? '${s.hrMaxOverride} bpm'
                : tx('自动（220−年龄）', en: 'Auto (220−age)'),
            () => _edit(
                context,
                tx('最大心率（0 = 自动按 220−年龄）', en: 'Max HR (0 = auto 220−age)'),
                s.hrMaxOverride,
                0,
                250, (v) {
              s.hrMaxOverride = v;
              save();
            }),
          ),
          const SizedBox(height: 6),
          Text(
            tx(
                '用于训练后自动估算循环负荷（Edwards TRIMP，按心率区间加权）；年龄不填按 190 估最大心率。',
                en: 'Estimates post-workout cardio load (Edwards TRIMP, zone-weighted); max HR defaults to 190 without age.'),
            style: const TextStyle(
                color: AppTheme.textDim, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }
}
