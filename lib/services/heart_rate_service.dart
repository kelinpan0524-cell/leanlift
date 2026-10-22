import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/db.dart';

/// BLE 连接状态（设置页/休息页 chip 共用的展示口径）。
/// [reconnecting] = 非用户主动断开后正在自动重连：界面显示「重连中」，
/// 不直接掉回「未连接」，避免用户以为设备被忘掉了。
enum HrLink { idle, scanning, connecting, reconnecting, connected }

/// 掉线自动重连退避（2026-10-22）：依次等 1s / 3s / 8s 再试，最多 3 次。
/// 只在「不是用户主动断开」时启用；用户可在设置页手动重连。
const List<Duration> kHrReconnectDelays = [
  Duration(seconds: 1),
  Duration(seconds: 3),
  Duration(seconds: 8),
];

/// 采样落盘节流：每收到一个点，最多每 10 秒把整段曲线追加写一次。
const int kHrPersistGapMs = 10000;

/// 按天分键存已采样的心率曲线（只存本地 prefs，不上传）。
String hrSamplesKeyForDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'hr.samples.${d.year.toString().padLeft(4, '0')}-'
      '${two(d.month)}-${two(d.day)}';
}

/// 序列化当天采样：带 sessionId 指纹，恢复时只认同一场训练，
/// 避免同一天上一场（异常退出残留）的曲线串到新会话里。
String encodeHrSamples(int? sessionId, List<HrPoint> points) => jsonEncode({
  'sid': sessionId,
  'pts': [
    for (final p in points) [p.ts, p.bpm],
  ],
});

/// 反序列化当天采样。json 损坏/结构不对返回 null；sessionId 对不上
/// （或存储里的 sid 为空而调用方有明确 sessionId）也返回 null。
List<HrPoint>? decodeHrSamples(String raw, {int? sessionId}) {
  try {
    final m = jsonDecode(raw);
    if (m is! Map) return null;
    final sid = (m['sid'] as num?)?.toInt();
    if (sessionId != null && sid != sessionId) return null;
    final pts = m['pts'];
    if (pts is! List) return null;
    final out = <HrPoint>[];
    for (final v in pts) {
      if (v is! List || v.length < 2) continue;
      final tsRaw = v[0];
      final bpmRaw = v[1];
      if (tsRaw is! num || bpmRaw is! num) continue;
      final ts = tsRaw.toInt();
      final bpm = bpmRaw.toInt();
      if (ts <= 0 || bpm <= 0 || bpm > 250) continue;
      out.add(HrPoint(ts, bpm));
    }
    return out;
  } catch (_) {
    return null;
  }
}

/// 标准蓝牙心率服务/测量特征（Bluetooth SIG 定义）。
/// 走公开标准 profile：免 bond、免厂商账号，WHOOP 等手环开启
/// 「心率广播」后多 App 可同时读（NOOP 已验证该路径）；不碰
/// NOOP 代码（PolyForm Noncommercial，只复用其验证过的思路）。
final Guid kHrServiceUuid = Guid('180d');
final Guid kHrMeasurementUuid = Guid('2a37');

/// 解析 Heart Rate Measurement 通知（0x2A37）：
/// flags bit0 = 0 逐字节 / 1 逐字（小端）。非法值（0 或 >250）与
/// 短包返回 null（传感器佩戴不良/广播半包时出现，直接丢弃不采样）。
int? parseHeartRate(List<int> v) {
  if (v.isEmpty) return null;
  final wide = (v[0] & 0x01) == 1;
  final int hr;
  if (wide) {
    if (v.length < 3) return null;
    hr = v[1] | (v[2] << 8);
  } else {
    if (v.length < 2) return null;
    hr = v[1];
  }
  if (hr <= 0 || hr > 250) return null;
  return hr;
}

/// 等距抽稀：按序取 n 个代表点（保留峰值位置，不做均值平滑——
/// 心率尖峰对 AI 解析有价值）。points.length <= maxPoints 时原样返回。
List<HrPoint> downsampleHr(List<HrPoint> points, int maxPoints) {
  if (maxPoints <= 0 || points.length <= maxPoints) {
    return List.of(points);
  }
  return [
    for (var i = 0; i < maxPoints; i++)
      points[(i * points.length) ~/ maxPoints],
  ];
}

/// 一段心率采样的汇总（曲线卡头部两格数字用）。
class HrSummary {
  const HrSummary({required this.avg, required this.max, required this.count});
  final double avg;
  final int max;
  final int count;
}

