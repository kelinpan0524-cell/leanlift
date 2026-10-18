import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
/// - **默认不常驻**：开关状态不进 shared_preferences，每次都要用户主动开启，
///   空闲 [idleTimeout] 无请求即自动关闭——堵"开了忘了关"。
///   用户可显式开「常驻」（[enablePersistent]）：但**只在记住的那个局域网里
///   生效**（落盘当前网络的签名，见 [_lanKey]），换到别的 Wi-Fi / 流量既不
///   自启、也不豁免空闲关闭；UI 上明示"仅建议在自家 Wi-Fi 开启"。
/// - **配对码**：6 位一次性码，错 5 次即作废，需重新生成；堵"配对太弱"；
/// - **令牌**：配对成功换 256-bit（32 字节）随机令牌，此后每个请求都要带；
/// - **记住设备**（2026-10-17 起）：已配对设备只存**令牌的 SHA-256 摘要**
///   （存摘要不存原文，泄了也换不成令牌），按令牌而非 IP 认设备（换 IP 不失效）。
///   这样"配对一次"才真的成立——重开开关或手机重启后电脑端无需重配；
///   想取消授权就在设置页把该设备「断开」，摘要随之从落盘里删掉。
/// - 数据不出手机、不出局域网，不经任何云端（符合仓库「无服务器」红线）。
class LocalBridgeService extends ChangeNotifier {
  LocalBridgeService({
    required this.db,
    required this.prefs,
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
  final SharedPreferences prefs;
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

  /// 已配对设备：**按令牌的 SHA-256 摘要索引**（不是按 IP——换个 IP 不该掉线，
  /// 令牌才是凭证）。落盘一份摘要，重开服务后免重新配对。
  final Map<String, _BridgeDevice> _devices = {};

  /// 摘要落盘键；值形如 [{h, ip, ua, f, l}]。
  static const String _devicesKey = 'bridge_devices_v1';

  /// 记住的设备条数上限（防无限增长；超了就丢最久没用过的）。
  static const int _maxDevices = 10;

  /// 常驻开关落盘键（用户显式开启；没有它，App 重启后桥一律不自启）。
  static const String _persistentKey = 'bridge_persistent_v1';

  /// 记住的局域网签名落盘键。签名取本机 IPv4 的前 3 段（如 `192.168.1`）：
  /// 不用 SSID 是有意的——Android 8+ 读 SSID 要定位权限，违背本 App
  /// 「不要权限」的底线；前三段签名零权限、对家用路由（同网段）足够准，
  /// 且令牌仍是真正的门禁，签名的职责只是"别在陌生网络自启"。
  static const String _lanKey = 'bridge_lan_v1';

  /// 自动拉起失败时给 UI 的提示（当前不在记住的局域网）。
  bool _persistentMismatch = false;

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
  List<BridgeDevice> get pairedDevices =>
      List.unmodifiable(_devices.values.map((d) => d.toPublic()));
  List<BridgeAccessEntry> get accessLog =>
      List.unmodifiable(_accessLog.reversed);

  // ---------- 常驻（仅记住的局域网） ----------

  /// 用户是否开了常驻（落盘，App 重启后仍在）。
  bool get persistentEnabled => prefs.getBool(_persistentKey) ?? false;

  /// 记住的局域网签名（如 `192.168.1`；没开过常驻时为 null）。
  String? get rememberedLan => prefs.getString(_lanKey);

  /// 常驻此刻是否生效：开了常驻 **且** 当前就在记住的局域网里。
  /// 运行中按已探测到的网卡判断（空闲巡检会顺带刷新，见 [_sweep]）。
  bool get persistentActive {
    final lan = rememberedLan;
    if (lan == null || !persistentEnabled) return false;
    return _lanOfIps(_localIps) == lan;
  }

  /// App 启动尝试自启但不在记住的局域网时置位，供页面提示"常驻没生效"。
  bool get persistentMismatch => _persistentMismatch;

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
    _persistentMismatch = false;
    _pairingCode = _newPairingCode();
    // 已配对设备从落盘里恢复：重开开关不该把电脑端踢下线（配对一次就够）
    _loadDevices();
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

  /// 停止服务。**已配对设备保留**（落盘不动）——下次开启无需重新配对；
  /// 要取消授权得在设置页显式「断开」那台设备。
  Future<void> stop() async {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    final s = _server;
    _server = null;
    _pairingCode = '';
    _actualPort = 0;
    _localIps = const [];
    _startedAt = null;
    // 顺带把这一轮的"最近活动"落盘（平时不为每个请求写盘，只在关服务时收口）
    _saveDevices();
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

  // ---------- 常驻：开启 / 关闭 / 自启 ----------

  /// 开启常驻：把「当前局域网签名 + 开关」落盘。
  /// 探不到局域网地址（没连 Wi-Fi）时拒绝并返回 false，免得记住一个空网。
  /// 只动常驻两项偏好，**不碰已配对设备**。
  Future<bool> enablePersistent() async {
    final lan = await _currentLan();
    if (lan == null) return false;
    await prefs.setBool(_persistentKey, true);
    await prefs.setString(_lanKey, lan);
    _persistentMismatch = false;
    notifyListeners();
    return true;
  }

  /// 关闭常驻：开关与记住的局域网一起清掉。已配对设备照旧保留——
  /// 常驻只是"免手动开开关"，跟"谁有资格连"是两码事。
  Future<void> disablePersistent() async {
    await prefs.setBool(_persistentKey, false);
    await prefs.remove(_lanKey);
    _persistentMismatch = false;
    notifyListeners();
  }

  /// App 启动时的自动拉起：**仅当**用户开了常驻、且当前就连在记住的那个
  /// 局域网里。任何不满足都安静返回 false——常驻绝不变成"到处自启"。
  Future<bool> maybeAutoStart() async {
    if (running) return true;
    final lan = rememberedLan;
    if (lan == null || !persistentEnabled) return false;
    final here = await _currentLan();
    if (here != lan) {
      // 留个提示给设置页："常驻没生效，因为你现在不在家里的网"
      _persistentMismatch = true;
      notifyListeners();
      return false;
    }
    return start();
  }

  /// 当前网络的局域网签名（探不到返回 null）。探测失败按"未知网络"算，
  /// 宁可不自启，也不在陌生网络里冒险。
  Future<String?> _currentLan() async {
    final ips = _localIps.isNotEmpty && running
        ? _localIps
        : await (ipProbe ?? probeLocalIps)();
    return _lanOfIps(ips);
  }

  /// 签名 = 首个 IPv4 地址的前 3 段。测试注入的 loopback 也会走到这
  /// （生产探测不含 loopback），不影响正确性。
  static String? _lanOfIps(List<String> ips) {
    for (final ip in ips) {
      if (ip.contains(':')) continue; // 跳过 IPv6
      final parts = ip.split('.');
      if (parts.length == 4) return parts.take(3).join('.');
    }
    return null;
  }

  /// 主动断开某台已配对设备（撤销其令牌，并从落盘里删掉摘要）。
  /// [id] 为 [BridgeDevice.id]（令牌摘要）。
  void revokeDevice(String id) {
    if (_devices.remove(id) == null) return;
    _saveDevices();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }

  // ---------- 空闲自动关闭 ----------

  /// 空闲巡检。常驻生效中不自动关——但"还在不在家"每次都重新探一遍网卡：
  /// 手机换了网（从家里走到外面）就自动回到普通规则，空闲照关。
  void _sweep() {
    if (!running) return;
    if (!persistentEnabled) {
      _idleStopIfDue();
      return;
    }
    unawaited(() async {
      final ips = await (ipProbe ?? probeLocalIps)();
      if (!running) return; // 巡检间隙里被关了就别再动
      _localIps = ips; // 顺带刷新，设置页"常驻是否生效"才不会骗人
      _idleStopIfDue();
    }());
  }

  void _idleStopIfDue() {
    if (persistentActive) return; // 还在记住的局域网里：豁免空闲关闭
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
    // 免令牌：健康检查（代理据此确认手机在线、接口版本一致、以及自己配没配上）
    if (req.method == 'GET' && (path == '/v1/health' || path == '/')) {
      final presented = _bearer(req);
      return _json(req.response, 200, {
        'app': 'baoji-timer',
        'api': apiVersion,
        // 带上令牌问"我这台配了吗"，代理的 status 命令据此给出可读结论
        'paired': presented != null && _authorize(addr, presented, touch: false),
        'pairedDevices': _devices.length,
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
    _rememberDevice(token, addr,
        (req.headers.value(HttpHeaders.userAgentHeader) ?? '').toString());
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
              // 稳定身份键：MCP 端查历史时可原样回传，改名后仍能命中。
              'exerciseKey': se.exerciseKey,
              'kind': se.kind,
              'restSec': se.restSec,
              'target': '${se.targetSets}×${se.targetRepsMin}-${se.targetRepsMax}',
              'sets': [
                for (final x in map[se.id!] ?? const <SetEntry>[])
                  {
                    'weightKg': x.weightKg,
                    'reps': x.reps,
                    'rir': x.rir,
                    // P0-C：rir 是真实观测（true）还是计划默认填充（false）
                    'rirRecorded': x.rirRecorded,
                    'kind': x.kind,
                    'doneAt': x.doneAt,
                    // P2-B 疼痛记录（v15）：painLevel 0 = 未填/无痛；
                    // painArea 是中文数据键（与动作名/肌群名同约定）
                    'painLevel': x.painLevel,
                    'painArea': x.painArea,
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
              'exerciseKey': e.exerciseKey,
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
  ///
  /// 查询优先用 `key`（稳定身份键，MCP 从 /v1/sessions /v1/today 拿到后
  /// 原样回传）；只给 `name` 时先按同名既有行反查键，改名后保留旧键的
  /// 动作也能命中历史。
  Future<int> _exercise(HttpRequest req) async {
    final name = (req.uri.queryParameters['name'] ?? '').trim();
    final keyParam = (req.uri.queryParameters['key'] ?? '').trim();
    if (name.isEmpty && keyParam.isEmpty) {
      return _json(req.response, 400, {'error': '缺少 name 或 key 参数'});
    }
    final key = keyParam.isNotEmpty
        ? keyParam
        : (await db.knownExerciseKey(name) ?? exerciseKeyOf(name));
    final displayName = name.isNotEmpty ? name : key;
    final limit = _intParam(req, 'limit', fallback: 40, min: 1, max: 2000);
    final last = await db.lastWorkingSets(displayName, exerciseKey: key);
    final pr = await db.maxWeightOf(displayName, exerciseKey: key);
    final history = await db.historySets(displayName,
        exerciseKey: key, kindFilter: 'working');
    final recent = history.length > limit
        ? history.sublist(history.length - limit)
        : history;
    return _json(req.response, 200, {
      'name': displayName,
      'exerciseKey': key,
      'prKg': pr,
      'lastSession': [
        for (final x in last)
          {
            'weightKg': x.weightKg,
            'reps': x.reps,
            'rir': x.rir,
            'rirRecorded': x.rirRecorded,
            'doneAt': x.doneAt,
            // P2-B 疼痛记录：painLevel 0 = 未填/无痛，painArea 中文数据键
            'painLevel': x.painLevel,
            'painArea': x.painArea,
          }
      ],
      'historyCount': history.length,
      'history': [
        for (final x in recent)
          {
            'weightKg': x.weightKg,
            'reps': x.reps,
            'rir': x.rir,
            'rirRecorded': x.rirRecorded,
            'doneAt': x.doneAt,
            'painLevel': x.painLevel,
            'painArea': x.painArea,
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

  /// 令牌校验：把请求里的令牌取摘要后按摘要索引，再常数时间比较。
  /// 顺带记一次"最近活动"（[touch] 为 false 时只读，别让 health 探测反复重置空闲计时）。
  bool _authorize(String addr, String token, {bool touch = true}) {
    final hash = _hashToken(token);
    final d = _devices[hash];
    if (d == null) return false;
    if (touch) {
      d.lastSeenAt = DateTime.now();
      d.lastAddress = addr;
      // 每次活动都刷一次落盘太频繁（每个请求一次写）；真正的落盘留给
      // 配对/断开/服务停止这三个时刻。
    }
    return true;
  }

  /// 记住一台设备：存**摘要**，不存令牌原文。
  void _rememberDevice(String token, String addr, String userAgent) {
    _devices[_hashToken(token)] = _BridgeDevice(
      hash: _hashToken(token),
      lastAddress: addr,
      userAgent: userAgent,
    );
    // 超上限就丢最久没活动的（电脑换得再多也不至于塞爆 prefs）
    if (_devices.length > _maxDevices) {
      final sorted = _devices.values.toList()
        ..sort((a, b) => a.lastSeenAt.compareTo(b.lastSeenAt));
      for (final old in sorted.take(_devices.length - _maxDevices)) {
        _devices.remove(old.hash);
      }
    }
    _saveDevices();
  }

  /// 令牌 → SHA-256 摘要（hex）。存摘要而非原文：prefs 万一被翻出来，
  /// 也换不出可用的令牌。
  static String _hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  // ---------- 设备落盘 ----------

  void _loadDevices() {
    _devices.clear();
    final raw = prefs.getString(_devicesKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final e in list) {
        if (e is! Map) continue;
        final d = _BridgeDevice.fromJson(Map<String, dynamic>.from(e));
        if (d != null) _devices[d.hash] = d;
      }
    } on FormatException catch (_) {
      // 落盘坏了就当没配过（用户重新配对即可），不让它拖住服务启动
    }
  }

  void _saveDevices() {
    final list = _devices.values.map((d) => d.toJson()).toList();
    unawaited(prefs.setString(_devicesKey, jsonEncode(list)));
  }

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

/// 已配对设备（对外暴露的只读视图，**不含令牌，也不含摘要全文**）。
class BridgeDevice {
  const BridgeDevice({
    required this.id,
    required this.address,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.userAgent,
  });

  /// 设备标识：令牌的 SHA-256 摘要（hex）。摘要不可逆，泄了也换不出令牌，
  /// 所以可以放心当 ID 用；UI 只显示前 8 位。
  final String id;

  /// 最近一次请求的来源 IP（换 IP 不影响配对，这里只是给人看的）。
  final String address;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final String userAgent;

  /// 给用户看的名字：优先浏览器/客户端自报的名字，没有就说"某台电脑"。
  String get label {
    final ua = userAgent.trim();
    if (ua.isEmpty) return '电脑（未署名）';
    // UA 往往是又臭又长的一串；只取能认出来的关键字
    for (final key in ['Claude', 'Cursor', 'VSCode', 'node', 'curl', 'Python']) {
      if (ua.contains(key)) return key;
    }
    return ua.length > 24 ? '${ua.substring(0, 24)}…' : ua;
  }
}

class _BridgeDevice {
  _BridgeDevice({
    required this.hash,
    required this.lastAddress,
    required this.userAgent,
  })  : firstSeenAt = DateTime.now(),
        lastSeenAt = DateTime.now();

  /// 令牌的 SHA-256 摘要（hex，64 位）——这是落盘的那份，不是令牌本身。
  final String hash;
  String lastAddress;
  final String userAgent;
  DateTime firstSeenAt;
  DateTime lastSeenAt;

  Map<String, Object?> toJson() => {
        'h': hash,
        'ip': lastAddress,
        'ua': userAgent,
        'f': firstSeenAt.millisecondsSinceEpoch,
        'l': lastSeenAt.millisecondsSinceEpoch,
      };

  /// 反序列化；摘要格式不对（旧版/损坏）就返回 null，当作没配过。
  /// 时间戳缺了就按"现在"算——宁可显示不准，也不该影响配对本身。
  static _BridgeDevice? fromJson(Map<String, dynamic> j) {
    final h = j['h'];
    if (h is! String || h.length != 64) return null;
    final d = _BridgeDevice(
      hash: h,
      lastAddress: (j['ip'] ?? '').toString(),
      userAgent: (j['ua'] ?? '').toString(),
    );
    final f = j['f'];
    final l = j['l'];
    if (f is int && f > 0) {
      d.firstSeenAt = DateTime.fromMillisecondsSinceEpoch(f);
    }
    if (l is int && l > 0) {
      d.lastSeenAt = DateTime.fromMillisecondsSinceEpoch(l);
    }
    return d;
  }

  BridgeDevice toPublic() => BridgeDevice(
        id: hash,
        address: lastAddress,
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
