// 循环排程轮转语义（2026-09-26 Arono 拍板）：模板日按「全局训练序号」
// 依次轮转，连练数不必等于训练日数——练2休1 配 6 个训练日即
// T1T2休T3T4休T5T6休T1…接着往下轮，练完一圈从头再来。
// （旧实现用窗口内 pos 取下标：连练 < 训练日数时多出的模板日永远排不上，
// 曾被当「搁浅」用警示兜底，语义废弃——现在这种配置就是正常轮转。）
// 同时锁定 trainableDayCount 口径。基建同 plan_repository_test：ffi 真库。
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
        '$dir/test_cycle_${DateTime.now().microsecondsSinceEpoch}.db';
    final rawDb = await databaseFactory.openDatabase(path);
    await Db.instance.createSchema(rawDb);
    db = Db.forTesting(rawDb);
    repo = PlanRepository(db, Settings(prefs));
  });

  tearDown(() async {
    await db.wipeAll();
  });

  /// 建 [titles] 个模板日，每日 1 个动作；[emptyIdx] 列表里的下标留空模板日。
  Future<Plan> buildCyclePlan(
    List<String> titles, {
    List<int> emptyIdx = const [],
    int train = 2,
    int rest = 2,
  }) async {
    final plan = await db.insertPlan(Plan(
      name: titles.join(),
      source: 'manual',
      createdAt: '2026-09-25',
      pattern: 'cycle',
      patternStart: '2026-09-01',
      cycleTrain: train,
      cycleRest: rest,
    ));
    for (var i = 0; i < titles.length; i++) {
      final day = await db.insertPlanDay(PlanDay(
          planId: plan.id!, weekday: i + 1, title: titles[i]));
      if (!emptyIdx.contains(i)) {
        await db.insertPlanExercise(PlanExercise(
          dayId: day,
          name: '动作${i + 1}',
          orderIdx: 0,
          sets: 3,
          repsMin: 8,
          repsMax: 12,
          restSec: 90,
          kind: 'compound',
          rule: const ProgressionRule(repsMin: 8, repsMax: 12),
        ));
      }
    }
    return plan;
  }

  test('trainableDayCount：有动作的训练日数，空模板日不计入', () async {
    final plan = await buildCyclePlan(['胸', '腿', '背']);
    expect(await repo.trainableDayCount(plan.id!), 3);

    final emptyBack = await buildCyclePlan(['胸', '腿', '背'],
        emptyIdx: const [2]);
    expect(await repo.trainableDayCount(emptyBack.id!), 2);
  });

  test('Arono 用例：6 训练日 + 练2休1 → 三个窗口转完一圈，从头再来', () async {
    final plan = await buildCyclePlan(
      ['胸', '腿', '背', '肩', '臂', '核心'],
      train: 2,
      rest: 1,
    );
    // 窗口1：胸、腿；休 1 天
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 1)))!.title, '胸');
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 2)))!.title, '腿');
    expect(await repo.dayForDateOn(plan, DateTime(2026, 9, 3)), isNull);
    // 窗口2：接着是第 3、4 个训练日，不是又从胸开始
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 4)))!.title, '背');
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 5)))!.title, '肩');
    expect(await repo.dayForDateOn(plan, DateTime(2026, 9, 6)), isNull);
    // 窗口3：第 5、6 个训练日；之后休 1 天再从胸（第 1 个）轮起
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 7)))!.title, '臂');
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 8)))!.title, '核心');
    expect(await repo.dayForDateOn(plan, DateTime(2026, 9, 9)), isNull);
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 10)))!.title, '胸',
        reason: '练完一圈从头再来');
  });

  test('跨窗口轮转：3 训练日 + 练2休2 → 每个训练日都轮得到', () async {
    final plan = await buildCyclePlan(['胸', '腿', '背']);
    // occ 序列 0,1 | 2,3 | 4,5 | 6 → 下标 0,1 | 2,0 | 1,2 | 0
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 1)))!.title, '胸');
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 2)))!.title, '腿');
    expect(await repo.dayForDateOn(plan, DateTime(2026, 9, 3)), isNull);
    expect(await repo.dayForDateOn(plan, DateTime(2026, 9, 4)), isNull);
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 5)))!.title, '背',
        reason: '第二个训练窗口接着用第 3 个模板日（旧实现这里又回到胸）');
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 6)))!.title, '胸');
    expect(await repo.dayForDateOn(plan, DateTime(2026, 9, 7)), isNull);
    expect(await repo.dayForDateOn(plan, DateTime(2026, 9, 8)), isNull);
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 9)))!.title, '腿');
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 10)))!.title, '背');
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 13)))!.title, '胸',
        reason: '12 天（3 个窗口 × 4 天周期）后回到起点');
  });

  test('连练=训练日数（对齐）：语义与旧版一致，胸腿背休休胸', () async {
    final plan =
        await buildCyclePlan(['胸', '腿', '背'], train: 3, rest: 2);
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 1)))!.title, '胸');
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 2)))!.title, '腿');
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 3)))!.title, '背');
    expect(await repo.dayForDateOn(plan, DateTime(2026, 9, 4)), isNull);
    expect(await repo.dayForDateOn(plan, DateTime(2026, 9, 5)), isNull);
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 6)))!.title, '胸');
  });

  test('空模板日被推导跳过：轮转只在有动作的模板日里循环', () async {
    final plan = await buildCyclePlan(['胸', '腿', '背'],
        emptyIdx: const [2], train: 2, rest: 2);
    // 可练日=[胸,腿]：occ 0=胸 1=腿，休 2 天后 occ 2=胸 3=腿
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 1)))!.title, '胸');
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 2)))!.title, '腿');
    expect(await repo.dayForDateOn(plan, DateTime(2026, 9, 3)), isNull);
    expect((await repo.dayForDateOn(plan, DateTime(2026, 9, 5)))!.title, '胸');
  });

  test('起始日之前不推导：返回休息', () async {
    final plan = await buildCyclePlan(['胸', '腿', '背']);
    expect(await repo.dayForDateOn(plan, DateTime(2026, 8, 31)), isNull,
        reason: 'patternStart(9/1) 之前不产生训练日');
  });

  test('cycleRotationIndex：「第N练」标签与实际轮转顺序一致，空模板日不编号', () async {
    final plan = await buildCyclePlan(['胸', '空A', '腿', '背', '空B', '肩'],
        emptyIdx: const [1, 4], train: 2, rest: 1);
    final days = await db.planDays(plan.id!);
    final exMap = await db.daysExercisesMap(days.map((d) => d.id!).toList());
    final rotation = cycleRotationIndex(days, exMap);

    // 空模板日不进编号；非空的按槽位顺序连续编号（与列表展示口径一致）
    expect(rotation.length, 4);
    expect(rotation[days[0].id], 1); // 胸
    expect(rotation.containsKey(days[1].id), false); // 空A
    expect(rotation[days[2].id], 2); // 腿
    expect(rotation[days[3].id], 3); // 背
    expect(rotation.containsKey(days[4].id), false); // 空B
    expect(rotation[days[5].id], 4); // 肩

    // 乱序输入结果不变（函数内部按 weekday,id 排序，不依赖传入顺序）
    expect(cycleRotationIndex(days.reversed.toList(), exMap), rotation);

    // 对拍轮转引擎：第 n 次训练（从 1 计）推导出的模板日，标签恰为第 n%4 练
    var n = 0;
    for (var i = 0; i < 30; i++) {
      final day = await repo.dayForDateOn(
          plan, DateTime(2026, 9, 1).add(Duration(days: i)));
      if (day != null) {
        n++;
        expect(rotation[day.id], ((n - 1) % 4) + 1,
            reason: '第 $n 次训练应使用第 ${((n - 1) % 4) + 1} 练的模板日');
      }
    }
    expect(n, 20, reason: '练2休1、30 天应恰好 20 个训练日');
  });
}
