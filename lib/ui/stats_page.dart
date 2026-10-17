import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app.dart';
import '../engine/engine.dart';
import '../engine/weight_unit.dart';
import '../l10n/lang.dart';
import '../l10n/names.dart';
import '../presets/exercise_library.dart';
import '../services/ai_service.dart';
import 'muscle_body_view.dart';
import 'recovery_card.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 体重/负荷 kg → 当前显示单位数值（lb 模式换算并 snap 0.5lb 网格，2026-10-17）。
/// 图表数据点转显示空间后，轴刻度/标签/弹tip同一空间，不再二次换算。
double _dispVal(double kg) => WeightUnits.isLb ? lbSnap(kgToLb(kg)) : kg;

/// 体重差值（kg 口径）→ 带符号的当前单位文本（+3.5kg / +7.7lb）。
String _fmtDeltaKg(double deltaKg) {
  final v = WeightUnits.isLb ? kgToLb(deltaKg) : deltaKg;
  return '${deltaKg > 0 ? '+' : ''}${v.toStringAsFixed(1)}${unitLabel()}';
}

/// 数值轴「好看」步长（1/2/5×10^n，约 4 格）。minStep 给有物理最小刻度的
/// 重量轴兜底，避免窄区间被放大成整段空白。
double _statAxisStep(double span, {double minStep = 1}) {
  if (span <= minStep) return minStep;
  final raw = span / 4;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final unit = raw / mag;
  final nice = unit <= 1 ? 1 : unit <= 2 ? 2 : unit <= 5 ? 5 : 10;
  return math.max(minStep, nice * mag);
}

/// 统计页统一的横向网格：只画横线、极淡，给折线一个参考但不抢戏。
FlGridData _statGrid() => FlGridData(
      show: true,
      drawVerticalLine: false,
      getDrawingHorizontalLine: (_) => FlLine(
        color: Colors.white.withValues(alpha: 0.045),
        strokeWidth: 1,
      ),
    );

/// 折线下方渐变：同色 24% → 透明，替代生硬的纯色面积。
LinearGradient _statGradient(Color c) => LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [c.withValues(alpha: 0.24), c.withValues(alpha: 0)],
    );

/// 数据点：实心圆点 + 卡片底色描边，压在线条上不糊成一团。
FlDotData _statDots(Color c) => FlDotData(
      show: true,
      getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
        radius: 3,
        color: c,
        strokeWidth: 2,
        strokeColor: AppTheme.card,
      ),
    );

/// 数据页：概览 / 肌肉 / 身体 三个 Tab + AI 分析包入口。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: AppTheme.bg,
        appBar: AppBar(
          title: Text(tx('数据', en: 'Stats')),
          actions: [
            TextButton.icon(
              onPressed: () => _exportAiPack(),
              icon: const Icon(Icons.share_outlined, size: 18),
              label: Text(tx('分析包', en: 'Analysis Pack')),
            ),
          ],
          bottom: TabBar(
            indicatorColor: AppTheme.primary,
            labelColor: AppTheme.text,
            unselectedLabelColor: AppTheme.textDim,
            tabs: [
              _statTab(Icons.insights, tx('概览', en: 'Overview')),
              _statTab(Icons.accessibility_new, tx('肌肉', en: 'Muscles')),
              _statTab(Icons.monitor_weight_outlined, tx('身体', en: 'Body')),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_OverviewTab(), _MuscleTab(), _BodyTab()],
        ),
      ),
    );
  }

  /// Tab 统一「小图标 + 文案」：三页是并列的诊断视角，图标帮助扫读，
  /// 同时保留 Text 让既有按文案定位的测试不受影响。
  Tab _statTab(IconData icon, String label) => Tab(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 6),
            Text(label),
          ],
        ),
      );

  Future<void> _exportAiPack() async {
    final c = app(context);
    final pack = await c.export.buildAiPack(
        bodyWeightKg: c.settings.bodyWeightKg, planRepo: c.planRepo);
    await c.export.shareText(
        tx('薄肌训练 · AI 分析包', en: 'Baoji · AI Analysis Pack'),
        pack,
        filename: 'ai_analysis_pack.md');
    // 同时尝试复制到剪贴板
    await Clipboard.setData(ClipboardData(text: pack));
    if (mounted) {
      toast(context,
          tx('分析包已生成并复制到剪贴板',
              en: 'Analysis pack generated and copied to clipboard'));
    }
  }
}

// ---------------- 概览 ----------------

