import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../db/db.dart';
import '../engine/engine.dart';
import '../engine/weight_unit.dart';
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
        final reconnecting = hr.link == HrLink.reconnecting;
        if (hr.link != HrLink.connected && !reconnecting) {
          return const SizedBox.shrink();
        }
        final bpm = hr.bpm;
        return GestureDetector(
          key: const Key('hrRestChip'),
          onTap: () => showHrRestSheet(context),
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
                  reconnecting
                      ? tx('重连中…', en: 'Reconnecting…')
                      : (bpm == null ? '--' : '$bpm'),
                  style: const TextStyle(
                    color: AppTheme.textDim,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (!reconnecting) ...[
                  const SizedBox(width: 2),
                  Text(
                    tx('bpm', en: 'bpm'),
                    style: const TextStyle(
                        color: AppTheme.textDim, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 休息页点心率：本次消耗速览（2026-10-18 Arono）。
/// 用户主动唤起的底部面板（与「直接输入重量」同一先例，不算打断训练）：
/// 大字卡路里（训练中 + 练后 EPOC 拆分）、平均/峰值、循环负荷，
/// 「查看心率曲线」保留原设备管理页入口。数据来自本场的实时采样缓冲
/// （hr.samples，落库仍按 v13 在会话结束一次性写入）。
Future<void> showHrRestSheet(BuildContext context) async {
  final c = app(context);
  final hr = c.hr;
  final st = c.settings;
  final points = hr.samples;
  final sum = summarizeHr(points);
  final load = computeHrLoad(
    [for (final p in points) (ts: p.ts, bpm: p.bpm)],
    age: st.hrAge,
    hrRest: st.hrRest,
    hrMaxOverride: st.hrMaxOverride,
  );
  final cal = computeHrCalories(
    [for (final p in points) (ts: p.ts, bpm: p.bpm)],
    bodyWeightKg: st.bodyWeightKg,
    age: st.hrAge,
    sex: HrSex.values[st.hrSex.clamp(0, HrSex.values.length - 1)],
    z4Sec: load.zoneSec[3],
    z5Sec: load.zoneSec[4],
  );
  final minutes = points.isEmpty
      ? 0
      : ((points.last.ts - points.first.ts) / 60000).round();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.favorite, size: 15, color: AppTheme.danger),
                const SizedBox(width: 6),
                Text(
                  tx('本次训练消耗', en: 'Session Burn'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  hr.bpm == null ? '-- bpm' : '${hr.bpm} bpm',
                  style: const TextStyle(
                      color: AppTheme.textDim,
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (points.isEmpty || sum == null) ...[
              Text(
                tx('还没有采到心率数据：确认心率带已戴上、连接正常，\n下一组休息时再点开看。',
                    en: 'No heart-rate samples yet: wear the strap and stay\nconnected, then tap again during your next rest.'),
                style:
                    const TextStyle(color: AppTheme.textDim, fontSize: 13.5),
              ),
            ] else ...[
              Text(
                tx('约 ${cal.totalKcal.round()} 千卡',
                    en: '~${cal.totalKcal.round()} kcal'),
                style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary,
                    fontFeatures: [FontFeature.tabularFigures()]),
              ),
              const SizedBox(height: 6),
              Text(
                tx('训练中 ${cal.activeKcal.round()} · 练后恢复 +${cal.epocKcal.round()}',
                    en: 'In-session ${cal.activeKcal.round()} · afterburn +${cal.epocKcal.round()}'),
                style:
                    const TextStyle(color: AppTheme.textDim, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Text(
                tx('平均 ${sum.avg.round()} bpm · 峰值 ${sum.max} bpm · 已记录 $minutes 分钟',
                    en: 'Avg ${sum.avg.round()} bpm · peak ${sum.max} bpm · $minutes min logged'),
                style:
                    const TextStyle(color: AppTheme.textDim, fontSize: 13),
              ),
              if (load.trimp >= 1) ...[
                const SizedBox(height: 4),
                Text(
                  tx('循环负荷 ${load.trimp.round()} · ${load.zoneSummary()}',
                      en: 'Cardio Load ${load.trimp.round()} · ${load.zoneSummary()}'),
                  style: const TextStyle(
                      color: AppTheme.textDim, fontSize: 13),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                tx('按心率估算（Keytel 方程 + 力量训练修正口径），仅供参考。',
                    en: 'Estimated from heart rate (Keytel equation with\nresistance-training correction). For reference only.'),
                style: const TextStyle(
                    color: AppTheme.textDim,
                    fontSize: 11.5,
                    height: 1.35),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('hrSheetOpenCurve'),
                icon: const Icon(Icons.show_chart, size: 18),
                label: Text(tx('查看心率曲线', en: 'View heart-rate curve')),
                onPressed: () {
                  Navigator.of(sheetCtx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HeartRatePage()),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
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
        HrLink.reconnecting => tx('重连中…', en: 'Reconnecting…'),
        HrLink.connected => tx('已连接', en: 'Connected'),
      };

  /// 扫描放到独立底部弹层：扫描结果逐条到达时只让弹层内部增长，
  /// 主页面完全不移动（2026-10-17 Arono：连 WHOOP 时页面「漂移」）。
  /// 弹层关闭时兜底停扫，避免后台一直扫。
  Future<void> _openScanSheet() async {
    final hr = app(context).hr;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ScanSheet(hr: hr),
    );
    if (hr.link == HrLink.scanning) unawaited(hr.stopScan());
  }

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
          final connecting = hr.link == HrLink.connecting;
          final reconnecting = hr.link == HrLink.reconnecting;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 状态卡：bpm 行与设备名槽位**始终存在**（未连接显示 -- /
              // 未选择设备），连接成功不再凭空多出一行把下方整体推下去
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.035)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: (connected
                                    ? AppTheme.danger
                                    : AppTheme.textDim)
                                .withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.monitor_heart_outlined,
                            size: 22,
                            color: connected
                                ? AppTheme.danger
                                : AppTheme.textDim,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    _statusText(hr.link),
                                    style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w700),
                                  ),
                                  if (hr.link == HrLink.scanning ||
                                      connecting ||
                                      reconnecting) ...[
                                    const SizedBox(width: 8),
                                    const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                hr.savedName ??
                                    tx('未选择设备', en: 'No device selected'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: AppTheme.textDim, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Icon(
                          Icons.favorite,
                          size: 18,
                          color:
                              connected ? AppTheme.danger : AppTheme.textDim,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          hr.bpm?.toString() ?? '--',
                          style: AppTheme.bigNum(44,
                              color: connected && hr.bpm != null
                                  ? AppTheme.danger
                                  : AppTheme.textDim),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          tx('bpm', en: 'bpm'),
                          style: const TextStyle(
                              color: AppTheme.textDim, fontSize: 13),
                        ),
                      ],
                    ),
                    // 错误是偶发信息：动画展开，不瞬间顶开下方内容
                    AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      alignment: Alignment.topCenter,
                      child: hr.lastError.isEmpty
                          ? const SizedBox(width: double.infinity)
                          : Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Padding(
                                    padding: EdgeInsets.only(top: 1),
                                    child: Icon(Icons.error_outline,
                                        size: 14, color: AppTheme.warn),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      hr.lastError,
                                      style: const TextStyle(
                                          color: AppTheme.warn, fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 主操作：扫描（结果在弹层里选）/ 断开
              BigButton(
                label: connected
                    ? tx('断开连接', en: 'Disconnect')
                    : connecting
                        ? tx('连接中…', en: 'Connecting…')
                        : reconnecting
                            ? tx('重连中…', en: 'Reconnecting…')
                            : tx('扫描心率设备', en: 'Scan Devices'),
                height: 64,
                fontSize: 18,
                onPressed: connected
                    ? () => hr.disconnect()
                    : (connecting || reconnecting)
                        ? null
                        : _openScanSheet,
              ),
              const SizedBox(height: 10),
              // 重连/忘记**始终显示**：没有保存设备时置灰。
              // 原实现首次连接成功后整行突然出现，页面高度跳一屏。
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.link, size: 18),
                      label: Text(tx('重连已保存设备', en: 'Reconnect')),
                      onPressed: hr.savedId == null || connecting
                          ? null
                          : () => hr.connectSaved(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.link_off, size: 18),
                      label: Text(tx('忘记设备', en: 'Forget')),
                      onPressed:
                          hr.savedId == null ? null : () => hr.forget(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _LoadParamsCard(s: c.settings),
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
}

/// 扫描弹层：列表在弹层内滚动，高度固定，结果到达不影响主页面布局。
class _ScanSheet extends StatefulWidget {
  const _ScanSheet({required this.hr});

  final HeartRateService hr;

  @override
  State<_ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends State<_ScanSheet> {
  @override
  void initState() {
    super.initState();
    // 弹层先出现再开扫：权限弹窗/蓝牙失败时用户能看到弹层里的状态
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.hr.startScan());
    });
  }

  @override
  Widget build(BuildContext context) {
    final hr = widget.hr;
    return SafeArea(
      child: ListenableBuilder(
        listenable: hr,
        builder: (context, _) {
          final scanning = hr.link == HrLink.scanning;
          final connecting = hr.link == HrLink.connecting;
          final found = hr.found;
          final status = connecting
              ? tx('正在连接…', en: 'Connecting…')
              : scanning
                  ? tx('正在搜索附近的心率设备…', en: 'Searching for nearby HR devices…')
                  : hr.lastError.isNotEmpty
                      ? hr.lastError
                      : found.isEmpty
                          ? tx('没有发现设备，确认手环已开启心率广播后重试',
                              en: 'No devices found — enable heart-rate broadcast and retry')
                          : tx('点选一个设备连接', en: 'Tap a device to connect');
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                        color: AppTheme.textDim.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                Row(
                  children: [
                    Text(tx('选择心率设备', en: 'Choose HR Device'),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tx('取消', en: 'Cancel'),
                          style:
                              const TextStyle(color: AppTheme.textDim)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (scanning || connecting)
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(
                          hr.lastError.isNotEmpty
                              ? Icons.error_outline
                              : Icons.bluetooth_searching,
                          size: 15,
                          color: hr.lastError.isNotEmpty
                              ? AppTheme.warn
                              : AppTheme.textDim,
                        ),
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        status,
                        style: TextStyle(
                            color: hr.lastError.isNotEmpty && !scanning
                                ? AppTheme.warn
                                : AppTheme.textDim,
                            fontSize: 13,
                            height: 1.4),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // 固定高度：结果 0→N 条时只在这里滚动，弹层高度不变
                SizedBox(
                  height: 232,
                  child: found.isEmpty
                      ? Center(
                          child: Icon(Icons.bluetooth_searching,
                              size: 40,
                              color:
                                  AppTheme.textDim.withValues(alpha: 0.5)),
                        )
                      : ListView.separated(
                          padding: EdgeInsets.zero,
                          itemCount: found.length,
                          separatorBuilder: (_, _) => const Divider(
                              height: 1, color: AppTheme.cardHi),
                          itemBuilder: (_, i) {
                            final r = found[i];
                            return ListTile(
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              leading: Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: AppTheme.primary
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: const Icon(Icons.watch_outlined,
                                    size: 18, color: AppTheme.primary),
                              ),
                              title: Text(_name(r),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 15)),
                              subtitle: Text(r.device.remoteId.str,
                                  style: const TextStyle(
                                      color: AppTheme.textDim,
                                      fontSize: 11)),
                              trailing: Text('${r.rssi} dBm',
                                  style: const TextStyle(
                                      color: AppTheme.textDim,
                                      fontSize: 11)),
                              enabled: !connecting,
                              onTap: () async {
                                await hr.connectResult(r);
                                if (context.mounted) {
                                  Navigator.pop(context);
                                }
                              },
                            );
                          },
                        ),
                ),
                const SizedBox(height: 8),
                // 按钮常驻（停止/重新扫描），弹层高度不随扫描结束跳变
                OutlinedButton.icon(
                  icon: Icon(
                      scanning
                          ? Icons.stop_circle_outlined
                          : Icons.refresh,
                      size: 18),
                  label: Text(scanning
                      ? tx('停止扫描', en: 'Stop Scan')
                      : tx('重新扫描', en: 'Scan Again')),
                  onPressed: connecting
                      ? null
                      : () => scanning ? hr.stopScan() : hr.startScan(),
                ),
              ],
            ),
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
    // 卡路里（Keytel 2005 + 力量训练 0.82 修正 + EPOC），参数全部来自
    // 设置；体重/年龄缺省引擎内部兜底，任何情况下都能给数。
    final cal = computeHrCalories(
      [for (final p in points) (ts: p.ts, bpm: p.bpm)],
      bodyWeightKg: s.bodyWeightKg,
      age: s.hrAge,
      sex: HrSex.values[s.hrSex.clamp(0, HrSex.values.length - 1)],
      z4Sec: load.zoneSec[3],
      z5Sec: load.zoneSec[4],
    );
    final kcalLine = cal.totalKcal >= 1
        ? tx('约 ${cal.totalKcal.round()} kcal（练后 +${cal.epocKcal.round()}）',
            en: '~${cal.totalKcal.round()} kcal (+${cal.epocKcal.round()} afterburn)')
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
        if (kcalLine.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(kcalLine,
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
      // 卡路里估算同样给 AI 做锚点（力量训练修正口径）
      final cal = computeHrCalories(
        [for (final p in widget.points) (ts: p.ts, bpm: p.bpm)],
        bodyWeightKg: s.bodyWeightKg,
        age: s.hrAge,
        sex: HrSex.values[s.hrSex.clamp(0, HrSex.values.length - 1)],
        z4Sec: load.zoneSec[3],
        z5Sec: load.zoneSec[4],
      );
      final calorieNote = cal.totalKcal >= 1
          ? '训练消耗估算约 ${cal.totalKcal.round()} kcal（训练中 ${cal.activeKcal.round()} + 练后 EPOC ${cal.epocKcal.round()}，力量训练修正口径，仅供参考）'
          : null;
      final note = [loadNote, calorieNote].whereType<String>().join('\n');
      final reply = await c.ai.chat([
        AiMessage(
            'user',
            buildHrAnalysisPrompt(pts,
                durationMin: durationMin, loadNote: note.isEmpty ? null : note)),
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

  Future<void> _editDouble(BuildContext context, String title, double current,
      double lo, double hi, ValueChanged<double> onSave) async {
    final ctrl = TextEditingController(
        text: current == current.roundToDouble()
            ? current.toStringAsFixed(0)
            : current.toString());
    final v = await showDialog<double>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(tx('取消', en: 'Cancel'),
                style: const TextStyle(color: AppTheme.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, double.tryParse(ctrl.text)),
            child: Text(tx('保存', en: 'Save'),
                style: const TextStyle(color: AppTheme.primary)),
          ),
        ],
      ),
    );
    if (v == null) return;
    onSave(v < lo ? lo : (v > hi ? hi : v));
  }

  Future<void> _editSex(BuildContext context) async {
    const opts = [
      (0, '未设置（按男女均值）', 'Unset (avg of m/f)'),
      (1, '男', 'Male'),
      (2, '女', 'Female'),
    ];
    final v = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        backgroundColor: AppTheme.card,
        title: Text(tx('性别', en: 'Sex')),
        children: [
          for (final o in opts)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, o.$1),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(tx(o.$2, en: o.$3),
                    style: const TextStyle(fontSize: 16)),
              ),
            ),
        ],
      ),
    );
    if (v == null) return;
    s.hrSex = v;
    unawaited(s.save());
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
      title: tx('心率与消耗参数', en: 'HR & Calorie Parameters'),
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
          _row(
            tx('性别', en: 'Sex'),
            switch (s.hrSex) {
              1 => tx('男', en: 'Male'),
              2 => tx('女', en: 'Female'),
              _ => tx('未设置', en: 'Unset'),
            },
            () => _editSex(context),
          ),
          _row(
            tx('体重', en: 'Body Weight'),
            // 单位感知显示（2026-10-17）：存 kg，显示随当前单位换算
            fmtWt(s.bodyWeightKg),
            () {
              final lb = WeightUnits.isLb;
              _editDouble(
                  context,
                  tx('体重 (${unitLabel()})',
                      en: 'Body weight (${unitLabel()})'),
                  lb ? lbSnap(kgToLb(s.bodyWeightKg)) : s.bodyWeightKg,
                  lb ? 66.0 : 30.0,
                  lb ? 551.0 : 250.0, (v) {
                // lb 输入换算回 kg 落库
                s.bodyWeightKg = lb ? lbToKg(v) : v;
                save();
              });
            },
          ),
          const SizedBox(height: 6),
          Text(
            tx(
                '用于训练后估算循环负荷（Edwards TRIMP）与卡路里（Keytel 心率方程 × 力量训练修正，数字仅供参考）；年龄不填按 190 估最大心率，性别/体重未设用默认值。',
                en: 'Estimates post-workout cardio load (Edwards TRIMP) and calories (Keytel HR equation with resistance adjustment; indicative only). Max HR defaults to 190 without age.'),
            style: const TextStyle(
                color: AppTheme.textDim, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }
}
