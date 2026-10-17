import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../db/db.dart';
import '../engine/engine.dart';
import 'export_service.dart';
import 'plan_repository.dart';

/// 局域网只读数据桥（方案 B，2026-10-17 Arono）。
///
/// 手机在自身 Wi-Fi 局域网里开一个**只读** HTTP 服务，供电脑上的 MCP 代理
/// （tools/mcp-bridge/）取训练数据——手机当数据源，电脑当 AI 大脑。
/// 手机端不实现 MCP 协议本身（Claude Desktop 只认 stdio/远程 URL），
/// 由电脑侧那个几十行的小代理转译。
///
/// 安全边界（有意为之，不是遗漏）：
/// - **只读**：不暴露任何写入口，计划/组的增删改一律不响应；
/// - **不常驻**：开关状态不进 shared_preferences，每次都要用户主动开启，
///   空闲 [idleTimeout] 无请求即自动关闭——堵"开了忘了关"；
/// - **配对码**：6 位一次性码，错 5 次即作废，需重新生成；堵"配对太弱"；
/// - **令牌**：配对成功换 256-bit（32 字节）随机令牌，此后每个请求都要带；
/// - 数据不出手机、不出局域网，不经任何云端（符合仓库「无服务器」红线）。
class LocalBridgeService extends ChangeNotifier {
  LocalBridgeService({
    required this.db,
    this.planRepo,
    this.bodyWeightKg,
    this.port = 8765,
    this.idleTimeout = const Duration(minutes: 10),
    this.sweepInterval = const Duration(seconds: 30),
    this.maxPairAttempts = 5,
    this.accessLogSize = 20,
    this.ipProbe,
  }) : _export = ExportService(db);

  final Db db;
  final PlanRepository? planRepo;

  /// 自重容量折算体重（与统计页/AI 数据包同一口径）；不传 = 旧口径记 0。
  /// 传函数而非数值：设置页改了体重后，下一次请求立刻用新值，不留快照。
  final double Function()? bodyWeightKg;
  final int port;
  final Duration idleTimeout;
  final Duration sweepInterval;
  final int maxPairAttempts;
  final int accessLogSize;

  /// 局域网地址探测（默认走 NetworkInterface）。测试注入用，
  /// 让单测不依赖跑测机器有没有网卡。
  final Future<List<String>> Function()? ipProbe;

  final ExportService _export;

  /// 桥接口版本：电脑侧代理据此判断能否对接（不兼容时不至于静默出错）。
  static const int apiVersion = 1;

  HttpServer? _server;
  Timer? _sweepTimer;
  String? _lastError;

  /// 本机可被局域网访问的 IPv4（无 Wi-Fi 时为空 → 起不来）。
  List<String> _localIps = const [];
  int _actualPort = 0;
  DateTime? _startedAt;
  DateTime _lastActivityAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _requestCount = 0;
  int _pairAttempts = 0;
  bool _pairingLocked = false;

  /// 当前 6 位配对码（用户主动"重新生成"或每次启动都会换新）。
  String _pairingCode = '';

  /// 已配对设备（IP → 令牌/时间）。令牌按 IP 隔离，一台电脑配一次即可。
  final Map<String, _BridgeClient> _clients = {};

  /// 最近的请求记录（诊断用：确认"电脑确实连上了"）。
  final List<BridgeAccessEntry> _accessLog = [];

  // ---------- 对外只读状态（设置页据此渲染） ----------

  bool get running => _server != null;
  String? get lastError => _lastError;
  List<String> get localIps => List.unmodifiable(_localIps);
  int get actualPort => _actualPort;
  DateTime? get startedAt => _startedAt;
  String get pairingCode => _pairingCode;
  bool get pairingLocked => _pairingLocked;
  int get requestCount => _requestCount;
  int get pairAttemptsUsed => _pairAttempts;
  List<BridgeClient> get clients => List.unmodifiable(
      _clients.values.map((c) => c.toPublic()));
  List<BridgeAccessEntry> get accessLog =>
      List.unmodifiable(_accessLog.reversed);

