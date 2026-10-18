// P1-A 动作稳定身份：
// - exerciseKeyOf 的空白/标点/大小写/中英别名归一；
// - 同义名共享历史与 PR（纵向查询按 exercise_key）；
// - 计划动作/会话动作落库自动写 key（显式键保留）；
// - AI 导入仍落到规范名，再由规范名落 key。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/services/ai_service.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('exerciseKeyOf 归一', () {
    test('中文别名、空白与括号注记归一到同一键', () {
      expect(exerciseKeyOf('平板卧推'), exerciseKeyOf('杠铃卧推'));
      expect(exerciseKeyOf(' 杠铃 卧推 '), '杠铃卧推');
      expect(exerciseKeyOf('引体'), '引体向上');
      expect(exerciseKeyOf('引体向上（正手）'), '引体向上');
      expect(
        exerciseKeyOf('腿举（倒蹬机）'),
        exerciseKeyOf('腿举(倒蹬机)'),
        reason: '中英文括号都当标点去掉',
      );
      expect(exerciseKeyOf('罗马椅挺身'), '山羊挺身');
    });

    test('英文别名大小写/连写/标点归一', () {
      expect(exerciseKeyOf('Bench Press'), '杠铃卧推');
      expect(exerciseKeyOf('bench-press'), '杠铃卧推');
      expect(exerciseKeyOf('Push-Up!'), '俯卧撑');
      expect(exerciseKeyOf('PULL UP'), '引体向上');
      expect(exerciseKeyOf('Bulgarian Split Squat'), '保加利亚分腿蹲');
      expect(exerciseKeyOf('RDL'), '罗马尼亚硬拉');
    });

    test('未知动作只去空白/标点+小写，不做模糊合并', () {
      expect(exerciseKeyOf(' 我的 自创-动作 '), '我的自创动作');
      expect(exerciseKeyOf('My Custom Move'), 'mycustommove');
      expect(exerciseKeyOf('Ab Wheel'), '健腹轮');
    });

    test('泛称不被吸到具体变体（保持既有收紧语义）', () {
      expect(exerciseKeyOf('卧推'), '卧推');
      expect(exerciseKeyOf('划船'), '划船');
      expect(exerciseKeyOf('深蹲'), '深蹲');
    });

    test('动作库里并存的动作不被错误合并', () {
      // 库中「仰卧起坐」与「卷腹」是两条动作（cue 不同）
      expect(exerciseKeyOf('仰卧起坐'), '仰卧起坐');
      expect(exerciseKeyOf('仰卧起坐'), isNot(exerciseKeyOf('卷腹')));
      expect(canonicalExerciseNameOf('仰卧起坐'), '仰卧起坐');
      // 英文 sit up 指仰卧起坐，不能和卷腹合并
      expect(exerciseKeyOf('Sit Up'), '仰卧起坐');
      expect(exerciseKeyOf('sit-up'), '仰卧起坐');
      expect(exerciseKeyOf('Sit Up'), isNot(exerciseKeyOf('卷腹')));
      expect(canonicalExerciseNameOf('Sit Up'), '仰卧起坐');
      // chin-up 是反握引体，不能并到正握「引体向上」
      expect(exerciseKeyOf('Chin Up'), exerciseKeyOf('引体向上（反手）'));
      expect(exerciseKeyOf('Chin Up'), isNot(exerciseKeyOf('引体向上')));
      // 「臀推」归到「杠铃臀推」，不能落到另一个动作「杠铃臀桥」
      expect(exerciseKeyOf('臀推'), '杠铃臀推');
      expect(exerciseKeyOf('臀推'), isNot(exerciseKeyOf('杠铃臀桥')));
      expect(canonicalExerciseNameOf('臀推'), '杠铃臀推');
      // 英文 hip thrust 同样归到臀推，而不是臀桥
      expect(exerciseKeyOf('Hip Thrust'), '杠铃臀推');
    });

    test('空名/纯标点返回空键', () {
      expect(exerciseKeyOf(''), '');
      expect(exerciseKeyOf('   '), '');
      expect(exerciseKeyOf('（）— 、'), '');
    });

    test('按身份键分组：同义名合并、不同身份即使同名也分开', () {
      final grouped = groupExerciseListsByIdentity<String>([
        (name: '杠铃卧推', exerciseKey: '杠铃卧推', items: const ['a']),
        (name: '平板卧推', exerciseKey: '杠铃卧推', items: const ['b']),
        (name: 'Bench Press', exerciseKey: null, items: const ['c']),
        (name: '哑铃飞鸟', exerciseKey: '', items: const ['d']),
      ]);
      final byKey = {for (final g in grouped) g.key: g.items};
      expect(byKey['杠铃卧推'], ['a', 'b', 'c']);
      expect(byKey['哑铃飞鸟'], ['d']);
      expect(byKey.containsKey('平板卧推'), isFalse,
          reason: '展示名统一用规范名，分组键仍是身份键');

      // 两个不同身份键共用同一个规范展示名：不能合并
      final collided = groupExerciseListsByIdentity<String>([
        (name: '杠铃卧推', exerciseKey: '杠铃卧推', items: const ['x']),
        (
          name: '杠铃卧推',
          exerciseKey: 'barbell_bench_press',
          items: const ['y']
        ),
      ]);
      expect(collided, hasLength(2));
      final used = <String>{};
      final labels = [
        for (final g in collided)
          uniqueExerciseLabel(g.displayName, g.key, used),
      ];
      expect(labels.toSet(), hasLength(2),
          reason: '展示名冲突时用键后缀区分，不能并桶');
    });

    test('编辑改名：任意改名保留旧键，只有换成已有动作才换键', () {
      // 同义名/拼写修正：仍是同一个动作，历史不断
      expect(
        exerciseKeyAfterRename(
            oldName: '杠铃卧推', oldKey: '杠铃卧推', newName: '平板卧推'),
        '杠铃卧推',
      );
      // 任意改名到新的显示名（不是词表动作）：沿用旧身份
      expect(
        exerciseKeyAfterRename(
            oldName: '杠铃卧推', oldKey: '杠铃卧推', newName: '杠铃卧推（宽握）'),
        '杠铃卧推',
      );
      expect(
        exerciseKeyAfterRename(
            oldName: '杠铃卧推', oldKey: '杠铃卧推', newName: '卧推王'),
        '杠铃卧推',
      );
      // 换成词表里的另一个动作：不能继承旧身份
      expect(
        exerciseKeyAfterRename(
          oldName: '杠铃卧推',
          oldKey: '杠铃卧推',
          newName: '哑铃飞鸟',
          newNameIsKnownExercise: true,
        ),
        '哑铃飞鸟',
      );
      // 新名字已有同名行（自定义键）：用已有键
      expect(
        exerciseKeyAfterRename(
          oldName: '杠铃卧推',
          oldKey: '杠铃卧推',
          newName: '哑铃飞鸟',
          storedNewKey: 'custom_fly',
        ),
        'custom_fly',
      );
      // 同义名改名、旧键是自定义键：仍属同一动作，保留自定义键
      expect(
        exerciseKeyAfterRename(
            oldName: '平板卧推', oldKey: 'custom_key', newName: '杠铃卧推'),
        'custom_key',
      );
      // 只改其他字段（名字没变）：自定义键原样保留
      expect(
        exerciseKeyAfterRename(
            oldName: '我的动作', oldKey: 'custom_key', newName: '我的动作'),
        'custom_key',
      );
      // 老行空键、名字没变：仍留空，交给落库层补
      expect(
        exerciseKeyAfterRename(oldName: '我的动作', oldKey: '', newName: '我的动作'),
        '',
      );
      // 老行空键、任意改名：保留旧名字对应的身份键
      expect(
        exerciseKeyAfterRename(
            oldName: '杠铃卧推', oldKey: '', newName: '卧推王'),
        '杠铃卧推',
      );
    });
  });

  group('同义名共享历史/PR（DB 纵向查询按 exercise_key）', () {
    late Db db;

    setUp(() async {
      final dir = await databaseFactory.getDatabasesPath();
      final path =
          '$dir/test_identity_${DateTime.now().microsecondsSinceEpoch}.db';
      final raw = await databaseFactory.openDatabase(path);
      await Db.instance.createSchema(raw);
      db = Db.forTesting(raw);
    });

    tearDown(() async {
      await db.wipeAll();
    });

    Future<int> addSession({
      required String date,
      required String name,
      required int startedAt,
      required List<(double, int)> sets,
      int targetSets = 3,
      String logging = LoggingMode.reps,
      String loadType = LoadMode.weighted,
    }) async {
      final s = await db.insertSession(
        Session(
          date: date,
          planDayTitle: '推日',
          startedAt: startedAt,
          endedAt: startedAt + 1000,
          status: 'done',
        ),
      );
      final seId = await db.insertSessionExercise(
        SessionExercise(
          sessionId: s.id!,
          name: name,
          orderIdx: 0,
          kind: 'compound',
          rule: const ProgressionRule(repsMin: 5, repsMax: 8),
          targetSets: targetSets,
          logging: logging,
          loadType: loadType,
        ),
      );
      var t = startedAt + 10;
      for (final (w, r) in sets) {
        await db.insertSet(
          SetEntry(
            sessionExerciseId: seId,
            weightKg: w,
            reps: r,
            kind: SetKind.working,
            doneAt: t++,
          ),
        );
      }
      return seId;
    }

    test('杠铃卧推 / 平板卧推 / Bench Press 共享历史与 PR', () async {
      await addSession(
        date: '2026-09-01',
        name: '杠铃卧推',
        startedAt: 1000,
        sets: [(60, 8), (62.5, 7)],
        targetSets: 3,
      );
      await addSession(
        date: '2026-09-08',
        name: '平板卧推',
        startedAt: 2000,
        sets: [(70, 5)],
        targetSets: 3,
      );
      final latestSe = await addSession(
        date: '2026-09-15',
        name: 'Bench Press',
        startedAt: 3000,
        sets: [(72.5, 5), (70, 6)],
        targetSets: 4,
        logging: LoggingMode.time,
        loadType: LoadMode.bodyweight,
      );

      // 任一别名查历史都拿到全部 5 组，且按时间升序
      final history = await db.historySets('平板卧推', kindFilter: 'working');
      expect(history.length, 5);
      expect(history.first.weightKg, 60);
      expect(history.last.weightKg, 70);

      // PR 跨别名取全局最高
      expect(await db.maxWeightOf('杠铃卧推'), 72.5);
      expect(await db.maxWeightOf('Bench Press'), 72.5);

      // 上次成绩 = 最近一次训练（含同一场里同键的全部正式组）
      final last = await db.lastWorkingSets('平板卧推');
      expect(last.length, 2);
      expect(last.map((e) => e.weightKg), [72.5, 70]);

      // 上次处方组数与记录形态同样跨别名取最近一场
      expect(await db.lastTargetSets('杠铃卧推'), 4);
      final modes = await db.lastExerciseModes('平板卧推');
      expect(modes, (LoggingMode.time, LoadMode.bodyweight));

      // 当前会话之前的历史截断仍按 session_exercise 的 done_at 生效
      final before = await db.historySets(
        '杠铃卧推',
        beforeSessionExerciseId: latestSe,
        kindFilter: 'working',
      );
      expect(before.length, 3, reason: '截掉最近一场的 2 组');
    });

    test('计划/会话动作落库写入 key，显式键保留', () async {
      final plan = await db.insertPlan(
        Plan(name: '身份测试', source: 'manual', createdAt: '2026-10-17'),
      );
      final dayId = await db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 1, title: '推'),
      );
      await db.insertPlanExercise(
        PlanExercise(
          dayId: dayId,
          name: '平板卧推',
          orderIdx: 0,
          sets: 3,
          repsMin: 5,
          repsMax: 8,
          restSec: 120,
          kind: 'compound',
          rule: ProgressionRule.fallback,
        ),
      );
      await db.insertPlanExercise(
        PlanExercise(
          dayId: dayId,
          name: '我的动作',
          orderIdx: 1,
          sets: 3,
          repsMin: 8,
          repsMax: 12,
          restSec: 90,
          kind: 'assistance',
          rule: ProgressionRule.fallback,
          exerciseKey: 'custom_key',
        ),
      );
      final rows = await db.dayExercises(dayId);
      expect(rows[0].exerciseKey, '杠铃卧推', reason: '空键按别名归一后的规范名生成');
      expect(rows[1].exerciseKey, 'custom_key', reason: '显式键不被覆盖');

      // startFromDay 走 insertSessionWithExercises：会话动作行同样带键
      final (_, sessions) = await db.insertSessionWithExercises(
        Session(
          date: '2026-10-17',
          planDayTitle: '推',
          startedAt: 3000,
          status: 'active',
        ),
        [
          SessionExercise(
            sessionId: 0,
            name: 'Bench Press',
            orderIdx: 0,
            kind: 'compound',
            rule: ProgressionRule.fallback,
          ),
        ],
      );
      expect(sessions.single.exerciseKey, '杠铃卧推');
      final stored = await db.sessionExercises(sessions.single.sessionId);
      expect(stored.single.exerciseKey, '杠铃卧推');
    });

    test('新行空键时复用同名已有键（改名/追加不拆身份）', () async {
      final plan = await db.insertPlan(
        Plan(name: '同名键', source: 'manual', createdAt: '2026-10-18'),
      );
      final dayId = await db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 1, title: '推'),
      );
      // 第一条：改名后的显示名 + 旧稳定键
      await db.insertPlanExercise(PlanExercise(
        dayId: dayId,
        name: '哑铃飞鸟',
        orderIdx: 0,
        sets: 3,
        repsMin: 8,
        repsMax: 12,
        restSec: 90,
        kind: 'assistance',
        rule: ProgressionRule.fallback,
        exerciseKey: '杠铃卧推',
      ));
      // 第二条同名、空键：应复用已有键而不是现算成「哑铃飞鸟」
      await db.insertPlanExercise(PlanExercise(
        dayId: dayId,
        name: '哑铃飞鸟',
        orderIdx: 1,
        sets: 3,
        repsMin: 8,
        repsMax: 12,
        restSec: 90,
        kind: 'assistance',
        rule: ProgressionRule.fallback,
      ));
      final rows = await db.dayExercises(dayId);
      expect(rows[1].exerciseKey, '杠铃卧推');
      expect(await db.knownExerciseKey('哑铃飞鸟'), '杠铃卧推');

      // 会话动作走同一口径
      final s = await db.insertSession(Session(
        date: '2026-10-18',
        planDayTitle: '推',
        startedAt: 1000,
        endedAt: 2000,
        status: 'done',
      ));
      final seId = await db.insertSessionExercise(SessionExercise(
        sessionId: s.id!,
        name: '哑铃飞鸟',
        orderIdx: 0,
        kind: 'assistance',
        rule: ProgressionRule.fallback,
      ));
      final se = (await db.sessionExercises(s.id!)).single;
      expect(se.id, seId);
      expect(se.exerciseKey, '杠铃卧推');

      // 同名定制键也优先于名字现算
      await db.insertSessionExercise(SessionExercise(
        sessionId: s.id!,
        name: '我的动作',
        orderIdx: 1,
        kind: 'assistance',
        rule: ProgressionRule.fallback,
        exerciseKey: 'custom_key',
      ));
      expect(await db.knownExerciseKey('我的动作'), 'custom_key');
      await db.insertPlanExercise(PlanExercise(
        dayId: dayId,
        name: '我的动作',
        orderIdx: 2,
        sets: 3,
        repsMin: 8,
        repsMax: 12,
        restSec: 90,
        kind: 'assistance',
        rule: ProgressionRule.fallback,
      ));
      final after = await db.dayExercises(dayId);
      expect(after.last.exerciseKey, 'custom_key');
    });

    test('计划内改名保留旧键（历史不断）；换动作清键则按新名字取键', () async {
      final plan = await db.insertPlan(
        Plan(name: '改名', source: 'manual', createdAt: '2026-10-17'),
      );
      final dayId = await db.insertPlanDay(
        PlanDay(planId: plan.id!, weekday: 1, title: '推'),
      );
      await db.insertPlanExercise(
        PlanExercise(
          dayId: dayId,
          name: '杠铃卧推',
          orderIdx: 0,
          sets: 3,
          repsMin: 5,
          repsMax: 8,
          restSec: 120,
          kind: 'compound',
          rule: ProgressionRule.fallback,
        ),
      );
      final original = (await db.dayExercises(dayId)).single;
      expect(original.exerciseKey, '杠铃卧推');

      // 编辑器改名：copyWith 保留 exerciseKey（旧身份）
      await db.updatePlanExercise(original.copyWith(name: '平板卧推'));
      var row = (await db.dayExercises(dayId)).single;
      expect(row.name, '平板卧推');
      expect(row.exerciseKey, '杠铃卧推', reason: '改名沿用旧键，历史不拆');

      // 换动作：调用方清空键 → 按新动作名取键
      await db.updatePlanExercise(row.copyWith(name: '哑铃飞鸟', exerciseKey: ''));
      row = (await db.dayExercises(dayId)).single;
      expect(row.exerciseKey, '哑铃飞鸟');
    });
  });

  test('AI 导入仍落到规范名，身份键由规范名计算', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ai = AiService(Settings(prefs));
    final specs = ai.parseResponse(
      '[{"weekday":1,"title":"推","exercises":[{"name":"平板卧推","sets":3,"reps_min":5,"reps_max":8}]}]',
    );
    expect(
      specs.single.exercises.single.name,
      '杠铃卧推',
      reason: 'AI 导入的名字仍是词表规范名（不是身份键）',
    );
    expect(exerciseKeyOf(specs.single.exercises.single.name), '杠铃卧推');
  });
}
