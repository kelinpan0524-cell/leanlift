import '../engine/exercise_identity.dart'
    show canonicalExerciseNameOf, exerciseKeyOf;

/// 动作示范视频映射（2026-09-27 深夜，Arono 拍板加入）。
///
/// 素材来自 wger.de 社区贡献的动作视频，许可证 **CC BY-SA 4.0**
/// （可自由使用与修改，需署名作者并以同许可分享衍生版本）。
/// 原片为 iPhone 原格式（MOV/H.265），开发期已统一转码为
/// 480p H.264 mp4（无声，纯动作演示），共 14 条约 6.4MB。
/// 原片地址：https://wger.de/media/exercise-video/ 下按动作 id 归档的 MOV 文件
/// （上游 commit 快照 2026-09-27，作者署名见各条 author）。
class ExerciseVideoAsset {
  final String file;
  final String author;

  const ExerciseVideoAsset({required this.file, required this.author});
}

const kExerciseVideoMap = <String, ExerciseVideoAsset>{
  '罗马尼亚硬拉': ExerciseVideoAsset(file: 'assets/videos/v507.mp4', author: 'Goulart'),
  '站姿提踵': ExerciseVideoAsset(file: 'assets/videos/v622.mp4', author: 'Goulart'),
  '杠铃卧推': ExerciseVideoAsset(file: 'assets/videos/v73.mp4', author: 'Goulart'),
  '杠铃箭步蹲': ExerciseVideoAsset(file: 'assets/videos/v46.mp4', author: 'Goulart'),
  '哑铃箭步蹲': ExerciseVideoAsset(file: 'assets/videos/v206.mp4', author: 'Goulart'),
  '腿举（倒蹬机）': ExerciseVideoAsset(file: 'assets/videos/v374.mp4', author: 'Goulart'),
  '哑铃锤式弯举': ExerciseVideoAsset(file: 'assets/videos/v272.mp4', author: 'Goulart'),
  '牧师凳弯举': ExerciseVideoAsset(file: 'assets/videos/v584.mp4', author: 'Goulart'),
  '哑铃颈后臂屈伸': ExerciseVideoAsset(file: 'assets/videos/v211.mp4', author: 'Goulart'),
  '双杠臂屈伸（挺胸）': ExerciseVideoAsset(file: 'assets/videos/v194.mp4', author: 'Goulart'),
  '引体向上': ExerciseVideoAsset(file: 'assets/videos/v475.mp4', author: 'Goulart'),
  '杠铃臀推': ExerciseVideoAsset(file: 'assets/videos/v294.mp4', author: 'Goulart'),
  '哑铃后踢': ExerciseVideoAsset(file: 'assets/videos/v655.mp4', author: 'Goulart'),
  '面拉': ExerciseVideoAsset(file: 'assets/videos/v222.mp4', author: 'Goulart'),
};

final Map<String, ExerciseVideoAsset> _kExerciseVideoByKey = {
  for (final e in kExerciseVideoMap.entries) exerciseKeyOf(e.key): e.value,
};

/// 该动作的示范视频；支持别名与规范名兜底，无视频返回 null。
ExerciseVideoAsset? exerciseVideoOf(String name) {
  final canonical = canonicalExerciseNameOf(name);
  return kExerciseVideoMap[name] ??
      kExerciseVideoMap[canonical] ??
      _kExerciseVideoByKey[exerciseKeyOf(canonical)];
}
