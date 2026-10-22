import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/services/diagnostic_log.dart';
import 'package:baoji_timer/ui/diagnostic_log_page.dart';
import 'package:baoji_timer/ui/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('诊断日志页：空态提示 + 记录按时间正序读取、最新在前', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final log = DiagnosticLog(prefs);
    Lang.setResolved(false);

    Widget host() => MaterialApp(
      theme: AppTheme.dark,
      home: DiagnosticLogPage(log: log),
    );

    await tester.pumpWidget(host());
    await tester.pump();
    expect(find.text('暂无记录'), findsOneWidget);

    log.log('lifecycle', 'paused');
    log.logError('async', StateError('boom'));
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.text('lifecycle'), findsOneWidget);
    expect(find.text('async'), findsOneWidget);
    expect(find.byType(SelectableText), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