  /// 相对空闲超时还剩多久自动关闭（未运行或刚启动时给满值）。
  Duration get remainingUntilAutoStop {
    if (!running) return Duration.zero;
    final idleFor = DateTime.now().difference(_lastActivityAt);
    final left = idleTimeout - idleFor;
    return left.isNegative ? Duration.zero : left;
  }

  /// 手机侧可用的连接串（电脑代理首次手工填写用）。
  String get endpointHint {
    if (_localIps.isEmpty) return 'http://<手机IP>:$_actualPort';
    return 'http://${_localIps.first}:$_actualPort';
  }

  // ---------- 生命周期 ----------

  /// 启动服务。返回是否成功；失败原因写在 [lastError]。
  /// 重复调用是幂等的（已在跑就返回 true）。
  Future<bool> start() async {
    if (running) return true;
    _lastError = null;
    // 没有局域网地址（未连 Wi-Fi / 只有蜂窝）时直接拒绝：免得开了却没人连得上。
    _localIps = await (ipProbe ?? probeLocalIps)();
    if (_localIps.isEmpty) {
      _lastError = '未找到局域网地址（请先连上 Wi-Fi）';
      notifyListeners();
      return false;
    }
    try {
      _server = await _bind(port);
    } on SocketException catch (e) {
      _lastError = '端口占用或无法监听：${e.message}';
      notifyListeners();
      return false;
    }
    _actualPort = _server!.port;
    _requestCount = 0;
    _pairAttempts = 0;
    _pairingLocked = false;
    _pairingCode = _newPairingCode();
    _clients.clear();
    _accessLog.clear();
    _startedAt = DateTime.now();
    _lastActivityAt = DateTime.now();
    _server!.listen(_onRequest, onError: (Object e) {
      _lastError = '服务异常：$e';
      notifyListeners();
    });
    _sweepTimer = Timer.periodic(sweepInterval, (_) => _sweep());
    notifyListeners();
    return true;
  }

  /// 端口占用时回落到系统分配端口（UI 显示实际端口，不写死）。
  Future<HttpServer> _bind(int preferred) async {
    try {
      return await HttpServer.bind(InternetAddress.anyIPv4, preferred,
          shared: false);
    } on SocketException {
      if (preferred == 0) rethrow;
      return await HttpServer.bind(InternetAddress.anyIPv4, 0, shared: false);
    }
  }

  /// 停止服务并清空全部令牌（断开所有已配对设备）。
  Future<void> stop() async {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    final s = _server;
    _server = null;
    _clients.clear();
    _pairingCode = '';
    _actualPort = 0;
    _localIps = const [];
    _startedAt = null;
    if (s != null) {
      await s.close(force: true);
    }
    notifyListeners();
  }

  /// 重新生成配对码（旧码立即失效；利用户"码被看见了，换一个"）。
  void regenerateCode() {
    if (!running) return;
    _pairingCode = _newPairingCode();
    _pairAttempts = 0;
    _pairingLocked = false;
    notifyListeners();
  }

  /// 主动断开某台已配对设备（撤销其令牌）。
  void revokeClient(String address) {
    if (_clients.remove(address) == null) return;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }

  // ---------- 空闲自动关闭 ----------

  void _sweep() {
    if (!running) return;
    if (DateTime.now().difference(_lastActivityAt) >= idleTimeout) {
      unawaited(stop());
    }
  }

  void _touch() {
    _lastActivityAt = DateTime.now();
    _requestCount++;
  }

  // ---------- 请求入口 ----------

  Future<void> _onRequest(HttpRequest req) async {
    final addr = _remoteAddress(req);
    var status = 0;
    try {
      req.response.headers.set('Cache-Control', 'no-store');
      status = await _route(req, addr);
    } on FormatException catch (e) {
      status = await _json(req.response, 400, {'error': '请求格式错误：$e'});
    } on Exception catch (e) {
      status = await _json(req.response, 500, {'error': '服务内部错误：$e'});
    } finally {
      // 无论成功失败都记账：诊断时能看到"电脑到底来没来、被拒在哪一步"
      _record(addr, '${req.method} ${req.uri.path}', status);
      try {
        await req.response.close();
      } on Exception catch (_) {
        // 对端提前断开（代理超时/用户关电脑），静默即可
      }
    }
  }

