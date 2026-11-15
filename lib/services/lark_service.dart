import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../db/db.dart';
import '../l10n/lang.dart';
import '../models/models.dart';
import 'settings.dart';

/// 计划日同步规格：LarkService 不反向依赖 PlanRepository。
/// 日期化排程后由仓库逐日解析出具体 date，这里只负责写日历。
class PlanDaySyncSpec {
  final int planDayId;
  final String date; // yyyy-MM-dd，这条训练安排在哪天
  final int weekday; // 1=周一（保留给旧调用方展示）
  final String title;
  final String detail;
  const PlanDaySyncSpec({
    required this.planDayId,
    required this.date,
    this.weekday = 1,
    required this.title,
    required this.detail,
  });
}

/// 飞书开放平台手机直连客户端（自建应用，日历最小权限）。
///
/// 凭证获取（开发期一次性，用 lark-cli 完成）：
///   1. 飞书开放平台建自建应用，开通日历权限（读写自己主日历）
///   2. lark-cli 走授权拿 refresh_token（有效期 30 天，App 内自动轮换续期）
///   3. 把 App ID / App Secret / refresh_token 填进 App 设置页
/// 运行期 App 用 refresh_token 换 user_access_token（2h），到期自动刷新。
class LarkService {
  LarkService(this._settings, this._db);

  final Settings _settings;
  final Db _db;

  static const _base = 'https://open.feishu.cn';
  static const _doneMarker = '—— 训练完成 ——';

  Future<String?>? _tokenInFlight;

  bool get configured =>
      _settings.larkEnabled &&
      _settings.larkAppId.isNotEmpty &&
      _settings.larkAppSecret.isNotEmpty &&
      _settings.larkRefreshToken.isNotEmpty;

