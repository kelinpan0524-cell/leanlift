// AI 复盘导出回归锁（体检清单遗留项 2026-09-26）：
// lastRecapReply/buildRecapMarkdown 纯函数 + 教练页「导出复盘存档」按钮可用态
// （可用态走真实恢复路径：prefs 注入对话历史 → 页面 initState 恢复）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/core/app.dart';
import 'package:baoji_timer/l10n/lang.dart';
import 'package:baoji_timer/services/ai_service.dart';
import 'package:baoji_timer/ui/ai_coach_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  tearDownAll(() async {
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/baoji_timer.db');
  });

  group('lastRecapReply', () {
    const recap = AiMessage('assistant', '复盘：容量总体上升，弱项是下肢。');
    final turns = [
      const AiMessage('user', '我最近练得怎么样？'),
      const AiMessage('assistant', '还行。'),
      AiMessage('user', AiService.kAnalysisInstruction),
      recap,
    ];

    test('没有复盘指令 → null', () {
      expect(AiService.lastRecapReply(turns.sublist(0, 2)), isNull);
      expect(AiService.lastRecapReply(const []), isNull);
    });

    test('复盘指令是最后一轮（回复未回）→ null', () {
      expect(
        AiService.lastRecapReply(turns.sublist(0, 3)),
        isNull,
      );
    });

    test('正常复盘 → 指令后紧跟的 assistant 轮', () {
      expect(AiService.lastRecapReply(turns), same(recap));
    });

    test('多轮复盘取最近一次；中间夹问答不干扰（按指令内容匹配）', () {
      const recap2 = AiMessage('assistant', '第二次复盘。');
      final multi = [
        ...turns,
        const AiMessage('user', '弱项怎么补？'),
        const AiMessage('assistant', '深蹲加容量。'),
        AiMessage('user', AiService.kAnalysisInstruction),
        recap2,
      ];
      expect(AiService.lastRecapReply(multi), same(recap2));
    });
  });

  group('buildRecapMarkdown', () {
    test('标题带绝对日期（补零），正文保持原文', () {
      final md = AiService.buildRecapMarkdown(
        DateTime(2026, 9, 8),
        'LeanLift 阶段复盘',
        '要点一\n要点二',
      );
      expect(md, contains('# LeanLift 阶段复盘 2026-09-08'));
      expect(md, contains('要点一\n要点二'));
    });
  });

  group('AI 教练页导出按钮可用态', () {
    late AppContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      container = AppContainer(prefs: prefs);
      await container.db.wipeAll();
    });

    tearDown(() async {
      await container.db.wipeAll();
      container.dispose();
    });

    Future<void> pumpCoach(WidgetTester tester) async {
      Lang.setResolved(false);
      await tester.pumpWidget(AppScope(
        container: container,
        child: const MaterialApp(home: AiCoachPage()),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    IconButton exportButton(WidgetTester tester) =>
        tester.widget<IconButton>(find.ancestor(
          of: find.byTooltip('导出复盘存档'),
          matching: find.byType(IconButton),
        ));

    testWidgets('历史里有复盘 → 导出按钮可点', (tester) async {
      container.settings.aiChatHistoryJson = jsonEncode([
        {'role': 'user', 'content': AiService.kAnalysisInstruction},
        {'role': 'assistant', 'content': '复盘内容：容量上升。'},
      ]);
      await pumpCoach(tester);
      expect(exportButton(tester).onPressed, isNotNull);
    });

    testWidgets('只有问答没有复盘 → 导出按钮置灰', (tester) async {
      container.settings.aiChatHistoryJson = jsonEncode([
        {'role': 'user', 'content': '我最近练得怎么样？'},
        {'role': 'assistant', 'content': '还行。'},
      ]);
      await pumpCoach(tester);
      expect(exportButton(tester).onPressed, isNull);
    });

    testWidgets('空历史 → 导出按钮置灰', (tester) async {
      await pumpCoach(tester);
      expect(exportButton(tester).onPressed, isNull);
    });
  });
}
