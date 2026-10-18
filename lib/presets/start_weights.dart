/// 起始重量查询（P2-A）：内置计划显式值 → 高频覆盖 → 动作库启发式。
/// 会话控制器与计划仓库共用同一入口，避免两套兜底逻辑漂移。
library;

import '../engine/exercise_identity.dart' show exerciseKeyOf;
import '../engine/weight_unit.dart' show lbToKg;
import 'baoji_plan.dart' show kBaojiExercisesByWeekday;
import 'exercise_library.dart'
    show defaultStartWeightOf, kStartWeightOverrides, libraryMetaForLift;

/// 已知起始重量（kg）；动作别名与半/全角标点先归一
/// （「平板卧推」→「杠铃卧推」、「上斜杠铃卧推(轻)」→ 全角库名）。
/// 词表外/未标注返回 null，由调用方决定最终兜底（会话控制器回退 20kg）。
double? knownStartWeightOf(String name) {
  final key = exerciseKeyOf(name);
  for (final list in kBaojiExercisesByWeekday.values) {
    for (final pe in list) {
      if (pe.name == name || (key.isNotEmpty && exerciseKeyOf(pe.name) == key)) {
        return pe.startWeightKg;
      }
    }
  }
  final override =
      (key.isEmpty ? null : kStartWeightOverrides[key]) ??
          kStartWeightOverrides[name];
  if (override != null) return override;
  final meta = libraryMetaForLift(name);
  return meta == null ? null : defaultStartWeightOf(meta);
}

/// 具体器械的空杆重量（kg）：EZ 杠约 10kg（lb 制 25lb）。
/// 返回 null = 按标准奥杆（kg 20 / lb 45）；T 杠、史密斯机等没有可靠
/// 的整机杆重数据，仍按标准奥杆口径，不做猜测。
double? warmupBarKgFor(String name, {required bool useLb}) {
  final key = exerciseKeyOf(name);
  if (key.contains('ez') || key.contains('曲杠')) {
    return useLb ? lbToKg(25) : 10;
  }
  return null;
}
