/// 动作稳定身份（P1-A）：跨同义词、改名与 AI 导入识别「这是同一个动作」。
///
/// 设计口径：
/// - [exerciseKeyOf] 是唯一的身份键计算入口：去空白/标点、英文转小写，
///   再把常见中英别名归一到内置动作库的规范中文名。键本身**不做模糊匹配**
///   ——「卧推」「划船」「深蹲」这类有歧义的泛称保持原样，避免把不同器械
///   或角度的动作误合并。
/// - [kExerciseAliases] 同时被 AI 导入的六级匹配复用，保证「AI 落到规范名」
///   与「历史按规范键归并」是同一套别名口径。
/// - 落库时 key 非空则保留（用户在计划编辑器里改名时默认沿用旧键，历史
///   不断）；为空时先查同名已有行，查不到才按名字计算（复制/替换/追加）。
library;

/// 动作别名 → 规范名（规范名取 `lib/presets/exercise_library.dart` 的中文原名）。
///
/// 只收指向明确的映射：
/// - 中文泛称「卧推」「划船」「深蹲」「弯举」「推举」等不在此表，
///   留给 AI 预览页人工确认，也避免身份键把不同变体错误合并；
/// - 英文键统一小写（[exerciseKeyOf] 会先做小写 + 去标点归一）；
/// - 中文键可带括号注记，查表前同样会去掉空白/标点。
const Map<String, String> kExerciseAliases = {
  // ---------- 中文口语/器械变体 ----------
  '平板卧推': '杠铃卧推',
  '杠铃推胸': '杠铃卧推',
  '杠铃平板卧推': '杠铃卧推',
  '平板杠铃卧推': '杠铃卧推',
  '上斜卧推': '上斜杠铃卧推',
  '上斜杠铃平板卧推': '上斜杠铃卧推',
  '哑铃上斜卧推': '上斜哑铃卧推',
  '平板哑铃卧推': '哑铃卧推',
  '哑铃平板卧推': '哑铃卧推',
  '引体': '引体向上',
  '正手引体': '引体向上',
  '引体向上（正手）': '引体向上',
  '引体向上(正手)': '引体向上',
  '反手引体': '引体向上（反手）',
  '反手引体向上': '引体向上（反手）',
  '背阔肌下拉': '高位下拉',
  '高位下拉机': '高位下拉',
  '倒蹬': '腿举（倒蹬机）',
  '倒蹬机': '腿举（倒蹬机）',
  '腿举': '腿举（倒蹬机）',
  '腿举机': '腿举（倒蹬机）',
  '蝴蝶机': '坐姿夹胸（蝴蝶机）',
  '蝴蝶机夹胸': '坐姿夹胸（蝴蝶机）',
  '蝴蝶机反向飞鸟': '蝴蝶机反向飞鸟（后束）',
  '高脚杯深蹲': '哑铃高脚杯深蹲',
  '酒杯深蹲': '哑铃高脚杯深蹲',
  '农夫行走': '哑铃农夫行走',
  '农夫走': '哑铃农夫行走',
  '哑铃农夫走': '哑铃农夫行走',
  '侧平举': '哑铃侧平举',
  '哑铃侧举': '哑铃侧平举',
  '前平举': '哑铃前平举',
  '哑铃前举': '哑铃前平举',
  '俯身飞鸟': '俯身飞鸟（后束）',
  '后束飞鸟': '俯身飞鸟（后束）',
  '罗马尼亚硬拉': '罗马尼亚硬拉',
  // 「臀推」对应库里的「杠铃臀推」；「杠铃臀桥」是另一个动作，不能合并。
  '臀推': '杠铃臀推',
  '臀冲': '杠铃臀推',
  '杠铃臀冲': '杠铃臀推',
  // 「仰卧起坐」与「卷腹」在库里是两条不同动作（cue 不同），不做别名。
  '仰卧卷腹': '卷腹',
  '自行车卷腹': '空中蹬车',
  '空中自行车': '空中蹬车',
  '波比': '波比跳',
  '立卧撑': '波比跳',
  '登山者': '登山跑',
  '登山式': '登山跑',
  '俄罗斯旋转': '俄罗斯转体',
  '俄罗斯扭转': '俄罗斯转体',
  '壶铃摇摆': '壶铃摆荡',
  '壶铃摆动': '壶铃摆荡',
  '单臂划船': '哑铃单臂划船',
  '单臂哑铃划船': '哑铃单臂划船',
  '飞鸟': '哑铃飞鸟',
  '提踵': '站姿提踵',
  '站姿提踵机': '站姿提踵',
  '腿弯举': '腿弯举（腘绳肌）',
  '俯卧腿弯举': '腿弯举（腘绳肌）',
  '腿屈伸': '腿屈伸（股四头）',
  '腿伸展': '腿屈伸（股四头）',
  '腿屈伸机': '腿屈伸（股四头）',
  '哈克蹲': '哈克深蹲',
  '保加利亚蹲': '保加利亚分腿蹲',
  '箭步走': '箭步蹲',
  '行走箭步蹲': '箭步蹲',
  '单腿硬拉': '哑铃单腿硬拉',
  '哑铃单腿罗马尼亚硬拉': '哑铃单腿硬拉',
  '罗马椅挺身': '山羊挺身',
  '小燕飞': '超人式',
  '超人': '超人式',
  '三头下压': '绳索下压',
  '绳索三头下压': '绳索下压',
  '哑铃过顶臂屈伸': '哑铃颈后臂屈伸',
  '碎颅式': '仰卧杠铃臂屈伸',
  '窄握卧推': '窄距卧推',
  '凳上反屈伸': '凳上臂屈伸',
  '直臂下拉': '直臂下压',
  'T把划船': 'T杠划船',
  '坐姿绳索划船': '坐姿划船',
  '绳索划船': '坐姿划船',
  '哑铃二头弯举': '哑铃弯举',
  '杠铃二头弯举': '杠铃弯举',
  '锤式弯举': '哑铃锤式弯举',
  '军事推举': '站姿推举',
  '杠铃推举': '站姿推举',
  '站姿杠铃推举': '站姿推举',
  '过头推举': '站姿推举',
  '哑铃推肩': '坐姿哑铃推举',
  '坐姿哑铃推肩': '坐姿哑铃推举',
  '哑铃推举': '坐姿哑铃推举',
  '绳索面拉': '面拉',
  '悬垂抬腿': '悬垂举腿',
  '平躺举腿': '仰卧举腿',
  '两头起': 'V字两头起',
  '腹肌轮': '健腹轮',
  '蹲跳': '深蹲跳',
  '跳箱': '箱跳',
  '靠墙蹲': '靠墙静蹲',
  '桥式': '臀桥',
  '土耳其起身': '土耳其起立',
  '帕洛夫推': '帕洛夫推举',
  '健腹轮滚动': '健腹轮',

  // ---------- 英文（键统一小写） ----------
  'bench press': '杠铃卧推',
  'barbell bench press': '杠铃卧推',
  'flat bench press': '杠铃卧推',
  'incline bench press': '上斜杠铃卧推',
  'incline barbell bench press': '上斜杠铃卧推',
  'dumbbell bench press': '哑铃卧推',
  'incline dumbbell press': '上斜哑铃卧推',
  'incline dumbbell bench press': '上斜哑铃卧推',
  'decline bench press': '下斜杠铃卧推',
  'push up': '俯卧撑',
  'push-up': '俯卧撑',
  'pushup': '俯卧撑',
  'incline push up': '上斜俯卧撑',
  'decline push up': '下斜俯卧撑（脚垫高）',
  'pike push up': '派克俯卧撑',
  'pull up': '引体向上',
  'pull-up': '引体向上',
  'pullup': '引体向上',
  // chin-up 是反握（库里的「引体向上（反手）」），不能并到正握引体。
  'chin up': '引体向上（反手）',
  'chin-up': '引体向上（反手）',
  'chinup': '引体向上（反手）',
  'lat pulldown': '高位下拉',
  'lat pull down': '高位下拉',
  'straight arm pulldown': '直臂下压',
  'barbell row': '杠铃划船',
  'bent over row': '杠铃划船',
  'pendlay row': '杠铃划船',
  't bar row': 'T杠划船',
  't-bar row': 'T杠划船',
  'dumbbell row': '哑铃单臂划船',
  'one arm dumbbell row': '哑铃单臂划船',
  'single arm dumbbell row': '哑铃单臂划船',
  'seated cable row': '坐姿划船',
  'cable row': '坐姿划船',
  'machine row': '器械划船',
  'inverted row': '反向划船',
  'dumbbell pullover': '哑铃仰卧上拉',
  'back extension': '山羊挺身',
  'hyperextension': '山羊挺身',
  'good morning': '早安式',
  'deadlift': '杠铃硬拉',
  'romanian deadlift': '罗马尼亚硬拉',
  'rdl': '罗马尼亚硬拉',
  'stiff leg deadlift': '直腿硬拉',
  'sldl': '直腿硬拉',
  'sumo deadlift': '相扑硬拉',
  'barbell squat': '杠铃深蹲',
  'back squat': '杠铃深蹲',
  'front squat': '颈前深蹲',
  'bodyweight squat': '徒手深蹲',
  'air squat': '徒手深蹲',
  'goblet squat': '哑铃高脚杯深蹲',
  'hack squat': '哈克深蹲',
  'bulgarian split squat': '保加利亚分腿蹲',
  'dumbbell lunge': '哑铃箭步蹲',
  'barbell lunge': '杠铃箭步蹲',
  'leg press': '腿举（倒蹬机）',
  'leg curl': '腿弯举（腘绳肌）',
  'seated leg curl': '坐姿腿弯举',
  'nordic curl': '北欧腿弯举',
  'leg extension': '腿屈伸（股四头）',
  'calf raise': '站姿提踵',
  'standing calf raise': '站姿提踵',
  'seated calf raise': '坐姿提踵',
  'hip thrust': '杠铃臀推',
  'glute bridge': '臀桥',
  'single leg glute bridge': '单腿臀桥',
  'overhead press': '站姿推举',
  'ohp': '站姿推举',
  'military press': '站姿推举',
  'barbell overhead press': '站姿推举',
  'push press': '借力推',
  'arnold press': '阿诺德推举',
  'seated dumbbell press': '坐姿哑铃推举',
  'dumbbell shoulder press': '坐姿哑铃推举',
  'lateral raise': '哑铃侧平举',
  'side lateral raise': '哑铃侧平举',
  'dumbbell lateral raise': '哑铃侧平举',
  'cable lateral raise': '绳索侧平举',
  'front raise': '哑铃前平举',
  'dumbbell front raise': '哑铃前平举',
  'dumbbell rear delt fly': '俯身飞鸟（后束）',
  'dumbbell reverse fly': '俯身飞鸟（后束）',
  'cable reverse fly': '绳索反向飞鸟',
  'pec deck reverse fly': '蝴蝶机反向飞鸟（后束）',
  'face pull': '面拉',
  'cable face pull': '面拉',
  'upright row': '直立划船',
  'barbell shrug': '杠铃耸肩',
  'dumbbell shrug': '哑铃耸肩',
  'barbell curl': '杠铃弯举',
  'dumbbell curl': '哑铃弯举',
  'dumbbell hammer curl': '哑铃锤式弯举',
  'cable hammer curl': '绳索锤式弯举',
  'preacher curl': '牧师凳弯举',
  'concentration curl': '集中弯举',
  'ez bar curl': '曲杠弯举（EZ杠）',
  'skull crusher': '仰卧杠铃臂屈伸',
  'lying triceps extension': '仰卧杠铃臂屈伸',
  'dumbbell overhead triceps extension': '哑铃颈后臂屈伸',
  'cable overhead triceps extension': '绳索过顶臂屈伸',
  'triceps pushdown': '绳索下压',
  'tricep pushdown': '绳索下压',
  'cable pushdown': '绳索下压',
  'pushdown': '绳索下压',
  'close grip bench press': '窄距卧推',
  'dip': '双杠臂屈伸',
  'dips': '双杠臂屈伸',
  'bench dip': '凳上臂屈伸',
  'plank': '平板支撑',
  'side plank': '侧平板支撑',
  'crunch': '卷腹',
  'sit up': '仰卧起坐',
  'sit-up': '仰卧起坐',
  'situp': '仰卧起坐',
  'bicycle crunch': '空中蹬车',
  'reverse crunch': '反向卷腹',
  'hanging leg raise': '悬垂举腿',
  'lying leg raise': '仰卧举腿',
  'russian twist': '俄罗斯转体',
  'mountain climber': '登山跑',
  'mountain climbers': '登山跑',
  'burpee': '波比跳',
  'burpees': '波比跳',
  'box jump': '箱跳',
  'jump squat': '深蹲跳',
  'kettlebell swing': '壶铃摆荡',
  'turkish get up': '土耳其起立',
  'turkish getup': '土耳其起立',
  'farmer walk': '哑铃农夫行走',
  'farmers walk': '哑铃农夫行走',
  'farmer carry': '哑铃农夫行走',
  'farmers carry': '哑铃农夫行走',
  'dead bug': '死虫式',
  'bird dog': '鸟狗式',
  'ab wheel': '健腹轮',
  'ab roller': '健腹轮',
  'jump rope': '跳绳',
  'bear crawl': '熊爬',
  'pallof press': '帕洛夫推举',
  'wall sit': '靠墙静蹲',
  'step up': '登阶',
  'cable crossover': '绳索夹胸',
  'cable fly': '绳索夹胸',
  'pec deck': '坐姿夹胸（蝴蝶机）',
  'butterfly': '坐姿夹胸（蝴蝶机）',
  'chest press machine': '坐姿推胸（推胸机）',
  'machine chest press': '坐姿推胸（推胸机）',
  'smith machine squat': '史密斯机深蹲',
  'smith machine bench press': '史密斯机卧推',
  'smith machine shoulder press': '史密斯机推肩',
  'superman': '超人式',
};

