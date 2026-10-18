// P1-C 训练块、减载与停滞协议引擎单测（2026-10-18）。
// 口径：块起点 = 当前计划第一次 done 训练；默认 5 周一块、第 N 周减载；
// 减载重量 0.9×、正式组数 -1（最少 1 组）；平台期连续 ≥3 次未顶格 →
// 建议减载 10% 或换变式，已顶格 → 保留加重建议。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/engine/engine.dart';

void main() {
  group('训练块周次（trainingBlockWeekOf）', () {
    final start = DateTime(2026, 10, 1);

    test('第 1 周：块起点当天到第 6 天', () {
      expect(
        trainingBlockWeekOf(
            blockStart: start, date: start, blockWeeks: 5),
        1,
      );
      expect(
        trainingBlockWeekOf(
          blockStart: start,
          date: start.add(const Duration(days: 6)),
          blockWeeks: 5,
        ),
        1,
      );
    });

    test('第 2-5 周按 7 天推进，第 5 周是减载周', () {
      for (final (days, week) in [(7, 2), (14, 3), (21, 4), (28, 5), (34, 5)]) {
        expect(
          trainingBlockWeekOf(
            blockStart: start,
            date: start.add(Duration(days: days)),
            blockWeeks: 5,
          ),
          week,
          reason: '第 $days 天 = 第 $week 周',
        );
      }
      expect(
        isDeloadWeekOf(
            blockStart: start,
            date: start.add(const Duration(days: 28)),
            blockWeeks: 5),
        isTrue,
      );
      expect(
        isDeloadWeekOf(
            blockStart: start,
            date: start.add(const Duration(days: 21)),
            blockWeeks: 5),
        isFalse,
      );
    });

    test('减载周后的下一周回到第 1 周（下一块）', () {
      expect(
        trainingBlockWeekOf(
          blockStart: start,
          date: start.add(const Duration(days: 35)),
          blockWeeks: 5,
        ),
        1,
      );
      expect(
        trainingBlockWeekOf(
          blockStart: start,
          date: start.add(const Duration(days: 63)),
          blockWeeks: 5,
        ),
        5,
        reason: '第 64-70 天是第二块的第 5 周',
      );
    });

    test('块长可改：4 周一块时第 4 周减载、第 5 周回到第 1 周', () {
      expect(
        isDeloadWeekOf(
            blockStart: start,
            date: start.add(const Duration(days: 21)),
            blockWeeks: 4),
        isTrue,
      );
      expect(
        trainingBlockWeekOf(
            blockStart: start,
            date: start.add(const Duration(days: 28)),
            blockWeeks: 4),
        1,
      );
    });

    test('块长 0 = 关闭；无块起点也关闭', () {
      expect(
        trainingBlockWeekOf(
            blockStart: start, date: start, blockWeeks: 0),
        isNull,
      );
      expect(
        isDeloadWeekOf(
            blockStart: start,
            date: start.add(const Duration(days: 28)),
            blockWeeks: 0),
        isFalse,
      );
      expect(
        trainingBlockWeekOf(
            blockStart: null, date: start, blockWeeks: 5),
        isNull,
      );
    });

    test('块起点在未来（改期/时区边界）按第 1 周，不出现负周次', () {
      expect(
        trainingBlockWeekOf(
          blockStart: start.add(const Duration(days: 3)),
          date: start,
          blockWeeks: 5,
        ),
        1,
      );
    });

    test('跨月/跨年按自然日推进（UTC 日期差，不受夏令时影响）', () {
      expect(
        trainingBlockWeekOf(
          blockStart: DateTime(2026, 12, 20),
          date: DateTime(2027, 1, 24), // 35 天
          blockWeeks: 5,
        ),
        1,
      );
      expect(
        trainingBlockWeekOf(
          blockStart: DateTime(2026, 3, 1),
          date: DateTime(2026, 3, 29), // 28 天（欧洲夏令时切换日）
          blockWeeks: 5,
        ),
        5,
      );
    });
  });

  group('减载调整（deloadWeightKg / deloadWorkingSets）', () {
    test('重量 ×0.9 向下取整到 0.5kg 网格（低重量也真的减载）', () {
      expect(deloadWeightKg(60), 54);
      expect(deloadWeightKg(62.5), 56.0, reason: '56.25 向下 → 56.0');
      expect(deloadWeightKg(100), 90);
      expect(deloadWeightKg(2.5), 2.0, reason: '2.25 向下 → 2.0，不能原样 2.5');
      expect(deloadWeightKg(1.0), 0.5);
      expect(deloadWeightKg(0.5), 0.5, reason: '最小片无更小档，保持');
    });

    test('0kg 自重档位保持 0（减载表达在组数上）', () {
      expect(deloadWeightKg(0), 0);
    });

    test('负重量（辅助配重）方向一致：配重更负 = 辅助更多 = 更省力', () {
      expect(deloadWeightKg(-30), -33);
      expect(deloadWeightKg(-20), -22);
    });

    test('正式组数 -1，最少 1 组；0/未知不凭空造组', () {
      expect(deloadWorkingSets(5), 4);
      expect(deloadWorkingSets(3), 2);
      expect(deloadWorkingSets(2), 1);
      expect(deloadWorkingSets(1), 1);
      expect(deloadWorkingSets(0), 0);
      expect(deloadWorkingSets(-1), 0);
    });
  });

  group('停滞协议（plateauProtocolOf）', () {
    const rule = ProgressionRule(repsMin: 6, repsMax: 10, incrementKg: 2.5);

    test('连续 3 次未顶格 → 建议减载 10% 或换变式，文案带原因', () {
      final p = plateauProtocolOf(
        const PlateauInfo(60, 3, 14, false),
        rule: rule,
      );
      expect(p.action, 'reduce');
      expect(p.suggestedWeightKg, 54);
      expect(p.reason, contains('连续 3 次'));
      expect(p.reason, contains('14 天'));
      expect(p.reason, contains('60kg'));
      expect(p.reason, contains('减载 10%'));
      expect(p.reason, contains('换一个变式'));
      expect(p.reason, contains('54kg'));
    });

    test('已顶格 → 保留加重建议（不误判成需要减载）', () {
      final p = plateauProtocolOf(
        const PlateauInfo(60, 3, 14, true),
        rule: rule,
      );
      expect(p.action, 'add');
      expect(p.suggestedWeightKg, 62.5);
      expect(p.reason, contains('加重到 62.5kg'));
      expect(p.reason, contains('次数顶格'));
      expect(p.reason, isNot(contains('减载')));
    });

    test('2 次但跨 12 天且未顶格 → none（先冲次数，不提前减载）', () {
      final p = plateauProtocolOf(
        const PlateauInfo(60, 2, 13, false),
        rule: rule,
      );
      expect(p.action, 'none');
      expect(p.suggestedWeightKg, 0);
      expect(p.reason, isEmpty);
    });

    test('2 次但跨 12 天且已顶格 → add（顶格优先于次数门槛）', () {
      final p = plateauProtocolOf(
        const PlateauInfo(60, 2, 13, true),
        rule: rule,
      );
      expect(p.action, 'add');
      expect(p.suggestedWeightKg, 62.5);
      expect(p.reason, contains('加重'));
    });

    test('没有平台期（null）→ none', () {
      final p = plateauProtocolOf(null, rule: rule);
      expect(p.action, 'none');
      expect(p.reason, isEmpty);
    });

    test('自重动作已顶格 → 加一组（不是加重到 2.5kg）', () {
      final p = plateauProtocolOf(
        const PlateauInfo(0, 3, 14, true),
        rule: rule,
        loadType: LoadMode.bodyweight,
      );
      expect(p.action, 'add');
      expect(p.suggestedWeightKg, 0);
      expect(p.reason, contains('加练一组'));
      expect(p.reason, isNot(contains('2.5kg')));
    });

    test('自重 0kg → 建议换变式，不给 0kg 的假减载数字', () {
      final p = plateauProtocolOf(
        const PlateauInfo(0, 4, 21, false),
        rule: rule,
        loadType: LoadMode.bodyweight,
      );
      expect(p.action, 'reduce');
      expect(p.suggestedWeightKg, 0);
      expect(p.reason, contains('换一个变式'));
      expect(p.reason, contains('没有重量可减'));
      expect(p.reason, isNot(contains('减载 10%')));
    });

    test('负重量（辅助配重）→ 减载方向是增加辅助（-33kg）', () {
      final p = plateauProtocolOf(
        const PlateauInfo(-30, 3, 15, false),
        rule: rule,
      );
      expect(p.action, 'reduce');
      expect(p.suggestedWeightKg, -33);
      expect(p.reason, contains('-33kg'));
    });

    test('计时动作（logging=time）文案用「秒」而不是「次」', () {
      final p = plateauProtocolOf(
        const PlateauInfo(0, 3, 12, false),
        rule: const ProgressionRule(repsMin: 30, repsMax: 60),
        logging: LoggingMode.time,
        loadType: LoadMode.bodyweight,
      );
      expect(p.action, 'reduce');
      expect(p.reason, contains('60 秒'));
      expect(p.reason, isNot(contains('60 次')));
    });
  });
}
