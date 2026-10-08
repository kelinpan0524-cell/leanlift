// 历史页表格化排版（2026-09-26 Arono：别再一条文字流，要格子）
// 覆盖：日期单独做卡片标题、计划标题独立一行、每动作一张
// 「组/重量 kg/次数/余力」表（R2 缩写改明示余力列）、备注保留。
// 明细行走公开布局函数 buildSessionDetailRows 直测（不绕页面异步）。
// （2026-09-27：1RM 竖线修复的 addRmPointToSeries 测试随函数一并移除，
//  1RM 图改走「每日最佳」口径，见 test/wger_p0_test.dart 的 DailyBest1Rm。）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/ui/history_page.dart';

void main() {
  testWidgets('明细布局：计划标题一行 + 动作表四列 + 余力明示 + 备注保留',
      (tester) async {
    final se = SessionExercise(
      sessionId: 1,
      name: '杠铃划船',
      orderIdx: 0,
      kind: 'compound',
      rule: ProgressionRule.fallback,
    ).copyWithId(7);
    const s = Session(
      id: 1,
      date: '2026-09-26',
      planDayTitle: '背 + 肩',
      startedAt: 1000,
      endedAt: 2000,
      status: 'done',
      restMs: 31 * 60000,
      activeMs: 26 * 60000,
    );
    final rows = buildSessionDetailRows(s, [se], {
      7: const [
        SetEntry(
          sessionExerciseId: 7,
          weightKg: 50,
          reps: 8,
          rir: 2,
          kind: SetKind.working,
          doneAt: 1100,
        ),
        SetEntry(
          sessionExerciseId: 7,
          weightKg: 30,
          reps: 10,
          rir: 1,
          kind: SetKind.warmup,
          doneAt: 1200,
          note: '热身偏轻',
        ),
      ],
    }, bodyWeightKg: 70);

    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: rows),
      ),
    ));
    await tester.pump();

    // 计划标题独立一行
    expect(find.text('背 + 肩'), findsOneWidget);
    expect(find.textContaining('训练 26 分 · 休息 31 分'), findsOneWidget);
    // 动作名 + 表头四列（余力列头明示，不再 R2 缩写）
    expect(find.text('杠铃划船'), findsOneWidget);
    expect(find.text('组'), findsOneWidget);
    expect(find.text('重量 kg'), findsOneWidget);
    expect(find.text('次数'), findsOneWidget);
    expect(find.text('余力'), findsOneWidget);
    // 两行数据：正式组 50/8/2，热身 30/10/热
    expect(find.text('50'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('2'), findsNWidgets(2),
        reason: '第一组余力 2 + 第二行组号 2 同字');
    expect(find.text('30'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    expect(find.text('热'), findsOneWidget);
    expect(find.text('1'), findsOneWidget, reason: '第一列组号');
    expect(find.textContaining('R2'), findsNothing, reason: '不再用 R 缩写');
    // 备注保留
    expect(find.textContaining('备注'), findsOneWidget);
    expect(find.textContaining('热身偏轻'), findsOneWidget);
  });

  testWidgets('加练标注：组号「N（加练）」+ 含加练行 + 列宽 64（无加练维持 34）',
      (tester) async {
    final withExtra = SessionExercise(
      sessionId: 1,
      name: '杠铃卧推',
      orderIdx: 0,
      kind: 'compound',
      rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
    ).copyWithId(7);
    final withoutExtra = SessionExercise(
      sessionId: 1,
      name: '杠铃划船',
      orderIdx: 1,
      kind: 'compound',
      rule: ProgressionRule.fallback,
    ).copyWithId(8);
    const s = Session(
      id: 1,
      date: '2026-10-08',
      planDayTitle: '推日',
      startedAt: 1000,
      endedAt: 2000,
      status: 'done',
    );
    final rows = buildSessionDetailRows(s, [withExtra, withoutExtra], {
      7: [
        // 计划 3 组 + 1 组加练（第 4 行标 isExtra）
        for (var i = 0; i < 4; i++)
          SetEntry(
            sessionExerciseId: 7,
            weightKg: 60,
            reps: 8,
            rir: 2,
            kind: SetKind.working,
            doneAt: 1100 + i,
            isExtra: i >= 3,
          ),
      ],
      8: [
        const SetEntry(
          sessionExerciseId: 8,
          weightKg: 50,
          reps: 8,
          rir: 2,
          kind: SetKind.working,
          doneAt: 1300,
        ),
      ],
    }, bodyWeightKg: 70);

    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: rows),
      ),
    ));
    await tester.pump();

    // 加练动作块：第 4 行组号带「（加练）」括注 + 单列一行含加练说明
    expect(find.text('4（加练）'), findsOneWidget);
    expect(find.textContaining('含加练 1 组'), findsOneWidget);
    final tables = tester.widgetList<Table>(find.byType(Table)).toList();
    expect(tables.length, 2);
    expect((tables[0].columnWidths![0] as FixedColumnWidth).value, 64,
        reason: '有加练的动作：第一列放宽装下「N（加练）」');
    expect((tables[1].columnWidths![0] as FixedColumnWidth).value, 34,
        reason: '无加练的动作：列宽维持 34');
    expect(find.text('1'), findsNWidgets(2),
        reason: '两动作各一个组号 1（无加练的组号不带括注）');
  });
}
