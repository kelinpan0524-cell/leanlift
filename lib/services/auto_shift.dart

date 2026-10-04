import 'package:shared_preferences/shared_preferences.dart';

import '../engine/engine.dart' show fmtDate;
import 'plan_repository.dart';

/// 错过训练日自动顺延（2026-10-04 Arono）：打开 App 时补扫「上一次检查
/// 之后、昨天为止」错过的训练日，逐日顺延（每错一个训练日推一天），
/// 结果由 App 容器交给首页弹一次提示。
///
/// 检查点（每个计划一行，存本地 prefs）：
/// - 记录「已判断完的最后一天」，每次扫描只看它之后、昨天为止的日子；
/// - 首次见到某计划处于启用态（含换激活计划、功能刚上线）→ 从今天起算，
///   不回头追历史——上线当天和刚切换的计划不会被旧账顺延；
/// - 开关关闭时不扫描也不推进检查点：期间错过的日子在重开后照常补扫。
class AutoShiftService {
  AutoShiftService(this._repo, this._prefs);

  final PlanRepository _repo;
  final SharedPreferences _prefs;

  static const _kPrefix = 'schedule.autoShift.';

  /// 扫描并顺延当前启用计划。返回顺延掉的日期（空 = 本次没有自动顺延）。
  /// [enabled] 由调用方读设置传入（便于测试注入）；[now] 注入便于测试。
  Future<List<DateTime>> run({required bool enabled, DateTime? now}) async {
    final plan = _repo.activePlan;
    final planId = plan?.id;
    if (plan == null || planId == null) return const [];
    if (!enabled) return const [];

    final nowDt = now ?? DateTime.now();
    final today = DateTime(nowDt.year, nowDt.month, nowDt.day);

    // 换激活计划（或首次运行）：不回头扫，从今天开始盯
    final lastActiveId = _prefs.getInt('${_kPrefix}lastActivePlan');
    final switched = lastActiveId != planId;
    final checkedStr = _prefs.getString('${_kPrefix}checked.$planId');
    final fromExclusive =
        switched || checkedStr == null || checkedStr.isEmpty
        ? today
        : DateTime.parse(checkedStr);

    final missed =
        await _repo.autoShiftMissedDays(plan, fromExclusive, today);

    if (switched) {
      await _prefs.setInt('${_kPrefix}lastActivePlan', planId);
    }
    // 昨天及更早全部判断完毕；今天留到明天再判
    await _prefs.setString(
        '${_kPrefix}checked.$planId', fmtDate(today.subtract(
            const Duration(days: 1))));
    if (missed.isNotEmpty) {
      // 刷新仓库缓存：首页/计划页拿新推导，练前提醒随 planRepo 监听重排
      await _repo.reload();
    }
    return missed;
  }
}
