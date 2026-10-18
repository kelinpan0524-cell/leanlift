// 动作编辑表单（计划编辑器与今日开练编辑页共用）的负荷类型回归：
// - 新增动作：选到词表自重动作时自动切「自重」
// - 编辑已有动作：改名不覆盖已保存的负荷类型（自定义动作/刻意负重都保留）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/presets/exercise_library.dart';
import 'package:baoji_timer/ui/plan_editor_page.dart';

PlanExercise _existing({
  required String name,
  required String loadType,
}) =>
    PlanExercise(
      dayId: 1,
      name: name,
      orderIdx: 0,
      sets: 3,
      repsMin: 8,
      repsMax: 12,
      restSec: 60,
      kind: 'assistance',
      rule: const ProgressionRule(repsMin: 8, repsMax: 12),
      loadType: loadType,
    );

/// 打开动作编辑表单、改名并保存，返回表单结果。
Future<ExerciseFormResult?> _renameAndSave(
  WidgetTester tester, {
  required String newName,
  PlanExercise? initial,
}) async {
  ExerciseFormResult? result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              result =
                  await Navigator.of(context).push<ExerciseFormResult>(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: ExerciseEditSheet(
                      initial: initial,
                      knownMetas: kExerciseLibrary,
                    ),
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, newName);
  await tester.pump();
  await tester.ensureVisible(find.text('保存'));
  await tester.tap(find.text('保存'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('新增动作：选到词表自重动作自动切「自重」', (tester) async {
    final result = await _renameAndSave(tester, newName: '俯卧撑');
    expect(result, isNotNull);
    expect(result!.name, '俯卧撑');
    expect(result.loadType, LoadMode.bodyweight,
        reason: '新增俯卧撑默认按自重口径，训练页才有自重渐进');
  });

  testWidgets('新增动作：负重变体仍是「负重」（要记录外加载重）', (tester) async {
    final result = await _renameAndSave(tester, newName: '负重引体向上');
    expect(result!.name, '负重引体向上');
    expect(result.loadType, LoadMode.weighted,
        reason: 'gear 标自重但动作本身要加重量，不能切成自重无重量列');
  });

  testWidgets('编辑已有动作：改名保留已保存的「自重」', (tester) async {
    final result = await _renameAndSave(
      tester,
      newName: '自定义自重动作改名',
      initial: _existing(name: '自定义自重动作', loadType: LoadMode.bodyweight),
    );
    expect(result!.name, '自定义自重动作改名');
    expect(result.loadType, LoadMode.bodyweight,
        reason: '已有动作的负荷类型不能被改名推断覆盖');
  });

  testWidgets('编辑已有动作：改名保留刻意设置的「负重」', (tester) async {
    final result = await _renameAndSave(
      tester,
      newName: '引体向上（负重版）',
      initial: _existing(name: '引体向上', loadType: LoadMode.weighted),
    );
    expect(result!.name, '引体向上（负重版）');
    expect(result.loadType, LoadMode.weighted,
        reason: '刻意设为负重的引体向上改名后仍要能记录外加载重');
  });
}