class _OverviewTab extends StatefulWidget {
  const _OverviewTab();

  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> {
  String? _selectedLift;
  Future<_OverviewData>? _future;

  /// 训练趋势卡（wger 统计维度借鉴）：周/月粒度 × 容量/组数/强度指标
  String _granularity = 'week';
  String _metric = 'volume';

  // ---- openGym 借鉴升级（2026-10-17）----

  /// 活动热力图口径：'time' 时长分钟 / 'volume' 容量吨位
  String _heatMode = 'time';

  /// 1RM 卡口径：'rm' 每日最佳估算 / 'top' 当日最大正式组重量
  String _rmMetric = 'rm';

  /// 1RM 卡横轴窗口：1m / 3m / 1y / all
  String _rmWindow = '1y';

  /// 余力分布窗口：30d / 90d / 1y / all
  String _rirWindow = '90d';

  @override
  void initState() {
    super.initState();
    // initState 里不能同步读 InheritedWidget，延后一帧
    // （缓存 future：切 chip 等 setState 不再触发全量重查）
    // setState 块体写法：箭头闭包会把 Future 返回给 setState，
    // debug 断言直接抛「callback argument returned a Future」
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          _future = _load(app(context));
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_OverviewData>(
      future: _future,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final d = snap.data!;
        if (d.weekTrend.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.insights, size: 48, color: AppTheme.textDim),
                const SizedBox(height: 12),
                Text(tx('完成第一次训练后，这里会显示进步曲线',
                    en: 'Progress curves appear after your first workout'),
                    style: const TextStyle(color: AppTheme.textDim)),
              ],
            ),
          );
        }
        final insights = localInsights(d.setsByName);
        // 所选动作不在本年度数据里（如新装/换计划）时重置到容量第一的动作
        if (d.topLifts.isEmpty) {
          _selectedLift = null;
        } else if (!_selectedLiftIn(d)) {
          _selectedLift = d.topLifts.first;
        }
        // ---- openGym 借鉴升级（2026-10-17）：KPI → 热力图 → 趋势
        //      → 1RM → 余力 → 休息 → 提醒，从「一眼总览」到「细节诊断」----
        final kpiCard = _buildKpiCard(d);
        final heatCard = _buildHeatmapCard(d);
        // 数据页重设计（2026-09-27 Arono：手机端"乱七八糟"反馈）：
        // 筛选控件从 SegmentedButton + ChoiceChip 混排（窄屏挤成竖排、
        // M3 蓝胶囊与绿色主题违和）统一为贴主题的下拉；粒度放卡片
        // 标题行右侧，指标单独一行，图表补左轴刻度与触摸提示。
        final trendCard = SectionCard(
          title: tx('训练趋势', en: 'Training Trend'),
          icon: Icons.show_chart,
          iconColor: AppTheme.accent,
          trailing: _StatDropdown<String>(
            value: _granularity,
            entries: [
              ('week', tx('按周', en: 'Weekly')),
              ('month', tx('按月', en: 'Monthly')),
            ],
            onChanged: (v) => setState(() => _granularity = v),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StatDropdown<String>(
                value: _metric,
                entries: [
                  ('volume', tx('容量', en: 'Volume')),
                  ('sets', tx('组数', en: 'Sets')),
                  ('intensity', tx('强度', en: 'Intensity')),
                ],
                onChanged: (v) => setState(() => _metric = v),
              ),
              const SizedBox(height: 8),
              Text(
                tx(
                    _metric == 'volume'
                        ? '正式组总容量（${unitLabel()}）· 自重按系数折算'
                        : _metric == 'sets'
                            ? '正式组组数'
                            : '平均强度 = 组重量 ÷ 该动作窗口内最佳 1RM（%）',
                    en: _metric == 'volume'
                        ? 'Total working-set volume (${unitLabel()})'
                        : _metric == 'sets'
                            ? 'Working sets count'
                            : 'Avg intensity = set weight ÷ best 1RM (%)'),
                style:
                    const TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
              const SizedBox(height: 8),
              _buildTrendChart(d),
            ],
          ),
        );
        final rmCard = _buildRmCard(d);
        final rirCard = _buildRirCard(d);
        final restCard = SectionCard(
          title: tx('组间休息趋势', en: 'Rest Between Sets Trend'),
          icon: Icons.timer_outlined,
          iconColor: AppTheme.accent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tx('每次训练的休息净时长 · 分钟',
                  en: 'Net rest time per workout · min'),
                  style: const TextStyle(
                      color: AppTheme.textDim, fontSize: 12)),
              const SizedBox(height: 8),
              SizedBox(
                height: 180,
                child: d.restMinutes.length < 2
                    ? Center(
                        child: Text(
                            tx('完成几次训练后，这里显示每次训练的休息总时长趋势',
                                en: 'Rest time per workout appears here after a few workouts'),
                            style: const TextStyle(color: AppTheme.textDim)))
                    : _buildRestChart(d),
              ),
            ],
          ),
        );
        // 宽屏（≥600 折叠屏展开档，设计基线双栏断点）左右分栏：
        // 第一行 = 总览+主力动作 | 活动+趋势，第二行 = 余力 | 休息，
        // 智能提醒通栏收尾；手机竖屏维持自上而下的单列顺序。
        final wide = MediaQuery.of(context).size.width >= 600;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            if (wide) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                      child: Column(
                          children: [kpiCard, const SizedBox(height: 12), rmCard])),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Column(
                          children: [heatCard, const SizedBox(height: 12), trendCard])),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: rirCard),
                  const SizedBox(width: 12),
                  Expanded(child: restCard),
                ],
              ),
            ] else ...[
              kpiCard,
              const SizedBox(height: 12),
              heatCard,
              const SizedBox(height: 12),
              trendCard,
              const SizedBox(height: 12),
              rmCard,
              const SizedBox(height: 12),
              rirCard,
              const SizedBox(height: 12),
              restCard,
            ],
            if (insights.isNotEmpty) ...[
              const SizedBox(height: 12),
              SectionCard(
                title: tx('智能提醒', en: 'Smart Tips'),
                icon: Icons.lightbulb_outline,
                iconColor: AppTheme.warn,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final i in insights)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 1),
                              child: Icon(Icons.lightbulb_outline,
                                  size: 15, color: AppTheme.warn),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(i,
                                  style: const TextStyle(
                                      color: AppTheme.warn,
                                      fontSize: 13,
                                      height: 1.4)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  bool _selectedLiftIn(_OverviewData d) => d.allLifts.contains(_selectedLift);

  /// 当前粒度的桶键（升序）
  List<int> _trendKeys(_OverviewData d) {
    final keys = (_granularity == 'week' ? d.weekTrend : d.monthTrend)
        .keys
        .toList()
      ..sort();
    return keys;
  }

  List<FlSpot> _trendPoints(_OverviewData d) {
    final map = _granularity == 'week' ? d.weekTrend : d.monthTrend;
    final keys = _trendKeys(d);
    final metric = switch (_metric) {
      'sets' => TrendMetric.sets,
      'intensity' => TrendMetric.intensity,
      _ => TrendMetric.volume,
    };
    final out = <FlSpot>[];
    for (var i = 0; i < keys.length; i++) {
      var v = (map[keys[i]] ?? TrendAcc()).metricValue(metric);
      // 容量底层按 kg 累计；lb 模式在显示层换算，轴/提示同一空间
      if (metric == TrendMetric.volume && WeightUnits.isLb) v *= kLbPerKg;
      out.add(FlSpot(i.toDouble(), v));
    }
    return out;
  }

  /// 趋势图 x 轴刻度：约 5 个日期标签（周桶显示周一、月桶显示一号）
  Widget _trendLabel(_OverviewData d, int i) {
    final keys = _trendKeys(d);
    if (i < 0 || i >= keys.length) return const SizedBox.shrink();
    final step = (keys.length / 5).ceil();
    if (i % step != 0 && i != keys.length - 1) {
      return const SizedBox.shrink();
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(keys[i] * 86400000);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        _granularity == 'week' ? '${dt.month}/${dt.day}' : '${dt.month}月',
        style: const TextStyle(color: AppTheme.textDim, fontSize: 10),
      ),
    );
  }

  /// 组间休息趋势的 x 轴日期标签（约 5 个，避免拥挤）
  Widget _restLabel(_OverviewData d, int i) {
    if (i < 0 || i >= d.restDates.length) return const SizedBox.shrink();
    final step = (d.restDates.length / 5).ceil();
    if (i % step != 0 && i != d.restDates.length - 1) {
      return const SizedBox.shrink();
    }
    final dt = parseDate(d.restDates[i]);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text('${dt.month}/${dt.day}',
          style: const TextStyle(color: AppTheme.textDim, fontSize: 10)),
    );
  }

  /// 当前指标数值的短格式（左轴刻度与触摸提示共用，避免长数字叠字）
  String _fmtMetric(double v) => switch (_metric) {
        'sets' => v.round().toString(),
        'intensity' => '${(v * 100).round()}%',
        _ => v >= 1000
            ? '${(v / 1000).toStringAsFixed(1)}k'
            : v.round().toString(),
      };

  /// 数值轴「好看」步长（1/2/5×10^n，约 4 格）。minStep 给有物理最小
  /// 刻度的重量轴（kg 2.5 / lb 5.5）兜底，避免窄区间被放大成整段空白。
  // 见文件顶部 _statAxisStep（身体 Tab 也要用，不做成 State 私有）
  double _axisStep(double span, {double minStep = 1}) =>
      _statAxisStep(span, minStep: minStep);

  /// 统计页统一的横向网格：只画横线、极淡，给折线一个参考但不抢戏。
  FlGridData get _chartGrid => _statGrid();

  /// 折线下方渐变：同色 24% → 透明，替代生硬的纯色面积。
  LinearGradient _chartGradient(Color c) => _statGradient(c);

  /// 数据点：实心圆点 + 卡片底色描边，压在线条上不糊成一团。
  FlDotData _chartDots(Color c) => _statDots(c);

  /// 训练趋势图：左轴刻度 + 触摸提示（日期 + 指标值）。
  /// 数据不足时收成一行紧凑提示，不再撑 200 高的空图。
  Widget _buildTrendChart(_OverviewData d) {
    final pts = _trendPoints(d);
    if (pts.length < 2) {
      return SizedBox(
        height: 64,
        child: Center(
          child: Text(
              tx('数据还少，再练几次就能看到趋势',
                  en: 'Not enough data yet — a few more workouts will show the trend'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textDim)),
        ),
      );
    }
    final keys = _trendKeys(d);
    final dataMax = pts.map((p) => p.y).reduce(math.max);
    final yStep = _axisStep(dataMax <= 0 ? 1 : dataMax);
    // 轴顶取整数刻度，避免出现「5.1k」这种突兀的非整刻度标签
    var maxY =
        dataMax <= 0 ? 1.0 : (dataMax / yStep).ceilToDouble() * yStep;
    if (maxY < dataMax * 1.05) maxY += yStep;
    final xStep = (keys.length / 5).ceil().clamp(1, keys.length);
    return SizedBox(
      height: 200,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxY,
          gridData: _chartGrid,
          borderData: FlBorderData(show: false),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => AppTheme.cardHi,
              tooltipPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem(
                      _trendTip(keys, s),
                      const TextStyle(
                          color: AppTheme.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          titlesData: FlTitlesData(
            // fl_chart 默认四边都出刻度：只留左/下，顶/右必须显式关掉，
            // 否则会出现头顶一排 0/0.2/…、右侧再复制一套 Y 值的“重影图”
            topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                interval: xStep.toDouble(),
                getTitlesWidget: (v, _) => _trendLabel(d, v.toInt()),
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                interval: yStep,
                getTitlesWidget: (v, _) => Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(_fmtMetric(v),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          color: AppTheme.textDim, fontSize: 10)),
                ),
              ),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: pts,
              isCurved: true,
              preventCurveOverShooting: true,
              color: AppTheme.primary,
              barWidth: 2.5,
              isStrokeCapRound: true,
              dotData: _chartDots(AppTheme.primary),
              belowBarData: BarAreaData(
                show: true,
                gradient: _chartGradient(AppTheme.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _trendTip(List<int> keys, FlSpot s) {
    final i = s.x.toInt();
    final dt = (i >= 0 && i < keys.length)
        ? DateTime.fromMillisecondsSinceEpoch(keys[i] * 86400000)
        : null;
    final unit = _metric == 'volume' ? ' ${unitLabel()}' : '';
    return '${dt == null ? '' : '${dt.month}/${dt.day}'}\n${_fmtMetric(s.y)}$unit';
  }

  /// 组间休息图（2026-09-27 截图反馈坐标轴数字重叠）：
  /// x 轴显式 interval 抽稀（一天多练也不重复堆叠），
  /// y 轴整数分钟刻度 + 触摸提示「日期 · N 分钟」。
  Widget _buildRestChart(_OverviewData d) {
    final dataMax = d.restMinutes.map((p) => p.y).reduce(math.max);
    final yStep = _axisStep(dataMax <= 0 ? 1 : dataMax, minStep: 1);
    var maxY =
        dataMax <= 0 ? 1.0 : (dataMax / yStep).ceilToDouble() * yStep;
    if (maxY < dataMax * 1.05) maxY += yStep;
    final xStep = (d.restDates.length / 5).ceil().clamp(1, d.restDates.length);
    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxY,
        gridData: _chartGrid,
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppTheme.cardHi,
            tooltipPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            getTooltipItems: (spots) => [
              for (final s in spots)
                LineTooltipItem(
                    _restTip(d, s),
                    const TextStyle(
                        color: AppTheme.text,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
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
              interval: xStep.toDouble(),
              getTitlesWidget: (v, _) => _restLabel(d, v.toInt()),
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 34,
              interval: yStep,
              getTitlesWidget: (v, _) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(v.round().toString(),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        color: AppTheme.textDim, fontSize: 10)),
              ),
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: d.restMinutes,
            isCurved: true,
            preventCurveOverShooting: true,
            color: AppTheme.warn,
            barWidth: 2.5,
            isStrokeCapRound: true,
            dotData: _chartDots(AppTheme.warn),
            belowBarData: BarAreaData(
              show: true,
              gradient: _chartGradient(AppTheme.warn),
            ),
          ),
        ],
      ),
    );
  }

  String _restTip(_OverviewData d, FlSpot s) {
    final i = s.x.toInt();
    final dt = (i >= 0 && i < d.restDates.length)
        ? parseDate(d.restDates[i])
        : null;
    return '${dt == null ? '' : '${dt.month}/${dt.day}'} · ${s.y.round()}${tx(' 分钟', en: ' min')}';
  }

  /// 1RM 动作下拉按钮（替代原 4 个 chip）：全宽、点开带搜索的弹层
  Widget _liftButton(_OverviewData d) {
    final empty = d.allLifts.isEmpty;
    return InkWell(
      onTap: empty ? null : () => _pickLift(d),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
            color: AppTheme.cardHi, borderRadius: BorderRadius.circular(10)),
        child: Row(
          children: [
            Icon(Icons.fitness_center,
                size: 18, color: empty ? AppTheme.textDim : AppTheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                    empty
                        ? tx('练几次后自动选出主力动作',
                            en: 'Top lifts appear after a few workouts')
                        : exname(_selectedLift ?? ''),
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.expand_more, size: 18, color: AppTheme.textDim),
          ],
        ),
      ),
    );
  }

  Future<void> _pickLift(_OverviewData d) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _LiftPickerSheet(
          all: d.allLifts, top: d.topLifts, current: _selectedLift),
    );
    if (picked != null && mounted) {
      setState(() => _selectedLift = picked);
    }
  }

  /// 主力动作 1RM / 顶组图（wger 每日最佳口径）：x 轴日期（训练日），
  /// y = 1RM 口径取当天最高估值（dips 也能诚实显示），
  /// 顶组口径取当天最大正式组重量；横轴按 1月/3月/1年/全部 过滤。
  /// 不足两天时给友好空态：告诉用户已经记了几天、当前多少。
  Widget _buildRmChart(_OverviewData d) {
    final lift = _selectedLift;
    final source = _rmMetric == 'top' ? d.topSetByDate : d.rmByDate;
    final byDate = lift == null ? null : source[lift];
    final keys = ((byDate?.keys.toList() ?? <int>[])..sort())
        .where((k) => k >= _rmWindowCutoffDay())
        .toList();
    final pts = [
      for (var i = 0; i < keys.length; i++)
        // 图表整体在显示单位空间绘制（2026-10-17）：lb 模式换算并 snap 0.5lb，
        // 轴刻度/弹tip/区间随之同空间，避免 kg 值配 lb 标签的错位
        FlSpot(i.toDouble(), _dispVal(byDate![keys[i]]!))
    ];
    if (lift == null || pts.length < 2) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              lift == null
                  ? tx('练几次之后，这里自动选出你的主力动作',
                      en: 'Top lifts are picked automatically after a few workouts')
                  : tx('${exname(lift)}：已记 ${keys.length} 天',
                      en: '${exname(lift)}: ${keys.length} days logged'),
              style: const TextStyle(fontSize: 14),
            ),
            if (pts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  tx('当前 1RM ≈ ${fmtKg(pts.last.y)}${unitLabel()} · 再练几场出进步趋势',
                      en: 'Current 1RM ≈ ${fmtKg(pts.last.y)}${unitLabel()} · keep training to see the trend'),
                  style: const TextStyle(
                      color: AppTheme.textDim, fontSize: 13),
                ),
              ),
          ],
        ),
      );
    }
    final dataMax = pts.map((p) => p.y).reduce((a, b) => a > b ? a : b);
    final dataMin = pts.map((p) => p.y).reduce((a, b) => a < b ? a : b);
    // 重量轴保留物理最小刻度（2.5kg≈5.5lb），上下各留半格：
    // 原实现 minY 固定 0，1RM 在 70kg 附近时整条线被压在图底
    final minStep = WeightUnits.isLb ? 5.5 : 2.5;
    final yStep = _axisStep(dataMax - dataMin, minStep: minStep);
    final lo = (dataMin / yStep).floorToDouble() * yStep;
    var hi = (dataMax / yStep).ceilToDouble() * yStep;
    if (hi <= lo) hi = lo + yStep;
    return LineChart(
      LineChartData(
        minY: lo,
        maxY: hi,
        gridData: _chartGrid,
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppTheme.cardHi,
            tooltipPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            getTooltipItems: (spots) => [
              for (final s in spots)
                LineTooltipItem(
                    _rmTip(keys, s),
                    const TextStyle(
                        color: AppTheme.text,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
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
              interval: (pts.length / 6).clamp(1, 100).toDouble(),
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= keys.length) return const SizedBox.shrink();
                final dt =
                    DateTime.fromMillisecondsSinceEpoch(keys[i] * 86400000);
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${dt.month}/${dt.day}',
                      style: const TextStyle(
                          color: AppTheme.textDim, fontSize: 10)),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: yStep,
              getTitlesWidget: (v, _) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  fmtKg(v),
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
            spots: pts,
            isCurved: false,
            color: AppTheme.accent,
            barWidth: 2.5,
            isStrokeCapRound: true,
            dotData: _chartDots(AppTheme.accent),
            belowBarData: BarAreaData(
              show: true,
              gradient: _chartGradient(AppTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  String _rmTip(List<int> keys, FlSpot s) {
    final i = s.x.toInt();
    final dt = (i >= 0 && i < keys.length)
        ? DateTime.fromMillisecondsSinceEpoch(keys[i] * 86400000)
        : null;
    return '${dt == null ? '' : '${dt.month}/${dt.day}'} · ${fmtKg(s.y)}${unitLabel()}';
  }

  // ================ openGym 借鉴升级（2026-10-17） ================

  /// KPI 2×2 卡：总训练次数 | 本月次数 | 连续周 | 30 天体重变化。
  /// 每格「彩色小图标 + 标签 + 大数字」：图标承担扫读，数字承担结论，
  /// 比纯数字四宫格更像仪表盘；体重 Δ 仍按目标方向降绿涨红。
  Widget _buildKpiCard(_OverviewData d) {
    final k = d.kpi;
    final delta = k.weightDelta30d;
    final deltaColor = delta == null
        ? null
        : delta.abs() < 0.05
            ? AppTheme.textDim
            : _weightDeltaColor(delta, d.weightGoalKg, d.latestWeightKg);
    final deltaText = delta == null ? '—' : _fmtDeltaKg(delta);
    Widget cell(
      IconData icon,
      Color iconColor,
      String value,
      String label, {
      Color? color,
    }) =>
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 12),
            decoration: BoxDecoration(
              color: AppTheme.cardHi.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.035)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: iconColor.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(icon, size: 14, color: iconColor),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppTheme.textDim,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(value,
                      maxLines: 1,
                      style: AppTheme.bigNum(26,
                          color: color ?? AppTheme.text)),
                ),
              ],
            ),
          ),
        );
    // padding 收紧（14/12）：概览新增卡多，宽屏双栏/测试视口下
    // 首屏要能装下更多卡
    return SectionCard(
      title: tx('总览', en: 'Overview'),
      icon: Icons.insights,
      iconColor: AppTheme.primary,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        children: [
          Row(
            children: [
              cell(Icons.event_available, AppTheme.primary,
                  '${k.totalSessions}', tx('总训练', en: 'Total workouts')),
              cell(Icons.calendar_month, AppTheme.accent, '${k.thisMonth}',
                  tx('本月', en: 'This month')),
            ],
          ),
          Row(
            children: [
              cell(Icons.local_fire_department, AppTheme.warn,
                  '${k.weekStreak}', tx('连续周', en: 'Week streak')),
              cell(
                  Icons.monitor_weight_outlined,
                  deltaColor ?? AppTheme.accent,
                  deltaText,
                  tx('30 天体重', en: '30-day weight'),
                  color: deltaColor),
            ],
          ),
        ],
      ),
    );
  }

  /// 活动热力图卡：近 12 个月 GitHub 风格格网 + 时长/吨位双口径切换
  /// （ToggleButtons 放标题行右侧 + padding 收紧：800×600 测试视口
  /// 里 KPI + 热力图要装得进首屏，趋势卡标题才在缓存构建范围内）。
  Widget _buildHeatmapCard(_OverviewData d) {
    final grid = _heatMode == 'volume' ? d.heatVolume : d.heatTime;
    final levels = activityLevels(grid);
    final activeDays = grid.expand((w) => w).where((v) => v > 0).length;
    return SectionCard(
      // 英文标题过长会和右侧口径切换挤成两行；时间范围已经在下方
      // 「近 12 个月 · N 天有训练」里说明，标题只留主题词
      title: tx('活动', en: 'Activity'),
      icon: Icons.local_fire_department_outlined,
      iconColor: AppTheme.warn,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      trailing: _HeatToggle(
        timeSelected: _heatMode == 'time',
        onChanged: (time) => setState(() => _heatMode = time ? 'time' : 'volume'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HeatmapView(grid: grid, levels: levels),
          const SizedBox(height: 2),
          Text(
            tx('过去 12 个月 · $activeDays 天有训练',
                en: 'Last 12 months · $activeDays active days'),
            style: const TextStyle(color: AppTheme.textDim, fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// 主力动作 1RM 卡升级：动作左右箭头（4 主力间切换）+ 动作选单 +
  /// 口径切换（1RM/顶组）+ 粒度切换（1月/3月/1年/全部）。
  Widget _buildRmCard(_OverviewData d) {
    final tops = d.topLifts;
    final lift = _selectedLift;
    final idx = lift == null ? -1 : tops.indexOf(lift);
    Widget arrow(IconData icon, int step) => Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: tops.length < 2
                ? AppTheme.cardHi.withValues(alpha: 0.4)
                : AppTheme.cardHi,
            borderRadius: BorderRadius.circular(10),
          ),
          child: IconButton(
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onPressed: tops.length < 2
                ? null
                : () {
                    final cur = idx < 0 ? 0 : idx;
                    final next = (cur + step + tops.length) % tops.length;
                    setState(() => _selectedLift = tops[next]);
                  },
            icon: Icon(icon, size: 20, color: AppTheme.textDim),
          ),
        );
    return SectionCard(
      title: tx('主力动作 1RM', en: 'Top Lifts 1RM'),
      icon: Icons.emoji_events_outlined,
      iconColor: AppTheme.primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 动作行：左右箭头在 4 主力间快切；中间按钮仍打开带搜索的
          // 全量弹层（动作库 150+，必须可搜）
          Row(
            children: [
              arrow(Icons.chevron_left, -1),
              Expanded(child: _liftButton(d)),
              arrow(Icons.chevron_right, 1),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatDropdown<String>(
                value: _rmMetric,
                entries: [
                  ('rm', tx('1RM', en: '1RM')),
                  ('top', tx('顶组', en: 'Top Set')),
                ],
                onChanged: (v) => setState(() => _rmMetric = v),
              ),
              _StatDropdown<String>(
                value: _rmWindow,
                entries: [
                  ('1m', tx('1 月', en: '1M')),
                  ('3m', tx('3 月', en: '3M')),
                  ('1y', tx('1 年', en: '1Y')),
                  ('all', tx('全部', en: 'All')),
                ],
                onChanged: (v) => setState(() => _rmWindow = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            tx(
                _rmMetric == 'top'
                    ? '每天取当日最大正式组重量（${unitLabel()}）· 前 4 为自动选出的主力动作'
                    : '每天取当日最佳 1RM（${unitLabel()}）· 前 4 为自动选出的主力动作',
                en: _rmMetric == 'top'
                    ? 'Daily top working-set weight (${unitLabel()}) · top 4 picked automatically'
                    : 'Daily best 1RM (${unitLabel()}) · top 4 picked automatically'),
            style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 200,
            child: _buildRmChart(d),
          ),
        ],
      ),
    );
  }

  /// 1RM 卡横轴窗口的截止日（epoch 天数）：1m=30 天 / 3m=90 天 / 1y=365 天。
  int _rmWindowCutoffDay() {
    if (_rmWindow == 'all') return 0;
    final days = _rmWindow == '1m' ? 30 : (_rmWindow == '3m' ? 90 : 365);
    return DateTime.now()
            .subtract(Duration(days: days))
            .millisecondsSinceEpoch ~/
        86400000;
  }

  /// 余力（RIR）分布卡：正式组直方图（桶 0/1/2/3/4/5+）+ 动态解读一句。
  Widget _buildRirCard(_OverviewData d) {
    final since = switch (_rirWindow) {
      '30d' => DateTime.now().subtract(const Duration(days: 30)),
      '90d' => DateTime.now().subtract(const Duration(days: 90)),
      '1y' => DateTime.now().subtract(const Duration(days: 365)),
      _ => null,
    };
    final dist = rirDistribution(d.allWorkingSets, since: since);
    return SectionCard(
      title: tx('余力分布', en: 'RIR Distribution'),
      icon: Icons.speed,
      iconColor: AppTheme.warn,
      trailing: _StatDropdown<String>(
        value: _rirWindow,
        entries: [
          ('30d', tx('30 天', en: '30D')),
          ('90d', tx('90 天', en: '90D')),
          ('1y', tx('1 年', en: '1Y')),
          ('all', tx('全部', en: 'All')),
        ],
        onChanged: (v) => setState(() => _rirWindow = v),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RirBars(dist: dist),
          const SizedBox(height: 10),
          Text(rirInsightLine(dist),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13)),
        ],
      ),
    );
  }

  /// 单次 JOIN 拉全部明细后内存聚合，避免逐 session 查询的 N+1。
  /// 2026-10-17 升级：明细改拉全历史（1RM/顶组/余力支持「全部」窗口），
  /// 训练趋势与主力动作仍按近一年窗口聚合（口径不变）。
  Future<_OverviewData> _load(AppContainer c) async {
    final now = DateTime.now();
    final from = fmtDate(now.subtract(const Duration(days: 365)));
    final today = fmtDate(now);
    final rows = await c.db.sessionRowsBetween('2000-01-01', today);
    // 自重容量折算（点名条目二）：引体/俯卧撑类按 系数×体重 计入容量；
    // 体重未设（0）时自动回旧口径（自重记 0）。
    final bodyWeight = c.settings.bodyWeightKg;
    final weightGoal = c.settings.weightGoalKg;
    // 休息趋势：按会话取休息净时长（老记录为 0 跳过）
    final sessionsForRest = await c.db.sessionsBetween(from, today);
    final restMinutes = <FlSpot>[];
    final restDates = <String>[];
    for (var i = 0; i < sessionsForRest.length; i++) {
      final s = sessionsForRest[i];
      if (s.restMs <= 0) continue;
      restMinutes.add(FlSpot(restMinutes.length.toDouble(), s.restMs / 60000));
      restDates.add(s.date);
    }
    // KPI（总次数/连续周）与活动热力图：全期 done 会话
    final allSessions = await c.db.sessionsBetween('2000-01-01', today);
    final bodyMetrics = await c.db.bodyMetrics();
    final weekT = <int, TrendAcc>{};
    final monthT = <int, TrendAcc>{};
    final setsByName = <String, List<SetEntry>>{};
    // 每日最佳 1RM（wger 口径）：动作 → 训练日(epoch天) → 当天最高估值
    final dailyBest = DailyBest1Rm();
    // 顶组口径：动作 → 训练日 → 当天最大正式组重量
    final dailyTop = DailyTopSet();
    // 动作在窗口内的历史最佳 1RM（强度分母；按行序递增 = 时间上"截至当时"）
    final bestRm = <String, double>{};
    // 热力图原料：每日正式组容量（SetEntry.volume 口径）/ 每日组数
    final volumeByDate = <String, double>{};
    final setCountsByDate = <String, int>{};
    // 余力分布原料：全历史正式组（窗口过滤交给引擎的 since 参数）
    final allWorking = <SetEntry>[];
    for (final r in rows) {
      final weight = (r['weight_kg'] as num?)?.toDouble();
      final reps = (r['reps'] as num?)?.toInt();
      if (weight == null || reps == null) continue; // 无组的动作行
      final kind = (r['kind'] as String?) ?? SetKind.working;
      final entry = SetEntry(
        sessionExerciseId: (r['se_id'] as num).toInt(),
        weightKg: weight,
        reps: reps,
        rir: (r['rir'] as num?)?.toInt() ?? 2,
        kind: kind,
        doneAt: (r['done_at'] as num?)?.toInt() ?? 0,
      );
      final name = (r['name'] as String?) ?? '';
      final date = (r['date'] as String?) ?? '';
      // 趋势/主力动作维持近一年口径（全历史会让周桶无限拉长）
      final inYear = date.compareTo(from) >= 0;
      if (inYear) setsByName.putIfAbsent(name, () => []).add(entry);
      if (kind == SetKind.working) {
        final d = parseDate(date);
        final vol = setVolumeWithBodyweight(entry,
            exerciseName: name, bodyWeightKg: bodyWeight);
        final rm = estimate1RM(weight, reps);
        if (rm > (bestRm[name] ?? 0)) bestRm[name] = rm;
        dailyBest.add(name, d, rm);
        dailyTop.add(name, d, weight);
        // 强度 = 组重量 ÷ 该动作截至当时的最佳 1RM（自重/辅助配重无意义不计）
        final best = bestRm[name]!;
        final intensity = weight > 0 && best > 0 ? weight / best : null;
        if (inYear) {
          weekT
              .putIfAbsent(trendKeyOf(d, TrendGranularity.week), TrendAcc.new)
              .add(setVolume: vol, intensity: intensity);
          monthT
              .putIfAbsent(trendKeyOf(d, TrendGranularity.month), TrendAcc.new)
              .add(setVolume: vol, intensity: intensity);
        }
        volumeByDate[date] = (volumeByDate[date] ?? 0) + entry.volume;
        setCountsByDate[date] = (setCountsByDate[date] ?? 0) + 1;
        allWorking.add(entry);
      }
    }
    // 主力动作 = 近一年正式组容量前 4（不再写死杠铃四大项名）
    final volumeByName = <String, double>{};
    for (final e in setsByName.entries) {
      volumeByName[e.key] = e.value
          .where((s) => s.kind == SetKind.working)
          .fold(
              0.0,
              (a, b) => a + setVolumeWithBodyweight(b,
                  exerciseName: e.key, bodyWeightKg: bodyWeight));
    }
    final topLifts = volumeByName.keys.where((k) => volumeByName[k]! > 0)
        .toList()
      ..sort((a, b) => volumeByName[b]!.compareTo(volumeByName[a]!));
    final kpi = computeStatsKpi(
        sessions: allSessions,
        bodyMetrics: bodyMetrics,
        now: now,
        weightGoalKg: weightGoal > 0 ? weightGoal : null);
    double? latestWeight;
    for (final m in bodyMetrics) {
      if (m.weightKg != null) latestWeight = m.weightKg;
    }
    return _OverviewData(
      weekTrend: weekT,
      monthTrend: monthT,
      allLifts: topLifts,
      topLifts: topLifts.take(4).toList(),
      restMinutes: restMinutes,
      restDates: restDates,
      rmByDate: dailyBest.byExercise,
      setsByName: setsByName,
      kpi: kpi,
      latestWeightKg: latestWeight,
      weightGoalKg: weightGoal,
      heatTime: activityHeatmap(sessions: allSessions, now: now,
          byVolume: false, setCountsByDate: setCountsByDate),
      heatVolume: activityHeatmap(sessions: allSessions, now: now,
          byVolume: true, volumeByDate: volumeByDate),
      topSetByDate: dailyTop.byExercise,
      allWorkingSets: allWorking,
    );
  }
}

class _OverviewData {
  /// 周/月粒度的趋势桶（key 见 trendKeyOf）
  final Map<int, TrendAcc> weekTrend;
  final Map<int, TrendAcc> monthTrend;

  /// 近一年有正式组容量的全部动作（容量降序）——下拉选单的数据源，
  /// 不再只能看前 4
  final List<String> allLifts;

  /// 近一年正式组容量前 4 的动作名（动态"四大项"）
  final List<String> topLifts;

  /// 每次训练的休息净时长（分钟，老记录为空）+ 对应日期
  final List<FlSpot> restMinutes;
  final List<String> restDates;

  /// 每日最佳 1RM：动作 → 训练日(epoch天) → 当天最高估值
  final Map<String, Map<int, double>> rmByDate;
  final Map<String, List<SetEntry>> setsByName;

  // ---- openGym 借鉴升级（2026-10-17）----

  /// 概览 KPI 四件套（总次数/本月/连续周/30 天体重 Δ）
  final StatsKpi kpi;

  /// 最近一条体重（Δ 颜色语义判定用）
  final double? latestWeightKg;

  /// 目标体重 kg（0 = 未设）
  final double weightGoalKg;

  /// 活动热力图双口径格网（时长分钟 / 容量）
  final List<List<double>> heatTime;
  final List<List<double>> heatVolume;

  /// 顶组口径：动作 → 训练日 → 当日最大正式组重量
  final Map<String, Map<int, double>> topSetByDate;

  /// 全历史正式组（余力分布的窗口过滤原料）
  final List<SetEntry> allWorkingSets;

  _OverviewData({
    required this.weekTrend,
    required this.monthTrend,
    required this.allLifts,
    required this.topLifts,
    required this.restMinutes,
    required this.restDates,
    required this.rmByDate,
    required this.setsByName,
    required this.kpi,
    required this.latestWeightKg,
    required this.weightGoalKg,
    required this.heatTime,
    required this.heatVolume,
    required this.topSetByDate,
    required this.allWorkingSets,
  });
}

// ---------------- 肌肉 ----------------

class _MuscleTab extends StatefulWidget {
  const _MuscleTab();

  @override
  State<_MuscleTab> createState() => _MuscleTabState();
}

class _MuscleTabState extends State<_MuscleTab> {
  Future<Map<String, double>>? _future;
  bool _front = true;

  /// 统计窗口（wger 统计维度借鉴）：本周 / 本月
  String _period = 'week';

  @override
  void initState() {
    super.initState();
    // initState 里不能同步读 InheritedWidget，延后一帧
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          _future = _load(app(context));
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, double>>(
      future: _future,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final share = snap.data!;
        final total = share.values.fold(0.0, (a, b) => a + b);
        // 色带归一基准：列表内最大占比（重肌群→琥珀端、轻肌群→灰端）。
        // 2026-09-26 Arono：容量颜色按程度分档，不再清一色绿
        final maxShare = share.values.fold(0.0, math.max);
        // 未练点名：统计期内占比近零的肌群直接点名（同一份 share，
        // 周/月粒度切换重载后自动跟随；全部命中时不占版面）
        final untrained = untrainedRegions(share);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            // 肌群恢复度（点名条目四）：只进数据页，不进训练中三要素
            // （2026-09-25 从计划页挪到数据页，计划页只管"练什么"）
            const MuscleRecoveryCard(),
            SectionCard(
              title: tx('肌群容量占比', en: 'Muscle Volume Share'),
              icon: Icons.bar_chart,
              iconColor: AppTheme.primary,
              trailing: _StatDropdown<String>(
                value: _period,
                entries: [
                  ('week', tx('本周', en: 'This week')),
                  ('month', tx('本月', en: 'This month')),
                ],
                onChanged: (v) {
                  setState(() => _period = v);
                  _future = _load(app(context));
                },
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _StatDropdown<bool>(
                    value: _front,
                    entries: [
                      (true, tx('正面视图', en: 'Front view')),
                      (false, tx('背面视图', en: 'Back view')),
                    ],
                    onChanged: (v) => setState(() => _front = v),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 300,
                    child: MuscleBodyView(
                      share: share,
                      front: _front,
                      ramp: (v) => maxShare <= 0
                          ? AppTheme.cardHi
                          : AppTheme.loadColor(v / maxShare),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ...kMuscleRegions.map((r) {
                    final v = share[r] ?? 0;
                    final color = maxShare <= 0
                        ? AppTheme.cardHi
                        : AppTheme.loadColor(v / maxShare);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          // FittedBox：大字号/窄屏下名称与百分比整体缩放，
                          // 数字绝不被折行（如"30"拆成两行）。列宽 76 =
                          // 最长英文名 Shoulders @14px 的自然宽度——44 会让
                          // 英文标签被 FittedBox 缩小、和相邻行字号不一致
                          SizedBox(
                            width: 76,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(mname(r),
                                  maxLines: 1,
                                  style: const TextStyle(fontSize: 14)),
                            ),
                          ),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: total == 0 ? 0 : v,
                                minHeight: 10,
                                backgroundColor: AppTheme.cardHi,
                                valueColor:
                                    AlwaysStoppedAnimation(color),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 52,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text('${(v * 100).toStringAsFixed(0)}%',
                                  maxLines: 1,
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                      color: total == 0
                                          ? AppTheme.textDim
                                          : color,
                                      fontSize: 13)),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  // 未练点名：漏练肌群一行点名，样式沿用页面既有警示提示
                  if (untrained.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        tx('未练到：${untrained.map(mname).join(' · ')}',
                            en:
                                'Not trained: ${untrained.map(mname).join(' · ')}'),
                        style: const TextStyle(
                            color: AppTheme.warn, fontSize: 13),
                      ),
                    ),
                  if ((share['肩'] ?? 0) < 0.15 || (share['背'] ?? 0) < 0.15)
                    Text(
                        tx('提示：肩、背容量偏低——薄肌计划的目标是肩背偏重，注意补齐。',
                            en: 'Tip: Shoulder and back volume are low — the Baoji plan emphasizes shoulders and back, so catch up on them.'),
                        style:
                            const TextStyle(color: AppTheme.warn, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 上下肢分布（wger 的 upper/lower 口径）：七分区归并成
            // 上肢（胸肩背手臂）/ 下肢（腿）/ 核心+其他 三条，一眼看结构
            SectionCard(
              title: tx('上下肢分布', en: 'Upper/Lower Split'),
              icon: Icons.accessibility_new,
              iconColor: AppTheme.accent,
              child: Builder(builder: (_) {
                final groups = regionGroupShare(share);
                const order = ['上肢', '下肢', '核心'];
                final hint = groups['下肢'] ?? 0;
                return Column(
                  children: [
                    for (final g in order)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 76,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  tx(g,
                                      en: switch (g) {
                                        '上肢' => 'Upper',
                                        '下肢' => 'Lower',
                                        _ => 'Core',
                                      }),
                                  maxLines: 1,
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                            ),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: groups[g] ?? 0,
                                  minHeight: 10,
                                  backgroundColor: AppTheme.cardHi,
                                  valueColor: AlwaysStoppedAnimation(
                                      AppTheme.loadColor(groups[g] ?? 0)),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 52,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  '${((groups[g] ?? 0) * 100).toStringAsFixed(0)}%',
                                  maxLines: 1,
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (hint < 0.25)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          tx('提示：下肢容量不足四分之一——练上不练下，力量和体态都会失衡。',
                              en: 'Tip: Lower-body work is under a quarter of volume — don\'t skip leg day.'),
                          style: const TextStyle(
                              color: AppTheme.warn, fontSize: 13),
                        ),
                      ),
                  ],
                );
              }),
            ),
          ],
        );
      },
    );
  }

  Future<Map<String, double>> _load(AppContainer c) async {
    final now = DateTime.now();
    final from = _period == 'week'
        ? mondayOf(now)
        : DateTime(now.year, now.month, 1);
    final sessions = await c.db.sessionsBetween(fmtDate(from), fmtDate(now));
    final metaMap = {for (final m in kExerciseLibrary) m.name: m};
    // 内置词表 + DB 沉淀合并（与动作库页同口径）：
    // AI 计划/编辑器沉淀的词表外动作才能在热力图与占比里正确归类
    final known = metaMap.keys.toSet();
    for (final m in await c.db.allExerciseMeta()) {
      if (!known.contains(m.name)) metaMap[m.name] = m;
    }
    final byName = <String, List<SetEntry>>{};
    for (final s in sessions) {
      final ses = await c.db.sessionExercises(s.id!);
      final map = await c.db.setsOfSession(s.id!);
      for (final se in ses) {
        byName.putIfAbsent(se.name, () => []).addAll(map[se.id!] ?? []);
      }
    }
    return muscleLoadShare(
      byName.entries
          .map((e) => MapEntry(
              e.key, e.value.where((x) => x.kind == SetKind.working).toList()))
          .toList(),
      metaMap,
      bodyWeightKg: c.settings.bodyWeightKg,
    );
  }
}
// ---------------- 身体 ----------------

class _BodyTab extends StatefulWidget {
  const _BodyTab();

  @override
  State<_BodyTab> createState() => _BodyTabState();
}

class _BodyTabState extends State<_BodyTab>
    with AutomaticKeepAliveClientMixin {
  final _weightCtrl = TextEditingController();
  final _waistCtrl = TextEditingController();
  final _fatCtrl = TextEditingController();
  Future<List<BodyMetric>>? _future;

  /// 体重曲线粒度：1m / 3m / 1y / all（openGym 借鉴，2026-10-17）
  String _bodyWindow = '1y';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // initState 里不能同步读 InheritedWidget，延后一帧
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          _future = app(context).db.bodyMetrics();
        });
      }
    });
  }

  @override
  void dispose() {
    _weightCtrl.dispose();
    _waistCtrl.dispose();
    _fatCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 必需
    final c = app(context);
    final goal = c.settings.weightGoalKg;
    return FutureBuilder<List<BodyMetric>>(
      future: _future,
      builder: (context, snap) {
        final all = snap.data ?? const <BodyMetric>[];
        // 粒度过滤（日期字符串 yyyy-MM-dd 可直接比较）
        final cutoff = switch (_bodyWindow) {
          '1m' => fmtDate(DateTime.now().subtract(const Duration(days: 30))),
          '3m' => fmtDate(DateTime.now().subtract(const Duration(days: 90))),
          '1y' => fmtDate(DateTime.now().subtract(const Duration(days: 365))),
          _ => null,
        };
        final data = cutoff == null
            ? all
            : all.where((m) => m.date.compareTo(cutoff) >= 0).toList();
        final weights = <FlSpot>[];
        for (var i = 0; i < data.length; i++) {
          if (data[i].weightKg != null) {
            // 体重曲线同 1RM 图：显示单位空间绘制（2026-10-17）
            weights.add(FlSpot(i.toDouble(), _dispVal(data[i].weightKg!)));
          }
        }
        // 30 天 Δ 小标注：复用 KPI 口径（不传 sessions，只算体重差）
        final delta30 = computeStatsKpi(
                sessions: const [],
                bodyMetrics: all,
                now: DateTime.now(),
                weightGoalKg: goal > 0 ? goal : null)
            .weightDelta30d;
        final latest = data.isEmpty ? null : data.last.weightKg;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            SectionCard(
              title: tx('体重趋势', en: 'Body Weight Trend'),
              icon: Icons.monitor_weight_outlined,
              iconColor: AppTheme.accent,
              trailing: _StatDropdown<String>(
                value: _bodyWindow,
                entries: [
                  ('1m', tx('1 月', en: '1M')),
                  ('3m', tx('3 月', en: '3M')),
                  ('1y', tx('1 年', en: '1Y')),
                  ('all', tx('全部', en: 'All')),
                ],
                onChanged: (v) => setState(() => _bodyWindow = v),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (delta30 != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        tx('30 天 ${_fmtDeltaKg(delta30)}',
                            en: '30-day ${_fmtDeltaKg(delta30)}'),
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: delta30.abs() < 0.05
                                ? AppTheme.textDim
                                : _weightDeltaColor(delta30, goal, latest)),
                      ),
                    ),
                  SizedBox(
                    height: 180,
                    child: weights.length < 2
                        ? Center(
                            child: Text(tx('每周固定时间记一次体重',
                                en: 'Weigh in at the same time each week'),
                                style:
                                    const TextStyle(color: AppTheme.textDim)))
                        : Builder(builder: (_) {
                            // 纵轴同时容纳数据点与目标线，避免目标线跑到画布外
                            final vals = weights.map((p) => p.y).toList();
                            if (goal > 0) vals.add(_dispVal(goal));
                            final vMin = vals.reduce(math.min);
                            final vMax = vals.reduce(math.max);
                            final yStep = _statAxisStep(vMax - vMin,
                                minStep: WeightUnits.isLb ? 2 : 1);
                            final lo =
                                (vMin / yStep).floorToDouble() * yStep;
                            var hi = (vMax / yStep).ceilToDouble() * yStep;
                            if (hi <= lo) hi = lo + yStep;
                            final xStep = (data.length / 4)
                                .ceil()
                                .clamp(1, data.length)
                                .toDouble();
                            return LineChart(
                              LineChartData(
                                minY: lo,
                                maxY: hi,
                                gridData: _statGrid(),
                                borderData: FlBorderData(show: false),
                                // 触摸提示：日期 + 体重（显示单位）
                                lineTouchData: LineTouchData(
                                  touchTooltipData: LineTouchTooltipData(
                                    getTooltipColor: (_) => AppTheme.cardHi,
                                    tooltipPadding: const EdgeInsets
                                        .symmetric(
                                        horizontal: 10, vertical: 6),
                                    getTooltipItems: (spots) => [
                                      for (final s in spots)
                                        LineTooltipItem(
                                          '${_bodyDate(data, s.x)}\n'
                                          '${fmtKg(s.y)}${unitLabel()}',
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
                                      sideTitles:
                                          SideTitles(showTitles: false)),
                                  rightTitles: const AxisTitles(
                                      sideTitles:
                                          SideTitles(showTitles: false)),
                                  bottomTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 22,
                                      interval: xStep,
                                      getTitlesWidget: (v, _) =>
                                          _bodyDateLabel(data, v.toInt()),
                                    ),
                                  ),
                                  leftTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 38,
                                      interval: yStep,
                                      getTitlesWidget: (v, _) => Padding(
                                        padding:
                                            const EdgeInsets.only(right: 6),
                                        child: Text(fmtKg(v),
                                            textAlign: TextAlign.right,
                                            style: const TextStyle(
                                                color: AppTheme.textDim,
                                                fontSize: 10)),
                                      ),
                                    ),
                                  ),
                                ),
                                // 目标线：虚线 + 小标签；未设不画
                                extraLinesData: goal > 0
                                    ? ExtraLinesData(horizontalLines: [
                                        HorizontalLine(
                                          // 目标线与数据点同在显示单位空间
                                          y: _dispVal(goal),
                                          color: AppTheme.primary,
                                          strokeWidth: 1,
                                          dashArray: [6, 4],
                                          label: HorizontalLineLabel(
                                            show: true,
                                            alignment: Alignment.topRight,
                                            padding: const EdgeInsets.only(
                                                bottom: 2, right: 2),
                                            style: const TextStyle(
                                                color: AppTheme.primary,
                                                fontSize: 10),
                                            labelResolver: (_) => tx(
                                                '目标 ${fmtWt(goal)}',
                                                en: 'Goal ${fmtWt(goal)}'),
                                          ),
                                        ),
                                      ])
                                    : null,
                                lineBarsData: [
                                  LineChartBarData(
                                    spots: weights,
                                    isCurved: true,
                                    preventCurveOverShooting: true,
                                    color: AppTheme.accent,
                                    barWidth: 2.5,
                                    isStrokeCapRound: true,
                                    dotData: _statDots(AppTheme.accent),
                                    belowBarData: BarAreaData(
                                      show: true,
                                      gradient:
                                          _statGradient(AppTheme.accent),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 目标体重入口（openGym 借鉴）：点改数字，防呆同身体录入
            Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => _editGoalWeight(c),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      const Icon(Icons.flag,
                          size: 18, color: AppTheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(tx('目标体重', en: 'Goal Weight'),
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                      Text(
                        goal > 0 ? fmtWt(goal) : tx('未设', en: 'Not set'),
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: goal > 0
                                ? AppTheme.primary
                                : AppTheme.textDim),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right,
                          size: 18, color: AppTheme.textDim),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: tx('记录今天', en: 'Log Today'),
              icon: Icons.edit_note,
              iconColor: AppTheme.primary,
              child: Column(
                children: [
                  TextField(
                    controller: _weightCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: _bodyFieldDecoration(
                        tx('体重 (${unitLabel()})',
                            en: 'Body Weight (${unitLabel()})')),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _waistCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: _bodyFieldDecoration(
                        tx('腰围 (cm，可选)', en: 'Waist (cm, optional)')),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _fatCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: _bodyFieldDecoration(
                        tx('体脂率 (%，可选)', en: 'Body Fat (%, optional)')),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () async {
                      final wDisp = double.tryParse(_weightCtrl.text);
                      final waist = double.tryParse(_waistCtrl.text);
                      final fat = double.tryParse(_fatCtrl.text);
                      if (wDisp == null && waist == null && fat == null) {
                        toast(this.context,
                            tx('至少填一项', en: 'Fill in at least one field'));
                        return;
                      }
                      // lb 模式：输入按 lb，落库前换算回 kg（kg 唯一存储口径）
                      final w = wDisp == null
                          ? null
                          : (WeightUnits.isLb ? lbToKg(wDisp) : wDisp);
                      // 防呆区间（wger measurements/limits 口径）：超界直接拦，
                      // 防手滑多敲一位把曲线打飞（单位填错也拦得住）
                      final err = validateBodyMetric(
                          weightKg: w, waistCm: waist, bodyFatPct: fat);
                      if (err != null) {
                        toast(this.context, err);
                        return;
                      }
                      await c.db.upsertBodyMetric(BodyMetric(
                        date: fmtDate(DateTime.now()),
                        weightKg: w,
                        waistCm: waist,
                        bodyFatPct: fat,
                      ));
                      _weightCtrl.clear();
                      _waistCtrl.clear();
                      _fatCtrl.clear();
                      if (mounted) {
                        toast(this.context, tx('已记录', en: 'Saved'));
                        setState(() {
                          _future = app(this.context).db.bodyMetrics();
                        });
                      }
                    },
                    child: Text(tx('保存', en: 'Save')),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 身体录入输入框统一外观：深色填充 + 无边框，聚焦时亮绿描边，
  /// 比默认下划线在深底上更清晰（数据页三连输入框）。
  InputDecoration _bodyFieldDecoration(String label) => InputDecoration(
        labelText: label,
        filled: true,
        fillColor: AppTheme.cardHi.withValues(alpha: 0.55),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide:
                const BorderSide(color: AppTheme.primary, width: 1.4)),
      );

  /// 体重图触摸提示的日期（x = data 下标）。
  String _bodyDate(List<BodyMetric> data, double x) {
    final i = x.round();
    if (i < 0 || i >= data.length) return '';
    final dt = parseDate(data[i].date);
    return '${dt.month}/${dt.day}';
  }

  /// 体重图 x 轴标签：约 4 个日期，避免窄屏叠字。
  Widget _bodyDateLabel(List<BodyMetric> data, int i) {
    if (i < 0 || i >= data.length) return const SizedBox.shrink();
    final step = (data.length / 4).ceil().clamp(1, data.length);
    if (i % step != 0 && i != data.length - 1) {
      return const SizedBox.shrink();
    }
    final dt = parseDate(data[i].date);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text('${dt.month}/${dt.day}',
          style: const TextStyle(color: AppTheme.textDim, fontSize: 10)),
    );
  }

  /// 目标体重编辑（底部弹层）：点行唤起、可取消可清除；
  /// 防呆复用 validateBodyMetric 的体重区间（20-350kg）。
  /// 返回值：'save' 保存 / 'clear' 清除 / null 取消。
  Future<void> _editGoalWeight(AppContainer c) async {
    final ctrl = TextEditingController(
        text: c.settings.weightGoalKg > 0
            ? fmtVal(c.settings.weightGoalKg)
            : '');
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              20, 16, 20, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tx('目标体重', en: 'Goal Weight'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: tx('目标体重 (${unitLabel()})',
                        en: 'Goal Weight (${unitLabel()})')),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (c.settings.weightGoalKg > 0)
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, 'clear'),
                      child: Text(tx('清除目标', en: 'Clear'),
                          style:
                              const TextStyle(color: AppTheme.danger)),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(tx('取消', en: 'Cancel'),
                        style:
                            const TextStyle(color: AppTheme.textDim)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, 'save'),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(96, 48)),
                    child: Text(tx('保存', en: 'Save')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result == 'clear') {
      c.settings.weightGoalKg = 0;
      await c.settings.save();
      if (mounted) {
        toast(context, tx('已清除目标体重', en: 'Goal weight cleared'));
        setState(() {});
      }
      return;
    }
    final vDisp = double.tryParse(ctrl.text.trim());
    if (vDisp == null) {
      toast(context, tx('请输入数字，如 65.5', en: 'Enter a number, e.g. 65.5'));
      return;
    }
    // lb 模式输入换算回 kg；防呆区间与身体录入同一套（体重 20-350kg）
    final v = WeightUnits.isLb ? lbToKg(vDisp) : vDisp;
    final err = validateBodyMetric(weightKg: v);
    if (err != null) {
      toast(context, err);
      return;
    }
    c.settings.weightGoalKg = v;
    await c.settings.save();
    if (mounted) {
      toast(context, tx('目标体重已设为 ${fmtWt(v)}',
          en: 'Goal weight set to ${fmtWt(v)}'));
      setState(() {});
    }
  }
}

// ---------------- 数据页筛选组件（2026-09-27 重设计） ----------------

/// 统计页统一筛选下拉：替代 SegmentedButton / ChoiceChip 混排——
/// 窄屏上会挤成竖排、多行折行，M3 默认蓝色胶囊也与深底绿主题违和。
/// 自绘按钮壳贴 AppTheme（cardHi 底、圆角），菜单项选中打绿勾。
class _StatDropdown<T> extends StatelessWidget {
  const _StatDropdown({
    required this.value,
    required this.entries,
    required this.onChanged,
  });

  final T value;
  final List<(T, String)> entries;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final match = entries.where((e) => e.$1 == value).toList();
    final label = match.isEmpty ? entries.first.$2 : match.first.$2;
    return PopupMenuButton<T>(
      initialValue: value,
      position: PopupMenuPosition.under,
      color: AppTheme.card,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      constraints: const BoxConstraints(minWidth: 128),
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final (v, text) in entries)
          PopupMenuItem(
            value: v,
            height: 44,
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: v == value
                      ? const Icon(Icons.check,
                          size: 16, color: AppTheme.primary)
                      : null,
                ),
                const SizedBox(width: 6),
                Text(
                  text,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: v == value ? FontWeight.w700 : FontWeight.w500,
                      color: v == value ? AppTheme.primary : AppTheme.text),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: AppTheme.cardHi, borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 16, color: AppTheme.textDim),
          ],
        ),
      ),
    );
  }
}

/// 热力图口径小分段（时长/吨位）：自绘胶囊贴 AppTheme，
/// 不用 M3 ToggleButtons（默认白描边 + 独立 textStyle 在深底上显得突兀，
/// 且测试字体下易丢中文）。点击目标 28dp 高，符合卡片标题行节奏。
class _HeatToggle extends StatelessWidget {
  const _HeatToggle({required this.timeSelected, required this.onChanged});

  final bool timeSelected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, bool selected, VoidCallback onTap) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: selected
                  ? AppTheme.primary.withValues(alpha: 0.18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected ? AppTheme.primary : AppTheme.textDim,
              ),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppTheme.cardHi,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg(tx('时长', en: 'Time'), timeSelected, () => onChanged(true)),
          seg(tx('吨位', en: 'Tonnage'), !timeSelected, () => onChanged(false)),
        ],
      ),
    );
  }
}