HrSummary? summarizeHr(List<HrPoint> points) {
  if (points.isEmpty) return null;
  var sum = 0;
  var max = 0;
  for (final p in points) {
    sum += p.bpm;
    if (p.bpm > max) max = p.bpm;
  }
  return HrSummary(avg: sum / points.length, max: max, count: points.length);
}

/// AI 心率解析的提示词（纯函数便于单测）；[points] 由调用方先降采样；
/// [loadNote] 为循环负荷摘要（可空，调用方按设置参数算好传入）。
String buildHrAnalysisPrompt(
  List<HrPoint> points, {
  required int durationMin,
  String? loadNote,
}) {
  final t0 = points.isEmpty ? 0 : points.first.ts;
  String fmt(int ts) {
    final s = ((ts - t0) / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  final lines = [for (final p in points) '${fmt(p.ts)} ${p.bpm}'].join('\n');
  final loadLine = (loadNote == null || loadNote.isEmpty) ? '' : '$loadNote\n';
  return '''
你是一名力量训练教练。用户刚完成一场力量训练（时长约 $durationMin 分钟），以下是训练期间的蓝牙心率采样（约每秒一次，已抽稀，格式「分:秒 心率bpm」）：

$loadLine$lines

请用中文输出简短解析，共 4 条要点，每条一行、以「·」开头，依次覆盖：
1. 平均强度与峰值是否合理（可结合循环负荷与区间停留，对照力量训练常见感受）；
2. 组间心率恢复快慢（从中观察恢复能力与休息时长是否匹配）；
3. 异常波动（如持续过高、骤降、佩戴漂移；没有就写"未见异常"）；
4. 一条下次训练的具体建议。
不要寒暄、不要开场白、不要总结标题。''';
}

/// 实时心率服务：标准 BLE Heart Rate profile（0x180D/0x2A37）。
///
/// 职责边界：
/// - 扫描/连接/解析/断线监听都在这里，UI 只读状态与调方法；
/// - 设备记忆直写 prefs（'set.hrId' / 'set.hrName'），不动 Settings；
/// - 采样缓冲：会话活跃窗口（App 容器在训练卡出现/消失时开关）内
///   逐条入内存；每 10 秒最多把当天曲线追加到本地 prefs，进程被杀
///   也能把已采样的部分读回来；会话结束一次性批量落库并清理本地副本；
/// - 掉线自动重连：非用户主动断开时按 1s/3s/8s 退避重连已保存设备，
///   最多 3 次；回到前台时若之前连过则静默补连一次；
/// - 所有失败静默（蓝牙关/权限拒/连接超时）——心率是增强功能，
///   绝不允许任何异常打扰训练主流程。
class HeartRateService extends ChangeNotifier {
  HeartRateService(this._prefs) {
    _savedId = _prefs.getString(_kId);
    _savedName = _prefs.getString(_kName);
  }

  static const _kId = 'set.hrId';
  static const _kName = 'set.hrName';

  final SharedPreferences _prefs;
  String? _savedId;
  String? _savedName;
  BluetoothDevice? _device;
  StreamSubscription? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _recording = false;
  int? _sessionId;
  final List<HrPoint> _samples = [];
  final List<ScanResult> _found = [];
  String lastError = '';

  /// 采样落盘节流：上次写盘（或写盘窗口起点）的墙钟毫秒。
  int _lastPersistMs = 0;

  /// 自动重连：已尝试次数 / 待执行的退避计时器。
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  /// 连接代次：任何用户主动操作（扫描/连接/断开/忘设备）都会 +1，
  /// 在途的旧连接 await 回来后发现代次变了就自行放弃，避免「断开后
  /// 又自己连上」或旧结果覆盖新状态。
  int _linkEpoch = 0;

  /// 用户主动断开（设置页「断开连接」/忘记设备）：不自动重连，
  /// 回到前台也不补连。
  bool _userInitiated = false;

  /// 本进程内成功连接过（用于回前台补连判断；用户主动断开时清零）。
  bool _wasConnected = false;

  bool _disposed = false;

  HrLink _link = HrLink.idle;
  HrLink get link => _link;
  int? _bpm;
  int? get bpm => _bpm;

  /// 最后一次有效读数的墙钟时间（毫秒）；null = 从未读到过。
  int? _bpmAt;

  /// 读数新鲜度窗口：BLE 心率约每秒一跳，超过 10 秒没有新读数，
  /// 说明设备已走远/佩戴异常/广播中断——旧值不能作为休息建议依据
  /// （chip 仍显示最后读数，但建议判定走 [freshBpm]）。
  static const int kFreshBpmWindowMs = 10000;

  /// 新鲜读数：[bpm] 在 [kFreshBpmWindowMs] 内有更新才返回，否则 null。
  int? get freshBpm {
    final b = _bpm;
    final at = _bpmAt;
    if (b == null || at == null) return null;
    if (DateTime.now().millisecondsSinceEpoch - at > kFreshBpmWindowMs) {
      return null;
    }
    return b;
  }

  String? get savedId => _savedId;
  String? get savedName => _savedName;
  List<ScanResult> get found => List.unmodifiable(_found);

  /// 本场已采样的心率点（只读视图）。休息页点心率看消耗时，卡路里/
  /// 负荷直接从这里现算——采样仍按 v13 约定在会话结束时一次性落库。
  List<HrPoint> get samples => List.unmodifiable(_samples);

  void _setLink(HrLink v) {
    if (_disposed || _link == v) return;
    _link = v;
    notifyListeners();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  /// 测试注入：直接设置连接状态与心率读数（不触发任何 BLE 调用）。
  /// 只给 widget 测试模拟「已连接 + 某个 bpm」用，正式代码不要调用。
  /// [atMs] 可指定读数时刻（毫秒 epoch），模拟「旧读数」验新鲜度；缺省 = 现在。
  @visibleForTesting
  void debugSetReading({HrLink link = HrLink.connected, int? bpm, int? atMs}) {
    _link = link;
    _bpm = bpm;
    _bpmAt = bpm == null
        ? null
        : (atMs ?? DateTime.now().millisecondsSinceEpoch);
    _safeNotify();
  }

  /// 测试注入：直接填充采样缓冲（不触发任何 BLE 调用），模拟「本场已
  /// 练了几十分钟」供卡路里/负荷面板测试用。正式代码不要调用。
  @visibleForTesting
  void debugSeedSamples(List<HrPoint> points) {
    _samples
      ..clear()
      ..addAll(points);
    _safeNotify();
  }

  /// 测试注入：走正式采样路径记一个点（含 10 秒落盘节流），
  /// 用于验证「进程被杀后能从 prefs 恢复当天曲线」。
  @visibleForTesting
  Future<void> debugRecordSample(int bpm, {int? atMs}) async {
    final ts = atMs ?? DateTime.now().millisecondsSinceEpoch;
    _bpm = bpm;
    _bpmAt = ts;
    if (_recording) {
      _samples.add(HrPoint(ts, bpm));
      if (ts - _lastPersistMs >= kHrPersistGapMs) {
        _lastPersistMs = ts;
        await _persistSamples();
      }
    }
    _safeNotify();
  }

  // ---------- 设备记忆 ----------

  Future<void> _remember(BluetoothDevice d, String name) async {
    _savedId = d.remoteId.str;
    _savedName = name;
    await _prefs.setString(_kId, _savedId!);
    await _prefs.setString(_kName, name);
    _safeNotify();
  }

  /// 忘记设备：断连并清掉记忆（设置页「忘记设备」用）。
  Future<void> forget() async {
    await disconnect();
    _savedId = null;
    _savedName = null;
    await _prefs.remove(_kId);
    await _prefs.remove(_kName);
    _safeNotify();
  }

  // ---------- 扫描 / 连接 ----------

  /// 是否具备扫描条件（权限 + 蓝牙开）。失败原因写 [lastError]。
  Future<bool> _ensureReady() async {
    if (!Platform.isAndroid) {
      lastError = '当前平台暂不支持（本版本仅 Android）';
      return false;
    }
    final states = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    if (!(states[Permission.bluetoothScan]?.isGranted ?? false) ||
        !(states[Permission.bluetoothConnect]?.isGranted ?? false)) {
      lastError = '蓝牙权限被拒绝，请在系统设置里允许"附近的设备"';
      return false;
    }
    final adapter = await FlutterBluePlus.adapterState.firstWhere(
      (s) => s != BluetoothAdapterState.turningOn,
      orElse: () => BluetoothAdapterState.off,
    );
    if (adapter != BluetoothAdapterState.on) {
      // 尝试代开一次（Android 13+ 需用户在弹窗确认；失败静默交给文案）
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {}
      lastError = '蓝牙未开启，请在下拉栏打开蓝牙';
      return false;
    }
    return true;
  }

  /// 扫描广播标准心率服务的设备（12 秒自动停）。
  Future<void> startScan() async {
    if (_link == HrLink.scanning || _link == HrLink.connecting) return;
    lastError = '';
    // 先确认权限/蓝牙可用，再放弃后台重连：否则用户在「重连中」
    // 打开扫描弹层但权限被拒，会把退避计时器取消掉、状态卡死在重连中。
    if (!await _ensureReady()) {
      _safeNotify();
      return;
    }
    if (_link == HrLink.connected || _link == HrLink.connecting) return;
    // 用户主动开扫 = 放弃后台重连（在途重连也作废，避免抢回连接）。
    _cancelReconnectTimer();
    _linkEpoch++;
    _found.clear();
    _setLink(HrLink.scanning);
    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final i = _found.indexWhere(
          (x) => x.device.remoteId == r.device.remoteId,
        );
        if (i >= 0) {
          _found[i] = r;
        } else {
          _found.add(r);
        }
      }
      _found.sort((a, b) => b.rssi.compareTo(a.rssi));
      _safeNotify();
    });
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 12),
        withServices: [kHrServiceUuid],
      );
    } catch (e) {
      lastError = '扫描失败：$e';
    }
    if (_link == HrLink.scanning) _setLink(HrLink.idle);
    _safeNotify();
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (_link == HrLink.scanning) _setLink(HrLink.idle);
    _safeNotify();
  }

  /// 连接扫描结果里的设备（设置页点列表项）。
  Future<void> connectResult(ScanResult r) async {
    final name = _deviceName(r);
    await stopScan();
    _userInitiated = false;
    await _connect(r.device, name);
  }

  /// 连接已保存的设备（训练开始/恢复会话时自动；设置页手动「重连」）。
  /// 没有保存设备时静默返回；失败静默（训练主流程不受影响）。
  Future<void> connectSaved() async {
    final id = _savedId;
    if (id == null || _link == HrLink.connected || _link == HrLink.connecting) {
      return;
    }
    if (!Platform.isAndroid) return;
    _userInitiated = false;
    _cancelReconnectTimer();
    _reconnectAttempt = 0;
    try {
      await _connect(BluetoothDevice.fromId(id), _savedName ?? id);
    } catch (_) {
      // 自动/手动重连失败保持静默：用户在设置页能看到状态并手动处理
    }
  }

  Future<bool> _connect(
    BluetoothDevice d,
    String name, {
    bool reconnect = false,
  }) async {
    _cancelReconnectTimer();
    final epoch = ++_linkEpoch;
    await _teardown(keepSaved: true, setLink: false);
    if (_disposed || epoch != _linkEpoch) return false;
    _device = d;
    _setLink(reconnect ? HrLink.reconnecting : HrLink.connecting);
    _safeNotify();
    try {
      await d.connect(timeout: const Duration(seconds: 8), autoConnect: false);
      if (epoch != _linkEpoch) {
        await _abortAttempt(d);
        return false;
      }
      // 掉线监听：非用户主动断开 → 自动重连（1s/3s/8s，最多 3 次）。
      _connSub?.cancel();
      _connSub = FlutterBluePlus.events.onConnectionStateChanged
          .where((e) => e.device.remoteId == d.remoteId)
          .listen((e) {
            if (epoch != _linkEpoch) return;
            if (e.connectionState == BluetoothConnectionState.disconnected) {
              unawaited(_handleUnexpectedDisconnect(epoch));
            }
          });
      final services = await d.discoverServices();
      if (epoch != _linkEpoch) {
        await _abortAttempt(d);
        return false;
      }
      BluetoothCharacteristic? chr;
      for (final s in services) {
        for (final c in s.characteristics) {
          if (c.uuid.str.toLowerCase().contains('2a37')) chr = c;
        }
      }
      if (chr == null) {
        lastError = '该设备没有标准心率服务（0x180D）';
        await _teardown(keepSaved: true, setLink: !reconnect);
        return false;
      }
      _notifySub?.cancel();
      _notifySub = chr.lastValueStream.listen((v) {
        if (epoch != _linkEpoch) return;
        final hr = parseHeartRate(v);
        if (hr == null) return;
        _onReading(hr);
      });
      await chr.setNotifyValue(true);
      if (epoch != _linkEpoch) {
        await _abortAttempt(d);
        return false;
      }
      _setLink(HrLink.connected);
      _reconnectAttempt = 0;
      _wasConnected = true;
      _userInitiated = false;
      lastError = '';
      await _remember(d, name);
      return true;
    } catch (e) {
      if (epoch != _linkEpoch) {
        await _abortAttempt(d);
        return false;
      }
      // 自动重连失败不弹错误（静默退避）；手动连接才写可见原因。
      if (!reconnect) {
        lastError = '连接失败，请确认手环已佩戴并在附近';
      }
      await _teardown(keepSaved: true, setLink: !reconnect);
      return false;
    }
  }

  /// 收到一条有效心率：更新读数；记录中则入缓冲并按 10 秒节流落盘。
  void _onReading(int hr) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _bpm = hr;
    _bpmAt = now;
    if (_recording) {
      _samples.add(HrPoint(now, hr));
      if (now - _lastPersistMs >= kHrPersistGapMs) {
        _lastPersistMs = now;
        unawaited(_persistSamples());
      }
    }
    _safeNotify();
  }

  String _deviceName(ScanResult r) {
    final n = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : r.device.platformName;
    return n.isNotEmpty ? n : r.device.remoteId.str;
  }

  /// 用户主动断开：不再自动重连，回前台也不补连。
  Future<void> disconnect() async {
    _userInitiated = true;
    _wasConnected = false;
    _reconnectAttempt = 0;
    _linkEpoch++;
    lastError = '';
    await _teardown();
  }

  /// 非用户主动掉线：清掉旧连接，进入「重连中」并按退避重试。
  /// [epoch] 是掉线时那一代连接；等待断开完成期间用户若已发起新操作
  /// （扫描/手连/断开），代次变化就放弃，不抢回状态。
  Future<void> _handleUnexpectedDisconnect(int epoch) async {
    if (_disposed || epoch != _linkEpoch) return;
    _notifySub?.cancel();
    _notifySub = null;
    _connSub?.cancel();
    _connSub = null;
    final d = _device;
    _device = null;
    _bpm = null;
    _bpmAt = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    if (_disposed || epoch != _linkEpoch) return;
    if (_userInitiated || _savedId == null) {
      _setLink(HrLink.idle);
      return;
    }
    _reconnectAttempt = 0;
    _setLink(HrLink.reconnecting);
    _scheduleNextReconnect();
  }

  /// App 回到前台：之前连过、当前已断开时静默补连一次（不弹任何提示）。
  /// 用户主动断开过的不补连，避免「我刚断开它又自己连上」。
  Future<void> handleAppResumed() async {
    if (_disposed || _userInitiated || _savedId == null || !_wasConnected) {
      return;
    }
    if (_link == HrLink.connected ||
        _link == HrLink.scanning ||
        _link == HrLink.connecting) {
      return;
    }
    _cancelReconnectTimer();
    // 这次补连就是全部动作：失败不继续后台退避，等用户手动重连。
    _reconnectAttempt = kHrReconnectDelays.length;
    final id = _savedId!;
    final ok = await _connect(
      BluetoothDevice.fromId(id),
      _savedName ?? id,
      reconnect: true,
    );
    // 补连失败才掉回未连接；若期间用户已发起扫描/手连，代次已变、
    // 状态归新操作所有，这里不能覆盖。
    if (!ok && !_disposed && _link == HrLink.reconnecting) {
      _reconnectAttempt = 0;
      _setLink(HrLink.idle);
    }
  }

  void _scheduleNextReconnect() {
    if (_disposed || _userInitiated) return;
    if (_savedId == null) {
      _setLink(HrLink.idle);
      return;
    }
    // 用户已经改走扫描/手动连接：自动重连退让，别抢状态。
    if (_link == HrLink.scanning ||
        _link == HrLink.connecting ||
        _link == HrLink.connected) {
      return;
    }
    if (_reconnectAttempt >= kHrReconnectDelays.length) {
      _reconnectAttempt = 0;
      lastError = '设备已断开，自动重连未成功，可在设置里手动重连';
      _setLink(HrLink.idle);
      return;
    }
    final delay = kHrReconnectDelays[_reconnectAttempt++];
    _setLink(HrLink.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      final id = _savedId;
      if (_disposed || _userInitiated || id == null) return;
      unawaited(_runReconnectAttempt(id));
    });
  }

  Future<void> _runReconnectAttempt(String id) async {
    final ok = await _connect(
      BluetoothDevice.fromId(id),
      _savedName ?? id,
      reconnect: true,
    );
    // 只有仍在「重连中」才继续退避；用户已扫描/手连/断开时不抢状态。
    if (!ok && !_disposed && !_userInitiated && _link == HrLink.reconnecting) {
      _scheduleNextReconnect();
    }
  }

  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// 放弃一次在途连接：只有当前 `_device` 仍是它时才清共享订阅，
  /// 避免把用户刚发起的新连接/扫描一起拆掉。
  Future<void> _abortAttempt(BluetoothDevice d) async {
    if (identical(_device, d)) {
      _notifySub?.cancel();
      _notifySub = null;
      _connSub?.cancel();
      _connSub = null;
      _device = null;
    }
    try {
      await d.disconnect();
    } catch (_) {}
  }

  Future<void> _teardown({bool keepSaved = false, bool setLink = true}) async {
    _cancelReconnectTimer();
    _notifySub?.cancel();
    _notifySub = null;
    _connSub?.cancel();
    _connSub = null;
    final d = _device;
    _device = null;
    _bpm = null;
    _bpmAt = null;
    if (setLink) {
      _setLink(HrLink.idle);
    } else {
      _safeNotify();
    }
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    if (!keepSaved) _safeNotify();
  }

  // ---------- 采样（会话活跃窗口内） ----------

  /// 会话开始/恢复：清空内存缓冲，并把当天已落盘的曲线读回来
  /// （进程被杀过也能接上之前的采样）。[sessionId] 作为指纹：
  /// 同一天上一场残留的数据不会串进新会话。
  void startRecording({int? sessionId}) {
    _recording = true;
    _sessionId = sessionId;
    _lastPersistMs = 0;
    _samples.clear();
    _restorePersistedSamples();
    _safeNotify();
  }

  /// 会话结束：停采样（缓冲保留，等 flushSamples 落库）。
  void stopRecording() => _recording = false;

  /// 采样缓冲一次性落库并清空（会话结束时调用；失败静默不阻塞收工）。
  /// 同时清掉当天/昨天的本地副本；若这期间已经开了新会话（sessionId
  /// 已变），只落库不清盘，避免误删新会话刚写入的曲线。
  Future<int> flushSamples(Db db, int sessionId) async {
    // 先取走快照再 await：新会话若在落库期间开始，不会把它的采样一起清掉。
    final toFlush = List.of(_samples);
    _samples.clear();
    final n = toFlush.length;
    try {
      if (n > 0) await db.insertHrSamples(sessionId, toFlush);
    } catch (_) {}
    if (_sessionId == sessionId) {
      _sessionId = null;
      await _clearPersistedSamples();
    }
    _safeNotify();
    return n;
  }

  /// 当天的采样桶 + 前一天：跨零点训练时前半段在昨天键里，恢复时一并读。
  List<String> _sampleKeys() {
    final now = DateTime.now();
    return [
      hrSamplesKeyForDate(DateTime(now.year, now.month, now.day - 1)),
      hrSamplesKeyForDate(now),
    ];
  }

  void _restorePersistedSamples() {
    final merged = <HrPoint>[];
    final seen = <String>{};
    for (final key in _sampleKeys()) {
      final raw = _prefs.getString(key);
      if (raw == null || raw.isEmpty) continue;
      final pts = decodeHrSamples(raw, sessionId: _sessionId);
      if (pts == null) {
        // 旧场次残留/损坏：不读回来，顺手清掉避免下次再猜。
        unawaited(_removePref(key));
        continue;
      }
      for (final p in pts) {
        if (seen.add('${p.ts}|${p.bpm}')) merged.add(p);
      }
    }
    merged.sort((a, b) => a.ts.compareTo(b.ts));
    _samples.addAll(merged);
  }

  Future<void> _persistSamples() async {
    final sid = _sessionId;
    if (sid == null || _disposed) return;
    try {
      await _prefs.setString(
        hrSamplesKeyForDate(DateTime.now()),
        encodeHrSamples(sid, List.of(_samples)),
      );
    } catch (_) {
      // 本地写失败只影响「被杀后补回」，不影响实时采样与结束时落库。
    }
  }

  Future<void> _clearPersistedSamples() async {
    for (final key in _sampleKeys()) {
      await _removePref(key);
    }
  }

  Future<void> _removePref(String key) async {
    try {
      await _prefs.remove(key);
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _linkEpoch++;
    _cancelReconnectTimer();
    _scanSub?.cancel();
    _notifySub?.cancel();
    _connSub?.cancel();
    final d = _device;
    _device = null;
    unawaited(d?.disconnect().catchError((Object e) {}));
    super.dispose();
  }
}
