import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/services/heart_rate_service.dart';

void main() {
  group('parseHeartRate（0x2A37 通知解析）', () {
    test('flags bit0=0：逐字节心率', () {
      expect(parseHeartRate([0x00, 72]), 72);
      expect(parseHeartRate([0x00, 158]), 158);
    });
    test('flags bit0=1：逐字小端心率', () {
      expect(parseHeartRate([0x01, 0xEA, 0x00]), 234);
      expect(parseHeartRate([0x01, 0x50, 0x00]), 80);
    });
    test('短包返回 null', () {
      expect(parseHeartRate([]), isNull);
      expect(parseHeartRate([0x00]), isNull);
      expect(parseHeartRate([0x01, 0xEA]), isNull);
    });
    test('非法值（0 / 超生理上限）返回 null', () {
      expect(parseHeartRate([0x00, 0x00]), isNull);
      expect(parseHeartRate([0x01, 0xF5, 0x00]), 245); // 上限内合法
      expect(parseHeartRate([0x01, 0x2D, 0x01]), isNull); // 301 超上限
      expect(parseHeartRate([0x01, 0xFF, 0x00]), isNull); // 255 超上限
    });
  });

  group('downsampleHr（AI 解析抽稀）', () {
    HrPoint p(int i, int bpm) => HrPoint(1000 * i, bpm);

    test('不足 maxPoints 时原样返回', () {
      final pts = [p(0, 100), p(1, 110)];
      expect(downsampleHr(pts, 60), pts);
    });
    test('超长时等距抽到 maxPoints 且保序', () {
      final pts = [for (var i = 0; i < 600; i++) p(i, 60 + i % 40)];
      final out = downsampleHr(pts, 60);
      expect(out.length, 60);
      expect(out.first, pts[0]);
      expect(out.last, pts[590]); // (59*600) ~/ 60 = 590
      for (var i = 1; i < out.length; i++) {
        expect(out[i].ts, greaterThanOrEqualTo(out[i - 1].ts));
      }
    });
    test('空列表返回空', () {
      expect(downsampleHr(const [], 60), isEmpty);
    });
    test('maxPoints<=0 原样返回（防御）', () {
      final pts = [p(0, 100)];
      expect(downsampleHr(pts, 0), pts);
    });
  });

  group('summarizeHr / buildHrAnalysisPrompt', () {
    test('均值与峰值', () {
      final s = summarizeHr(
          [const HrPoint(0, 100), const HrPoint(1000, 140)])!;
      expect(s.avg, 120);
      expect(s.max, 140);
      expect(s.count, 2);
    });
    test('空采样返回 null', () {
      expect(summarizeHr(const []), isNull);
    });
    test('提示词包含降采样行与时长', () {
      final pts = [const HrPoint(0, 100), const HrPoint(65000, 130)];
      final prompt = buildHrAnalysisPrompt(pts, durationMin: 45);
      expect(prompt, contains('45 分钟'));
      expect(prompt, contains('0:00 100'));
      expect(prompt, contains('1:05 130'));
    });
    test('loadNote 可选注入与省略', () {
      final pts = [const HrPoint(0, 100)];
      final withLoad = buildHrAnalysisPrompt(pts, durationMin: 30,
          loadNote: '本场循环负荷（Edwards TRIMP）约 9，区间停留：Z2 18分');
      expect(withLoad, contains('Edwards TRIMP'));
      expect(withLoad, contains('Z2 18分'));
      final noLoad = buildHrAnalysisPrompt(pts, durationMin: 30);
      expect(noLoad, isNot(contains('TRIMP')));
    });
  });

  group('读数新鲜度 freshBpm（休息建议依据）', () {
    late HeartRateService svc;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      svc = HeartRateService(prefs);
    });

    tearDown(() => svc.dispose());

    test('新鲜窗口内的读数返回，bpm 与 freshBpm 一致', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      svc.debugSetReading(bpm: 130, atMs: now - 3000);
      expect(svc.bpm, 130);
      expect(svc.freshBpm, 130);
    });

    test('超过 10 秒窗口的旧读数：freshBpm 为 null，bpm 保留最后值', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      svc.debugSetReading(bpm: 130, atMs: now - 10001);
      expect(svc.bpm, 130, reason: 'chip 仍显示最后读数');
      expect(svc.freshBpm, isNull, reason: '旧读数不作为建议依据');
    });

    test('无读数 / 断链后 freshBpm 为 null', () {
      expect(svc.freshBpm, isNull);
      final now = DateTime.now().millisecondsSinceEpoch;
      svc.debugSetReading(bpm: 100, atMs: now);
      expect(svc.freshBpm, 100);
      svc.debugSetReading(link: HrLink.idle, bpm: null);
      expect(svc.freshBpm, isNull);
    });
  });
}