  Future<int> _route(HttpRequest req, String addr) async {
    final path = req.uri.path;
    // 免令牌：健康检查（代理据此确认手机在线且接口版本一致）
    if (req.method == 'GET' && (path == '/v1/health' || path == '/')) {
      return _json(req.response, 200, {
        'app': 'baoji-timer',
        'api': apiVersion,
        'paired': _clients.containsKey(addr),
      });
    }
    // 免令牌：配对（配对码本身就是凭证）
    if (req.method == 'POST' && path == '/v1/pair') {
      return _pair(req, addr);
    }
    // 其余一律要求令牌
    final token = _bearer(req);
    if (token == null || !_authorize(addr, token)) {
      _touch();
      return _json(req.response, 401, {'error': '未配对或令牌无效'});
    }
    _touch();
    _markSeen(addr);
    if (req.method != 'GET') {
      return _json(req.response, 405, {'error': '本桥只读，不支持的请求方法'});
    }
    switch (path) {
      case '/v1/summary':
        return _summary(req);
      case '/v1/sessions':
        return _sessions(req);
      case '/v1/today':
        return _today(req);
      case '/v1/exercise':
        return _exercise(req);
      default:
        return _json(req.response, 404, {'error': '未知接口：$path'});
    }
  }

  // ---------- /v1/pair ----------