/// 1RM 动作选单（底部弹层）：动作库全量 150+，顶部搜索框过滤；
/// 容量前 4 标「主力」徽标，当前选中打勾。
class _LiftPickerSheet extends StatefulWidget {
  const _LiftPickerSheet(
      {required this.all, required this.top, this.current});

  final List<String> all;
  final List<String> top;
  final String? current;

  @override
  State<_LiftPickerSheet> createState() => _LiftPickerSheetState();
}

class _LiftPickerSheetState extends State<_LiftPickerSheet> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _q.text.trim().toLowerCase();
    final list = [
      for (final n in widget.all)
        if (query.isEmpty ||
            n.toLowerCase().contains(query) ||
            exname(n).toLowerCase().contains(query))
          n,
    ];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.72),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 10),
                decoration: BoxDecoration(
                    color: AppTheme.textDim,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(tx('选择动作', en: 'Pick an Exercise'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: TextField(
                controller: _q,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: tx('搜索动作', en: 'Search exercises'),
                  prefixIcon:
                      const Icon(Icons.search, size: 20),
                  filled: true,
                  fillColor: AppTheme.cardHi,
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none),
                ),
              ),
            ),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(tx('没有匹配的动作', en: 'No matching exercises'),
                      style: const TextStyle(color: AppTheme.textDim)),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final n = list[i];
                    final isTop = widget.top.contains(n);
                    return ListTile(
                      dense: true,
                      title: Text(exname(n),
                          style: const TextStyle(fontSize: 14)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isTop)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                  color: AppTheme.primary
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6)),
                              child: Text(tx('主力', en: 'Top'),
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: AppTheme.primary,
                                      fontWeight: FontWeight.w600)),
                            ),
                          if (n == widget.current) ...[
                            const SizedBox(width: 8),
                            const Icon(Icons.check,
                                size: 18, color: AppTheme.primary),
                          ],
                        ],
                      ),
                      onTap: () => Navigator.pop(context, n),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------- 数据页升级组件（openGym 借鉴，2026-10-17） ----------------

