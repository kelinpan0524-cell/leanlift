// 局域网只读数据桥（方案 B，2026-10-17 Arono）的端到端测试。
//
// 这里跑的是**真 socket**：起真 HttpServer、用 HttpClient 发真请求，
// 覆盖"配对 → 令牌 → 只读接口"整条链路，以及三条安全边界：
// 未配对拒绝、配对码错满作废、撤销令牌即时失效；
// 另加空闲自动关闭（堵"开了忘了关"）与只读（无写入口）。
import 'dart:convert';
import 'dart:io';

import 'package:baoji_timer/db/db.dart';
import 'package:baoji_timer/engine/engine.dart';
import 'package:baoji_timer/services/local_bridge.dart';
import 'package:baoji_timer/services/plan_repository.dart';
import 'package:baoji_timer/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // TestWidgetsFlutterBinding 默认给 HttpClient 打桩（一切请求返回 400）。
    // 本套测试要的恰恰是**真 socket**（真服务器 + 真客户端），故解除打桩，
    // 否则测的就不是"局域网能不能连上"，而是一段假的 400。
    HttpOverrides.global = null;
  });

  late Db db;
  late PlanRepository repo;
  late LocalBridgeService bridge;

  /// 造数据：启用中的周计划（今天=推日，含一个动作）+ 两次已完成的卧推训练。
  Future<void> seed() async {
    final plan = await db.insertPlan(Plan(
      name: '测试计划',
      source: 'manual',
      createdAt: '2026-10-01',
    ));
    final today = DateTime.now();
    final dayId = await db.insertPlanDay(PlanDay(
      planId: plan.id!,
      weekday: today.weekday,
      title: '推日',
    ));
    await db.insertPlanExercise(PlanExercise(
      dayId: dayId,
      name: '卧推',
      orderIdx: 0,
      sets: 3,
      repsMin: 5,
      repsMax: 8,
      restSec: 180,
      kind: 'compound',
      rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
    ));

    Future<void> session(DateTime when, List<(double, int)> sets) async {
      final ses = await db.insertSession(Session(
        date: fmtDate(when),
        planDayTitle: '推日',
        startedAt: when.millisecondsSinceEpoch - 3600000,
        endedAt: when.millisecondsSinceEpoch,
        status: 'done',
      ));
      final seId = await db.insertSessionExercise(SessionExercise(
        sessionId: ses.id!,
        name: '卧推',
        orderIdx: 0,
        kind: 'compound',
        rule: ProgressionRule(repsMin: 5, repsMax: 8, workingSets: 3),
      ));
      for (final (w, r) in sets) {
        await db.insertSet(SetEntry(
          sessionExerciseId: seId,
          weightKg: w,
          reps: r,
          rir: 2,
          kind: SetKind.working,
          doneAt: when.millisecondsSinceEpoch,
        ));
      }
    }

    await session(today.subtract(const Duration(days: 3)), [(60, 8)]);
    await session(today.subtract(const Duration(days: 1)), [(65, 8), (65, 8)]);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = await databaseFactory.getDatabasesPath();
    final path =
        '$dir/test_bridge_${DateTime.now().microsecondsSinceEpoch}.db';
    final raw = await databaseFactory.openDatabase(path);
    await Db.instance.createSchema(raw);
    db = Db.forTesting(raw);
    repo = PlanRepository(db, Settings(prefs));
    await seed();
    bridge = LocalBridgeService(
      db: db,
      planRepo: repo,
      port: 0, // 测试用系统分配端口
      ipProbe: () async => const ['127.0.0.1'],
    );
  });

  tearDown(() async {
    await bridge.stop();
    await db.wipeAll();
  });

  /// 直连本机端口发请求（模拟同一局域网的电脑）。
  Future<({int status, String body})> call(
    String method,
    String path, {
    String? token,
    Object? body,
    int? port,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(
          method, Uri.parse('http://127.0.0.1:${port ?? bridge.actualPort}$path'));
      if (token != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      return (status: res.statusCode, body: await utf8.decodeStream(res));
    } finally {
      client.close(force: true);
    }
  }

  /// 走一次配对，返回令牌。
  Future<String> pair() async {
    final res = await call('POST', '/v1/pair', body: {'code': bridge.pairingCode});
    expect(res.status, 200);
    return (jsonDecode(res.body) as Map<String, dynamic>)['token'] as String;
  }

  test('探不到局域网地址时拒绝启动（免得开了没人连得上）', () async {
    final lone = LocalBridgeService(
      db: db,
      port: 0,
      ipProbe: () async => const [],
    );
    expect(await lone.start(), isFalse);
    expect(lone.running, isFalse);
    expect(lone.lastError, isNotNull);
    await lone.stop();
  });

  test('health 免令牌；未配对读受保护接口一律 401', () async {
    expect(await bridge.start(), isTrue);
    final health = await call('GET', '/v1/health');
    expect(health.status, 200);
    expect(jsonDecode(health.body)['api'], LocalBridgeService.apiVersion);

    for (final p in ['/v1/sessions', '/v1/summary', '/v1/today']) {
      final r = await call('GET', p);
      expect(r.status, 401, reason: '$p 未配对时必须拒绝');
    }
    // 伪造令牌同样拒绝
    final fake = await call('GET', '/v1/sessions', token: 'deadbeef');
    expect(fake.status, 401);
  });

  test('配对码错误累加到上限即作废，正确码也不再接受', () async {
    expect(await bridge.start(), isTrue);
    final code = bridge.pairingCode;
    // 前 max-1 次只是拒绝；第 max 次同时触发作废
    for (var i = 0; i < bridge.maxPairAttempts - 1; i++) {
      final r = await call('POST', '/v1/pair', body: {'code': '000000'});
      expect(r.status, 401, reason: '第 ${i + 1} 次错码应只是拒绝');
      expect(bridge.pairingLocked, isFalse);
    }
    final last = await call('POST', '/v1/pair', body: {'code': '000000'});
    expect(last.status, 403);
    expect(bridge.pairingLocked, isTrue);
    // 作废后即使拿对的码也不放行（必须回手机上重新生成）
    final after = await call('POST', '/v1/pair', body: {'code': code});
    expect(after.status, 403);
    // 重新生成后恢复正常
    bridge.regenerateCode();
    expect(bridge.pairingLocked, isFalse);
    final fresh = await call('POST', '/v1/pair', body: {'code': bridge.pairingCode});
    expect(fresh.status, 200);
  });

  test('配对成功后可用令牌读取所有只读接口', () async {
    expect(await bridge.start(), isTrue);
    final token = await pair();
    expect(token.length, 64); // 32 字节 hex
    // 配对成功后旧码立即换新：防止别人拿旧码再配一台
    expect(bridge.pairingCode, isNot(equals('')));

    final sessions = await call('GET', '/v1/sessions?limit=5', token: token);
    expect(sessions.status, 200);
    final sj = jsonDecode(sessions.body) as Map<String, dynamic>;
    expect(sj['count'], 2);
    final first = (sj['sessions'] as List).last as Map<String, dynamic>;
    expect(((first['exercises'] as List).first as Map)['name'], '卧推');

    final summary = await call('GET', '/v1/summary?weeks=8', token: token);
    expect(summary.status, 200);
    expect(summary.body, contains('卧推'));
    expect(summary.body, contains('训练概要'));

    final today = await call('GET', '/v1/today', token: token);
    expect(today.status, 200);
    final tj = jsonDecode(today.body) as Map<String, dynamic>;
    expect(tj['planName'], '测试计划');
    expect((tj['today'] as Map)['title'], '推日');
    expect((tj['next7'] as List).length, 7);

    final ex = await call('GET', '/v1/exercise?name=卧推', token: token);
    expect(ex.status, 200);
    final ej = jsonDecode(ex.body) as Map<String, dynamic>;
    expect(ej['prKg'], 65);
    expect((ej['lastSession'] as List).length, 2);
    expect(ej['historyCount'], 3);

    expect(await call('GET', '/v1/exercise', token: token).then((r) => r.status),
        400);
    expect(
        await call('GET', '/v1/nope', token: token).then((r) => r.status), 404);
  });

  test('只读：任何写方法都被拒（405），不留写入口', () async {
    expect(await bridge.start(), isTrue);
    final token = await pair();
    for (final m in ['POST', 'PUT', 'DELETE', 'PATCH']) {
      final r = await call(m, '/v1/sessions', token: token);
      expect(r.status, 405, reason: '$m 不该被接受');
    }
  });

  test('撤销设备后令牌立即失效', () async {
    expect(await bridge.start(), isTrue);
    final token = await pair();
    expect((await call('GET', '/v1/sessions', token: token)).status, 200);
    expect(bridge.clients.length, 1);
    bridge.revokeClient(bridge.clients.first.address);
    expect((await call('GET', '/v1/sessions', token: token)).status, 401);
  });

  test('无请求超时后自动关闭（堵"开了忘了关"）', () async {
    final quick = LocalBridgeService(
      db: db,
      port: 0,
      ipProbe: () async => const ['127.0.0.1'],
      idleTimeout: const Duration(milliseconds: 250),
      sweepInterval: const Duration(milliseconds: 50),
    );
    expect(await quick.start(), isTrue);
    // 有请求时不关（请求本身把空闲计时顶回去）
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect((await call('GET', '/v1/health', port: quick.actualPort)).status, 200);
    expect(quick.running, isTrue);
    // 静置超过空闲阈值后自动关
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(quick.running, isFalse);
    await quick.stop();
  });

  test('start/stop 幂等，重启会换新配对码并清空令牌', () async {
    expect(await bridge.start(), isTrue);
    final code1 = bridge.pairingCode;
    final token = await pair();
    expect(await bridge.start(), isTrue); // 重复 start 无害
    await bridge.stop();
    expect(bridge.running, isFalse);
    expect(bridge.clients, isEmpty);

    expect(await bridge.start(), isTrue);
    expect(bridge.pairingCode, isNot(equals(code1)));
    expect((await call('GET', '/v1/sessions', token: token)).status, 401);
  });
}