  Future<int> _pair(HttpRequest req, String addr) async {
    _touch();
    if (_pairingLocked) {
      return _json(req.response, 403,
          {'error': '配对码连续输错已作废，请在手机上重新生成'});
    }
    final body = await _readBody(req);
    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const FormatException('body 必须是对象');
      data = Map<String, dynamic>.from(decoded);
    } on FormatException catch (_) {
      return _json(req.response, 400, {'error': 'body 必须是 JSON 对象'});
    }
    final code = (data['code'] ?? '').toString().trim();
    if (code != _pairingCode || code.isEmpty) {
      _pairAttempts++;
      if (_pairAttempts >= maxPairAttempts) {
        _pairingLocked = true;
        notifyListeners();
        return _json(req.response, 403, {'error': '配对码错误次数过多，已作废'});
      }
      notifyListeners();
      return _json(req.response, 401,
          {'error': '配对码不正确（还剩 ${maxPairAttempts - _pairAttempts} 次）'});
    }
    final token = _newToken();
    _clients[addr] = _BridgeClient(
      address: addr,
      token: token,
      userAgent: (req.headers.value(HttpHeaders.userAgentHeader) ?? '')
          .toString(),
    );
    // 配对成功后旧码立即失效：避免"配完还有人拿旧码再配一台"
    _pairingCode = _newPairingCode();
    _pairAttempts = 0;
    notifyListeners();
    return _json(req.response, 200, {'token': token, 'api': apiVersion});
  }

  // ---------- 只读数据接口 ----------

  /// AI 数据包（Markdown 文本，供 MCP 工具直接返回给模型）。
  /// 复用 App 内「AI 教练」同一套数据组装，保证手机端和电脑端看到的一致。
  Future<int> _summary(HttpRequest req) async {
    final weeks = _intParam(req, 'weeks', fallback: 8, min: 1, max: 52);
    final text = await _export.buildAiData(
      weeks: weeks,
      bodyWeightKg: bodyWeightKg?.call() ?? 0,
      planRepo: planRepo,
    );
    return _text(req.response, 200, text);
  }

  /// 训练记录明细（结构化 JSON，默认最近 [limit] 次）。
  Future<int> _sessions(HttpRequest req) async {
    final limit = _intParam(req, 'limit', fallback: 20, min: 1, max: 500);
    final from = req.uri.queryParameters['from'];
    final to = req.uri.queryParameters['to'];
    final sessions = (from != null && to != null)
        ? await db.sessionsBetween(_validDate(from), _validDate(to))
        : await db.recentSessions(limit: limit);
    final out = <Map<String, dynamic>>[];
    for (final s in sessions) {
      final ses = await db.sessionExercises(s.id!);
      final map = await db.setsOfSession(s.id!);
      out.add({
        'date': s.date,
        'dayTitle': s.planDayTitle,
        'durationMin': s.durationMin,
        'impression': s.impression,
        'status': s.status,
        'notes': s.notes,
        'exercises': [
          for (final se in ses)
            {
              'name': se.name,
              'kind': se.kind,
              'restSec': se.restSec,
              'target': '${se.targetSets}×${se.targetRepsMin}-${se.targetRepsMax}',
              'sets': [
                for (final x in map[se.id!] ?? const <SetEntry>[])
                  {
                    'weightKg': x.weightKg,
                    'reps': x.reps,
                    'rir': x.rir,
                    'kind': x.kind,
                    'doneAt': x.doneAt,
                  }
              ],
            }
        ],
      });
    }
    return _json(req.response, 200, {'count': out.length, 'sessions': out});
  }

  /// 今天/未来 7 天的计划安排（与首页「今日训练」同一口径）。
  Future<int> _today(HttpRequest req) async {
    final repo = planRepo;
    final plan = await db.activePlan();
    if (plan == null || repo == null) {
      return _json(req.response, 200, {
        'date': fmtDate(DateTime.now()),
        'planName': null,
        'today': null,
        'next7': const [],
      });
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = <Map<String, dynamic>>[];
    for (var i = 0; i < 7; i++) {
      final d = today.add(Duration(days: i));
      final day = await repo.dayForDateOn(plan, d);
      if (day == null) {
        days.add({'date': fmtDate(d), 'title': null, 'exercises': const []});
        continue;
      }
      final exs = await db.dayExercises(day.id!);
      days.add({
        'date': fmtDate(d),
        'title': day.title,
        'exercises': [
          for (final e in exs)
            {
              'name': e.name,
              'sets': e.sets,
              'repsMin': e.repsMin,
              'repsMax': e.repsMax,
              'restSec': e.restSec,
              'kind': e.kind,
              'supersetTag': e.supersetTag,
            }
        ],
      });
    }
    return _json(req.response, 200, {
      'date': fmtDate(today),
      'planName': plan.name,
      'today': days.first,
      'next7': days,
    });
  }

  /// 单个动作的战绩：历史最高（PR）、上次成绩、最近若干组。
  Future<int> _exercise(HttpRequest req) async {
    final name = (req.uri.queryParameters['name'] ?? '').trim();
    if (name.isEmpty) {
      return _json(req.response, 400, {'error': '缺少 name 参数'});
    }
    final limit = _intParam(req, 'limit', fallback: 40, min: 1, max: 2000);
    final last = await db.lastWorkingSets(name);
    final pr = await db.maxWeightOf(name);
    final history = await db.historySets(name, kindFilter: 'working');
    final recent = history.length > limit
        ? history.sublist(history.length - limit)
        : history;
    return _json(req.response, 200, {
      'name': name,
      'prKg': pr,
      'lastSession': [
        for (final x in last)
          {
            'weightKg': x.weightKg,
            'reps': x.reps,
            'rir': x.rir,
            'doneAt': x.doneAt,
          }
      ],
      'historyCount': history.length,
      'history': [
        for (final x in recent)
          {
            'weightKg': x.weightKg,
            'reps': x.reps,
            'rir': x.rir,
            'doneAt': x.doneAt,
          }
      ],
    });
  }

  // ---------- 工具 ----------

  /// 局域网 IPv4 探测：找不到（未连 Wi-Fi）返回空，start 会据此拒绝启动。
  Future<List<String>> probeLocalIps() async {
    try {
      final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      return [
        for (final i in ifaces)
          for (final a in i.addresses) a.address,
      ];
    } on Exception catch (_) {
      return const [];
    }
  }

  String _remoteAddress(HttpRequest req) {
    final info = req.connectionInfo;
    if (info == null) return 'unknown';
    final addr = info.remoteAddress.address;
    // IPv4-mapped IPv6（::ffff:192.168.1.5）在部分 Android 上会出现，
    // 统一成纯 IPv4，令牌按 IP 索引才不会因为写法不同而误判"未配对"。
    return addr.startsWith('::ffff:') ? addr.substring(7) : addr;
  }

  /// 令牌校验：按来源 IP 索引 + 常数时间比较，避免时序侧信道。
  bool _authorize(String addr, String token) {
    final c = _clients[addr];
    if (c == null) return false;
    return _constEq(c.token, token);
  }

  void _markSeen(String addr) => _clients[addr]?.lastSeenAt = DateTime.now();

  String? _bearer(HttpRequest req) {
    final raw = req.headers.value(HttpHeaders.authorizationHeader);
    if (raw != null && raw.startsWith('Bearer ')) {
      final t = raw.substring(7).trim();
      if (t.isNotEmpty) return t;
    }
    // 备用头：某些客户端不方便自定义 Authorization 时用
    final alt = req.headers.value('x-baoji-token');
    return (alt == null || alt.isEmpty) ? null : alt;
  }

  Future<String> _readBody(HttpRequest req) async {
    final text = await utf8.decodeStream(req);
    // 配对请求体极小；超长直接按格式错误处理，避免被人塞大包
    if (text.length > 1024) throw const FormatException('请求体过大');
    return text;
  }

  int _intParam(HttpRequest req, String key,
      {required int fallback, required int min, required int max}) {
    final raw = req.uri.queryParameters[key];
    final v = int.tryParse(raw ?? '') ?? fallback;
    return v.clamp(min, max);
  }

  /// 日期参数只接受 yyyy-MM-dd（防止把奇怪字符串直接拼进 SQL 比较）。
  String _validDate(String raw) {
    final t = DateTime.tryParse(raw);
    if (t == null) throw const FormatException('日期格式应为 yyyy-MM-dd');
    return fmtDate(t);
  }

  String _newPairingCode() {
    final r = Random.secure().nextInt(1000000);
    return r.toString().padLeft(6, '0');
  }

  String _newToken() {
    final r = Random.secure();
    final bytes = List<int>.generate(32, (_) => r.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 常数时间字符串比较（长度不同立刻返回 false，不泄露逐位信息）。
  static bool _constEq(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<int> _json(HttpResponse res, int status, Object body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    res.write(jsonEncode(body));
    return status;
  }

  Future<int> _text(HttpResponse res, int status, String body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType('text', 'markdown', charset: 'utf-8');
    res.write(body);
    return status;
  }

  void _record(String addr, String line, int status) {
    _accessLog.add(BridgeAccessEntry(
      at: DateTime.now(),
      address: addr,
      line: line,
      status: status,
    ));
    while (_accessLog.length > accessLogSize) {
      _accessLog.removeAt(0);
    }
  }
}

/// 已配对设备（对外暴露的只读视图，不含令牌原文）。
class BridgeClient {
  const BridgeClient({
    required this.address,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.userAgent,
  });

  final String address;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final String userAgent;
}

class _BridgeClient {
  _BridgeClient({
    required this.address,
    required this.token,
    required this.userAgent,
  })  : firstSeenAt = DateTime.now(),
        lastSeenAt = DateTime.now();

  final String address;
  final String token;
  final String userAgent;
  final DateTime firstSeenAt;
  DateTime lastSeenAt;

  BridgeClient toPublic() => BridgeClient(
        address: address,
        firstSeenAt: firstSeenAt,
        lastSeenAt: lastSeenAt,
        userAgent: userAgent,
      );
}

/// 一条访问记录（设置页/排障时看"电脑到底连上没、被拒在第几步"）。
class BridgeAccessEntry {
  const BridgeAccessEntry({
    required this.at,
    required this.address,
    required this.line,
    required this.status,
  });

  final DateTime at;
  final String address;
  final String line;
  final int status;
}