/// 热力图格色 5 档：0 = 空格子（比卡片底色略亮，网格结构可见），
/// 1-4 由底色向主题绿渐深。
Color _heatColor(int level) {
  const t = [0.0, 0.35, 0.6, 0.8, 1.0];
  const empty = Color(0xFF29323D);
  if (level <= 0) return empty;
  return Color.lerp(empty, AppTheme.primary, t[level.clamp(0, 4)])!;
}

/// 体重 Δ 颜色语义（概览 KPI 与身体 Tab 共用）：
/// 有目标体重 → 现体重高于目标时降为绿（朝目标）、低于目标时涨为绿；
/// 无目标 → 降绿涨红。latestWeightKg 为 null 时按无目标处理。
Color _weightDeltaColor(double delta, double goalKg, double? latestWeightKg) {
  final cutting = latestWeightKg == null || latestWeightKg >= goalKg;
  final towardGoal = cutting ? delta < 0 : delta > 0;
  return towardGoal ? AppTheme.primary : AppTheme.danger;
}

/// 活动热力图：月份标签 + 周格网（CustomPaint 自绘，不引第三方）+
/// 「少 ▢▢▢▢▢ 多」图例。列 = 周（旧→新），行 = 周一..周日。
class _HeatmapView extends StatelessWidget {
  const _HeatmapView({required this.grid, required this.levels});