  /// 拿有效 user_access_token；失败返回 null。
  /// single-flight：并发调用共享同一次刷新，避免 refresh_token 轮换竞态。
  Future<String?> ensureToken() {
    if (!configured) return Future.value(null);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_settings.larkAccessToken.isNotEmpty &&
        _settings.larkTokenExpiry - now > 120000) {
      return Future.value(_settings.larkAccessToken);
    }
    final inFlight = _tokenInFlight;
    if (inFlight != null) return inFlight;
    final f = _refreshToken().whenComplete(() => _tokenInFlight = null);
    _tokenInFlight = f;
    return f;
  }

  Future<String?> _refreshToken() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final resp = await http
          .post(
            Uri.parse('$_base/open-apis/authen/v2/oauth/token'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'grant_type': 'refresh_token',
              'client_id': _settings.larkAppId,
              'client_secret': _settings.larkAppSecret,
              'refresh_token': _settings.larkRefreshToken,
            }),
          )
          .timeout(const Duration(seconds: 20));
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      if (resp.statusCode != 200 ||
          data['code'] != 0 ||
          data['access_token'] == null) {
        return null; // refresh_token 过期/失效或网络错误
      }
      _settings.larkAccessToken = data['access_token'] as String;
      _settings.larkTokenExpiry =
          now + ((data['expires_in'] as num?)?.toInt() ?? 6900) * 1000;
      final newRefresh = data['refresh_token'] as String?;
      if (newRefresh != null && newRefresh.isNotEmpty) {
        _settings.larkRefreshToken = newRefresh; // 轮换
      }
      await _settings.save();
      return _settings.larkAccessToken;
    } catch (_) {
      return null;
    }
  }

  /// 拿用户主日历 id（设置页"测试连接"用）。
  Future<String> fetchPrimaryCalendar() async {
    final token = await ensureToken();
    if (token == null) {
      throw LarkException(tx('授权失效或网络不可用，请检查后重试',
          en: 'Auth expired or network unavailable, check settings and retry'));
    }
    final resp = await http
        .get(
          Uri.parse('$_base/open-apis/calendar/v4/calendars?page_size=50'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 20));
    final data =
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (data['code'] != 0) {
      throw LarkException(tx('获取日历失败：${data['msg']}',
          en: 'Failed to load calendars: ${data['msg']}'));
    }
    final items = (data['data']?['calendar_list'] as List?) ?? [];
    for (final c in items) {
      final m = Map<String, dynamic>.from(c as Map);
      if (m['type'] == 'primary') return m['calendar_id'] as String;
    }
    if (items.isNotEmpty) {
      return Map<String, dynamic>.from(items.first as Map)['calendar_id']
          as String;
    }
    throw LarkException(tx('没有可用日历', en: 'No available calendar'));
  }

  /// 计划日 → 日历事件（有则更新、无则建）。
  /// 失败时入离线队列，联网后由 retryPending 补写。
  Future<void> upsertDayEvent({
    required String date,
    required String title,
    required String detail,
    int? planDayId,
  }) async {
    if (!configured) return;
    try {
      await _upsertDayEventRaw(
          date: date, title: title, detail: detail, planDayId: planDayId);
    } catch (_) {
      await _db.enqueueSync('upsert_day', jsonEncode({
        'date': date,
        'title': title,
        'detail': detail,
        'plan_day_id': planDayId,
      }));
    }
  }

  Future<void> _upsertDayEventRaw({
    required String date,
    required String title,
    required String detail,
    int? planDayId,
  }) async {
    final token = await ensureToken();
    if (token == null) throw const LarkException('no token');
    final cid = _settings.larkCalendarId.isNotEmpty
        ? _settings.larkCalendarId
        : await fetchPrimaryCalendar();
    final startTs =
        _tsOf(date, _settings.larkEventHour, _settings.larkEventMinutes);
    final endTs = startTs + 3600; // 1 小时
    final body = jsonEncode({
      'summary': title,
      'description': detail,
      'start_time': {'timestamp': '$startTs'},
      'end_time': {'timestamp': '$endTs'},
      'reminders': [
        {'minutes': _settings.larkReminderMin}
      ],
    });
    final exist = planDayId == null
        ? null
        : await _db.larkSyncForDayDate(planDayId, date);
    http.Response resp;
    if (exist != null) {
      resp = await http
          .patch(
            Uri.parse(
                '$_base/open-apis/calendar/v4/calendars/$cid/events/${exist.larkEventId}'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json'
            },
            body: body,
          )
          .timeout(const Duration(seconds: 20));
      final patchData =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      if (patchData['code'] != 0) {
        // patch 失败常见原因：用户在飞书端把这条日程手动删了，本地映射成了死链。
        // GET 探测确认：事件确实不存在 → 清掉死映射，用同一 body 重建（POST）；
        // GET 抛网络异常则维持 throw → 入离线队列，下次再试。
        final probe = await http.get(
          Uri.parse(
              '$_base/open-apis/calendar/v4/calendars/$cid/events/${exist.larkEventId}'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 20));
        final probeData =
            jsonDecode(utf8.decode(probe.bodyBytes)) as Map<String, dynamic>;
        if (probeData['code'] != 0) {
          if (exist.id != null) await _db.removeLarkSyncById(exist.id!);
          resp = await _postDayEvent(cid, token, body);
        } else {
          // 事件还在：真正的权限/参数问题，按原失败路径抛出入队
          throw LarkException('${patchData['msg']}');
        }
      }
    } else {
      resp = await _postDayEvent(cid, token, body);
    }
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (data['code'] != 0) throw LarkException('${data['msg']}');
    final eventId =
        (data['data']?['event']?['event_id'] as String?) ?? exist?.larkEventId ?? '';
    if (eventId.isNotEmpty && planDayId != null) {
      await _db.upsertLarkSync(LarkSync(
        refType: 'plan_day:$date',
        refId: planDayId,
        larkEventId: eventId,
        eventDate: date,
        syncedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }
  }

  /// POST 新建日历事件（upsert 与"事件被手动删后重建"共用）。
  Future<http.Response> _postDayEvent(String cid, String token, String body) {
    return http
        .post(
          Uri.parse('$_base/open-apis/calendar/v4/calendars/$cid/events'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json'
          },
          body: body,
        )
        .timeout(const Duration(seconds: 20));
  }

  /// 训练完成 → 回填摘要到当天事件描述（失败入队）。
  Future<void> backfillSessionSummary({
    required String date,
    required String summary,
  }) async {
    if (!configured) return;
    try {
      await _backfillSessionSummaryRaw(date: date, summary: summary);
    } catch (_) {
      await _db.enqueueSync('session_summary', jsonEncode({
        'date': date,
        'summary': summary,
      }));
    }
  }

  Future<void> _backfillSessionSummaryRaw({
    required String date,
    required String summary,
  }) async {
    final token = await ensureToken();
    if (token == null) throw const LarkException('no token');
    final cid = _settings.larkCalendarId.isNotEmpty
        ? _settings.larkCalendarId
        : await fetchPrimaryCalendar();
    // 找当天含"（训练）"的事件（由本 App 创建，避免误伤用户手建事件）
    final fromTs = _tsOf(date, 0, 0) - 86400;
    final toTs = _tsOf(date, 23, 59) + 86400;
    final resp = await http.get(
      Uri.parse(
          '$_base/open-apis/calendar/v4/calendars/$cid/events?start_time=$fromTs&end_time=$toTs&page_size=50'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 20));
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (data['code'] != 0) throw LarkException('${data['msg']}');
    final items = (data['data']?['items'] as List?) ?? [];
    String? eventId;
    String prevDesc = '';
    for (final it in items) {
      final m = Map<String, dynamic>.from(it as Map);
      if ((m['summary'] as String?)?.contains('（训练）') != true) continue;
      final rawTs = (m['start_time'] as Map?)?['timestamp']?.toString();
      final ts = rawTs == null ? null : int.tryParse(rawTs);
      if (ts != null &&
          fmtYmd(DateTime.fromMillisecondsSinceEpoch(ts * 1000)) != date) {
        continue;
      }
      eventId = m['event_id'] as String?;
      prevDesc = (m['description'] as String?) ?? '';
      break;
    }
    if (eventId == null) {
      // 找不到事件不能静默当成功：主路径要入队、离线行要保留重试，
      // 等日程补写成功后摘要随之补上
      throw LarkException(tx('当天未找到训练日程（可能尚未同步或被手动删除）',
          en: 'No workout event found for that day (not synced yet or deleted manually)'));
    }
    // 已回填过就跳过，避免重试时摘要重复追加
    if (prevDesc.contains(_doneMarker)) return;
    final newDesc = prevDesc.isEmpty
        ? '$_doneMarker\n$summary'
        : '$prevDesc\n\n$_doneMarker\n$summary';
    final patchResp = await http
        .patch(
          Uri.parse(
              '$_base/open-apis/calendar/v4/calendars/$cid/events/$eventId'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json'
          },
          body: jsonEncode({'description': newDesc}),
        )
        .timeout(const Duration(seconds: 20));
    final patchData =
        jsonDecode(utf8.decode(patchResp.bodyBytes)) as Map<String, dynamic>;
    if (patchResp.statusCode < 200 ||
        patchResp.statusCode >= 300 ||
        patchData['code'] != 0) {
      throw LarkException('${patchData['msg'] ?? patchResp.statusCode}');
    }
  }

  /// 删除某计划日对应的日历事件（切计划/删计划时撤下日程）。
  /// ① 过去的日历事件是训练历史（带「—— 训练完成 ——」摘要回填），永不触碰：
  ///    eventDate 与 fmtYmd 同为 YYYY-MM-DD，字符串比较即可。
  /// ② 只有日历侧确认删掉（2xx 且 code==0）或事件本已不存在（404）才清本地映射；
  ///    其余失败（网络异常/token 失效/权限拒绝）保留映射，交给下次同步或离线队列，
  ///    不让事件变成 App 再也定位不到的孤儿。
  Future<void> removePlanDayEvent(int planDayId) async {
    final syncs = await _db.larkSyncsForDay(planDayId);
    if (syncs.isEmpty) return;
    final today = fmtYmd(DateTime.now());
    final futureSyncs =
        syncs.where((s) => s.eventDate.compareTo(today) >= 0).toList();
    if (futureSyncs.isEmpty) return;
    try {
      final token = await ensureToken();
      if (token == null) return; // 凭证不可用：保留映射，等下次同步
      final cid = _settings.larkCalendarId.isNotEmpty
          ? _settings.larkCalendarId
          : await fetchPrimaryCalendar();
      for (final sync in futureSyncs) {
        final resp = await http
            .delete(
              Uri.parse(
                  '$_base/open-apis/calendar/v4/calendars/$cid/events/${sync.larkEventId}'),
              headers: {'Authorization': 'Bearer $token'},
            )
            .timeout(const Duration(seconds: 20));
        final data =
            jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
        final deleted = (resp.statusCode >= 200 &&
                resp.statusCode < 300 &&
                data['code'] == 0) ||
            resp.statusCode == 404; // 事件已被手动删：同样算清理完成
        if (deleted) {
          if (sync.id != null) {
            await _db.removeLarkSyncById(sync.id!);
          } else {
            await _db.removeLarkSync(sync.refType, planDayId);
          }
        }
      }
      // 其余失败（403 权限拒绝、网关错误页等）：保留映射，下次再试
    } catch (_) {
      // 网络不可用/响应体异常：保留映射，交给下次同步或离线队列
    }
  }

  /// 把训练安排写入飞书日历。日期化排程后，仓库已经把未来 14 天逐日
  /// 解析成带具体日期的 spec（含循环模式和手动改期），这里直接逐条写。
  Future<int> syncUpcomingDays({required List<PlanDaySyncSpec> days}) async {
    if (!configured) return 0;
    var n = 0;
    for (final day in days) {
      await upsertDayEvent(
        date: day.date,
        title: '${day.title}（训练）',
        detail: day.detail,
        planDayId: day.planDayId,
      );
      n++;
    }
    return n;
  }

  /// 启动/联网时补写离线队列。
  /// 重试走 Raw 路径（失败不重新入队）；失败行带自增 attempts 重新入队，
  /// 超过上限的行放弃删除——避免"当天本不在计划内"之类注定失败的行永久空转。
  static const maxRetryAttempts = 10;

  Future<int> retryPending() async {
    if (!configured) return 0;
    final pending = await _db.pendingSync();
    var done = 0;
    for (final row in pending) {
      final op = row['op'] as String;
      final payload =
          jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      try {
        if (op == 'upsert_day') {
          await _upsertDayEventRaw(
            date: payload['date'] as String,
            title: payload['title'] as String,
            detail: payload['detail'] as String? ?? '',
            planDayId: payload['plan_day_id'] as int?,
          );
        } else if (op == 'session_summary') {
          await _backfillSessionSummaryRaw(
            date: payload['date'] as String,
            summary: payload['summary'] as String? ?? '',
          );
        }
        await _db.removeSync(row['id'] as int);
        done++;
      } catch (_) {
        // 仍失败：带 attempts 计数重新入队（插到队尾）；超上限的行放弃删除。
        // 先 enqueue 再 removeSync：中途崩溃宁可留重复行也不丢操作。
        final attempts = (payload['attempts'] as num?)?.toInt() ?? 0;
        if (attempts < maxRetryAttempts) {
          await _db.enqueueSync(
              op, jsonEncode({...payload, 'attempts': attempts + 1}));
        }
        await _db.removeSync(row['id'] as int);
      }
    }
    return done;
  }

  static String fmtYmd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  int _tsOf(String date, int hour, int minute) {
    final p = date.split('-').map(int.parse).toList();
    final dt = DateTime(p[0], p[1], p[2], hour, minute);
    return dt.millisecondsSinceEpoch ~/ 1000;
  }
}

class LarkException implements Exception {
  final String message;
  const LarkException(this.message);
  @override
  String toString() => message;
}
