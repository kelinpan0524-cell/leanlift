// AI 教练页 widget 测试：
// ①冒烟：页面骨架渲染（基建同 widget_layout_test：ffi 真库）；
// ②端到端渲染：AppContainer.aiOverride 注入 MockClient 模拟 AI 回复，
//   验证 Markdown 排版（加粗/表格/列表）上屏、计划 JSON 从气泡隐藏、
//   保存按钮出现——AI 请求链路本身在 ai_service_test 另行覆盖。
// 2026-09-26：排计划契约并入每次对话（原「排计划模式」开关已删），
// 排计划回复在默认对话里即可触发保存按钮。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/services/ai_service.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:baoji_timer/ui/ai_coach_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = AppContainer(prefs: prefs);
    await container.db.wipeAll();
    await container.planRepo.reload();
  });

  tearDown(() async {
    await container.db.wipeAll();
    container.dispose();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // 测试环境的系统语言是 en_US，i18n 解析会把 tx() 全部切英文；
    // 这里固定回中文，断言继续用中文文案（与源语言逐字一致）
    Lang.setResolved(false);
    await tester.pumpWidget(AppScope(
      container: container,
      child: const MaterialApp(home: AiCoachPage()),
    ));
    // 数据包加载挂在 postFrameCallback：多泵几帧让 ffi 查询落地
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('未配置：显示配置引导，不崩', (tester) async {
    await pumpPage(tester);
    expect(find.textContaining('还没配置 AI 接口'), findsOneWidget);
    expect(find.text('AI 教练'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ---------- 端到端：Mock AI 回复的 Markdown 渲染（2026-09-26 Arono 需求） ----------

  /// 配好 AI + 注入 MockClient，返回造好的容器。AI 固定回 [reply]。
  Future<AppContainer> coachWith(String reply) async {
    SharedPreferences.setMockInitialValues({
      'set.aiBaseUrl': 'http://127.0.0.1:1',
      'set.aiApiKey': 'sk-test',
      'set.aiModel': 'test-model',
    });
    final prefs = await SharedPreferences.getInstance();
    final ai = AiService(Settings(prefs), httpClient: MockClient((req) async {
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': reply}
            }
          ]
        })),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }));
    final c = AppContainer(prefs: prefs, aiOverride: ai);
    await c.db.wipeAll();
    await c.planRepo.reload();
    return c;
  }

  /// 轮询桥接：真实延时 + pump，直到 [done] 成立（上限约 1.6 秒防死等）。
  Future<void> bridgeUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 8 && !done(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  /// 等数据包就绪（状态行「已附近 8 周训练数据」）→ 发消息 → 等 [replyArrived]
  /// 判据成立（由调用方给出回复中的标志性内容）。不等数据包就发会被
  /// _send 以 pack==null 丢消息（「训练数据还没准备好」）。
  Future<void> sendAndBridge(
    WidgetTester tester,
    String text,
    bool Function() replyArrived,
  ) async {
    await bridgeUntil(
        tester, () => find.textContaining('已附近 8 周训练数据').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.byTooltip('发送'));
    await bridgeUntil(tester, replyArrived);
  }

  testWidgets('排计划回复：表格/加粗/列表渲染成排版，计划 JSON 不上屏，保存按钮出现',
      (tester) async {
    // 容器创建含真实 ffi DB 操作：必须包 runAsync，否则 FakeAsync 等
    // 不到 isolate 回包直接挂到超时（项目已知坑）
    await tester.runAsync(() async {
      container = await coachWith('好的，按每周三练设计，推拉腿分化：\n\n'
          '| 动作 | 组数 | 次数 |\n'
          '|---|---|---|\n'
          '| 杠铃卧推 | 3 | 5-8 |\n'
          '| 高位下拉 | 3 | 8-12 |\n\n'
          '**设计要点**：\n'
          '- 同一肌群间隔 48 小时\n'
          '- 复合动作休息 180 秒\n\n'
          '```json\n'
          '[{"weekday":1,"title":"推日","exercises":[{"name":"杠铃卧推","sets":3,"reps_min":5,"reps_max":8,"rest_sec":180,"kind":"compound","main_muscle":"胸"}]}]\n'
          '```\n'
          '想调整随时说。');
    });
    await pumpPage(tester);
    // 回复到达判据：提取到计划才会挂保存按钮
    await sendAndBridge(tester, '帮我安排每周三练的计划',
        () => find.text('预览并保存为计划').evaluate().isNotEmpty);

    // Markdown 渲染：裸 ** 星号不上屏（findRichText 才能匹配富文本内部）；
    // 表格单元格/列表项成为渲染后的可见文本
    expect(find.textContaining('**', findRichText: true), findsNothing,
        reason: '加粗的星号是 Markdown 源码，不应原样显示');
    expect(find.text('杠铃卧推', findRichText: true), findsWidgets,
        reason: '表格单元格已渲染');
    // 计划 JSON 从气泡摘除（完整内容走预览弹层）
    expect(find.textContaining('weekday', findRichText: true), findsNothing,
        reason: '计划 JSON 已隐藏，气泡只留说明');
    expect(find.text('预览并保存为计划'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通问答回复：加粗与列表渲染，无保存按钮', (tester) async {
    await tester.runAsync(() async {
      container = await coachWith('**结论**：练得不错。\n\n'
          '- 卧推稳步加重\n'
          '- 背部容量偏低\n\n'
          '建议下周把划船加一组。');
    });
    await pumpPage(tester);
    // 回复到达判据：加粗段「结论」渲染出来（富文本内部也要可见）
    await sendAndBridge(tester, '我最近练得怎么样？',
        () => find.textContaining('结论', findRichText: true).evaluate().isNotEmpty);

    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.text('卧推稳步加重', findRichText: true), findsOneWidget,
        reason: '列表项已渲染');
    expect(find.text('预览并保存为计划'), findsNothing,
        reason: '普通回复没有计划，不出现保存按钮');
    expect(tester.takeException(), isNull);
  });
}
