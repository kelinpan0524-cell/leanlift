// 今日开练编辑（2026-10-07）：纯函数层与数据流回归。
// 覆盖：
//  - clearSupersetTagsAfterMutation：相邻对保留 / 重排拆散全清 / 孤 tag 清 /
//    删一员后剩余两人相邻仍保留（对拍 superset.dart supersetTagClears 语义）；
//  - renumberOrderIdx：任意乱序输入后 orderIdx 与列表下标一致；
//  - todayExerciseDefaults / todayRuleFor：复合/辅助默认值与步长
//    （照抄计划编辑器 _pickFromLibrary/_openExerciseSheet 口径）；
//  - 数据流：内存里改组数/删行/加行 → renumberOrderIdx → startFromDay，
//    断言 session_exercises 落库行反映编辑值且 orderIdx 与编辑后顺序一致，
//    且 db.dayExercises(dayId) 原样未动——钉死「编辑只影响当天、不写回
//    长期计划」（锚点 session_controller.dart startFromDay、
//    db.dart dayExercises 按 ORDER BY order_idx, id 读回）。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/engine/today_plan_edit.dart';
import 'package:baoji_timer/services/session_controller.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

PlanExercise _pe(
  String name,
  int order, {
  int sets = 3,
  String supersetTag = '',
  int repsMin = 5,
  int repsMax = 8,
}) =>
    PlanExercise(
      dayId: 1,
      name: name,
      orderIdx: order,
      sets: sets,
      repsMin: repsMin,
      repsMax: repsMax,
      restSec: 120,
      kind: 'compound',
      rule: ProgressionRule(
          repsMin: repsMin, repsMax: repsMax, workingSets: sets),
      supersetTag: supersetTag,
    );

