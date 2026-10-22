// 设置主页重构（2026-09-26 Arono：系统设置式分组行+子页面）回归测试：
// ①八个入口一屏可见（不再无限下滑）；②行点进去是子页（拿训练偏好验证）；
// ③AI 行状态摘要。基建同 ai_coach_widget_test：ffi 真库。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:baoji_timer/ui/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
  });

  tearDownAll(() async {
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/baoji_timer.db');
  });

  late AppContainer container;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    container = AppContainer(prefs: prefs);
    await container.db.wipeAll();
    await container.planRepo.reload();
  });

  tearDown(() async {
    await container.db.wipeAll();
    container.dispose();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(AppScope(
      container: container,
      // 设置主页与计划页同构：无自身 Scaffold，由宿主（HomeShell/测试）提供
      child: const MaterialApp(home: Scaffold(body: SettingsPage())),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('设置主页：八个入口一屏可见（不再无限下滑）', (tester) async {
    await pumpPage(tester);
    for (final t in [
      '语言',
      '训练偏好',
      '专注模式',
      'AI 教练',
      '飞书日历',
      '权限',
      '应用更新',
      '数据与备份',
    ]) {
      expect(find.text(t), findsOneWidget, reason: '$t 应作为分组行一屏可见');
      // 视口断言：八个入口都要在默认测试屏（高 600 逻辑像素）附近可达，
      // 防止未来往主页加内容把入口挤到深处、退化回「一直滑」
      expect(tester.getTopLeft(find.text(t)).dy, lessThan(800),
          reason: '$t 应贴近屏幕顶部（查找优化是本次重构的核心目标）');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('训练偏好子页可达：点行进入子页看到具体配置', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('训练偏好'));
    await tester.pump(); // 起帧（动画首帧 elapsed=0，单次长 pump 不推进）
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('复合动作休息（秒）'), findsOneWidget,
        reason: '子页应展示具体配置项');
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 教练行：未配置时状态摘要可见', (tester) async {
    await pumpPage(tester);
    expect(find.text('未配置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('训练偏好：每周复盘默认周日 20:00；未配 AI 不显示 AI 周报开关',
      (tester) async {
    // 拉高视口：训练偏好页很长，拉高后无需滚动即可拿到完整布局断言
    tester.view.physicalSize = const Size(412, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpPage(tester);
    await tester.tap(find.text('训练偏好'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('每周复盘提醒'), findsOneWidget);
    expect(find.text('提醒日'), findsOneWidget);
    // 同一页上方练前提醒也默认 20:00：限定在「每周复盘」卡片内断言
    final weeklyCard = find
        .ancestor(of: find.text('每周复盘提醒'), matching: find.byType(Card))
        .first;
    expect(find.descendant(of: weeklyCard, matching: find.text('周日')),
        findsOneWidget);
    expect(find.descendant(of: weeklyCard, matching: find.text('20:00')),
        findsOneWidget);
    expect(find.text('AI 自动写周报'), findsNothing,
        reason: '没配 AI Key 时开关不露出（点了也没用）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('训练块长度下拉：改块长持久化，选「关」= 0 关闭减载', (tester) async {
    tester.view.physicalSize = const Size(412, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpPage(tester);
    await tester.tap(find.text('训练偏好'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(container.settings.trainingBlockWeeks, 5, reason: '默认 5 周一块');
    // 页上有两个 int 下拉（提醒日/块长），限定到「训练块长度」所在行
    final blockRow = find
        .ancestor(of: find.text('训练块长度'), matching: find.byType(Row))
        .first;
    final dropdown = find.descendant(
      of: blockRow,
      matching: find.byType(DropdownButton<int>),
    );
    expect(dropdown, findsOneWidget);

    // 改成 6 周：设置即时生效并写进本地偏好
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('6 周').last);
    await tester.pumpAndSettle();
    await tester.idle();
    expect(container.settings.trainingBlockWeeks, 6);
    expect(prefs.getInt('set.trainingBlockWeeks'), 6, reason: '改块长要落盘');

    // 选「关」：0 = 关闭（不安排减载周）
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('关').last);
    await tester.pumpAndSettle();
    await tester.idle();
    expect(container.settings.trainingBlockWeeks, 0);
    expect(prefs.getInt('set.trainingBlockWeeks'), 0, reason: '关闭也要落盘');

    // 模拟重启：新 Settings 实例从同一份偏好加载，仍是关闭
    final reloaded = Settings(prefs);
    expect(reloaded.trainingBlockWeeks, 0, reason: '重启后仍保持关闭');
    expect(tester.takeException(), isNull);
  });

  testWidgets('训练偏好：配了 AI 才露出「AI 自动写周报」，默认关', (tester) async {
    tester.view.physicalSize = const Size(412, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container.settings.set(() {
      container.settings.aiBaseUrl = 'https://api.example.com/v1';
      container.settings.aiApiKey = 'sk-test';
    });

    await pumpPage(tester);
    await tester.tap(find.text('训练偏好'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('AI 自动写周报'), findsOneWidget);
    final tile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'AI 自动写周报'),
    );
    expect(tile.value, isFalse, reason: '默认关：不主动替用户联网');
    expect(tester.takeException(), isNull);
  });

  test('撤销 AI 配置会自动收回「AI 自动写周报」授权', () async {
    SharedPreferences.setMockInitialValues({
      'set.aiBaseUrl': 'https://api.example.com/v1',
      'set.aiApiKey': 'sk-test',
      'set.aiModel': 'test-model',
      'set.aiWeeklyRecapOn': true,
    });
    final prefs = await SharedPreferences.getInstance();
    final s = Settings(prefs);
    expect(s.aiWeeklyRecapOn, isTrue, reason: '配好 AI 且用户打开过');

    s.aiApiKey = '';
    await s.save();
    expect(s.aiWeeklyRecapOn, isFalse, reason: '撤销 AI 配置即收回授权');
    expect(prefs.getBool('set.aiWeeklyRecapOn'), isFalse);

    // 重新填入任意端点：开关保持关，必须用户再次明确打开
    s.aiApiKey = 'sk-other';
    await s.save();
    expect(s.aiWeeklyRecapOn, isFalse);
  });

  test('加载时 AI 未配置但旧开关为开：按未授权处理', () async {
    SharedPreferences.setMockInitialValues({'set.aiWeeklyRecapOn': true});
    final prefs = await SharedPreferences.getInstance();
    final s = Settings(prefs);
    expect(s.aiConfigured, isFalse);
    expect(s.aiWeeklyRecapOn, isFalse);
  });
}
