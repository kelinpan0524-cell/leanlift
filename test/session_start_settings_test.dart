// 开场设置（2026-10）单测：①开练前记体重判定纯函数；②屏幕常亮/
// 开练记体重两个新开关的默认值与持久化读回。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:baoji_timer/services/weight_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('shouldAskWeightOnStart 判定', () {
    test('开关关：今天没记过也不弹', () {
      expect(
        shouldAskWeightOnStart(
            enabled: false, lastMetricDate: '2026-10-01', today: '2026-10-17'),
        isFalse,
      );
    });

    test('开关开 + 最新记录是今天：不弹（每天最多问一次）', () {
      expect(
        shouldAskWeightOnStart(
            enabled: true, lastMetricDate: '2026-10-17', today: '2026-10-17'),
        isFalse,
      );
    });

    test('开关开 + 最新记录是昨天：弹', () {
      expect(
        shouldAskWeightOnStart(
            enabled: true, lastMetricDate: '2026-10-16', today: '2026-10-17'),
        isTrue,
      );
    });

    test('开关开 + 从没记过（null）：弹', () {
      expect(
        shouldAskWeightOnStart(enabled: true, lastMetricDate: null, today: '2026-10-17'),
        isTrue,
      );
    });
  });

  group('开场设置开关存取', () {
    test('默认值与改值保存后的读回', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final s = Settings(prefs);
      expect(s.wakelockEnabled, isTrue, reason: '常亮默认开');
      expect(s.askWeightOnStart, isTrue, reason: '开练记体重默认开');

      s.wakelockEnabled = false;
      s.askWeightOnStart = false;
      await s.save();

      final reloaded = Settings(prefs);
      expect(reloaded.wakelockEnabled, isFalse);
      expect(reloaded.askWeightOnStart, isFalse);
    });
  });
}
