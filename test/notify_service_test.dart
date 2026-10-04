// 训练卡前台服务通道（调研条目 1/3）与通知栏遥控按钮回传的单测。
// 原生 Kotlin 侧无法本地单测，这里只测 Dart→原生的通道契约与
// 原生→Dart 的动作分发；Kotlin 编译由 CI 把关。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/services/notify_service.dart';
import 'package:baoji_timer/services/session_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('baoji/training');
  final binding = TestWidgetsFlutterBinding.instance;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('训练卡：休息态推 start（幂等更新），字段与原生读取约定一致', () async {
    final svc = NotifyService();
    await svc.showTrainingCard(const TrainingCard(
      active: true,
      resting: true,
      paused: false,
      title: '组间休息中',
      text: '还剩 1分30秒 · 下一组 60kg×5-8 次',
      remaining: 90,
      total: 180,
      chronoStartMs: 123456,
      restEndAtMs: 1770000000000,
    ));
    expect(calls, hasLength(1));
    expect(calls.single.method, 'start');
    expect(calls.single.arguments, <String, Object?>{
      'phase': 1,
      'title': '组间休息中',
      'text': '还剩 1分30秒 · 下一组 60kg×5-8 次',
      'paused': false,
      'remaining': 90,
      'total': 180,
      'chronoBase': 123456,
      // 原生侧用它渲染系统 chronometer 倒数（锁屏自动走秒）
      'restEndAt': 1770000000000,
    });
  });

  test('训练卡：动作态 phase=0 且带 chronometer 起点（系统自动走秒）', () async {
    final svc = NotifyService();
    await svc.showTrainingCard(const TrainingCard(
      active: true,
      resting: false,
      paused: false,
      title: '卧推',
      text: '本组 60kg×5-8 次 · 第 1/3 组',
      remaining: -1,
      total: 0,
      chronoStartMs: 999,
    ));
    final args = calls.single.arguments as Map;
    expect(args['phase'], 0);
    expect(args['chronoBase'], 999);
    expect(args['remaining'], -1);
  });

  test('结束训练：停前台服务走 stop', () async {
    final svc = NotifyService();
    await svc.stopTrainingCard();
    expect(calls.single.method, 'stop');
  });

  test('原生通道异常不外抛（训练不崩在通知上）', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async => throw PlatformException(code: 'NATIVE_ERROR'));
    final svc = NotifyService();
    await svc.showTrainingCard(const TrainingCard.inactive());
    await svc.stopTrainingCard();
  });

  test('通知栏按钮动作（暂停/继续/±10 秒）回传分发到 onNotifAction', () async {
    final svc = NotifyService();
    final got = <String>[];
    svc.onNotifAction = got.add;
    for (final action in const ['pause', 'resume', 'minus10', 'plus10']) {
      final data = const StandardMethodCodec().encodeMethodCall(
        MethodCall('notifAction', {'action': action}),
      );
      await binding.defaultBinaryMessenger
          .handlePlatformMessage('baoji/training', data, (_) {});
    }
    expect(got, ['pause', 'resume', 'minus10', 'plus10']);
  });
}