  final List<List<double>> grid;
  final List<List<int>> levels;

  static const _enMonths = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      final w = cons.maxWidth;
      // 2px 间距：53 列在手机宽度上能铺满整卡（3px 时格子只剩 4px、
      // 整块看起来像一串虚点）；320 窄屏也不再触发横向滚动
      const gap = 2.0;
      final cols = grid.isEmpty ? 1 : grid.length;
      // 窄屏多列时格子保底 2.5px，装不下就横向滚动兜底；
      // 上限 8.5：宽屏下格子不放大，整卡高度可控（概览首屏装得下）
      final cell = ((w - gap * (cols - 1)) / cols).clamp(2.5, 8.5);
      final gridW = cols * cell + (cols - 1) * gap;
      final gridH = 7 * cell + 6 * gap;
      // 末列 = 本周；由此反推首列周一
      final endMonday = mondayOf(DateTime.now());
      final startMonday =
          endMonday.subtract(Duration(days: 7 * (cols - 1)));
      final graph = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: gridW,
            height: 13,
            child: CustomPaint(
              painter: _MonthLabelPainter(
                  startMonday: startMonday,
                  cols: cols,
                  cell: cell,
                  gap: gap),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: gridW,
            height: gridH,
            child: CustomPaint(
              painter: _HeatCellPainter(
                  levels: levels, cell: cell, gap: gap),
            ),
          ),
        ],
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 320dp 窄屏 53 列装不下：横向滚动兜底（正好装下时不滚）
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: graph,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(tx('少', en: 'Less'),
                  style: const TextStyle(
                      color: AppTheme.textDim, fontSize: 11)),
              const SizedBox(width: 6),
              for (var i = 0; i < 5; i++) ...[
                Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: _heatColor(i),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                if (i < 4) const SizedBox(width: 3),
              ],
              const SizedBox(width: 6),
              Text(tx('多', en: 'More'),
                  style: const TextStyle(
                      color: AppTheme.textDim, fontSize: 11)),
            ],
          ),
        ],
      );
    });
  }
}