/// 空白 + 中英文标点/符号。键里保留文字与数字，其余一律去掉。
final RegExp _noise = RegExp(
  r'''[\s\u3000!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~，。、；：！？“”‘’（）【】《》〈〉「」『』〔〕…—–～·•＂＇｀＾＿％＋－＝＜＞＠＃＆＊／＼｜＄]''',
);

String _normalize(String raw) => raw.toLowerCase().replaceAll(_noise, '');

/// 规范化别名表：键 = 去空白/标点/小写后的别名，值 = 规范中文名。
/// 懒加载一次；表是 const，运行期不变。
final Map<String, String> _normalizedAliases = {
  for (final e in kExerciseAliases.entries) _normalize(e.key): e.value,
};

/// 动作名 → 稳定身份键。
///
/// 规则：先按 [kExerciseAliases] 归一到规范名（中英别名、大小写、括号注记
/// 都无视），再去掉全部空白与中英文标点、英文转小写。键只用于「是不是
/// 同一个动作」的相等判断，展示仍用原始 [name]。
///
/// 空名 / 纯标点返回空串；调用方据此跳过身份查询而不是把所有空键聚合。
String exerciseKeyOf(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '';
  final normalized = _normalize(trimmed);
  if (normalized.isEmpty) return '';
  final canonical = _normalizedAliases[normalized] ?? trimmed;
  final key = _normalize(canonical);
  return key.isEmpty ? normalized : key;
}

