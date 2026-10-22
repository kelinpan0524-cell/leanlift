// AI 计划作用于现有计划 + 删除快照回收站（2026-09-26 Arono 三需求）：
// ① replacePlanWithSpecs：替换现有计划内容，计划行与启用态保留；
// ② 删除计划 → 快照进回收站 → 7 天内恢复为新计划；过期惰性清除；
// ③ AI 教练会话历史（aiChatHistoryJson）落盘往返。
// 基建同 plan_repository_test.dart：ffi 真库 + 独立测试库路径。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/models/models.dart';
import 'package:baoji_timer/services/plan_repository.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
  });

  late Db db;
  late SharedPreferences prefs;
  late PlanRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final dir = await databaseFactory.getDatabasesPath();
    final path =
        '$dir/test_aiact_${DateTime.now().microsecondsSinceEpoch}.db';
    final rawDb = await databaseFactory.openDatabase(path);
    await Db.instance.createSchema(rawDb);
    db = Db.forTesting(rawDb);
    repo = PlanRepository(db, Settings(prefs));
  });

  tearDown(() async {
    await db.wipeAll();
  });

  AiDaySpec spec(int weekday, String title, String exName) => AiDaySpec(
        weekday,
        title,
        [
          AiExerciseSpec(
              name: exName, sets: 3, repsMin: 5, repsMax: 8, restSec: 150),
        ],
      );

  Future<Plan> saveNamed(String name, int weekday, String exName,
      {bool activate = true}) {
    return repo.saveAiPlan(
      name: name,
      specs: [spec(weekday, '推日', exName)],
      metaMap: const {},
      activate: activate,
    );
  }

  test('replacePlanWithSpecs：内容全量重建、id 不变、可选改名、启用态保留', () async {
    final a = await saveNamed('计划A', 1, '杠铃卧推');
    await saveNamed('计划B', 2, '引体向上'); // B 后保存 → B 成为使用中
    expect(repo.activePlan?.name, '计划B');

    final replaced = await repo.replacePlanWithSpecs(
      a.id!,
      [spec(3, '腿日', '杠铃深蹲'), spec(5, '推日二', '杠铃卧推')],
      const {},
      rename: '计划A·改',
    );

    expect(replaced.id, a.id, reason: '替换不换 id');
    expect(replaced.name, '计划A·改');
    expect(replaced.isActive, 0, reason: 'A 原本未启用，替换后仍不启用');
    final days = await db.planDays(a.id!);
    expect(days.length, 2, reason: '旧内容被全量重建');
    final exMap = await db
        .daysExercisesMap(days.map((d) => d.id!).toList());
    final names = [
      for (final list in exMap.values)
        for (final e in list) e.name,
    ];
    expect(names, containsAll(['杠铃深蹲', '杠铃卧推']));
    expect(names, isNot(contains('引体向上')));

    // 使用中的计划被替换后仍是使用中（启用态保留）
    final activeId = repo.activePlan?.id;
    await repo.replacePlanWithSpecs(
        repo.activePlan!.id!, [spec(6, '新推日', '杠铃卧推')], const {});
    expect(repo.activePlan?.id, activeId);
  });

  test('删除计划 → 快照进回收站 → 恢复为新计划（训练日/动作完整）', () async {
    final a = await saveNamed('要删的计划', 1, '杠铃卧推');
    await saveNamed('留守计划', 2, '引体向上');
    final trashBefore = await db.listDeletedPlans();
    expect(trashBefore, isEmpty);

    await repo.deletePlanAndFixActive(a.id!);
    expect((await db.allPlans()).any((p) => p.id == a.id!), isFalse,
        reason: '原计划已硬删');
    final trash = await db.listDeletedPlans();
    expect(trash.length, 1);
    expect(trash.first['name'], '要删的计划');

    final restored = await repo.restoreFromTrash(trash.first['id'] as int);
    expect(restored, isNotNull);
    expect(restored!.id, isNot(a.id!), reason: '恢复为新 id');
    expect(restored.name, '要删的计划');
    expect(restored.isActive, 0, reason: '恢复不自动启用');
    final days = await db.planDays(restored.id!);
    expect(days.length, 1);
    final exMap = await db.daysExercisesMap(days.map((d) => d.id!).toList());
    expect(exMap[days.first.id!]!.first.name, '杠铃卧推');
    expect(await db.listDeletedPlans(), isEmpty, reason: '恢复后回收站行删除');
  });

  test('回收站过期清除：7 天前的快照被清，新快照保留', () async {
    final a = await saveNamed('老快照', 1, '杠铃卧推');
    await repo.deletePlanAndFixActive(a.id!);
    // 手工把 deleted_at 改成 8 天前，模拟过期
    final old = DateTime.now().subtract(const Duration(days: 8));
    await (await db.database).update(
      'deleted_plans',
      {'deleted_at': old.toIso8601String()},
    );

    final b = await saveNamed('新快照', 2, '引体向上');
    await repo.deletePlanAndFixActive(b.id!);

    await db.purgeExpiredDeletedPlans(keepDays: 7);
    final rows = await db.listDeletedPlans();
    expect(rows.length, 1);
    expect(rows.first['name'], '新快照');
  });

  test('删除带排程覆盖行与循环参数的计划再恢复：映射与参数完整', () async {
    // 独立评审点名的 HIGH 场景：覆盖行 day_id 在快照里存的是"训练日下标"，
    // 恢复必须映射回同一下标的新训练日，错位一天就是排程事故
    final plan = await repo.saveAiPlan(
      name: '循环计划',
      specs: [
        spec(1, '推', '杠铃卧推'),
        spec(3, '拉', '引体向上'),
        spec(5, '腿', '杠铃深蹲'),
      ],
      metaMap: const {},
      activate: false,
    );
    await db.updatePlanFields(plan.id!, {
      'pattern': 'cycle',
      'pattern_start': '2026-09-01',
      'cycle_train': 2,
      'cycle_rest': 1,
    });
    final days = await db.planDays(plan.id!);
    final legDay = days.firstWhere((d) => d.title == '腿');
    await db.upsertScheduleEntry(PlanScheduleEntry(
        planId: plan.id!, date: '2026-09-28', dayId: legDay.id));
    await db.upsertScheduleEntry(
        PlanScheduleEntry(planId: plan.id!, date: '2026-09-29', dayId: null));

    await repo.deletePlanAndFixActive(plan.id!);
    final trash = await db.listDeletedPlans();
    final restored = await repo.restoreFromTrash(trash.first['id'] as int);
    expect(restored, isNotNull);
    // 循环参数与起始日原样还原
    expect(restored!.pattern, 'cycle');
    expect(restored.patternStart, '2026-09-01');
    expect(restored.cycleTrain, 2);
    expect(restored.cycleRest, 1);

    // 覆盖行映射：按标题找到新"腿日"，覆盖行应精确指向它；显式休息保持 null
    final newDays = await db.planDays(restored.id!);
    final newLegDay = newDays.firstWhere((d) => d.title == '腿');
    final entries = await db.allScheduleEntries(restored.id!);
    expect(entries.length, 2);
    for (final e in entries) {
      if (e.date == '2026-09-28') {
        expect(e.dayId, newLegDay.id,
            reason: '指向"腿"的覆盖行必须映射回新的腿日 id，不能错位');
      } else if (e.date == '2026-09-29') {
        expect(e.dayId, isNull, reason: '显式休息行保持 null');
      }
    }
  });

  test('AI 会话历史：Settings 落盘往返', () async {
    final history = jsonEncode([
      {'role': 'user', 'content': '帮我排个计划'},
      {'role': 'assistant', 'content': '好的'},
    ]);
    final s = Settings(prefs);
    s.aiChatHistoryJson = history;
    await s.save();
    // 同一 prefs 重建 Settings（App 冷启动路径）应读到历史
    final s2 = Settings(prefs);
    expect(s2.aiChatHistoryJson, history);
  });
}