/// 月份标签：月份变化的列顶标「N 月」（英文用三字母缩写）。
class _MonthLabelPainter extends CustomPainter {
  _MonthLabelPainter({
    required this.startMonday,
    required this.cols,
    required this.cell,
    required this.gap,
  });

  final DateTime startMonday;
  final int cols;
  final double cell;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    var prevMonth = -1;
    // 相邻月份只隔 4-5 周，53 列时标签会挤成「10月11月12月」一条；
    // 维护已画标签的右边界，放不下就跳过该月（保持可读的留白）
    var lastRight = double.negativeInfinity;
    for (var i = 0; i < cols; i++) {
      final d = startMonday.add(Duration(days: 7 * i));
      if (d.month == prevMonth) continue;
      prevMonth = d.month;
      final tp = TextPainter(
        text: TextSpan(
          text: Lang.isEn
              ? _HeatmapView._enMonths[d.month - 1]
              : '${d.month}月',
          style: const TextStyle(
              color: AppTheme.textDim, fontSize: 9, fontFamily: 'Roboto'),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      // 右侧列的标签可能越界：末列前移防裁切
      final x = (i * (cell + gap))
          .clamp(0.0, (size.width - tp.width).clamp(0.0, double.infinity))
          .toDouble();
      if (x < lastRight + 6) continue;
      tp.paint(canvas, Offset(x, 0));
      lastRight = x + tp.width;
    }
  }

  @override
  bool shouldRepaint(covariant _MonthLabelPainter old) =>
      old.startMonday != startMonday ||
      old.cols != cols ||
      old.cell != cell;
}

/// 周格网：圆角小方格，色 = activityLevels 的 5 档。
class _HeatCellPainter extends CustomPainter {
  _HeatCellPainter({
    required this.levels,
    required this.cell,
    required this.gap,
  });

