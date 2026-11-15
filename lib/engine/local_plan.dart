import '../models/models.dart';
import '../presets/exercise_library.dart';

/// 本地计划生成（调研条目 13：AI 不可用时显式回落本地，Fitbod 离线能力思路）。
/// AI 拆解无网/无 Key/失败时，用本地规则从描述里提取训练天数、肌群偏好、
/// 器械约束，生成一份结构化计划；提取不到按「每周 3 练、全身均衡」兜底
/// （与 AI 设计提示词的同一默认）。纯本地、可单元测试，输出与 AI 契约
/// 同构（weekday/title/exercises），由服务层转成 AiDaySpec 落库。

/// 本地生成的一个动作（字段与 AiExerciseSpec 对齐，避免 services 层二次转换）。
class LocalPlanExercise {
  final String name;
  final int sets;
  final int repsMin;
  final int repsMax;
  final int restSec;
  final String kind; // compound | assistance
  final String mainMuscle;

  const LocalPlanExercise({
    required this.name,
    required this.sets,
    required this.repsMin,
    required this.repsMax,
    required this.restSec,
    required this.kind,
    required this.mainMuscle,
  });
}

class LocalPlanDay {
  final int weekday; // 1=周一 … 7=周日
  final String title;
  final List<LocalPlanExercise> exercises;

  const LocalPlanDay(this.weekday, this.title, this.exercises);
}

/// 用户未提肌群时的默认轮转（全身均衡：每次都带一个主肌群）。
const _kDefaultRotation = ['胸', '背', '腿', '肩', '手臂', '核心'];

/// 训练天数 → 周内分布（间隔排布，避免连练同肌群）。
const _kDaySlots = <int, List<int>>{
  1: [3],
  2: [2, 5],
  3: [1, 3, 5],
  4: [1, 3, 5, 6],
  5: [1, 2, 3, 5, 6],
  6: [1, 2, 3, 4, 5, 6],
  7: [1, 2, 3, 4, 5, 6, 7],
};

/// 从自然语言描述生成本地计划。确定性输出（不随机），同输入同结果。
/// [now] 仅供未来扩展（如按周内已有训练跳日），当前不影响输出。
List<LocalPlanDay> localPlanFromDescription(String description) {
  final text = description.trim();
  // 1) 训练天数：阿拉伯数字优先，其次中文数字（「每周X练/一周X次/X天」）。
  var days = 3;
  final ar = RegExp(r'(?:每周|一周|每星期)?\s*([1-7])\s*(?:练|天|次)').firstMatch(text);
  if (ar != null) {
    days = int.parse(ar.group(1)!);
  } else {
    final cn = RegExp(r'(?:每周|一周)\s*([一二三四五六七])\s*(?:练|天|次)')
        .firstMatch(text);
    if (cn != null) days = '一二三四五六七'.indexOf(cn.group(1)!) + 1;
  }
  days = days.clamp(1, 7);

  // 2) 器械约束：居家词（哑铃/弹力带/自重…）→ home；健身房词 → gym；未提 → both。
  final equipment = RegExp(r'哑铃|弹力带|居家|家里|在家|宿舍|自重|徒手').hasMatch(text)
      ? 'home'
      : (RegExp(r'健身房|杠铃|器械|绳索').hasMatch(text) ? 'gym' : 'both');

  // 3) 肌群偏好：描述里提到的肌群按提及顺序轮转；没提走默认全身轮转。
  const regions = ['胸', '背', '腿', '肩', '手臂', '核心'];
  final wanted = [for (final r in regions) if (text.contains(r)) r];

  // 4) 逐日选动作：主肌群轮转，每天从库内按顺序取（复合优先），全局去重，
  //    库内不够时重置已用名单允许复用（如居家单肌群动作少）。
  final slots = _kDaySlots[days] ?? const [1, 3, 5];
  final used = <String>{};
  final out = <LocalPlanDay>[];
  for (var i = 0; i < slots.length; i++) {
    final region = wanted.isEmpty
        ? _kDefaultRotation[i % _kDefaultRotation.length]
        : wanted[i % wanted.length];
    final exs = _pickDayExercises(region, equipment, used, fallbackRotation: wanted);
    if (exs.isEmpty) continue; // 该肌群无可用动作（理论不发生）：跳过该日
    out.add(LocalPlanDay(slots[i], _dayTitle(region, i), exs));
  }
  return out;
}

String _dayTitle(String region, int seq) => '第 ${seq + 1} 练 · $region';

/// 一天 3 个动作：主肌群复合 1 + 主肌群辅助 1 +（库里够时）同肌群再取 1；
/// 不足 3 个时按轮转顺序从下一肌群补。
List<LocalPlanExercise> _pickDayExercises(
    String region, String equipment, Set<String> used,
    {required List<String> fallbackRotation}) {
  final out = <LocalPlanExercise>[];
  void addFrom(String r, {required bool compound}) {
    final m = _nextExercise(r, equipment, used,
        compoundOnly: compound, allowAny: !compound ? true : false);
    if (m == null) return;
    used.add(m.name);
    final isCompound = m.isCompound;
    final timed = defaultLoggingFor(m.name) == LoggingMode.time;
    out.add(LocalPlanExercise(
      name: m.name,
      sets: 3,
      repsMin: timed ? 30 : (isCompound ? 6 : 10),
      repsMax: timed ? 45 : (isCompound ? 10 : 15),
      restSec: timed ? 60 : (isCompound ? 180 : 90),
      kind: timed ? 'assistance' : (isCompound ? 'compound' : 'assistance'),
      mainMuscle: m.muscles.main,
    ));
  }

  addFrom(region, compound: true);
  addFrom(region, compound: false);
  addFrom(region, compound: false); // 同肌群第二个辅助（无则空）
  if (out.length < 3) {
    final rotation = fallbackRotation.isEmpty ? _kDefaultRotation : fallbackRotation;
    final idx = rotation.indexOf(region);
    // 从下一个肌群循环补齐
    for (var k = 1; k <= rotation.length && out.length < 3; k++) {
      addFrom(rotation[(idx + k) % rotation.length], compound: out.isEmpty);
    }
    if (out.isEmpty) {
      // 提到的肌群一个动作都没有（脏描述）：回落全身轮转
      for (final r in _kDefaultRotation) {
        addFrom(r, compound: true);
        if (out.isNotEmpty) break;
      }
    }
  }
  return out;
}

/// 在肌群 r 中按库顺序取下一个未用动作。
/// [compoundOnly] true 只取复合；false 先辅助后复合（避免一天全是复合）。
ExerciseMeta? _nextExercise(
  String region,
  String equipment,
  Set<String> used, {
  required bool compoundOnly,
  required bool allowAny,
}) {
  bool okEquipment(String eq) => switch (equipment) {
        'home' => eq != 'gym',
        'gym' => eq != 'home',
        _ => true,
      };
  ExerciseMeta? pick(bool Function(ExerciseMeta) want) {
    for (final m in kExerciseLibrary) {
      if (m.muscles.main != region) continue;
      if (!okEquipment(m.equipment)) continue;
      if (used.contains(m.name)) continue;
      if (want(m)) return m;
    }
    return null;
  }

  if (compoundOnly) return pick((m) => m.isCompound);
  final aux = pick((m) => !m.isCompound);
  return aux ?? (allowAny ? pick((m) => m.isCompound) : null);
}
