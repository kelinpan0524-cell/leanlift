// P1-D 停练回归降档纯函数：14 天边界、85% 重量取整、组数 -1、
// 与减载周取更低系数不叠加。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/engine/engine.dart';

void main() {
  group('停练天数（layoffDaysSince / isLayoffAfter）', () {
    final today = DateTime(2026, 10, 18);

    test('14 天边界：第 13 天不触发，第 14 天当天触发', () {
      expect(layoffDaysSince('2026-10-05', today), 13);
      expect(isLayoffAfter('2026-10-05', today), isFalse,
          reason: '13 天还没到两周，按正常处方走');
      expect(layoffDaysSince('2026-10-04', today), 14);
      expect(isLayoffAfter('2026-10-04', today), isTrue,
          reason: '≥14 天当天就触发');
      expect(isLayoffAfter('2026-09-18', today), isTrue);
    });

    test('无记录/空串/脏值/未来日期一律不触发', () {
      expect(layoffDaysSince(null, today), 0);
      expect(layoffDaysSince('', today), 0);
      expect(layoffDaysSince('not-a-date', today), 0);
      expect(layoffDaysSince('2026-10-25', today), 0,
          reason: '未来日期（改过系统时间/导入脏数据）按 0 处理');
      expect(isLayoffAfter(null, today), isFalse, reason: '新用户没有停练一说');
    });

    test('跨月/跨年按自然日计算', () {
      expect(layoffDaysSince('2026-12-20', DateTime(2027, 1, 3)), 14);
      expect(layoffDaysSince('2026-01-31', DateTime(2026, 2, 14)), 14);
    });
  });

  group('停练回归重量（layoffWeightKg）', () {
    test('正重量 0.85× 后向下取整到 0.5kg', () {
      expect(layoffWeightKg(60), 51);
      expect(layoffWeightKg(62.5), 53,
          reason: '53.125 向下 → 53，不超过 85%');
      expect(layoffWeightKg(100), 85);
      expect(layoffWeightKg(2.5), 2.0, reason: '2.125 向下 → 2.0，不能原样 2.5');
      expect(layoffWeightKg(1.0), 0.5);
      expect(layoffWeightKg(0.5), 0.5, reason: '最小片无更小档，保持');
    });

    test('自重 0kg 保持 0，负重量按辅助增加 15% 后向上取整', () {
      expect(layoffWeightKg(0), 0, reason: '自重动作不改重量，只减组');
      expect(layoffWeightKg(-30), -34.5,
          reason: '-30 ×1.15 = -34.5，配重更负 = 辅助更多');
      expect(layoffWeightKg(-33), -38.0, reason: '-37.95 向上到 0.5 网格 = -38');
    });

    test('减载公式重构后行为不变（回归护栏）', () {
      expect(deloadWeightKg(60), 54);
      expect(deloadWeightKg(62.5), 56.0);
      expect(deloadWeightKg(2.5), 2.0);
      expect(deloadWeightKg(-30), -33);
    });
  });

  group('停练回归组数与叠加（layoffWorkingSets / recoveryWeightFactor）', () {
    test('正式组数 -1，最少 1 组；0/未知保持 0', () {
      expect(layoffWorkingSets(4), 3);
      expect(layoffWorkingSets(3), 2);
      expect(layoffWorkingSets(1), 1);
      expect(layoffWorkingSets(0), 0, reason: '不凭空造组');
    });

    test('与减载周不叠加：取更低的 0.85 一档', () {
      expect(recoveryWeightFactor(layoff: true, deload: true), 0.85);
      expect(recoveryWeightFactor(layoff: true, deload: false), 0.85);
      expect(recoveryWeightFactor(layoff: false, deload: true), 0.9);
      expect(recoveryWeightFactor(layoff: false, deload: false), isNull);
      // 不叠加的数值口径：60kg 同时命中是 51kg，不是 54×0.85 = 45.9
      final factor = recoveryWeightFactor(layoff: true, deload: true)!;
      expect(reducedWeightKg(60, factor), 51);
    });
  });
}