  final List<List<int>> levels;
  final double cell;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final radius = Radius.circular(cell * 0.28);
    for (var w = 0; w < levels.length; w++) {
      for (var d = 0; d < levels[w].length; d++) {
        paint.color = _heatColor(levels[w][d]);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(w * (cell + gap), d * (cell + gap), cell, cell),
            radius,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HeatCellPainter old) =>
      old.levels != levels || old.cell != cell || old.gap != gap;
}

/// 余力直方图：0/1/2/3/4/5+ 六柱，柱高按组数占比、柱顶标组数。
/// 1-2 次余力 = 增肌甜点区（主题绿高亮）；0 = 力竭（红警示）；3+ = 淡绿。
class _RirBars extends StatelessWidget {
  const _RirBars({required this.dist});

  final Map<int, int> dist;

  Color _barColor(int b) => b == 0
      ? AppTheme.danger.withValues(alpha: 0.55)
      : (b <= 2 ? AppTheme.primary : AppTheme.primary.withValues(alpha: 0.35));

  Color _labelColor(int b) => b == 0
      ? AppTheme.danger
      : (b <= 2 ? AppTheme.primary : AppTheme.textDim);

  @override
  Widget build(BuildContext context) {
    final maxCount = dist.values.fold(0, (a, b) => a > b ? a : b);
    return SizedBox(
      height: 148,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var b = 0; b <= 5; b++)
            Expanded(
              child: Column(
                children: [
                  Text(
                    '${dist[b] ?? 0}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: (dist[b] ?? 0) > 0
                            ? _labelColor(b)
                            : AppTheme.textDim),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: FractionallySizedBox(
                      widthFactor: 0.62,
                      // 轨道：没有组的桶也保留一根淡色柱，六档结构一眼可见
                      child: Container(
                        alignment: Alignment.bottomCenter,
                        decoration: BoxDecoration(
                          color: AppTheme.cardHi.withValues(alpha: 0.45),
                          borderRadius:
                              const BorderRadius.vertical(
                                  top: Radius.circular(6)),
                        ),
                        child: FractionallySizedBox(
                          heightFactor: maxCount <= 0
                              ? 0.0
                              : (dist[b] ?? 0) / maxCount,
                          widthFactor: 1,
                          child: Container(
                            decoration: BoxDecoration(
                              color: _barColor(b),
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(6)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    b == 5 ? '5+' : '$b',
                    style: const TextStyle(
                        color: AppTheme.textDim, fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
