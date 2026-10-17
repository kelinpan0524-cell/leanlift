import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../db/db.dart';
import '../engine/engine.dart';
import 'plan_repository.dart';

/// 导出：CSV / JSON 全量 / AI 分析包（Markdown，可直接粘给任何 AI）。
class ExportService {
  ExportService(this._db);

  final Db _db;

  Future<File> _writeTmp(String name, String content) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/$name');
    await f.writeAsString(content, flush: true);
    return f;
  }

  Future<void> shareText(String title, String text, {String? filename}) async {
    if (filename != null) {
      final f = await _writeTmp(filename, text);
      await Share.shareXFiles([XFile(f.path)], subject: title, text: title);
    } else {
      await Share.share(text, subject: title);
    }
  }

  String _csv(String v) => '"${v.replaceAll('"', '""')}"';

  /// 动作的实际组间休息（相邻两组 doneAt 之差的平均，>30 分钟的跨动作/中场
  /// 休息剔除）。计划休息秒数带上，AI 才能对比"计划 vs 实际"。
  String _actualRestNote(SessionExercise se, List<SetEntry> sets) {
    if (sets.length < 2) return '';
    final gaps = <int>[];
    for (var i = 1; i < sets.length; i++) {
      final g = sets[i].doneAt - sets[i - 1].doneAt;
      if (g > 0 && g < 30 * 60 * 1000) gaps.add(g);
    }
    if (gaps.isEmpty) return '';
    final avgSec = (gaps.fold(0, (a, b) => a + b) / gaps.length / 1000).round();
    final planned = se.restSec > 0 ? '计划休 ${se.restSec}s' : '休息跟随全局设置';
    return '（$planned · 实际均休 ~${avgSec}s）';
  }

  Future<String> buildCsv() async {
    final sessions = await _db.recentSessions(limit: 100000);
    // v14 起带动作记录形态三列：logging/load_type（动作行）、duration_sec
    // （计时组实际保持秒数，非计时/老记录为空）。
    final buf = StringBuffer(
        'date,plan_day,exercise,weight_kg,reps,rir,kind,done_at,logging,load_type,duration_sec\n');
    for (final s in sessions) {
      final ses = await _db.sessionExercises(s.id!);
      final map = await _db.setsOfSession(s.id!);
      for (final se in ses) {
        for (final set in map[se.id!] ?? const <SetEntry>[]) {
          buf.writeln(
              '${s.date},${_csv(s.planDayTitle)},${_csv(se.name)},${set.weightKg},${set.reps},${set.rir},${set.kind},${set.doneAt},${se.logging},${se.loadType},${set.durationSec ?? ''}');
        }
      }
    }
    return buf.toString();
  }

  Future<String> buildJson() async {
    final all = await _db.exportAllJson();
    return const JsonEncoder.withIndent('  ').convert(all);
  }

  /// 从全量 JSON 恢复（清空后写入）。返回恢复的训练次数；
  /// 缺关键数据段时抛 FormatException，行损坏交给 Db.restoreAll 的事务兜底。
  /// v14 键（logging/load_type/duration_sec）老备份行缺失时由列 DEFAULT
  /// 回默认（按次数 + 常规负重），无需预处理。
  Future<int> restoreFromJson(Map<String, dynamic> data) async {
    for (final k in const [
      'plans',
      'plan_days',
      'plan_exercises',
      'sessions',
      'session_exercises',
      'sets',
    ]) {
      if (data[k] is! List) {
        throw FormatException('备份缺少必要数据段（$k）');
      }
    }
    await _db.restoreAll(data);
    return (data['sessions'] as List).length;
  }

  String _hhmm(int epochMs) {
    final t = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  /// AI 数据包（纯数据，无提示词）：App 内「AI 教练」的对话上下文。
  /// [bodyWeightKg]：自重容量折算体重——不传/传 0 时自重动作容量记 0
  /// （旧口径）。调用点传 settings.bodyWeightKg 与统计页保持同一容量口径。
  /// [planRepo]：非 null 时数据包第一段插入「当前计划与日程」（使用中计划、
  /// 今天/明天练什么、未来 7 天日程）——LLM 不知道今天几号，导出分享类
  /// 调用不传则该段不出现。
  Future<String> buildAiData({
    int weeks = 8,
    double bodyWeightKg = 0,
    PlanRepository? planRepo,
  }) async {
    final now = DateTime.now();
    final from = fmtDate(now.subtract(Duration(days: weeks * 7)));
    final to = fmtDate(now);
    final sessions = await _db.sessionsBetween(from, to);

    final buf = StringBuffer();
    if (planRepo != null) {
      final snap = await _resolvePlanContext(planRepo, now);
      if (snap != null) {
        buf.write(buildPlanContextSection(snap));
        buf.writeln();
      }
    }
    buf.writeln('## 训练概要');
    buf.writeln('- 数据时间范围：$from 至 $to');
    buf.writeln('- 训练次数：${sessions.length} 次');
    if (sessions.isNotEmpty) {
      final span = sessions.last.date == sessions.first.date
          ? sessions.first.date
          : '${sessions.first.date} ~ ${sessions.last.date}';
      buf.writeln('- 时间跨度：$span');
      // 主观自评分布（v8 起总结页可选填）：给 AI 教练的恢复/疲劳信号
      final rated = sessions.where((s) => s.impression != null).toList();
      if (rated.isNotEmpty) {
        final good = rated.where((s) => s.impression == 3).length;
        final ok = rated.where((s) => s.impression == 2).length;
        final bad = rated.where((s) => s.impression == 1).length;
        buf.writeln(
            '- 主观自评（${rated.length}/${sessions.length} 次已评）：好 $good · 一般 $ok · 差 $bad');
      }
    }
    buf.writeln();
    buf.writeln('## 每次训练明细');
    final byNameVolume = <String, double>{};
    for (final s in sessions) {
      final ses = await _db.sessionExercises(s.id!);
      final map = await _db.setsOfSession(s.id!);
      final stats = sessionStatsFrom(map, ses, bodyWeightKg: bodyWeightKg);
      buf.writeln('### ${s.date} ${s.planDayTitle}');
      final feel = switch (s.impression) {
        1 => ' · 自评差',
        2 => ' · 自评一般',
        3 => ' · 自评好',
        _ => '',
      };
      final timeNote = s.restMs > 0
          ? '（训练 ${(s.activeMs / 60000).ceil()} 分 · 休息 ${(s.restMs / 60000).ceil()} 分）'
          : '';
      buf.writeln('- 总容量 ${stats.volume.toStringAsFixed(0)}kg · 正式组 ${stats.workingSets} 组 · 时长 ${s.durationMin} 分钟$feel$timeNote');
      for (final se in ses) {
        final sets = map[se.id!] ?? const <SetEntry>[];
        if (sets.isEmpty) continue;
        // 计时动作（v14）组表述带秒数单位，按次数动作保持原样
        final desc = sets
            .map((x) =>
                '${x.weightKg}kg×${x.durationSec != null ? '${x.durationSec}秒' : '${x.reps}'}${x.kind == SetKind.warmup ? '(热)' : x.kind == SetKind.failure ? '(失)' : ''}')
            .join(', ');
        buf.writeln('- ${se.name}${_loggingNote(se)}: $desc${_actualRestNote(se, sets)}');
        byNameVolume[se.name] = (byNameVolume[se.name] ?? 0) +
            sets.fold(
                0.0,
                (a, b) =>
                    a +
                    setVolumeWithBodyweight(b,
                        exerciseName: se.name, bodyWeightKg: bodyWeightKg));
      }
      buf.writeln();
    }
    if (byNameVolume.isNotEmpty) {
      buf.writeln('## 各动作累计容量（kg）');
      final sorted = byNameVolume.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in sorted) {
        buf.writeln('- ${e.key}: ${e.value.toStringAsFixed(0)}');
      }
      buf.writeln();
    }
    final body = await _db.bodyMetrics(limit: 60);
    if (body.isNotEmpty) {
      buf.writeln('## 身体数据');
      for (final b in body) {
        final parts = <String>[];
        if (b.weightKg != null) parts.add('体重 ${b.weightKg}kg');
        if (b.waistCm != null) parts.add('腰围 ${b.waistCm}cm');
        if (b.bodyFatPct != null) parts.add('体脂 ${b.bodyFatPct}%');
        if (parts.isNotEmpty) buf.writeln('- ${b.date}: ${parts.join('，')}');
      }
      buf.writeln();
    }
    buf.writeln('## 原始数据（JSON，供核对）');
    final compact = <Map<String, dynamic>>[];
    for (final s in sessions) {
      final ses = await _db.sessionExercises(s.id!);
      final map = await _db.setsOfSession(s.id!);
      compact.add({
        'date': s.date,
        'day': s.planDayTitle,
        'exercises': [
          for (final se in ses)
            {
              'name': se.name,
              // v14：非默认记录形态才带键，默认形态保持老结构
              if (se.logging != LoggingMode.reps) 'logging': se.logging,
              if (se.loadType != LoadMode.weighted) 'load_type': se.loadType,
              'sets': [
                for (final x in map[se.id!] ?? const <SetEntry>[])
                  {
                    'w': x.weightKg,
                    'r': x.reps,
                    'rir': x.rir,
                    'kind': x.kind,
                    if (x.durationSec != null) 'dur_s': x.durationSec,
                  }
              ],
            }
        ],
      });
    }
    buf.writeln('```json');
    buf.writeln(jsonEncode(compact));
    buf.writeln('```');
    return buf.toString();
  }

  /// AI 分析包：预制教练提示词 + 数据包（buildAiData）。
  /// 目标：直接整段复制给任意大模型，即可获得训练分析与总结。
  Future<String> buildAiPack({
    int weeks = 8,
    double bodyWeightKg = 0,
    PlanRepository? planRepo,
  }) async {
    final buf = StringBuffer();
    buf.writeln('# 训练数据分析请求');
    buf.writeln();
    buf.writeln('你是一位专业力量训练教练。请基于下面的结构化数据分析：');
    buf.writeln('1. 各大项（深蹲/卧推/硬拉/推举）的进步趋势，指出停滞或退步的动作；');
    buf.writeln('2. 训练频率与容量是否足以支撑渐进超负荷；');
    buf.writeln('3. 肌群均衡度（哪个肌群训练量偏低）；');
    buf.writeln('4. 组间休息是否合适：结合"计划休息 vs 实际休息"判断哪些动作休息过长或过短'
        '（参考：增肌复合动作 90-180 秒、辅助动作 60-90 秒、大重量低次数力量组 3-5 分钟）；');
    buf.writeln('5. 给出未来 2-4 周的具体调整建议（加重策略、弱项补强、恢复建议）。');
    buf.writeln();
    buf.write(await buildAiData(
        weeks: weeks, bodyWeightKg: bodyWeightKg, planRepo: planRepo));
    return buf.toString();
  }

  /// 「当前计划与日程」快照解析：计划现查（不读 repo.activePlan 缓存
  /// ——ai_coach_page._loadData 不调 reload，缓存可能过期），逐日走
  /// repo.dayForDateOn（首页同一口径：覆盖行 > 循环推导 > 星期模板）。
  /// 解析不出计划返回 null，调用方整段省略。
  Future<PlanContextSnapshot?> _resolvePlanContext(
      PlanRepository repo, DateTime now) async {
    final plan = await _db.activePlan();
    if (plan == null) return null;
    final today = DateTime(now.year, now.month, now.day);
    final todayDay = await _resolveDayLine(plan, repo, today, expand: true);
    final tomorrowDay = await _resolveDayLine(
        plan, repo, today.add(const Duration(days: 1)));
    final next7 = <PlanDayLine>[];
    for (var i = 0; i < 7; i++) {
      next7.add(
          await _resolveDayLine(plan, repo, today.add(Duration(days: i))));
    }
    const wd = '一二三四五六日';
    final String scheduleDesc;
    if (plan.isCycle) {
      final head = plan.cycleRest > 0
          ? '循环 练${plan.cycleTrain}休${plan.cycleRest}'
          : '循环连练 ${plan.cycleTrain} 天（未设休息日）';
      if (plan.patternStart.isEmpty) {
        scheduleDesc = '$head（未设起始日，暂无法推导）';
      } else {
        final start = parseDate(plan.patternStart);
        scheduleDesc =
            '$head，起始日 ${plan.patternStart}（周${wd[start.weekday - 1]}）';
      }
    } else {
      final days = await _db.planDays(plan.id!);
      final byWd = <int, String>{for (final d in days) d.weekday: d.title};
      scheduleDesc = '按星期（${[
        for (var i = 1; i <= 7; i++)
          if (byWd[i] != null) '周${wd[i - 1]}=${byWd[i]}',
      ].join('；')}）';
    }
    // 'active' 可能是上次崩溃残留（session_controller 有恢复逻辑），
    // 文案用「尚未结束」而不是断言用户此刻正在训练。
    final active = await _db.activeSession();
    final sessionNote = active == null
        ? null
        : '${active.planDayTitle}（${fmtDate(DateTime.fromMillisecondsSinceEpoch(active.startedAt))} '
            '${_hhmm(active.startedAt)} 开始，尚未结束）';
    return PlanContextSnapshot(
      today: fmtDate(today),
      planName: plan.name,
      scheduleDesc: scheduleDesc,
      todayDay: todayDay,
      tomorrowDay: tomorrowDay,
      next7: next7,
      activeSessionNote: sessionNote,
    );
  }

  /// 单日行解析。dayForDateOn 返回 null → 休息日；返回训练日但动作清单为空
  /// → 「标题（未编排动作）」不当作休息日（飞书同步会跳过空动作日，这里刻意
  /// 不跳，避免 AI 对当天安排得出错误结论）。只有今天（expand=true）逐动作展开。
  Future<PlanDayLine> _resolveDayLine(
      Plan plan, PlanRepository repo, DateTime d,
      {bool expand = false}) async {
    final day = await repo.dayForDateOn(plan, d);
    final date = fmtDate(d);
    if (day == null) {
      return PlanDayLine(date: date, title: '');
    }
    final exs = await _db.dayExercises(day.id!);
    if (exs.isEmpty) {
      return PlanDayLine(date: date, title: '${day.title}（未编排动作）');
    }
    return PlanDayLine(
      date: date,
      title: day.title,
      exCount: exs.length,
      exLines: expand
          ? [
              for (var k = 0; k < exs.length; k++)
                '${exs[k].name} ${exs[k].sets}×${exs[k].repsMin}-${exs[k].repsMax}'
                '${_supersetNote(exs, k)}',
            ]
          : const [],
    );
  }

  /// 超级组标注（AI 教练数据包用，v9）：连续段的第一人注明与谁配对
  /// 交替，让教练看得懂今天的安排；段中/段尾与未配对动作不加尾巴。
  static String _supersetNote(List<PlanExercise> exs, int k) {
    final t = exs[k].supersetTag;
    if (t.isEmpty) return '';
    if (k > 0 && exs[k - 1].supersetTag == t) return ''; // 段中/段尾
    if (k + 1 >= exs.length || exs[k + 1].supersetTag != t) return '';
    return '（超级组：与「${exs[k + 1].name}」配对交替）';
  }

  /// 记录形态标注（v14，AI 教练数据包用）：仅非默认形态加尾巴，教练才
  /// 读得懂「60秒×3组」与单侧/自重的口径。默认形态输出空串（老格式不变）。
  static String _loggingNote(SessionExercise se) {
    final tags = <String>[
      if (se.logging == LoggingMode.time) '按时间记秒',
      if (se.logging == LoggingMode.repsPerSide) '单侧动作记总数',
      if (se.loadType == LoadMode.bodyweight) '自重',
    ];
    return tags.isEmpty ? '' : '（${tags.join('·')}）';
  }
}

