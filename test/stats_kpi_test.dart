// 数据页统计升级（openGym 借鉴）引擎纯函数单测：
//  - computeStatsKpi：四字段（总数/本月/连续周跨周与本周未练不断链/30 天 Δ 边界）
//  - activityHeatmap：空数据全零、维度 = 周数×7、时长三级回退口径、容量口径
//  - rirDistribution：桶归并（5 含 5+）与 since 过滤
//  - rirInsightLine：两主分支 + 空数据
// 全部纯 Dart，不起 DB / 不 pump widget。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/engine/engine.dart';

Session _ses(DateTime day, {String status = 'done'}) => Session(
      date: fmtDate(day),
      planDayTitle: '推日',
      startedAt: day.millisecondsSinceEpoch - 3600000,
      endedAt: day.millisecondsSinceEpoch,
      status: status,
    );

SetEntry _set(int rir,
        {String kind = SetKind.working,
        int doneAt = 0,
        double weight = 60,
        int reps = 8}) =>
    SetEntry(
      sessionExerciseId: 1,
      weightKg: weight,
      reps: reps,
      rir: rir,
      kind: kind,
      doneAt: doneAt,
    );

void main() {
  group('computeStatsKpi', () {
    test('总数只认 done；本月按自然月', () {
      final now = DateTime.now();
      final kpi = computeStatsKpi(
        sessions: [
          _ses(now),
          _ses(now.subtract(const Duration(days: 40))),
          _ses(now, status: 'active'), // 进行中不算
          _ses(now.subtract(const Duration(days: 3)), status: 'quit'), // 弃练不算
        ],
        bodyMetrics: const [],
        now: now,
      );
      expect(kpi.totalSessions, 2);
      expect(kpi.thisMonth, 1);
    });

    test('连续周：本周已练连数三周', () {
      final now = DateTime.now();
      final thisMonday = mondayOf(now);
      final kpi = computeStatsKpi(
        sessions: [
          _ses(thisMonday.add(const Duration(days: 1))), // 本周
          _ses(thisMonday.subtract(const Duration(days: 2))), // 上周
          _ses(thisMonday.subtract(const Duration(days: 9))), // 上上周
        ],
        bodyMetrics: const [],
        now: now,
      );
      expect(kpi.weekStreak, 3);
    });

    test('连续周：本周还没练不断链，从上周起算', () {
      final now = DateTime.now();
      final thisMonday = mondayOf(now);
      final kpi = computeStatsKpi(
        sessions: [
          _ses(thisMonday.subtract(const Duration(days: 2))), // 上周
          _ses(thisMonday.subtract(const Duration(days: 9))), // 上上周
        ],
        bodyMetrics: const [],
        now: now,
      );
      expect(kpi.weekStreak, 2, reason: '本周未练不断链');
    });

    test('连续周：断一周就归零', () {
      final now = DateTime.now();
      final thisMonday = mondayOf(now);
      final kpi = computeStatsKpi(
        sessions: [
          _ses(thisMonday.subtract(const Duration(days: 9))), // 上上周
        ],
        bodyMetrics: const [],
        now: now,
      );
      expect(kpi.weekStreak, 0);
    });

    test('30 天 Δ 基线取「最近一条日期 − 30 天」那天（含）之前的最近记录', () {
      final now = DateTime.now();
      final kpi = computeStatsKpi(
        sessions: const [],
        bodyMetrics: [
          BodyMetric(date: fmtDate(now.subtract(const Duration(days: 31))), weightKg: 70),
          // 29 天前在窗口内（晚于 cutoff），不能当基线
          BodyMetric(date: fmtDate(now.subtract(const Duration(days: 29))), weightKg: 72),
          BodyMetric(date: fmtDate(now), weightKg: 71),
        ],
        now: now,
      );
      expect(kpi.weightDelta30d, closeTo(1.0, 0.001), reason: '71 − 70（31 天前那条）');
    });

    test('30 天 Δ：不足两条或窗口内无基线返回 null', () {
      final now = DateTime.now();
      expect(
        computeStatsKpi(
          sessions: const [],
          bodyMetrics: [
            BodyMetric(date: fmtDate(now), weightKg: 71),
            BodyMetric(date: fmtDate(now.subtract(const Duration(days: 5))), weightKg: 72),
          ],
          now: now,
        ).weightDelta30d,
        isNull,
        reason: '最近一条之前 30 天内再无体重 → 无基线',
      );
      expect(
        computeStatsKpi(sessions: const [], bodyMetrics: const [], now: now)
            .weightDelta30d,
        isNull,
      );
    });
  });

  group('activityHeatmap', () {
    test('空数据：全零，维度 = 53 周 × 7 天', () {
      final now = DateTime(2026, 10, 14); // 周三
      final grid = activityHeatmap(sessions: const [], now: now, byVolume: false);
      expect(grid.length, 53);
      for (final week in grid) {
        expect(week.length, 7);
        for (final v in week) {
          expect(v, 0.0);
        }
      }
    });

    test('网格固定 53 周：早期训练落在对应列，空周保持全零', () {
      final now = DateTime(2026, 10, 14); // 周三
      final monday = mondayOf(now); // 本周周一
      // 两周前的周一练过 → 仍铺满 53 列（标题「近 12 个月」），
      // 训练落进对应列，本周列全零
      final grid = activityHeatmap(
        sessions: [_ses(monday.subtract(const Duration(days: 14)))],
        now: now,
        byVolume: false,
      );
      expect(grid.length, 53, reason: '固定 12 个月坐标系，不再按首次训练截断');
      final startMonday =
          monday.subtract(const Duration(days: 7 * 52));
      final col =
          monday.subtract(const Duration(days: 14)).difference(startMonday).inDays ~/
              7;
      expect(grid[col][0], greaterThan(0), reason: '两周前的周一落在倒数第 3 列');
      expect(grid.last, everyElement(0.0), reason: '本周无训练全零');
    });

    test('时长口径：activeMs+restMs 优先，缺失回退起止差，再缺失按组数×4 估', () {
      final now = DateTime(2026, 10, 14); // 周三，本周周一 10/12
      final mon = DateTime(2026, 10, 12);
      // ① 有 restMs：20 分钟
      final a = Session(
          date: fmtDate(mon),
          planDayTitle: '',
          startedAt: 0,
          endedAt: 999999999,
          status: 'done',
          activeMs: 10 * 60000,
          restMs: 10 * 60000);
      // ② 无 rest/active：回退 endedAt-startedAt = 30 分钟
      final b = Session(
          date: fmtDate(mon.add(const Duration(days: 1))),
          planDayTitle: '',
          startedAt: 1000000,
          endedAt: 1000000 + 30 * 60000,
          status: 'done');
      // ③ 全缺：按该日组数 ×4 分钟估
      final c = Session(
          date: fmtDate(mon.add(const Duration(days: 2))),
          planDayTitle: '',
          startedAt: 0,
          status: 'done');
      final grid = activityHeatmap(
        sessions: [a, b, c],
        now: now,
        byVolume: false,
        setCountsByDate: {fmtDate(mon.add(const Duration(days: 2))): 5},
      );
      expect(grid.last[0], closeTo(20, 0.001));
      expect(grid.last[1], closeTo(30, 0.001));
      expect(grid.last[2], closeTo(20, 0.001), reason: '5 组 × 4 分钟');
    });

    test('容量口径：volumeByDate 落到对应日格', () {
      final now = DateTime(2026, 10, 14); // 本周周一 10/12
      final grid = activityHeatmap(
        sessions: const [],
        now: now,
        byVolume: true,
        volumeByDate: {'2026-10-12': 500, '2026-10-13': 300},
      );
      expect(grid.last[0], closeTo(500, 0.001)); // 周一
      expect(grid.last[1], closeTo(300, 0.001)); // 周二
    });

    test('activityLevels：无活动全 0；有活动按当周合计分 1-4 档', () {
      final levels = activityLevels([
        List.filled(7, 0.0), // 全空周 → 全 0
        [60, 60, 0, 0, 0, 0, 0], // 合计 120
        [10, 0, 0, 0, 0, 0, 0], // 合计 10
        [500, 0, 0, 0, 0, 0, 0], // 合计 500
      ]);
      expect(levels[0], everyElement(0));
      expect(levels[2].where((v) => v > 0), everyElement(1), reason: '最轻周 = 低档');
      expect(levels[1].where((v) => v > 0), everyElement(2), reason: '中间周 = 中档');
      expect(levels[3].where((v) => v > 0), everyElement(4), reason: '最重周 = 顶档');
    });
  });

  group('rirDistribution', () {
    test('桶归并：0 归 0、5 及以上归 5、非正式组不计', () {
      final dist = rirDistribution([
        _set(0),
        _set(1),
        _set(2),
        _set(3),
        _set(4),
        _set(5),
        _set(7), // 越界值归 5+
        _set(-1), // 负值归 0
        _set(2, kind: SetKind.warmup), // 热身不计
        _set(2, kind: SetKind.failure), // 力竭组不计
      ]);
      expect(dist[0], 2);
      expect(dist[1], 1);
      expect(dist[2], 1);
      expect(dist[3], 1);
      expect(dist[4], 1);
      expect(dist[5], 2);
      expect(dist.length, 6, reason: '键固定 0..5');
    });

    test('since 过滤：只统计 doneAt ≥ since 的组', () {
      final since = DateTime(2026, 10, 1);
      final sets = [
        _set(2, doneAt: DateTime(2026, 9, 20).millisecondsSinceEpoch),
        _set(3, doneAt: DateTime(2026, 10, 2).millisecondsSinceEpoch),
        _set(2, doneAt: DateTime(2026, 10, 10).millisecondsSinceEpoch),
      ];
      final dist = rirDistribution(sets, since: since);
      expect(dist[2], 1, reason: '窗口内只有 10/10 那组 rir=2');
      expect(dist[3], 1);
      // 不传 since 全算
      final all = rirDistribution(sets);
      expect(all[2], 2);
      expect(all[3], 1);
    });
  });

  group('rirInsightLine', () {
    test('多数组 1-2 次余力 → 接近力竭', () {
      final line = rirInsightLine(
          {0: 0, 1: 3, 2: 4, 3: 1, 4: 0, 5: 0});
      expect(line, contains('接近力竭'));
    });

    test('多数组 ≥3 次余力 → 留力偏多', () {
      final line = rirInsightLine(
          {0: 0, 1: 1, 2: 2, 3: 4, 4: 3, 5: 2});
      expect(line, contains('留力偏多'));
    });

    test('空数据不给空串', () {
      final line = rirInsightLine({for (var i = 0; i <= 5; i++) i: 0});
      expect(line, isNotEmpty);
    });
  });

  group('DailyTopSet（顶组口径）', () {
    test('同日多组取最大重量', () {
      final d = DateTime(2026, 10, 14);
      final top = DailyTopSet();
      top.add('卧推', d, 60);
      top.add('卧推', d, 72.5);
      top.add('卧推', d, 65);
      top.add('卧推', d.add(const Duration(days: 1)), 70);
      final days = top.byExercise['卧推']!;
      expect(days.length, 2);
      expect(days[d.millisecondsSinceEpoch ~/ 86400000], 72.5);
      expect(days[d.add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 86400000],
          70);
    });
  });
}
