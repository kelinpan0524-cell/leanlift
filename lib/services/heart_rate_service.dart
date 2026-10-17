import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/db.dart';

/// BLE 连接状态（设置页/休息页 chip 共用的展示口径）。
enum HrLink { idle, scanning, connecting, connected }

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
String buildHrAnalysisPrompt(List<HrPoint> points,
    {required int durationMin, String? loadNote}) {
  final t0 = points.isEmpty ? 0 : points.first.ts;
  String fmt(int ts) {
    final s = ((ts - t0) / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  final lines = [
    for (final p in points) '${fmt(p.ts)} ${p.bpm}',
  ].join('\n');
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
///   逐条入内存，会话结束一次性批量落库 hr_sample 表；
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
  final List<HrPoint> _samples = [];
  final List<ScanResult> _found = [];
  String lastError = '';

  HrLink _link = HrLink.idle;
  HrLink get link => _link;
  int? _bpm;
  int? get bpm => _bpm;
  String? get savedId => _savedId;
  String? get savedName => _savedName;
  List<ScanResult> get found => List.unmodifiable(_found);

  void _setLink(HrLink v) {
    if (_link == v) return;
    _link = v;
    notifyListeners();
  }

  // ---------- 设备记忆 ----------

  Future<void> _remember(BluetoothDevice d, String name) async {
    _savedId = d.remoteId.str;
    _savedName = name;
    await _prefs.setString(_kId, _savedId!);
    await _prefs.setString(_kName, name);
    notifyListeners();
  }

  /// 忘记设备：断连并清掉记忆（设置页「忘记设备」用）。
  Future<void> forget() async {
    await disconnect();
    _savedId = null;
    _savedName = null;
    await _prefs.remove(_kId);
    await _prefs.remove(_kName);
    notifyListeners();
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
    final adapter = await FlutterBluePlus.adapterState
        .firstWhere((s) => s != BluetoothAdapterState.turningOn,
            orElse: () => BluetoothAdapterState.off);
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
    if (!await _ensureReady()) {
      notifyListeners();
      return;
    }
    _found.clear();
    _setLink(HrLink.scanning);
    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final i = _found.indexWhere(
            (x) => x.device.remoteId == r.device.remoteId);
        if (i >= 0) {
          _found[i] = r;
        } else {
          _found.add(r);
        }
      }
      _found.sort((a, b) => b.rssi.compareTo(a.rssi));
      notifyListeners();
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
    notifyListeners();
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (_link == HrLink.scanning) _setLink(HrLink.idle);
    notifyListeners();
  }

  /// 连接扫描结果里的设备（设置页点列表项）。
  Future<void> connectResult(ScanResult r) async {
    final name = _deviceName(r);
    await stopScan();
    await _connect(r.device, name);
  }

  /// 连接已保存的设备（训练开始/恢复会话时自动；设置页手动「重连」）。
  /// 没有保存设备时静默返回；失败静默（训练主流程不受影响）。
  Future<void> connectSaved() async {
    final id = _savedId;
    if (id == null || _link == HrLink.connected) return;
    if (!Platform.isAndroid) return;
    try {
      await _connect(BluetoothDevice.fromId(id), _savedName ?? id);
    } catch (_) {
      // 自动重连失败保持静默：用户在设置页能看到状态并手动处理
    }
  }

  Future<void> _connect(BluetoothDevice d, String name) async {
    await _teardown(keepSaved: true);
    _device = d;
    _setLink(HrLink.connecting);
    notifyListeners();
    try {
      await d.connect(timeout: const Duration(seconds: 8), autoConnect: false);
      // 掉线监听：训练中手环关掉/走出范围 → 回到未连接，不自动重连
      // （保守策略：避免休眠耗电与半死连接，用户回设置页一键重连）。
      _connSub?.cancel();
      _connSub = FlutterBluePlus
          .events.onConnectionStateChanged
          .where((e) => e.device.remoteId == d.remoteId)
          .listen((e) {
        if (e.connectionState == BluetoothConnectionState.disconnected) {
          unawaited(_teardown());
        }
      });
      final services = await d.discoverServices();
      BluetoothCharacteristic? chr;
      for (final s in services) {
        for (final c in s.characteristics) {
          if (c.uuid.str.toLowerCase().contains('2a37')) chr = c;
        }
      }
      if (chr == null) {
        lastError = '该设备没有标准心率服务（0x180D）';
        await _teardown();
        return;
      }
      _notifySub?.cancel();
      _notifySub = chr.lastValueStream.listen((v) {
        final hr = parseHeartRate(v);
        if (hr == null) return;
        _bpm = hr;
        if (_recording) {
          _samples.add(
              HrPoint(DateTime.now().millisecondsSinceEpoch, hr));
        }
        notifyListeners();
      });
      await chr.setNotifyValue(true);
      _setLink(HrLink.connected);
      lastError = '';
      await _remember(d, name);
    } catch (e) {
      lastError = '连接失败，请确认手环已佩戴并在附近';
      await _teardown();
    }
  }

  String _deviceName(ScanResult r) {
    final n = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : r.device.platformName;
    return n.isNotEmpty ? n : r.device.remoteId.str;
  }

  Future<void> disconnect() => _teardown();

  Future<void> _teardown({bool keepSaved = false}) async {
    _notifySub?.cancel();
    _notifySub = null;
    _connSub?.cancel();
    _connSub = null;
    final d = _device;
    _device = null;
    _bpm = null;
    _setLink(HrLink.idle);
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    if (!keepSaved) notifyListeners();
  }

  // ---------- 采样（会话活跃窗口内） ----------

  /// 会话开始：清空缓冲并开始采样（App 容器在训练卡出现时调用）。
  void startRecording() {
    _samples.clear();
    _recording = true;
  }

  /// 会话结束：停采样（缓冲保留，等 flushSamples 落库）。
  void stopRecording() => _recording = false;

  /// 采样缓冲一次性落库并清空（会话结束时调用；失败静默不阻塞收工）。
  Future<int> flushSamples(Db db, int sessionId) async {
    if (_samples.isEmpty) return 0;
    final n = _samples.length;
    try {
      await db.insertHrSamples(sessionId, List.of(_samples));
      _samples.clear();
    } catch (_) {}
    return n;
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _notifySub?.cancel();
    _connSub?.cancel();
    unawaited(_device?.disconnect().catchError((Object e) {}));
    super.dispose();
  }
}