/// 动作名 → 规范展示名（别名归一后的中文原名；非别名返回去首尾空白的原名）。
///
/// 统计页按身份键合并后需要一个可读名字：键去掉了标点（如
/// 「腿举（倒蹬机）」→「腿举倒蹬机」），不能直接拿来展示；这里保留
/// 标点，只把别名换成规范名。
String canonicalExerciseNameOf(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '';
  final normalized = _normalize(trimmed);
  if (normalized.isEmpty) return trimmed;
  return _normalizedAliases[normalized] ?? trimmed;
}

/// 已有行的身份键：显式键优先（改名保留的旧键/导入的定制键），
/// 空键按名字现算。所有按身份合并的调用方共用这一口径。
String exerciseIdentityKeyOf(String name, String? key) {
  final explicit = key?.trim() ?? '';
  return explicit.isNotEmpty ? explicit : exerciseKeyOf(name);
}

/// 编辑/改名后的稳定键。
///
/// 计划编辑器的改名是「同一个动作换显示名」，默认必须沿用旧键；只有
/// 明确换成了另一个已有动作时才换键：
/// - 名字没变：保留原键（自定义键也不动）；
/// - [storedNewKey] 非空：新名字已有同名行（计划/历史/自定义键），
///   直接用它（相同 = 同身份，不同 = 换动作）；
/// - [newNameIsKnownExercise] 且新名字是词表里的另一个动作：用新键；
/// - 其余（含「杠铃卧推」→「杠铃卧推（宽握）」「卧推王」这类任意改名）：
///   保留旧身份，历史/PR 不断。
///
/// 空新名字返回原键（表单正常拦截空名，这里只做兜底）。
String exerciseKeyAfterRename({
  required String oldName,
  required String oldKey,
  required String newName,
  String? storedNewKey,
  bool newNameIsKnownExercise = false,
}) {
  final oldTrim = oldName.trim();
  final newTrim = newName.trim();
  if (newTrim.isEmpty || newTrim == oldTrim) return oldKey;
  final oldIdentity =
      oldKey.trim().isNotEmpty ? oldKey.trim() : exerciseKeyOf(oldTrim);
  final newKey = exerciseKeyOf(newTrim);
  if (newKey.isEmpty) return oldIdentity;
  final stored = storedNewKey?.trim() ?? '';
  if (stored.isNotEmpty) return stored;
  if (newNameIsKnownExercise && newKey != exerciseKeyOf(oldTrim)) {
    return newKey;
  }
  return oldIdentity;
}

