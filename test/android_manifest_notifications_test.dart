// 定时本地通知的 Android manifest 配置回归：
// flutter_local_notifications v16+ 自身 manifest 只声明通知权限，调度接收器
// 必须由 App 声明；缺了它 zonedSchedule 到点没有接收者、重启后排期丢失。
// 这里直接读 manifest 文本做静态守卫（比等真机验证便宜）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manifest 声明定时通知接收器与开机恢复权限', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android.permission.RECEIVE_BOOT_COMPLETED'),
        reason: '重启后插件要恢复已排期');
    expect(
      manifest,
      contains('com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver'),
      reason: '到点触发通知的广播接收器',
    );
    expect(
      manifest,
      contains(
          'com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver'),
      reason: '开机/应用更新后恢复排期的接收器',
    );
  });
}
