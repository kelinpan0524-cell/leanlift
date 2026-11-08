import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/presets/exercise_library.dart';

SetEntry _ws(double w, int reps, {int rir = 2, int at = 1000}) => SetEntry(
      sessionExerciseId: 1,
      weightKg: w,
      reps: reps,
      rir: rir,
      kind: SetKind.working,
      doneAt: at,
    );

void main() {
  group('渐进超负荷判定', () {
    const rule = ProgressionRule(
        repsMin: 5, repsMax: 8, incrementKg: 2.5, rirTarget: 2, workingSets: 3);

    test('三组全部达到上限且末组余力充足 → 加重', () {
      final v = evaluateProgression(
        workingSets: [_ws(80, 8), _ws(80, 8), _ws(80, 8, rir: 2)],
        currentWeight: 80,
        rule: rule,
      );
      expect(v.action, ProgressionAction.increase);
      expect(v.deltaKg, 2.5);
    });

    test('末组余力不足 → 保持', () {
      final v = evaluateProgression(
        workingSets: [_ws(80, 8), _ws(80, 8), _ws(80, 8, rir: 0)],
        currentWeight: 80,
        rule: rule,
      );
      expect(v.action, ProgressionAction.hold);
    });

    test('有组低于下限 → 减重约 5%', () {
      final v = evaluateProgression(
        workingSets: [_ws(80, 8), _ws(80, 4), _ws(80, 8)],
        currentWeight: 80,
        rule: rule,
      );
      expect(v.action, ProgressionAction.decrease);
      expect(v.deltaKg, lessThan(0));
      expect(v.deltaKg, -4.0); // 80*5% = 4
    });

    test('区间内完成 → 保持', () {
      final v = evaluateProgression(
        workingSets: [_ws(80, 7), _ws(80, 6), _ws(80, 8)],
        currentWeight: 80,
        rule: rule,
      );
      expect(v.action, ProgressionAction.hold);
      expect(v.deltaKg, 0);
    });

    test('无正式组 → 保持且不崩溃', () {
      final v = evaluateProgression(
        workingSets: [_ws(40, 5, rir: 3).copyWarm()],
        currentWeight: 80,
        rule: rule,
      );
      expect(v.action, ProgressionAction.hold);
    });

    test('recommendWeight：无历史返回 null，有历史按判定推下一重量', () {
      expect(recommendWeight(historyWorkingSets: [], rule: rule), isNull);
      final rec = recommendWeight(
        historyWorkingSets: [
          _ws(80, 8, at: 1),
          _ws(80, 8, at: 2),
          _ws(80, 8, at: 3)
        ],
        rule: rule,
      );
      expect(rec, 82.5);
    });

    test('回归：同一次训练的多组都参与判定（不是只看最后一组）', () {
      // 同一次训练内：8、4、8 → 有组破下限 → 应减重
      // 若错误地只看末组（8次）会误判为加重
      final hourMs = 3600 * 1000;
      final rec = recommendWeight(
        historyWorkingSets: [
          _ws(80, 8, at: 1000),
          _ws(80, 4, at: 2 * hourMs),
          _ws(80, 8, at: 4 * hourMs),
        ],
        rule: rule,
      );
      expect(rec, 76.0); // 80 - 5% = 76
    });

    test('回归：超过 4 小时窗口视为两次训练，只看最近一次', () {
      final hourMs = 3600 * 1000;
      final rec = recommendWeight(
        historyWorkingSets: [
          _ws(80, 4, at: 1000), // 上一次的失手组，不应影响本次判定
          _ws(80, 8, at: 10 * hourMs),
          _ws(80, 8, at: 10 * hourMs + 60),
          _ws(80, 8, at: 10 * hourMs + 120),
        ],
        rule: rule,
      );
      expect(rec, 82.5); // 最近一次三组全 8 → 加重
    });
  });

  group('1RM 与 PR', () {
    test('1RM 分公式：1 次取实际值（实测即真值）', () {
      expect(estimate1RM(100, 1), 100);
      expect(estimate1RM(0, 5), 0); // 非法输入仍为 0
    });

    test('1RM 分公式：2-5 次用 Epley', () {
      // 100×5 → 100 × (1 + 5/30) = 116.667
      expect(estimate1RM(100, 2), closeTo(106.6667, 0.001));
      expect(estimate1RM(100, 5), closeTo(116.6667, 0.001));
      expect(estimate1RM(80, 3), closeTo(88.0, 0.001));
    });

    test('1RM 分公式：6-12 次取 Epley 与 Brzycki 平均的保守口径', () {
      // 100×6：Epley 120，Brzycki 100×36/31≈116.129 → 平均 ≈118.0645
      expect(estimate1RM(100, 6), closeTo(118.0645, 0.001));
      // 100×10：两公式恰好相等（Epley 133.33、Brzycki 360/27=133.33）→ 133.33
      expect(estimate1RM(100, 10), closeTo(133.3333, 0.001));
      // 100×12：Epley 140，Brzycki 100×36/25=144 → 平均 142
      expect(estimate1RM(100, 12), closeTo(142.0, 0.001));
    });

    test('1RM 分公式：13 次起不再混入发散的 Brzycki', () {
      // 旧口径 100×30 ≈ 357kg（3.57 倍）、100×36 ≈ 1910kg（19 倍），
      // 且 37 次断崖掉回 223；新口径只用 Epley：20/30/36 次 = 166.7/200/220
      expect(estimate1RM(100, 20), closeTo(166.6667, 0.001));
      expect(estimate1RM(100, 30), closeTo(200.0, 0.001));
      expect(estimate1RM(100, 36), closeTo(220.0, 0.001));
      // 单调性：13→40 次估值不下降（旧口径在 36→37 处断崖）
      var prev = 0.0;
      for (var r = 13; r <= 40; r++) {
        final v = estimate1RM(100, r);
        expect(v, greaterThan(prev), reason: '$r 次估值不该低于更低次数');
        prev = v;
      }
    });

    test('1RM 分公式：37 次以上沿用 Epley（高次数段只剩它）', () {
      // Epley 100×(1+37/30) = 223.33
      expect(estimate1RM(100, 37), closeTo(223.3333, 0.001));
    });

    test('PR 检测：超过历史最佳重量才算', () {
      final history = [_ws(80, 8), _ws(82.5, 5)];
      expect(isPrWeight(82.5, history), isFalse); // 平记录不算
      expect(isPrWeight(85, history), isTrue);
      expect(isPrWeight(80, []), isFalse); // 无历史（首次）不算
    });
  });

  group('容量与肌群', () {
    test('sessionStats：热身组不计容量', () {
      final stats = sessionStatsFrom({
        1: [
          _ws(20, 8).asWarm(),
          _ws(80, 8),
          _ws(80, 6),
        ],
      }, [
        const SessionExercise(
            sessionId: 1,
            id: 1,
            name: '卧推',
            orderIdx: 0,
            kind: 'compound',
            rule: ProgressionRule(repsMin: 5, repsMax: 8)),
      ]);
      expect(stats.volume, 80 * 8 + 80 * 6);
      expect(stats.workingSets, 2);
      expect(stats.reps, 14);
    });

    test('muscleLoadShare 按主肌群聚合且归一化', () {
      const meta = {
        '卧推': ExerciseMeta('卧推', MuscleGroups(main: '胸'), true),
        '划船': ExerciseMeta('划船', MuscleGroups(main: '背'), false),
      };
      final share = muscleLoadShare([
        MapEntry('卧推', [_ws(80, 10)]), // 800
        MapEntry('划船', [_ws(50, 10)]), // 500
      ], meta);
      expect(share['胸'], closeTo(800 / 1300, 0.001));
      expect(share['背'], closeTo(500 / 1300, 0.001));
      final sum = share.values.fold(0.0, (a, b) => a + b);
      expect(sum, closeTo(1.0, 0.001));
    });

    test('未知动作归入「其他」不崩溃', () {
      final share = muscleLoadShare([
        MapEntry('神秘动作', [_ws(30, 10)]),
      ], const {});
      expect(share['其他'], closeTo(1.0, 0.001));
    });
  });

  group('日期工具', () {
    test('mondayOf 返回周一零点', () {
      final d = DateTime(2026, 9, 23); // 周三
      final m = mondayOf(d);
      expect(m.weekday, DateTime.monday);
      expect(m, DateTime(2026, 9, 21));
    });

    test('fmtDate/parseDate 往返一致', () {
      final d = DateTime(2026, 9, 5);
      expect(fmtDate(d), '2026-09-05');
      expect(parseDate(fmtDate(d)), d);
    });
  });

  group('休息分档（调研条目 9）', () {
    test('热身组不触发计时（restSecondsAfterSet 返回 0）', () {
      expect(
        restSecondsAfterSet(
            kind: SetKind.warmup, reps: 10, repsMax: 8, baseSec: 180),
        0,
      );
      expect(
        restTierForSet(kind: SetKind.warmup, reps: 5, repsMax: 8),
        RestTier.none,
      );
    });

    test('达标正式组（次数达到上限）给标准休息', () {
      expect(
        restSecondsAfterSet(
            kind: SetKind.working, reps: 8, repsMax: 8, baseSec: 180),
        180,
      );
      expect(
        restTierForSet(kind: SetKind.working, reps: 8, repsMax: 8),
        RestTier.standard,
      );
    });

    test('未达标正式组给 ×1.5 更长休息（30 秒网格向上取整）', () {
      // 180 → 270；120 → 180；60 → 90
      expect(
        restSecondsAfterSet(
            kind: SetKind.working, reps: 6, repsMax: 8, baseSec: 180),
        270,
      );
      expect(
        restSecondsAfterSet(
            kind: SetKind.working, reps: 5, repsMax: 8, baseSec: 120),
        180,
      );
      expect(
        restSecondsAfterSet(
            kind: SetKind.working, reps: 7, repsMax: 8, baseSec: 60),
        90,
      );
    });

    test('力竭组按未达标档处理（更需要恢复）', () {
      expect(
        restTierForSet(kind: SetKind.failure, reps: 3, repsMax: 8),
        RestTier.extended,
      );
      expect(
        restSecondsAfterSet(
            kind: SetKind.failure, reps: 3, repsMax: 8, baseSec: 120),
        180,
      );
    });

    test('逐动作覆盖优先于全局基础值（Flexify 规则），覆盖值同样参与分档', () {
      // 覆盖 240：达标 → 240；未达标 → 360
      expect(
        restSecondsAfterSet(
            kind: SetKind.working,
            reps: 8,
            repsMax: 8,
            baseSec: 180,
            overriddenSec: 240),
        240,
      );
      expect(
        restSecondsAfterSet(
            kind: SetKind.working,
            reps: 5,
            repsMax: 8,
            baseSec: 180,
            overriddenSec: 240),
        360,
      );
      // 覆盖 0 = 未配置，回落基础值
      expect(
        restSecondsAfterSet(
            kind: SetKind.working,
            reps: 8,
            repsMax: 8,
            baseSec: 180,
            overriddenSec: 0),
        180,
      );
    });

    test('延长档不超过 600 秒上限', () {
      expect(
        restSecondsAfterSet(
            kind: SetKind.failure, reps: 1, repsMax: 8, baseSec: 500),
        600,
      );
    });
  });

  group('自重容量折算（点名条目二）', () {
    SetEntry bwSet({double w = 0, int reps = 10, String kind = SetKind.working}) =>
        SetEntry(
          sessionExerciseId: 1,
          weightKg: w,
          reps: reps,
          rir: 2,
          kind: kind,
          doneAt: 1000,
        );

    test('引体向上按 ACE 口径 0.70×体重 计入容量', () {
      // 0.70 × 70kg × 10 次 = 490
      expect(
        setVolumeWithBodyweight(bwSet(reps: 10),
            exerciseName: '引体向上', bodyWeightKg: 70),
        closeTo(490, 0.01),
      );
    });

    test('俯卧撑按 ACE 口径 0.64×体重 计入容量', () {
      // 0.64 × 70 × 10 = 448
      expect(
        setVolumeWithBodyweight(bwSet(reps: 10),
            exerciseName: '俯卧撑', bodyWeightKg: 70),
        closeTo(448, 0.01),
      );
    });

    test('负重自重动作：总负荷 = 系数×体重 + 外载', () {
      // 负重引体挂 10kg：(0.70×70 + 10) × 8 = 472
      expect(
        setVolumeWithBodyweight(bwSet(w: 10, reps: 8),
            exerciseName: '负重引体向上', bodyWeightKg: 70),
        closeTo(472, 0.01),
      );
    });

    test('无系数动作维持旧口径：0 重量记 0、有重量按重量×次数', () {
      expect(
        setVolumeWithBodyweight(bwSet(reps: 10),
            exerciseName: '杠铃卧推', bodyWeightKg: 70),
        0,
      );
      expect(
        setVolumeWithBodyweight(bwSet(w: 80, reps: 8),
            exerciseName: '杠铃卧推', bodyWeightKg: 70),
        640,
      );
    });

    test('热身组与辅助配重（负重量）仍不计容量', () {
      expect(
        setVolumeWithBodyweight(bwSet(reps: 10, kind: SetKind.warmup),
            exerciseName: '俯卧撑', bodyWeightKg: 70),
        0,
      );
      expect(
        setVolumeWithBodyweight(bwSet(w: -20, reps: 10),
            exerciseName: '引体向上', bodyWeightKg: 70),
        0,
      );
    });

    test('体重为 0（未设置）时不折算，自重记 0', () {
      expect(
        setVolumeWithBodyweight(bwSet(reps: 10),
            exerciseName: '引体向上', bodyWeightKg: 0),
        0,
      );
    });

    test('变体名子串匹配：用户沉淀的「引体向上（宽握）」命中引体系数', () {
      expect(
        setVolumeWithBodyweight(bwSet(reps: 10),
            exerciseName: '引体向上（宽握）', bodyWeightKg: 70),
        closeTo(490, 0.01),
      );
    });

    test('评审回归：最长键优先——变体名不被短键「俯卧撑」抢先', () {
      // 「上斜俯卧撑（宽距）」应命中 0.55（上斜俯卧撑）而非 0.64（俯卧撑）
      expect(bodyweightLoadRatio('上斜俯卧撑（宽距）'), 0.55);
      // 「下斜俯卧撑」（无后缀沉淀名）应命中 0.70 而非 0.64
      expect(bodyweightLoadRatio('下斜俯卧撑'), 0.70);
      expect(
        setVolumeWithBodyweight(bwSet(reps: 10),
            exerciseName: '下斜俯卧撑', bodyWeightKg: 70),
        closeTo(490, 0.01),
      );
    });

    test('sessionStats 传入体重后自重动作进容量，不传则维持旧口径', () {
      const se = SessionExercise(
        sessionId: 1,
        id: 1,
        name: '引体向上',
        orderIdx: 0,
        kind: 'compound',
        rule: ProgressionRule(repsMin: 5, repsMax: 10),
      );
      final sets = {1: [bwSet(reps: 10)]};
      final withBw = sessionStatsFrom(sets, [se], bodyWeightKg: 70);
      final withoutBw = sessionStatsFrom(sets, [se]);
      expect(withBw.volume, closeTo(490, 0.01));
      expect(withoutBw.volume, 0);
    });

    test('muscleLoadShare 传入体重后自重容量计入肌群占比', () {
      const meta = {
        '引体向上': ExerciseMeta('引体向上', MuscleGroups(main: '背'), true),
        '划船': ExerciseMeta('划船', MuscleGroups(main: '背'), false),
      };
      final share = muscleLoadShare([
        MapEntry('引体向上', [bwSet(reps: 10)]), // 0.7×70×10 = 490
        MapEntry('划船', [bwSet(w: 51, reps: 10)]), // 510
      ], meta, bodyWeightKg: 70);
      expect(share['背'], closeTo(1.0, 0.001));
    });

    test('系数表内的锚点值与 ACE 口径一致（回归护栏）', () {
      expect(kBodyweightLoadRatio['俯卧撑'], 0.64);
      expect(kBodyweightLoadRatio['引体向上'], 0.70);
    });
  });

  group('本地计划生成（调研条目 13）', () {
    test('提取训练天数：每周四练 → 4 个训练日', () {
      final days = localPlanFromDescription('每周四练，练背、胸、腿，增肌');
      expect(days.length, 4);
      expect(days.map((d) => d.weekday).toSet(), {1, 3, 5, 6});
    });

    test('提取肌群偏好：练背、胸、腿 → 动作覆盖三个肌群', () {
      final days = localPlanFromDescription('每周三练，练背、胸、腿');
      final muscles = days
          .expand((d) => d.exercises.map((e) => e.mainMuscle))
          .toSet();
      expect(muscles.contains('背'), isTrue);
      expect(muscles.contains('胸'), isTrue);
      expect(muscles.contains('腿'), isTrue);
    });

    test('提取器械约束：家里只有哑铃 → 不出现健身房专属动作', () {
      final days = localPlanFromDescription('每周三练，家里只有哑铃和弹力带');
      for (final d in days) {
        for (final e in d.exercises) {
          final meta = kExerciseLibrary.firstWhere((m) => m.name == e.name);
          expect(meta.equipment, isNot('gym'),
              reason: '居家约束下不应出现健身房专属动作：${e.name}');
        }
      }
    });

    test('无描述按默认：每周 3 练全身均衡', () {
      final days = localPlanFromDescription('');
      expect(days.length, 3);
      for (final d in days) {
        expect(d.exercises, isNotEmpty);
        expect(d.exercises.length, lessThanOrEqualTo(3));
      }
    });

    test('动作参数符合契约：复合 6-10 次/休 180，辅助 10-15 次/休 90', () {
      final days = localPlanFromDescription('每周三练');
      for (final d in days) {
        for (final e in d.exercises) {
          if (e.kind == 'compound') {
            expect(e.repsMin, 6);
            expect(e.repsMax, 10);
            expect(e.restSec, 180);
          } else {
            expect(e.repsMin, 10);
            expect(e.repsMax, 15);
            expect(e.restSec, 90);
          }
        }
      }
    });

    test('确定性：同输入同输出', () {
      final a = localPlanFromDescription('每周 4 练，健身房，增肌');
      final b = localPlanFromDescription('每周 4 练，健身房，增肌');
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].weekday, b[i].weekday);
        expect(
          a[i].exercises.map((e) => e.name).toList(),
          b[i].exercises.map((e) => e.name).toList(),
        );
      }
    });

    test('动作名都来自内置词表（可被 AI 落库流程直接消费）', () {
      final names = kExerciseLibrary.map((m) => m.name).toSet();
      for (final d in localPlanFromDescription('每周 6 练，胸肩背腿手臂核心都练')) {
        for (final e in d.exercises) {
          expect(names.contains(e.name), isTrue, reason: '${e.name} 不在词表');
        }
      }
    });
  });
}

extension _SetExt on SetEntry {
  SetEntry copyWarm() => SetEntry(
        sessionExerciseId: sessionExerciseId,
        weightKg: weightKg,
        reps: reps,
        rir: rir,
        kind: SetKind.warmup,
        doneAt: doneAt,
      );

  SetEntry asWarm() => copyWarm();
}
