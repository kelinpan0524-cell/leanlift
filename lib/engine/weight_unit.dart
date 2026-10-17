/// 重量单位（kg / lb）：kg 是唯一存储口径（SQLite / 导出 / 引擎计算全 kg），
/// lb 只存在于显示与输入层（2026-10-17）。换数据库不动、导出不动、引擎不动。
///
/// 全局当前单位仿 l10n 的 Lang.setResolved 静态模式：
/// 设置服务在加载/保存时同步静态值，Widget 树里的页面靠 Settings.notifyListeners
/// 重建；通知/前台服务等非 Widget 上下文直接读静态值。纯 Dart，不依赖 UI。
library;

/// 支持的重量单位。
enum WeightUnit { kg, lb }

/// 全局当前重量单位（服务侧与测试直接读写静态值）。
class WeightUnits {
  WeightUnits._();

  static WeightUnit _current = WeightUnit.kg;

  static WeightUnit get current => _current;
  static bool get isLb => _current == WeightUnit.lb;

  static void setResolved(WeightUnit u) => _current = u;

  /// 一键切换（训练中点单位标签 / 设置页选择行共用）。
  static void toggle() =>
      _current = _current == WeightUnit.kg ? WeightUnit.lb : WeightUnit.kg;
}

/// 1 lb = 0.45359237 kg（国际磅的精确定义）。
const double kKgPerLb = 0.45359237;
const double kLbPerKg = 2.2046226218487757;

double lbToKg(double lb) => lb * kKgPerLb;
double kgToLb(double kg) => kg * kLbPerKg;

/// lb 显示/输入统一 snap 到 0.5lb 网格：输入 220lb 存 99.79kg，回显仍 220lb；
/// kg 存值换算到 lb 也落在这个网格上，来回切换不漂移。
double lbSnap(double lb) => (lb * 2).roundToDouble() / 2;

/// 当前单位标签（'kg' / 'lb'）。
String unitLabel() => WeightUnits.isLb ? 'lb' : 'kg';

/// 数值格式化：整数不带小数点，小数去尾零（与 UI 层 fmtKg 同规则）。
String _trimNum(double v) => v == v.roundToDouble()
    ? v.toStringAsFixed(0)
    : v
        .toStringAsFixed(2)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');

/// kg → 当前单位的数值字符串（不带单位后缀；lb 模式换算并 snap 0.5lb）。
/// 负值 = 辅助器械配重，取绝对值换算后保留负号。
String fmtVal(double kg) =>
    _trimNum(WeightUnits.isLb ? lbSnap(kgToLb(kg)) : kg);

/// kg → 当前单位的「数值+单位」串（如 100kg / 220.5lb）。
String fmtWithUnit(double kg) => '${fmtVal(kg)}${unitLabel()}';

/// 步进按钮的显示标签（当前单位）：kg [0.5,1.25,2.5,5]，lb [1.25,2.5,5,10]
/// （均为标准杠铃片重；lb 组对标 kg 组的相对粒度）。
List<double> stepLabels() =>
    WeightUnits.isLb ? const [1.25, 2.5, 5, 10] : const [0.5, 1.25, 2.5, 5];

/// 把当前 kg 草稿按显示单位步进一步（[dispStep] 为显示单位的步长数值）。
/// kg 模式直接加；lb 模式先 snap 到 0.5lb 网格再加步长再换算回 kg，
/// 保证显示值始终落在 0.5lb 网格上，连续点按不累积换算漂移。
double nudgedKg(double draftKg, double dispStep) => WeightUnits.isLb
    ? lbToKg(lbSnap(kgToLb(draftKg)) + dispStep)
    : draftKg + dispStep;

/// lb 制杠铃片规格（每片 lb 数，降序；45/35/25/10/5/2.5 为美制健身房最普遍一套）。
const List<double> kLbPlateSizes = [45, 35, 25, 10, 5, 2.5];

/// lb 制标准奥杆重量（lb）。
const double kLbBar = 45;