/// 是否是别名表里登记过的名字（用于判断备注旧键是不是动作名，
/// 而不是 `custom_squat` 这类显式定制键）。
bool isExerciseAliasName(String name) {
  final normalized = _normalize(name);
  return normalized.isNotEmpty && _normalizedAliases.containsKey(normalized);
}

/// 一组按身份键合并后的动作数据。
class ExerciseIdentityGroup<T> {
  ExerciseIdentityGroup({
    required this.key,
    required this.displayName,
    required this.items,
  });

  /// 稳定身份键（分组依据）。
  final String key;

  /// 规范展示名（保留标点、别名换规范名）。
  final String displayName;

  final List<T> items;
}

/// 把多行「动作名 + 稳定键 + 数据」按身份键合并。
/// 返回的每一组以身份键区分；[ExerciseIdentityGroup.displayName] 只用于展示。
/// 同义名/改名合并成一桶；不同身份键即使展示名相同也不会被合并。
List<ExerciseIdentityGroup<T>> groupExerciseListsByIdentity<T>(
  Iterable<({String name, String? exerciseKey, List<T> items})> rows,
) {
  final byKey = <String, ExerciseIdentityGroup<T>>{};
  for (final row in rows) {
    final identity = exerciseIdentityKeyOf(row.name, row.exerciseKey);
    final group = byKey.putIfAbsent(
      identity,
      () => ExerciseIdentityGroup<T>(
        key: identity,
        displayName: canonicalExerciseNameOf(row.name),
        items: <T>[],
      ),
    );
    group.items.addAll(row.items);
  }
  return byKey.values.toList(growable: false);
}

/// 给一组动作挑一个展示标签：优先用规范名；如果已被另一个身份占用，
/// 追加身份键后缀，避免两个身份在 UI 的字符串键里被合并。
String uniqueExerciseLabel(
    String displayName, String identityKey, Set<String> used) {
  final base = displayName.trim().isEmpty ? identityKey : displayName.trim();
  if (used.add(base)) return base;
  final suffix = identityKey.trim().isEmpty ? '?' : identityKey.trim();
  var label = '$base·$suffix';
  var n = 2;
  while (!used.add(label)) {
    label = '$base·$suffix#$n';
    n++;
  }
  return label;
}