/// 「当前计划与日程」单日行。title 为空 = 休息日；exLines 仅今天展开
/// （已格式化为「杠铃卧推 4×6-8」）。
class PlanDayLine {
  final String date; // yyyy-MM-dd
  final String title; // '' = 休息日；「标题（未编排动作）」= 训练日但无动作
  final int exCount;
  final List<String> exLines;

  const PlanDayLine({
    required this.date,
    required this.title,
    this.exCount = 0,
    this.exLines = const [],
  });
}

/// 「当前计划与日程」快照（纯数据）。planName 为空 = 无使用中计划。
class PlanContextSnapshot {
  final String today; // yyyy-MM-dd
  final String planName;
  final String scheduleDesc;
  final PlanDayLine? todayDay;
  final PlanDayLine? tomorrowDay;
  final List<PlanDayLine> next7;
  final String? activeSessionNote;

  const PlanContextSnapshot({
    required this.today,
    required this.planName,
    required this.scheduleDesc,
    required this.todayDay,
    required this.tomorrowDay,
    required this.next7,
    required this.activeSessionNote,
  });
}

/// 「当前计划与日程」段文本组装（纯函数，无 DB/网络/密钥，可直接单测）。
/// 全中文紧凑，喂给大模型的数据段不走 tx() 本地化。
String buildPlanContextSection(PlanContextSnapshot s) {
  const wd = '一二三四五六日';
  final buf = StringBuffer('## 当前计划与日程（日期为绝对日期）\n');
  if (s.planName.isEmpty) {
    buf.writeln('- 使用中计划：无（未启用任何训练计划）');
    return buf.toString();
  }
  buf.writeln('- 使用中计划：${s.planName}');
  if (s.scheduleDesc.isNotEmpty) buf.writeln('- 排程方式：${s.scheduleDesc}');
  String weekdayOf(String date) => '周${wd[DateTime.parse(date).weekday - 1]}';
  String dayLabel(PlanDayLine d) {
    if (d.title.isEmpty) return '休息日';
    if (d.exCount == 0) return d.title; // 已含「（未编排动作）」后缀
    return '${d.title}（${d.exCount} 个动作）';
  }

  final today = s.todayDay;
  if (today != null) {
    buf.writeln(today.title.isEmpty
        ? '- 今天 ${today.date}（${weekdayOf(today.date)}）：'
            '今天是休息日（按计划无训练安排）'
        : '- 今天 ${today.date}（${weekdayOf(today.date)}）：${today.title}');
    if (today.exLines.isNotEmpty) {
      buf.writeln('- 动作清单（组×次）：');
      for (final line in today.exLines) {
        buf.writeln('  - $line');
      }
    }
  }
  final tomorrow = s.tomorrowDay;
  if (tomorrow != null) {
    buf.writeln(
        '- 明天 ${tomorrow.date}（${weekdayOf(tomorrow.date)}）：${dayLabel(tomorrow)}');
  }
  if (s.next7.isNotEmpty) {
    buf.writeln('- 未来 7 天日程：');
    for (final d in s.next7) {
      buf.writeln('  - ${d.date} ${weekdayOf(d.date)}：${dayLabel(d)}');
    }
  }
  if (s.activeSessionNote != null) {
    buf.writeln('- 注意：当前有一场进行中的训练会话「${s.activeSessionNote}」');
  }
  return buf.toString();
}