void main() {
  group('clearSupersetTagsAfterMutation（纯函数）', () {
    test('相邻同 tag 两人组：保留不动', () {
      final list = [_pe('甲', 0, supersetTag: 'ss'), _pe('乙', 1, supersetTag: 'ss')];
      final out = clearSupersetTagsAfterMutation(list);
      expect(out.map((e) => e.supersetTag), ['ss', 'ss'],
          reason: '相邻成组不受影响');
    });

    test('重排拆散（中间隔了别人）：全组清空', () {
      final list = [
        _pe('甲', 0, supersetTag: 'ss'),
        _pe('丙', 1),
        _pe('乙', 2, supersetTag: 'ss'),
      ];
      final out = clearSupersetTagsAfterMutation(list);
      expect(out.map((e) => e.supersetTag), ['', '', ''],
          reason: '同 tag 不再相邻 = 拆散，全部解除');
    });

    test('孤 tag（单人）：清空', () {
      final list = [_pe('甲', 0, supersetTag: 'ss'), _pe('乙', 1)];
      final out = clearSupersetTagsAfterMutation(list);
      expect(out.first.supersetTag, '', reason: '单人不成组');
    });

    test('三人组删掉中间一人：剩余两人相邻仍保留', () {
      final three = [
        _pe('甲', 0, supersetTag: 'ss'),
        _pe('乙', 1, supersetTag: 'ss'),
        _pe('丙', 2, supersetTag: 'ss'),
      ];
      final afterDelete = [...three]..removeAt(1); // 删乙，剩甲丙相邻
      final out = clearSupersetTagsAfterMutation(afterDelete);
      expect(out.map((e) => e.supersetTag), ['ss', 'ss'],
          reason: '删一员后剩余两人相邻，仍是合法超级组');
    });

    test('无标记的列表：原样返回（不重建新列表内容）', () {
      final list = [_pe('甲', 0), _pe('乙', 1)];
      final out = clearSupersetTagsAfterMutation(list);
      expect(identical(out, list), isTrue, reason: '无清理时返回原列表');
    });
  });

  group('renumberOrderIdx（纯函数）', () {
    test('任意乱序 orderIdx 输入后与列表下标一致，其余字段原样', () {
      final list = [
        _pe('甲', 7),
        _pe('乙', 2),
        _pe('丙', 99),
      ];
      final out = renumberOrderIdx(list);
      expect([for (final e in out) e.orderIdx], [0, 1, 2]);
      expect([for (final e in out) e.name], ['甲', '乙', '丙'],
          reason: '顺序不变，只重排号');
      expect(out[2].sets, 3, reason: '其余字段不丢');
    });
  });

  group('todayExerciseDefaults / todayRuleFor（纯函数）', () {
    test('复合默认：4 组×6-10 次/休 150s/步长 2.5kg，规则同步', () {
      final d = todayExerciseDefaults(dayId: 1, orderIdx: 3, isCompound: true);
      expect(d.sets, 4);
      expect(d.repsMin, 6);
      expect(d.repsMax, 10);
      expect(d.restSec, 150);
      expect(d.kind, 'compound');
      expect(d.rule.workingSets, 4);
      expect(d.rule.incrementKg, 2.5);
      expect(d.rule.repsMin, 6);
      expect(d.rule.repsMax, 10);
      expect(d.orderIdx, 3);
    });

    test('辅助默认：3 组×8-12 次/休 90s/步长 1.25kg，规则同步', () {
      final d =
          todayExerciseDefaults(dayId: 1, orderIdx: 0, isCompound: false);
      expect(d.sets, 3);
      expect(d.repsMin, 8);
      expect(d.repsMax, 12);
      expect(d.restSec, 90);
      expect(d.kind, 'assistance');
      expect(d.rule.workingSets, 3);
      expect(d.rule.incrementKg, 1.25);
    });

    test('todayRuleFor 按参数与 kind 重建：workingSets 跟组数、步长跟类型', () {
      final c = todayRuleFor(sets: 5, repsMin: 3, repsMax: 6, kind: 'compound');
      expect(c.workingSets, 5);
      expect(c.repsMin, 3);
      expect(c.repsMax, 6);
      expect(c.incrementKg, 2.5);
      final a = todayRuleFor(sets: 2, repsMin: 12, repsMax: 15, kind: 'assistance');
      expect(a.workingSets, 2);
      expect(a.incrementKg, 1.25);
    });
  });

  group('数据流：编辑只进会话快照，不写回长期计划', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      // 测试环境没有宿主插件：wakelock_plus 的 pigeon toggle 通道挂 mock 回包
      // （编码后的 [null]，与 session_controller_test 同一套）。
      final binding = TestWidgetsFlutterBinding.instance;
      final pigeonNullReply = ByteData(3)
        ..setUint8(0, 12)
        ..setUint8(1, 1)
        ..setUint8(2, 0);
      binding.defaultBinaryMessenger.setMockMessageHandler(
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
        (data) async => pigeonNullReply,
      );
    });

    late Db db;
    late SharedPreferences prefs;
    final controllers = <SessionController>[];

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      final dir = await databaseFactory.getDatabasesPath();
      final path = '$dir/test_today_edit_${DateTime.now().microsecondsSinceEpoch}.db';
      final rawDb = await databaseFactory.openDatabase(path);
      await Db.instance.createSchema(rawDb);
      db = Db.forTesting(rawDb);
    });

    tearDown(() async {
      for (final c in controllers) {
        c.dispose();
      }
      controllers.clear();
      await db.wipeAll();
    });

    Future<PlanDay> makePlanDay(String title) async {
      final plan = await db.insertPlan(Plan(
          name: '测试计划-$title',
          source: 'manual',
          createdAt: '2026-10-07',
          isActive: 1));
      final dayId = await db.insertPlanDay(
          PlanDay(planId: plan.id!, weekday: 3, title: title));
      return PlanDay(id: dayId, planId: plan.id!, weekday: 3, title: title);
    }

    Future<PlanExercise> addPlanEx(
      PlanDay day,
      String name,
      int order, {
      int sets = 3,
      int repsMin = 5,
      int repsMax = 8,
      String supersetTag = '',
    }) async {
      final pe = PlanExercise(
        dayId: day.id!,
        name: name,
        orderIdx: order,
        sets: sets,
        repsMin: repsMin,
        repsMax: repsMax,
        restSec: 120,
        kind: 'compound',
        rule: ProgressionRule(
            repsMin: repsMin, repsMax: repsMax, workingSets: sets),
        supersetTag: supersetTag,
      );
      final id = await db.insertPlanExercise(pe);
      return pe.copyWith(id: id);
    }

    test('改组数/删行/加行 + 归一化后 startFromDay：会话落库反映编辑值，计划表原样', () async {
      final day = await makePlanDay('推日');
      final a = await addPlanEx(day, '卧推', 0, sets: 3);
      await addPlanEx(day, '划船', 1, sets: 3);
      final cEx = await addPlanEx(day, '深蹲', 2, sets: 3);

      // ===== 内存编辑（编辑页要做的事，零 DB 写）：删划船、卧推改 5 组、
      // 末尾加一个复合默认动作（面拉）=====
      var edited = [a, cEx];
      edited = [
        edited[0].copyWith(sets: 5, rule: todayRuleFor(sets: 5, repsMin: 5, repsMax: 8, kind: 'compound')),
        edited[1],
        todayExerciseDefaults(dayId: day.id!, orderIdx: 2, isCompound: true)
            .copyWith(name: '面拉'),
      ];
      edited = renumberOrderIdx(edited);
      expect([for (final e in edited) e.orderIdx], [0, 1, 2]);

      // ===== 开练：startFromDay 吃内存快照 =====
      final c = SessionController(db, Settings(prefs), prefs, null);
      controllers.add(c);
      await c.startFromDay(day: day, planExercises: edited);
      expect(c.hasActive, isTrue);
      expect(c.exercises.length, 3, reason: '编辑后的 3 个动作进会话');

      // ===== 会话落库行反映编辑值且 orderIdx 与编辑后顺序一致 =====
      final ses = await db.sessionExercises(c.session!.id!);
      expect([for (final e in ses) e.name], ['卧推', '深蹲', '面拉'],
          reason: '被杀恢复/历史明细按 ORDER BY order_idx 读回，顺序必须就是编辑后的顺序');
      expect([for (final e in ses) e.orderIdx], [0, 1, 2]);
      expect(ses[0].rule.workingSets, 5, reason: '卧推改的 5 组进了会话快照');
      expect(ses[2].rule.workingSets, 4, reason: '新加的面拉用复合默认 4 组');
      expect(ses[2].restSec, 150, reason: '新加动作默认休息 150s');

      // ===== 长期计划原样未动（核心承诺）=====
      final planRows = await db.dayExercises(day.id!);
      expect([for (final e in planRows) e.name], ['卧推', '划船', '深蹲'],
          reason: '计划表仍是原 3 个动作、原顺序');
      expect([for (final e in planRows) e.orderIdx], [0, 1, 2]);
      expect(planRows[0].sets, 3, reason: '卧推在计划里仍是 3 组，改的只是今天');
      expect(planRows.length, 3, reason: '没写回、没追加');
    });

    test('超级组相邻对保留 tag 进会话；拆散后的清单 tag 已在内存清掉', () async {
      final day = await makePlanDay('超级组日');
      final a = await addPlanEx(day, '动作甲', 0, supersetTag: 'ss');
      final b = await addPlanEx(day, '动作乙', 1, supersetTag: 'ss');
      final cEx = await addPlanEx(day, '动作丙', 2);

      // 保留相邻对：tag 原样进会话（训练中轮转按它分组）
      final c = SessionController(db, Settings(prefs), prefs, null);
      controllers.add(c);
      final kept = renumberOrderIdx([a, b, cEx]);
      await c.startFromDay(day: day, planExercises: kept);
      expect(c.exercises.map((e) => e.supersetTag).toList(), ['ss', 'ss', ''],
          reason: '相邻对 tag 原样快照进会话');
      // 先收掉第一个会话：startFromDay 有「已有进行中会话」防重入守卫，
      // 不收的话第二个会话静默不开（exercises 为空）
      await c.finish();

      // 拆散（把乙拖到丙后面）：clearSupersetTagsAfterMutation 在内存清掉，
      // 新会话里不再带悬空标记
      final c2 = SessionController(db, Settings(prefs), prefs, null);
      controllers.add(c2);
      final split = renumberOrderIdx(clearSupersetTagsAfterMutation([a, cEx, b]));
      expect(split.map((e) => e.supersetTag), ['', '', ''],
          reason: '拆散后内存清单已无悬空 tag');
      await c2.startFromDay(day: day, planExercises: split);
      expect(c2.exercises.map((e) => e.supersetTag).toList(), ['', '', ''],
          reason: '会话快照不带拆散的 tag');

      // 计划表原样：tag 仍在（编辑只影响今天）
      final planRows = await db.dayExercises(day.id!);
      expect(planRows.map((e) => e.supersetTag).toList(), ['ss', 'ss', '']);
    });
  });
}
