// 动作记录形态（v14）引擎测试：单侧目标偶数化、计时文案单位换算、
// 自重负荷的链形态（无重量轴、recommendWeight 恒 0、触顶加组建议）。
// 数字判定逻辑与既有规则链完全一致（progression_chain_test.dart 锁定），
// 这里只锁形态差异。
import 'package:flutter_test/flutter_test.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/presets/exercise_library.dart';

SetEntry _set(double w, int reps,
        {int rir = 2, int at = 1000, bool extra = false}) =>
    SetEntry(
      sessionExerciseId: 1,
      weightKg: w,
      reps: reps,
      rir: rir,
      kind: SetKind.working,
      doneAt: at,
      isExtra: extra,
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

    test('加组建议按会话快照组数：快照 4 / 规则 3 → 建议 5 组', () {
      const topped = ChainState(weightKg: 0, targetReps: 8);
      expect(
        bodyweightExtraSetTarget(
          state: topped,
          rule: rule,
          loadType: LoadMode.bodyweight,
          plannedSets: 4,
        ),
        5,
        reason: '计划已是 4 组时，加组应建议第 5 组而不是第 4 组',
      );
      final why = chainTargetWhy(
        rule: rule,
        state: topped,
        loadType: LoadMode.bodyweight,
        plannedSets: 4,
      );
      expect(why, contains('5 组'));
      expect(why, isNot(contains('4 组')));
    });
  });

  group('自重变式阶梯（P2-E）', () {
    test('任务点名的四类都查得到下一档（含双杠胸版）', () {
      expect(nextBodyweightVariation('俯卧撑'), '下斜俯卧撑（脚垫高）');
      expect(nextBodyweightVariation('引体向上'), '负重引体向上');
      expect(nextBodyweightVariation('双杠臂屈伸'), '双杠臂屈伸（挺胸）');
      expect(nextBodyweightVariation('双杠臂屈伸（挺胸）'), '负重双杠臂屈伸');
      expect(nextBodyweightVariation('徒手深蹲'), '箭步蹲');
      expect(nextBodyweightVariation('臀桥'), '单腿臀桥');
    });

    test('阶梯里的每一级都是动作库规范名（防拼写漂移）', () {
      final names = kExerciseLibrary.map((m) => m.name).toSet();
      for (final ladder in kBodyweightLadders) {
        for (final name in ladder) {
          expect(names, contains(name), reason: '阶梯动作「$name」不在动作库');
        }
      }
    });

    test('别名/英文名同一口径查到下一档', () {
      expect(nextBodyweightVariation('push up'), '下斜俯卧撑（脚垫高）');
      expect(nextBodyweightVariation('pull-up'), '负重引体向上');
      expect(nextBodyweightVariation('dips'), '双杠臂屈伸（挺胸）');
      expect(nextBodyweightVariation('glute bridge'), '单腿臀桥');
    });

    test('改名但保留旧 exerciseKey 的动作也能查到下一档', () {
      expect(
        nextBodyweightVariation('地板俯卧撑', exerciseKey: '俯卧撑'),
        '下斜俯卧撑（脚垫高）',
      );
      expect(
        nextBodyweightVariation('地板俯卧撑',
            exerciseKey: 'my_custom_push_day'),
        isNull,
        reason: '键和名字都对不上时不能瞎猜',
      );
    });

    test('阶梯末端、不在阶梯上、空名 → null', () {
      expect(nextBodyweightVariation('下斜俯卧撑（脚垫高）'), isNull);
      expect(nextBodyweightVariation('负重引体向上'), isNull);
      expect(nextBodyweightVariation('负重双杠臂屈伸'), isNull);
      expect(nextBodyweightVariation('平板支撑'), isNull);
      expect(nextBodyweightVariation(''), isNull);
    });

    test('有效负荷推断：默认 weighted 的 0kg 自重动作按 bodyweight 处理', () {
      // 内置计划/模板/老库：loadType 是默认 weighted，但动作在阶梯上且
      // 本场正式组全是 0kg → 推断为自重（P2-E 复核修复）。
      expect(
        effectiveLoadTypeFor(
          exerciseName: '引体向上',
          loadType: LoadMode.weighted,
          workingSets: _session(0, 8),
        ),
        LoadMode.bodyweight,
      );
      // 真加了重量 → 维持 weighted（不催换变式）
      expect(
        effectiveLoadTypeFor(
          exerciseName: '引体向上',
          loadType: LoadMode.weighted,
          workingSets: _session(10, 8),
        ),
        LoadMode.weighted,
      );
      // 不在阶梯上的 0kg 动作也不推断（比如平板支撑之外的词表外动作）
      expect(
        effectiveLoadTypeFor(
          exerciseName: '神秘自创动作',
          loadType: LoadMode.weighted,
          workingSets: _session(0, 8),
        ),
        LoadMode.weighted,
      );
      // 阶梯末端（没有下一档）同样算自重动作，不能被当成负重
      expect(
        effectiveLoadTypeFor(
          exerciseName: '下斜俯卧撑（脚垫高）',
          loadType: LoadMode.weighted,
          workingSets: _session(0, 12),
        ),
        LoadMode.bodyweight,
      );
      expect(isBodyweightLadderExercise('下斜俯卧撑（脚垫高）'), isTrue);
      expect(isBodyweightLadderExercise('单腿臀桥'), isTrue);
      expect(isBodyweightLadderExercise('神秘自创动作'), isFalse);
      // 负重变体（gear=自重但训练要加重量）即使 0kg 也不推断为自重
      expect(
        effectiveLoadTypeFor(
          exerciseName: '负重引体向上',
          loadType: LoadMode.weighted,
          workingSets: _session(0, 8),
        ),
        LoadMode.weighted,
      );
      // 显式 bodyweight 原样返回
      expect(
        effectiveLoadTypeFor(
          exerciseName: '引体向上',
          loadType: LoadMode.bodyweight,
          workingSets: _session(0, 8),
        ),
        LoadMode.bodyweight,
      );
    });

    test('H3：改名保留旧键的负重变体不误判为自重（统一判定入口）', () {
      // 「引体向上」改名成「引体向上（负重版）」保留旧键：旧键仍命中自重
      // 阶梯，但名字里的「负重」是显式负重变体 → 按 weighted 口径，
      // 0kg 组也不推断为自重。
      expect(
        effectiveLoadTypeFor(
          exerciseName: '引体向上（负重版）',
          exerciseKey: '引体向上',
          loadType: LoadMode.weighted,
          workingSets: _session(0, 8),
        ),
        LoadMode.weighted,
        reason: '后缀注记的负重变体优先于「名字以负重开头」启发式',
      );
      // 改名前的旧行存的 loadType 是 bodyweight 时，名字意图同样优先
      expect(
        effectiveLoadTypeFor(
          exerciseName: '引体向上（负重版）',
          exerciseKey: '引体向上',
          loadType: LoadMode.bodyweight,
          workingSets: _session(0, 8),
        ),
        LoadMode.weighted,
        reason: '显式负重变体名压住存储的 bodyweight 与阶梯推断',
      );
      // 前缀负重变体再叠加改名（负重引体向上（负重版））同理
      expect(
        effectiveLoadTypeFor(
          exerciseName: '负重引体向上（负重版）',
          exerciseKey: '负重引体向上',
          loadType: LoadMode.bodyweight,
          workingSets: _session(0, 8),
        ),
        LoadMode.weighted,
      );
      // 名字干净的真改名（保留旧键）仍按自重推断：不能误伤
      expect(
        effectiveLoadTypeFor(
          exerciseName: '地板引体',
          exerciseKey: '引体向上',
          loadType: LoadMode.weighted,
          workingSets: _session(0, 8),
        ),
        LoadMode.bodyweight,
      );
    });

    test('H3：负重版不进自重阶梯建议（就绪判断与变式建议共用同一推断）', () {
      const rule = ProgressionRule(repsMin: 5, repsMax: 8);
      final topped = _session(0, 8); // 0kg 顶格三组：真自重动作此时已 ready
      expect(
        bodyweightProgressionReady(
          exerciseName: '引体向上（负重版）',
          exerciseKey: '引体向上',
          rule: rule,
          loadType: LoadMode.weighted,
          workingSets: topped,
          plannedSets: 3,
        ),
        isFalse,
        reason: '负重变体 0kg 也不算自重触顶，不给「加练一组」',
      );
      expect(
        bodyweightVariationSuggestion(
          exerciseName: '引体向上（负重版）',
          exerciseKey: '引体向上',
          rule: rule,
          loadType: LoadMode.weighted,
          workingSets: topped,
          plannedSets: 3,
        ),
        isNull,
        reason: '不进自重阶梯建议（同一函数推断，与就绪判断结论一致）',
      );
    });

    test('H3：引擎与控制器同一口径——库里纯自重（不在阶梯上）0kg 也推断自重', () {
      // 平板支撑：动作库标纯自重但不在变式阶梯上；统一后引擎与控制器
      // （此前只查动作库）对这类动作结论一致。
      expect(
        effectiveLoadTypeFor(
          exerciseName: '平板支撑',
          loadType: LoadMode.weighted,
          workingSets: _session(0, 45),
        ),
        LoadMode.bodyweight,
      );
      // 阶梯与动作库两个信号合并，而不是各判各的
      expect(isBodyweightLadderExercise('平板支撑'), isFalse);
    });

    test('建议只在计划组全部练满、达标且次数顶到 reps_max 时出现', () {
      const rule = ProgressionRule(repsMin: 8, repsMax: 12);
      String? suggest(
        List<SetEntry> sets, {
        String load = LoadMode.bodyweight,
        String name = '俯卧撑',
        String key = '',
      }) =>
          bodyweightVariationSuggestion(
            exerciseName: name,
            exerciseKey: key,
            rule: rule,
            loadType: load,
            workingSets: sets,
            plannedSets: 3,
          );

      // 3 组全部 12 次 → 下一档
      expect(suggest(_session(0, 12)), '下斜俯卧撑（脚垫高）');
      // 还有空间（10 次）→ 继续爬次数，不换变式
      expect(suggest(_session(0, 10)), isNull);
      // 计划 3 组只做了 1 组（哪怕顶格）→ 不提前建议
      expect(suggest(_session(0, 12, n: 1)), isNull);
      // 末组 RIR 0（已记录）→ 没达到余力门槛，不催升级
      expect(
        suggest([
          _set(0, 12, at: 1000),
          _set(0, 12, at: 1001),
          _set(0, 12, at: 1002, rir: 0),
        ]),
        isNull,
      );
      // 默认 weighted + 0kg（内置计划/模板/老库）也要给建议
      expect(suggest(_session(0, 12), load: LoadMode.weighted),
          '下斜俯卧撑（脚垫高）');
      // 默认 weighted + 真加了重量 → 负重渐进，不换变式
      expect(suggest(_session(10, 12), load: LoadMode.weighted), isNull);
      // 阶梯已到顶 → 没有下一档
      expect(suggest(_session(0, 12), name: '下斜俯卧撑（脚垫高）'), isNull);
      // 改名保留旧键 → 仍能查到
      expect(
        suggest(_session(0, 12), name: '地板俯卧撑', key: '俯卧撑'),
        '下斜俯卧撑（脚垫高）',
      );
    });

    test('bodyweightProgressionReady：练满/达标/余力够/触顶四条全满足', () {
      const rule = ProgressionRule(repsMin: 8, repsMax: 12);
      bool ready(List<SetEntry> sets, {int planned = 3}) =>
          bodyweightProgressionReady(
            exerciseName: '俯卧撑',
            rule: rule,
            // 默认 weighted + 0kg：走有效自重推断
            loadType: LoadMode.weighted,
            workingSets: sets,
            plannedSets: planned,
          );

      expect(ready(_session(0, 12)), isTrue);
      expect(ready(_session(0, 10)), isFalse, reason: '没有顶到 reps_max');
      expect(ready(_session(0, 12, n: 1)), isFalse, reason: '计划 3 组只做 1 组');
      expect(
        ready([
          _set(0, 12, at: 1000),
          _set(0, 12, at: 1001),
          _set(0, 12, at: 1002, rir: 0),
        ]),
        isFalse,
        reason: '末组 RIR 0 未达 rirTarget-1',
      );
      expect(ready(_session(10, 12)), isFalse,
          reason: '真加了重量 → 负重渐进，不算自重升级');
      // 阶梯末端动作同样按自重判定 ready（只是没有下一档可建议）
      expect(
        bodyweightProgressionReady(
          exerciseName: '下斜俯卧撑（脚垫高）',
          rule: rule,
          loadType: LoadMode.weighted,
          workingSets: _session(0, 12),
          plannedSets: 3,
        ),
        isTrue,
      );
      // 负重变体保持负重口径（训练页要能记录外加载重）
      expect(
        bodyweightProgressionReady(
          exerciseName: '负重引体向上',
          rule: rule,
          loadType: LoadMode.weighted,
          workingSets: _session(0, 12),
          plannedSets: 3,
        ),
        isFalse,
      );
    });

    test('加练组不参与触顶判定', () {
      const rule = ProgressionRule(repsMin: 8, repsMax: 12);
      // 只有加练组（正常组可能还没练完）→ 不触发
      final onlyExtra = [
        _set(0, 12, extra: true),
        _set(0, 12, at: 1001, extra: true),
      ];
      expect(
        bodyweightVariationSuggestion(
          exerciseName: '俯卧撑',
          rule: rule,
          loadType: LoadMode.bodyweight,
          workingSets: onlyExtra,
          plannedSets: 3,
        ),
        isNull,
      );
    });
  });

  group('isBodyweightUi（H3 收尾：训练页 UI 只叠加规则①）', () {
    test('显式负重变体名压过存储的 bodyweight（改名保留旧键场景）', () {
      expect(
        isBodyweightUi(
            exerciseName: '引体向上（负重版）', loadType: LoadMode.bodyweight),
        isFalse,
        reason: '名字含「负重」→ 按负重 UI，要给重量输入',
      );
      expect(
        isBodyweightUi(exerciseName: '负重双杠', loadType: LoadMode.bodyweight),
        isFalse,
      );
    });

    test('普通自重/负重行为不变', () {
      expect(
        isBodyweightUi(exerciseName: '引体向上', loadType: LoadMode.bodyweight),
        isTrue,
      );
      expect(
        isBodyweightUi(exerciseName: '俯卧撑', loadType: LoadMode.bodyweight),
        isTrue,
      );
      expect(
        isBodyweightUi(exerciseName: '卧推', loadType: LoadMode.weighted),
        isFalse,
      );
    });
  });
}
