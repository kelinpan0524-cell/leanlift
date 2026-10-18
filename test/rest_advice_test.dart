// P2-F 心率自适应休息建议：纯函数阈值回归。
// 覆盖高心率（extend）/ 正常（ok）/ 低心率（shorten）/ 无数据（ok），
// 以及力竭组、剩余时间、静息心率脏值等边界。
import 'package:flutter_test/flutter_test.dart';

import 'package:baoji_timer/engine/rest_rules.dart';
import 'package:baoji_timer/l10n/lang.dart';

void main() {
  RestAdvice advice(int? bpm,
          {int rest = 60, int remain = 120, int rir = 2}) =>
      restAdvice(bpm, rest, remain, rir);

  group('restAdvice（心率自适应休息建议）', () {
    test('高心率 → extend，原因是一句话建议多休 30 秒', () {
      final a = advice(130);
      expect(a.action, RestAdviceAction.extend);
      expect(a.reason, contains('心率仍高'));
      expect(a.reason, contains('多休 30 秒'));
    });

    test('正常心率 → ok，按计划休息', () {
      // 95 - 60 = 35，低于 40 的高心率阈值
      final a = advice(95);
      expect(a.action, RestAdviceAction.ok);
      expect(a.reason, contains('按计划休息'));
    });

    test('低心率且恢复充分 → shorten，可提前 30 秒', () {
      final a = advice(70);
      expect(a.action, RestAdviceAction.shorten);
      expect(a.reason, contains('提前 30 秒'));
    });

    test('无数据（null / 0）→ ok，不影响现有休息流程', () {
      for (final bpm in <int?>[null, 0, -5]) {
        final a = advice(bpm);
        expect(a.action, RestAdviceAction.ok, reason: '无数据时不做任何调整');
        expect(a.reason, contains('暂无心率数据'));
      }
    });

    test('末组接近力竭（RIR≤1）时高心率阈值下调到静息 +30', () {
      // 95 - 60 = 35：RIR 2 不算高，RIR 1 就该多歇
      expect(advice(95, rir: 2).action, RestAdviceAction.ok);
      expect(advice(95, rir: 1).action, RestAdviceAction.extend);
      expect(advice(95, rir: 0).action, RestAdviceAction.extend);
    });

    test('低心率但末组接近力竭 → 不催提前开练', () {
      final a = advice(70, rir: 1);
      expect(a.action, RestAdviceAction.ok);
      expect(a.reason, contains('力竭'));
    });

    test('剩余不足 60 秒时即使心率已恢复也不建议提前', () {
      expect(advice(70, remain: 59).action, RestAdviceAction.ok);
      expect(advice(70, remain: 60).action, RestAdviceAction.shorten);
    });

    test('休息已结束 → ok，不再给加时建议', () {
      final a = advice(130, remain: 0);
      expect(a.action, RestAdviceAction.ok);
      expect(a.reason, contains('休息已结束'));
    });

    test('静息心率脏值按 60 兜底', () {
      // 若拿 0 当静息，95 会误判成高心率；兜底后 95-60=35 → ok
      expect(advice(95, rest: 0).action, RestAdviceAction.ok);
      expect(advice(95, rest: 200).action, RestAdviceAction.ok);
    });

    test('RIR 越界按 0-5 夹取', () {
      // rir=-3 → 0（接近力竭）：95 就算高心率
      expect(advice(95, rir: -3).action, RestAdviceAction.extend);
      // rir=9 → 5：低心率仍可提前
      expect(advice(70, rir: 9).action, RestAdviceAction.shorten);
    });

    test('英文界面输出英文原因', () {
      Lang.setResolved(true);
      addTearDown(() => Lang.setResolved(false));
      final a = advice(130);
      expect(a.action, RestAdviceAction.extend);
      expect(a.reason, contains('Heart rate still high'));
    });
  });
}
