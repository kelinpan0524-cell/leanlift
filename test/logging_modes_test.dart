// 动作记录形态（v14）引擎测试：单侧目标偶数化、计时文案单位换算、
// 自重负荷的链形态（无重量轴、recommendWeight 恒 0、触顶加组建议）。
// 数字判定逻辑与既有规则链完全一致（progression_chain_test.dart 锁定），
// 这里只锁形态差异。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/engine/engine.dart';

SetEntry _set(double w, int reps, {int rir = 2, int at = 1000}) => SetEntry(
      sessionExerciseId: 1,
      weightKg: w,
      reps: reps,
      rir: rir,
      kind: SetKind.working,
      doneAt: at,
    );

/// 同一场 n 组同重量同「次数/秒数」。
List<SetEntry> _session(double w, int reps, {int n = 3, int rir = 2}) => [
      for (var i = 0; i < n; i++) _set(w, reps, rir: rir, at: 1000 + i),
    ];

void main() {
  group('normalizeTarget：单侧动作目标偶数化', () {
    test('边界：1→2、4→4、5→6、0→2', () {
      expect(normalizeTarget(1, LoggingMode.repsPerSide), 2);
      expect(normalizeTarget(4, LoggingMode.repsPerSide), 4);
      expect(normalizeTarget(5, LoggingMode.repsPerSide), 6);
      expect(normalizeTarget(0, LoggingMode.repsPerSide), 2);
    });

    test('非单侧形态原样返回（不取偶）', () {
      expect(normalizeTarget(5, LoggingMode.reps), 5);
      expect(normalizeTarget(5, LoggingMode.time), 5);
      expect(normalizeTarget(1, LoggingMode.reps), 1);
      expect(normalizeTarget(0, LoggingMode.reps), 0);
    });
  });

  group('计时形态（logging=time）文案换单位', () {
    // 平板支撑：30-60 秒
    final rule = const ProgressionRule(repsMin: 30, repsMax: 60);

    test('evaluateChain 达标爬升：reason 含「秒」不含「X 次」', () {
      final last = _session(0, 45);
      final state = chainStateFromHistory(last, rule);
      final v = evaluateChain(
        rule: rule,
        state: state,
        workingSets: last,
        logging: LoggingMode.time,
      );
      expect(v.action, 'advance');
      expect(v.next.targetReps, 46); // 数字逻辑与次数形态完全一致
      expect(v.reason, contains('45 秒目标'));
      expect(v.reason, contains('下次目标 46 秒'));
      expect(v.reason, isNot(contains('45 次')));
      expect(v.reason, isNot(contains('46 次')));
    });

    test('evaluateChain 触顶停住：文案「保持 N 秒」', () {
      const state = ChainState(weightKg: 0, targetReps: 60);
      final v = evaluateChain(
        rule: rule,
        state: state,
        workingSets: _session(0, 60),
        logging: LoggingMode.time,
        loadType: LoadMode.bodyweight,
      );
      expect(v.action, 'hold');
      expect(v.reason, contains('保持 60 秒'));
      expect(v.reason, isNot(contains('60 次')));
    });

    test('evaluateProgression 同步换秒：加重文案含「秒」', () {
      final v = evaluateProgression(
        workingSets: _session(0, 60),
        currentWeight: 0,
        rule: rule,
        logging: LoggingMode.time,
      );
      expect(v.action, ProgressionAction.increase);
      expect(v.reason, contains('60 秒'));
      expect(v.reason, isNot(contains('60 次')));
    });

    test('缺省 logging（reps）时文案与历史行为一致（含「次」）', () {
      final last = _session(0, 45);
      final v = evaluateChain(
        rule: rule,
        state: chainStateFromHistory(last, rule),
        workingSets: last,
      );
      expect(v.reason, contains('45 次目标'));
    });

    test('repsUnitLabel：time→秒 / reps→次', () {
      expect(repsUnitLabel(LoggingMode.time), '秒');
      expect(repsUnitLabel(LoggingMode.reps), '次');
      expect(repsUnitLabel(LoggingMode.repsPerSide), '次');
    });
  });

  group('chainTargetWhy：目标可解释化（为什么是这个数字）', () {
    final rule = const ProgressionRule(
        repsMin: 5, repsMax: 8, incrementKg: 2.5, workingSets: 3);

    test('次数轴还有空间：全部组做到 N 次 → 下次目标 N+1 次', () {
      final why = chainTargetWhy(
          rule: rule, state: const ChainState(weightKg: 60, targetReps: 7));
      expect(why, contains('全部组做到 7 次'));
      expect(why, contains('下次目标 8 次'));
      expect(why, isNot(contains('加重')));
    });

    test('weighted 次数轴触顶：下次加重、目标回到下限', () {
      final why = chainTargetWhy(
          rule: rule, state: const ChainState(weightKg: 60, targetReps: 8));
      expect(why, contains('顶住 8 次'));
      expect(why, contains('加重至 62.5kg'));
      expect(why, contains('目标回到 5 次'));
    });

    test('bodyweight 触顶：下次加练一组（X 组）', () {
      final why = chainTargetWhy(
        rule: rule,
        state: const ChainState(weightKg: 0, targetReps: 8),
        loadType: LoadMode.bodyweight,
      );
      expect(why, contains('顶住 8 次'));
      expect(why, contains('加练一组（4 组）'), reason: 'workingSets 3 + 1');
      expect(why, isNot(contains('加重')));
    });

    test('timed 口径：文案用「秒」表述', () {
      final trule = const ProgressionRule(repsMin: 30, repsMax: 60);
      final why = chainTargetWhy(
        rule: trule,
        state: const ChainState(weightKg: 0, targetReps: 45),
        logging: LoggingMode.time,
      );
      expect(why, contains('全部组做到 45 秒'));
      expect(why, contains('下次目标 46 秒'));
      expect(why, isNot(contains('45 次')));
    });

    test('timed + weighted 触顶：加重文案也用秒', () {
      final trule = const ProgressionRule(repsMin: 30, repsMax: 60);
      final why = chainTargetWhy(
        rule: trule,
        state: const ChainState(weightKg: 10, targetReps: 60),
        logging: LoggingMode.time,
      );
      expect(why, contains('顶住 60 秒'));
      expect(why, contains('目标回到 30 秒'));
    });

    test('单侧口径：每边均分表述', () {
      // 目标 6（每边 3）还有空间 → 下次链目标 7，表述按偶数口径抬到 8（每边 4）
      final why = chainTargetWhy(
        rule: rule,
        state: const ChainState(weightKg: 40, targetReps: 6),
        logging: LoggingMode.repsPerSide,
      );
      expect(why, contains('全部组做到 6 次（每边 3）'));
      expect(why, contains('下次目标 8 次（每边 4）'));
    });

    test('全链到头（hold 堵点）：给保持文案', () {
      // 重量轴天花板 65 且触顶停住：65kg×8 次已无处可推
      final cappedRule = const ProgressionRule(
        repsMin: 5,
        repsMax: 8,
        workingSets: 3,
        chain: [
          ChainRule(axis: 'reps', step: 1, ceiling: 8, advanceOnCap: true),
          ChainRule(
              axis: 'load',
              step: 2.5,
              ceiling: 65,
              advanceOnCap: false,
              resetRepsTo: 5),
        ],
      );
      final why = chainTargetWhy(
          rule: cappedRule,
          state: const ChainState(weightKg: 65, targetReps: 8));
      expect(why, contains('已到规则链尽头'));
      expect(why, contains('保持当前档'));
    });

    test('bodyweight 次数轴还有空间：正常爬次数（不提加组/加重）', () {
      final why = chainTargetWhy(
        rule: rule,
        state: const ChainState(weightKg: 0, targetReps: 6),
        loadType: LoadMode.bodyweight,
      );
      expect(why, contains('全部组做到 6 次'));
      expect(why, contains('下次目标 7 次'));
    });
  });

  group('自重负荷（loadType=bodyweight）', () {
    final rule = const ProgressionRule(
        repsMin: 5, repsMax: 8, incrementKg: 2.5, workingSets: 3);

    test('recommendWeight 恒 0（达标/减重/无历史都不走重量轴）', () {
      expect(
        recommendWeight(
            historyWorkingSets: _session(0, 8), rule: rule,
            loadType: LoadMode.bodyweight),
        0.0,
      );
      expect(
        recommendWeight(
            historyWorkingSets: _session(0, 3), rule: rule,
            loadType: LoadMode.bodyweight),
        0.0,
      );
      expect(
        recommendWeight(historyWorkingSets: const [], rule: rule,
            loadType: LoadMode.bodyweight),
        0.0,
      );
    });

    test('defaultBodyweightFor：只有次数轴（无 load 规则），天花板=reps_max、触顶停住', () {
      final chain = ProgressionChain.defaultBodyweightFor(rule);
      expect(chain.rules.length, 1);
      expect(chain.rules.single.axis, 'reps');
      expect(chain.rules.single.ceiling, 8);
      expect(chain.rules.single.advanceOnCap, isFalse);

      // 顶格 8 再达标：advance 原样返回（不进位负重 2.5kg）
      const state = ChainState(weightKg: 0, targetReps: 8);
      expect(chain.advance(state, rule), state);

      // of(rule, loadType: bodyweight) 走同一条链（显式 chain 也不采用）
      const explicit = ProgressionRule(
        repsMin: 5,
        repsMax: 8,
        chain: [ChainRule(axis: 'load', step: 2.5)],
      );
      expect(
        ProgressionChain.of(explicit, loadType: LoadMode.bodyweight).rules
            .single.axis,
        'reps',
      );
      // 缺省 loadType 的既有行为不变：显式 chain 优先
      expect(ProgressionChain.of(explicit).rules.single.axis, 'load');
    });

    test('evaluateChain bodyweight：次数触顶 hold 而非加重', () {
      final last = _session(0, 8);
      final v = evaluateChain(
        rule: rule,
        state: chainStateFromHistory(last, rule),
        workingSets: last,
        loadType: LoadMode.bodyweight,
      );
      expect(v.action, 'hold');
      expect(v.next.weightKg, 0); // 不进位到 2.5kg
      expect(v.next.targetReps, 8);
      expect(v.reason, contains('自重档位'));
    });

    test('bodyweightExtraSetTarget：触顶返回 workingSets+1，封顶 +2', () {
      // 链已触顶（目标=天花板 8）→ 建议加 1 组
      const topped = ChainState(weightKg: 0, targetReps: 8);
      expect(
        bodyweightExtraSetTarget(
            state: topped, rule: rule, loadType: LoadMode.bodyweight),
        4, // workingSets 3 + 1
      );
      // 封顶：建议数永远不会超过 workingSets + 2
      final capped = bodyweightExtraSetTarget(
          state: topped, rule: rule, loadType: LoadMode.bodyweight)!;
      expect(capped, lessThanOrEqualTo(rule.workingSets + 2));

      // 链还有空间（目标 6 < 8）→ null，正常爬次数
      const mid = ChainState(weightKg: 0, targetReps: 6);
      expect(
        bodyweightExtraSetTarget(
            state: mid, rule: rule, loadType: LoadMode.bodyweight),
        isNull,
      );

      // weighted 负荷永不建议加组（含触顶状态）
      expect(
        bodyweightExtraSetTarget(
            state: topped, rule: rule, loadType: LoadMode.weighted),
        isNull,
      );
    });
  });
}
