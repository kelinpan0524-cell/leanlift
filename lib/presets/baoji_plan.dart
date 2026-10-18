export 'exercise_library.dart'
    show kBaojiExerciseMeta, kExerciseLibrary, PresetExercise;

import '../models/models.dart';
import 'exercise_library.dart' show defaultLoadTypeFor;

/// 内置薄肌计划（PRD：四大项核心 + 每周三练 + 肩背偏重、上胸重点）。
/// 首次启动一键写入；每个动作带建议起始重量，用户可在设置里改。

const kBaojiPlanName = '薄肌计划（内置）';

class PresetExercise {
  final String name;
  final int sets;
  final int repsMin;
  final int repsMax;
  final int restSec;
  final String kind; // compound | assistance
  final double startWeightKg;

  const PresetExercise(this.name, this.sets, this.repsMin, this.repsMax,
      this.restSec, this.kind, this.startWeightKg);

  PlanExercise toPlanExercise(int dayId, int orderIdx) => PlanExercise(
        dayId: dayId,
        name: name,
        orderIdx: orderIdx,
        sets: sets,
        repsMin: repsMin,
        repsMax: repsMax,
        restSec: restSec,
        kind: kind,
        // 内置计划里的引体向上等自重动作按自重口径落库（P2-E 复核修复）。
        loadType: defaultLoadTypeFor(name),
        rule: ProgressionRule(
          repsMin: repsMin,
          repsMax: repsMax,
          incrementKg: kind == 'compound' ? 2.5 : 1.25,
          workingSets: sets,
          desc: kind == 'compound'
              ? '全部正式组达 $repsMax 次且末组余力≥1 → 加 2.5kg；有组低于 $repsMin 次 → 减 5%'
              : '全部正式组达 $repsMax 次且末组余力≥1 → 加 1.25kg',
        ),
      );
}

const kBaojiDayTitles = {
  1: '推力日 A（胸·肩）',
  3: '拉力日（背·后束）',
  5: '腿部日 + 轻推·手臂',
};

const kBaojiExercisesByWeekday = <int, List<PresetExercise>>{
  // 周一 推力日 A（胸肩为主，上胸重点）
  1: [
    PresetExercise('杠铃卧推', 3, 5, 8, 180, 'compound', 45),
    PresetExercise('上斜哑铃卧推', 3, 8, 12, 120, 'assistance', 16),
    PresetExercise('站姿推举', 3, 5, 8, 180, 'compound', 30),
    PresetExercise('哑铃侧平举', 4, 12, 15, 90, 'assistance', 6),
  ],
  // 周三 拉力日（背为绝对主角）
  3: [
    PresetExercise('杠铃硬拉', 3, 5, 8, 180, 'compound', 70),
    PresetExercise('引体向上', 3, 6, 10, 120, 'compound', 0),
    PresetExercise('坐姿划船', 3, 8, 12, 120, 'assistance', 40),
    PresetExercise('俯身飞鸟（后束）', 4, 12, 15, 90, 'assistance', 5),
  ],
  // 周五 腿 + 轻推 + 手臂
  5: [
    PresetExercise('杠铃深蹲', 3, 5, 8, 180, 'compound', 60),
    PresetExercise('罗马尼亚硬拉', 3, 8, 10, 150, 'compound', 50),
    PresetExercise('上斜杠铃卧推（轻）', 2, 6, 8, 120, 'compound', 32.5),
    PresetExercise('杠铃弯举', 3, 10, 12, 90, 'assistance', 20),
    PresetExercise('绳索下压', 3, 10, 12, 90, 'assistance', 20),
  ],
};

