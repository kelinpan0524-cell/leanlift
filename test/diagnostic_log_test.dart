import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:baoji_timer/services/diagnostic_log.dart';

void main() {
  test('滚动保留最近 200 条，重新打开仍能读到', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final log = DiagnosticLog(prefs);
    for (var i = 0; i < 250; i++) {
      log.log('test', 'm$i');
    }
    expect(log.entries.length, 200);
    expect(log.entries.first.message, 'm50');
    expect(log.entries.last.message, 'm249');

    await log.flush();
    final reopened = DiagnosticLog(prefs);
    expect(reopened.entries.length, 200);
    expect(reopened.entries.first.message, 'm50');
    expect(reopened.entries.last.message, 'm249');
  });

  test('异常记录带栈顶且单条消息有上限', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final log = DiagnosticLog(prefs);
    log.logError('async', StateError('boom'), StackTrace.current);
    expect(log.entries, hasLength(1));
    expect(log.entries.single.tag, 'async');
    expect(log.entries.single.message, contains('boom'));
    expect(log.entries.single.message.length, lessThanOrEqualTo(800));
  });

  test('损坏的历史日志不影响新建实例', () async {
    SharedPreferences.setMockInitialValues({DiagnosticLog.prefsKey: '{oops'});
    final prefs = await SharedPreferences.getInstance();
    final log = DiagnosticLog(prefs);
    expect(log.entries, isEmpty);
    log.log('app', 'ok');
    expect(log.entries.single.message, 'ok');
  });
}
