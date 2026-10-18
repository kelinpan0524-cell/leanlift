import 'dart:async';

import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../l10n/lang.dart';
import '../l10n/names.dart';
import '../presets/exercise_library.dart';
import '../services/ai_service.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 本地周复盘页（P1-E1，2026-10-18）：
/// 不配置 AI Key 也能看「这周练得怎么样、下周做什么」。
/// 复盘数字全部来自本机 SQLite；只有用户配置了 AI 且打开「AI 自动写周报」
/// 时，页面才会在前台可见时主动请求一次 AI，绝不在后台发起网络请求。
class WeeklyRecapPage extends StatefulWidget {
  const WeeklyRecapPage({super.key, this.now});

  /// 测试注入的「今天」；null = 系统当前时间。
  final DateTime? now;

  @override
  State<WeeklyRecapPage> createState() => _WeeklyRecapPageState();
}

/// 周复盘页路由观察者：页面被别的路由盖住时中止在途 AI 请求。
/// 由 `MaterialApp.navigatorObservers` 注册（main.dart）；单独 pump 页面的
/// 测试没有注册也不受影响（只是收不到路由事件）。
final RouteObserver<ModalRoute<dynamic>> weeklyRecapRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();

class _WeeklyRecapPageState extends State<WeeklyRecapPage>
    with WidgetsBindingObserver, RouteAware {
  Future<WeeklyRecap>? _future;

  /// 最近一次加载好的本地复盘（AI 重试复用，不重复查库）。
  WeeklyRecap? _recap;

  /// AI 叙事（P1-E2）：只在页面打开时前台请求一次；失败回退本地版。
  bool _aiRequested = false;
  bool _aiLoading = false;
  bool _aiCancelled = false;
  String? _aiText;
  String? _aiError;

  /// 发起请求的 AiService（页面关闭/退后台时中止在途 HTTP）。
  AiService? _aiService;

  /// 刷新/重试/取消的代际号：旧请求晚到不能覆盖新状态。
  int _aiGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // initState 里不能同步读 InheritedWidget，延后一帧再加载
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _future = _load();
      });
      _future!.then((recap) {
        if (!mounted) return;
        _recap = recap;
        _maybeGenerateAi();
      }, onError: (Object _) {
        // FutureBuilder 展示错误态；AI 不启动。
      });
    });
  }

  @override
  void dispose() {
    weeklyRecapRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _cancelAiRequest();
    _aiGeneration++; // 让在途请求的回包失效
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) weeklyRecapRouteObserver.subscribe(this, route);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 打开页面时若正好在后台（或被系统压后台），回到前台再补一次；
      // 已经请求过则不会重复（_aiRequested 门控）。
      _maybeGenerateAi();
    } else {
      // 退到后台立即中止在途请求：绝不让 AI 请求在后台继续收发。
      _cancelAiRequest();
    }
  }

  @override
  void didPushNext() {
    // 被别的页面盖住：页面已不可见，中止在途 AI 请求。
    _cancelAiRequest();
  }

  @override
  void didPopNext() {
    // 从别的页面返回本页：补算一次 AI 周报。典型场景是刚去设置页
    // 配好了 AI/打开开关——首载时条件不满足没请求过（_aiRequested
    // 仍为 false），回来后这里补上；已生成过则内部门控拦住不重复。
    _maybeGenerateAi();
  }

  /// 中止在途 AI 请求（页面关闭/退后台/被盖住）；失败文案由 catch 分支
  /// 按 [_aiCancelled] 静默处理，不把「用户离开」误报成网络错误。
  void _cancelAiRequest() {
    if (!_aiLoading) return;
    _aiCancelled = true;
    _aiService?.cancelWeeklyRecapNarrative();
  }

  /// 下拉刷新重算本地数据；成功后若 AI 还没请求过（_aiRequested=false，
  /// 比如首载时页面被盖住/不在前台），补发一次生成。已生成过则
  /// [_maybeGenerateAi] 的门控拦住，不会为刷新重复烧 Token——
  /// 要主动重写周报仍走 AI 卡的「重试」。
  Future<void> _refresh() async {
    final next = _load();
    setState(() {
      _future = next;
    });
    try {
      final recap = await next;
      if (!mounted) return;
      _recap = recap;
      await _maybeGenerateAi();
    } catch (_) {
      // FutureBuilder 已负责错误态；这里吞掉，避免 RefreshIndicator
      // 把失败冒泡成未处理异常。
    }
  }

  /// AI 周报只在「配置了 AI + 用户打开开关 + App 前台 + 本页是当前路由」
  /// 时请求一次。绝不后台联网：不满足条件就跳过，用户可点「重试」手动触发。
  Future<void> _maybeGenerateAi({bool retry = false}) async {
    if (!mounted) return;
    final c = app(context);
    if (!c.settings.aiConfigured || !c.settings.aiWeeklyRecapOn) return;
    if (_aiLoading) return;
    if (_aiRequested && !retry) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    // 页面被别的路由盖住时不算「打开着」：即使 App 仍在前台也不联网。
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    final recap = _recap;
    if (recap == null) return;

    _aiRequested = true;
    _aiCancelled = false;
    _aiService = c.ai;
    final generation = ++_aiGeneration;
    setState(() {
      _aiLoading = true;
      _aiError = null;
    });
    try {
      final text = await c.ai.weeklyRecapNarrative(recap);
      if (!mounted || generation != _aiGeneration) return;
      setState(() {
        _aiText = text;
        _aiLoading = false;
      });
    } on AiException catch (e) {
      if (!mounted || generation != _aiGeneration) return;
      if (_aiCancelled) {
        // 用户离开/退后台导致的中止：保留本地版，不误报网络错误。
        _aiCancelled = false;
        setState(() {
          _aiLoading = false;
        });
        return;
      }
      setState(() {
        _aiError = e.message;
        _aiLoading = false;
      });
    } catch (e) {
      if (!mounted || generation != _aiGeneration) return;
      if (_aiCancelled) {
        _aiCancelled = false;
        setState(() {
          _aiLoading = false;
        });
        return;
      }
      setState(() {
        _aiError = e.toString();
        _aiLoading = false;
      });
    }
  }

  void _retryAi() {
    _maybeGenerateAi(retry: true);
  }

  Future<WeeklyRecap> _load() async {
    final c = app(context);
    await c.planRepo.reload();
    final now = widget.now ?? DateTime.now();
    final weekStart = mondayOf(now);
    final weekEnd = weekStart.add(const Duration(days: 6));
    final prevStart = weekStart.subtract(const Duration(days: 7));

    // 本周计划：按当前生效排程（覆盖行 > 循环 > 星期模板）逐天解析。
    // 自动顺延/手动改期都通过排程生效：顺延后的内容只在新日期计一次，
    // 原日期的休息墓碑不回补成「缺勤」——否则同一份计划会被算两遍，
    // 手动休息/清空也会被误判成缺勤。
    // 计划创建或启用前的日子不追溯：取 createdAt / activatedAt 的较晚者。
    final planned = <String, RecapPlannedDay>{};
    final plan = c.planRepo.activePlan;
    if (plan?.id != null) {
      final created = plan!.createdAt.trim();
      final activated = plan.activatedAt.trim();
      final planStart =
          activated.isNotEmpty &&
              (created.isEmpty || activated.compareTo(created) > 0)
          ? activated
          : created;

      int setsForDay(int dayId) {
        final exs =
            c.planRepo.exercisesByDayId[dayId] ?? const <PlanExercise>[];
        return exs.fold<int>(0, (acc, e) => acc + e.sets);
      }

      for (var i = 0; i < 7; i++) {
        final day = weekStart.add(Duration(days: i));
        final date = fmtDate(day);
        if (planStart.isNotEmpty && date.compareTo(planStart) < 0) continue;
        final planDay = await c.planRepo.dayForDateOn(plan, day);
        if (planDay?.id == null) continue;
        final sets = setsForDay(planDay!.id!);
        if (sets > 0) {
          planned[date] = RecapPlannedDay(dayId: planDay.id, workingSets: sets);
        }
      }
    }

    final sessions = await c.db.sessionsBetween(
      fmtDate(weekStart),
      fmtDate(weekEnd),
    );
    // 明细多取一周：1RM 进步/停滞要与上周对比。
    final rows = await c.db.sessionRowsBetween(
      fmtDate(prevStart),
      fmtDate(weekEnd),
    );
    final bodyMetrics = await c.db.bodyMetrics();

    // 内置词表 + DB 沉淀（自定义动作）合并，肌群归类口径与数据页一致。
    final metaMap = {for (final m in kExerciseLibrary) m.name: m};
    final known = metaMap.keys.toSet();
    for (final m in await c.db.allExerciseMeta()) {
      if (!known.contains(m.name)) metaMap[m.name] = m;
    }

    final recapSets = <RecapSetRow>[];
    for (final r in rows) {
      final weight = (r['weight_kg'] as num?)?.toDouble();
      final reps = (r['reps'] as num?)?.toInt();
      if (weight == null || reps == null) continue; // 没有组的动作行
      final dateStr = (r['date'] as String?) ?? '';
      if (dateStr.isEmpty) continue;
      final DateTime day;
      try {
        day = parseDate(dateStr);
      } catch (_) {
        continue; // 坏日期不参与复盘，也不让整页崩掉
      }
      recapSets.add(
        RecapSetRow(
          name: (r['name'] as String?) ?? '',
          exerciseKey: (r['exercise_key'] as String?) ?? '',
          weightKg: weight,
          reps: reps,
          kind: (r['kind'] as String?) ?? SetKind.working,
          date: day,
          sessionId: (r['session_id'] as num?)?.toInt(),
          logging: (r['logging'] as String?) ?? LoggingMode.reps,
        ),
      );
    }

    return weeklyRecap(
      now: now,
      weekStart: weekStart,
      plannedByDate: planned,
      sessions: sessions,
      sets: recapSets,
      excludeProgressSessionIds: c.session.deloadSessionIds,
      metaByName: metaMap,
      bodyMetrics: bodyMetrics,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = app(context).settings;
    final aiOn = settings.aiConfigured && settings.aiWeeklyRecapOn;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: Text(tx('周复盘', en: 'Weekly Recap'))),
      body: FutureBuilder<WeeklyRecap>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 44,
                    color: AppTheme.textDim,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    tx('本周数据没读出来', en: 'Could not load this week'),
                    style: const TextStyle(color: AppTheme.textDim),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _refresh,
                    child: Text(tx('重试', en: 'Retry')),
                  ),
                ],
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final r = snap.data!;
          return RefreshIndicator(
            onRefresh: _refresh,
            color: AppTheme.primary,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _completionCard(r),
                if (aiOn) ...[
                  const SizedBox(height: 12),
                  _aiCard(),
                ],
                const SizedBox(height: 12),
                _actionCard(r),
                const SizedBox(height: 12),
                _progressCard(r),
                const SizedBox(height: 12),
                _muscleCard(r),
                const SizedBox(height: 12),
                _weightCard(r),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      aiOn ? Icons.auto_awesome : Icons.lock_outline,
                      size: 13,
                      color: aiOn ? AppTheme.violetSoft : AppTheme.textDim,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        aiOn
                            ? tx(
                                '复盘数字在手机上计算 · AI 周报仅在打开本页时前台生成',
                                en:
                                    'Recap numbers are computed on your phone · the AI note is generated only while this page is open',
                              )
                            : tx(
                                '全部在手机上计算 · 不需要网络或 AI',
                                en:
                                    'Calculated on your phone · no network or AI needed',
                              ),
                        style: const TextStyle(
                          color: AppTheme.textDim,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 本周完成度：计划训练/正式组 vs 实际完成。
  /// 无计划时不再显示「0/—」，只展示实际完成量并明确说明没有计划。
  Widget _completionCard(WeeklyRecap r) {
    final hasPlan = r.plannedSessions > 0;
    final extraLine = _extraLine(r);
    return SectionCard(
      title: tx('本周完成度', en: 'This Week'),
      icon: Icons.event_available,
      iconColor: AppTheme.primary,
      trailing: Text(
        '${r.weekStart.month}/${r.weekStart.day} - ${r.weekEnd.month}/${r.weekEnd.day}',
        style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _bigStat(
                  tx('训练', en: 'Workouts'),
                  '${r.completedSessions}',
                  valueKey: const ValueKey('recap-total-sessions'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _bigStat(
                  tx('正式组', en: 'Working sets'),
                  '${r.completedWorkingSets}',
                  valueKey: const ValueKey('recap-total-sets'),
                ),
              ),
            ],
          ),
          if (hasPlan) ...[
            const SizedBox(height: 12),
            _progressLine(
              r.completedPlannedSessions,
              r.plannedSessions,
              tx('计划训练', en: 'Planned workouts'),
              valueKey: const ValueKey('recap-plan-sessions'),
            ),
            const SizedBox(height: 6),
            _progressLine(
              r.completedPlannedWorkingSets,
              r.plannedWorkingSets,
              tx('计划组数', en: 'Planned sets'),
              valueKey: const ValueKey('recap-plan-sets'),
            ),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              tx(
                '本周没有可对照的计划训练，上面是实际完成量。',
                en: 'No planned workouts to compare this week — the numbers above are your actual totals.',
              ),
              style: const TextStyle(
                color: AppTheme.textDim,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
          // 没有计划时所有训练都是「实际完成」，不叫「加练」。
          if (hasPlan && extraLine != null) ...[
            const SizedBox(height: 8),
            Text(
              extraLine,
              style: const TextStyle(color: AppTheme.accent, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  /// 计划外说明：计划日之外的训练 + 计划日内超出计划组数的加组。
  String? _extraLine(WeeklyRecap r) {
    final extraSessions = r.extraSessions;
    final extraSets = r.extraWorkingSets;
    if (extraSessions <= 0 && extraSets <= 0) return null;
    if (extraSessions > 0 && extraSets > 0) {
      return tx(
        '另有 $extraSessions 次计划外训练、$extraSets 个计划外正式组（含计划内加组），不计入计划完成。',
        en: 'Plus $extraSessions workouts and $extraSets working sets outside the plan (including extra sets within planned sessions); not counted toward the plan.',
      );
    }
    if (extraSessions > 0) {
      return tx(
        '另有 $extraSessions 次计划外训练，不计入计划完成。',
        en: 'Plus $extraSessions workouts outside the plan, not counted toward the plan.',
      );
    }
    return tx(
      '另有 $extraSets 个计划外正式组（含计划内加组），不计入计划完成。',
      en: 'Plus $extraSets working sets outside the plan (including extra sets within planned sessions), not counted toward the plan.',
    );
  }

  Widget _bigStat(String label, String value, {Key? valueKey}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            key: valueKey,
            maxLines: 1,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }

  Widget _progressLine(int done, int planned, String label, {Key? valueKey}) {
    final ratio = planned <= 0 ? 0.0 : (done / planned).clamp(0.0, 1.0);
    final color = planned > 0 && done >= planned
        ? AppTheme.primary
        : AppTheme.accent;
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              maxLines: 1,
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 7,
              backgroundColor: AppTheme.cardHi,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 52,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              '$done/$planned',
              key: valueKey,
              maxLines: 1,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  /// AI 周报（P1-E2）：打开页面时前台生成一次；失败保留本地版并给重试。
  /// 尚未请求过（打开页面时条件不满足）时给手动入口，绝不显示
  /// 永远转下去的假加载。
  Widget _aiCard() {
    final Widget body;
    if (_aiLoading) {
      body = Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tx('AI 正在写这周总结…', en: 'AI is writing this week’s note…'),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
            ),
          ),
        ],
      );
    } else if (_aiText != null) {
      body = Text(
        _aiText!,
        key: const ValueKey('recap-ai-text'),
        style: const TextStyle(fontSize: 14, height: 1.55),
      );
    } else if (_aiError != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tx(
              'AI 周报没生成出来，已显示下面的本地版。',
              en: 'The AI note did not come through — the local version below still has you covered.',
            ),
            key: const ValueKey('recap-ai-fallback'),
            style: const TextStyle(color: AppTheme.warn, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            _aiError!,
            style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _aiLoading ? null : _retryAi,
              child: Text(tx('重试', en: 'Retry')),
            ),
          ),
        ],
      );
    } else {
      // 没请求过且没在加载（打开页面时被前台/路由条件挡住，补算也没触发）：
      // 给一个明确的生成入口，不再显示没有尽头的加载行。
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tx(
              '本次还没生成过 AI 周报，本地版照常可用。',
              en: 'The AI note has not been generated this time — the local version still works.',
            ),
            key: const ValueKey('recap-ai-pending'),
            style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _retryAi,
              child: Text(tx('生成 AI 周报', en: 'Generate AI note')),
            ),
          ),
        ],
      );
    }
    return SectionCard(
      title: tx('AI 周报', en: 'AI Weekly Note'),
      icon: Icons.auto_awesome,
      iconColor: AppTheme.violetSoft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          body,
          const SizedBox(height: 8),
          Text(
            tx(
              '只在打开本页时前台请求 AI，不会后台联网',
              en: 'AI is requested only while this page is open — never in the background',
            ),
            style: const TextStyle(color: AppTheme.textDim, fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// 一条明确的行动建议（纯本地规则，不调 AI）。
  Widget _actionCard(WeeklyRecap r) {
    return SectionCard(
      title: tx('下周行动', en: 'Next Action'),
      icon: Icons.lightbulb_outline,
      iconColor: AppTheme.warn,
      child: Text(r.action, style: const TextStyle(fontSize: 14, height: 1.55)),
    );
  }

  /// 1RM 进步与停滞：只对比本周与上周都练过的动作（减载场已排除）。
  Widget _progressCard(WeeklyRecap r) {
    final hasAny =
        r.improvedExercises.isNotEmpty || r.stalledExercises.isNotEmpty;
    return SectionCard(
      title: tx('进步与停滞', en: 'Progress & Stalls'),
      icon: Icons.trending_up,
      iconColor: AppTheme.primary,
      child: hasAny
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in r.improvedExercises) _changeRow(e, up: true),
                for (final e in r.stalledExercises) _changeRow(e, up: false),
              ],
            )
          : Text(
              tx(
                '近期还没有可对比的动作。同一动作上周和本周都练过，这里才会判断 1RM 是进步还是停滞。',
                en: 'Nothing to compare yet. An exercise needs to appear both last week and this week before we judge 1RM progress or a stall.',
              ),
              style: const TextStyle(
                color: AppTheme.textDim,
                fontSize: 13,
                height: 1.45,
              ),
            ),
    );
  }

  Widget _changeRow(RecapExerciseChange e, {required bool up}) {
    final color = up ? AppTheme.primary : AppTheme.warn;
    final delta = e.deltaKg;
    final deltaText = delta > 0 ? '+${fmtWt(delta)}' : fmtWt(delta);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            up ? Icons.trending_up : Icons.trending_flat,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  exname(e.name),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${fmtWt(e.previousBest1Rm)} → ${fmtWt(e.best1Rm)} · $deltaText',
                  style: TextStyle(color: color, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 六个肌群的周组数：不足的目标用警示黄，达标用主绿。
  Widget _muscleCard(WeeklyRecap r) {
    final other = r.weeklySetsByMuscle['其他'] ?? 0;
    return SectionCard(
      title: tx('肌群周组数', en: 'Weekly Sets by Muscle'),
      icon: Icons.accessibility_new,
      iconColor: AppTheme.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tx(
              '主肌群 1 组、次肌群 0.5 组折算；含力竭组、不含热身组。',
              en: 'Main muscle counts 1 set, secondary 0.5; failure sets count, warm-ups do not.',
            ),
            style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
          ),
          const SizedBox(height: 6),
          for (final region in kMuscleRegions)
            if (kWeeklySetTargets.containsKey(region))
              _muscleRow(region, r.weeklySetsByMuscle[region] ?? 0),
          // 词表外动作的组数也要露出来：整周只练自定义动作时，
          // 六行都是 0 会让用户以为没练。
          if (other > 0) _otherMuscleRow(other),
        ],
      ),
    );
  }

  Widget _muscleRow(String region, double sets) {
    final target = kWeeklySetTargets[region]!;
    final status = weeklySetStatusOf(region, sets)!;
    final color = weeklySetStatusColor(status);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                mname(region),
                maxLines: 1,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
          Expanded(
            child: Text(
              '${fmtSetDose(sets)} / ${target.min}-${target.max}',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          Text(
            weeklySetStatusText(status),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _otherMuscleRow(double sets) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                mname('其他'),
                maxLines: 1,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
          Expanded(
            child: Text(
              tx(
                '${fmtSetDose(sets)} 组（未归类动作，无目标）',
                en: '${fmtSetDose(sets)} sets (unclassified, no target)',
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// 最近 7 天体重趋势：首条 → 末条 + 差值；不足两条时只显示记录。
  Widget _weightCard(WeeklyRecap r) {
    final trend = r.weightTrend;
    Widget body;
    if (!trend.hasData) {
      body = Text(
        tx(
          '近 7 天还没有体重记录。开练前顺手记一条，下周就能看到变化。',
          en: 'No weigh-ins in the last 7 days. Log one before your next workout and the trend will show up here.',
        ),
        style: const TextStyle(
          color: AppTheme.textDim,
          fontSize: 13,
          height: 1.45,
        ),
      );
    } else if (trend.deltaKg == null) {
      body = Text(
        tx(
          '近 7 天 1 条记录：${fmtWt(trend.startKg!)}。再记一次就能看到增减。',
          en: '1 entry in the last 7 days: ${fmtWt(trend.startKg!)}. Log once more to see the change.',
        ),
        style: const TextStyle(fontSize: 14, height: 1.45),
      );
    } else {
      final delta = trend.deltaKg!;
      final deltaText = delta > 0 ? '+${fmtWt(delta)}' : fmtWt(delta);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${fmtWt(trend.startKg!)} → ${fmtWt(trend.endKg!)}',
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  deltaText,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            tx(
              '近 7 天 ${trend.points.length} 条体重记录',
              en: '${trend.points.length} weigh-ins in the last 7 days',
            ),
            style: const TextStyle(color: AppTheme.textDim, fontSize: 12),
          ),
        ],
      );
    }
    return SectionCard(
      title: tx('7 天体重趋势', en: '7-Day Weight Trend'),
      icon: Icons.monitor_weight_outlined,
      iconColor: AppTheme.accent,
      child: body,
    );
  }
}
