// 电脑端 MCP 代理的自测：不依赖任何测试框架，直接 `node selftest.mjs`。
//
// 覆盖三件事：
//   1) 工具调用 → 手机接口的映射是否正确（用假 backend 断言 URL/参数/返回值）；
//   2) JSON-RPC 握手与 tools/list 是否符合 MCP 客户端预期；
//   3) 手机没开/未配对时，工具返回的是"可读的错误文本"而不是协议级 error——
//      模型据此能告诉用户"去手机上把开关打开"，而不是看到一串崩溃。
import assert from 'node:assert/strict';
import { rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  callTool,
  createBackend,
  createHandler,
  createReloadingBackend,
} from './baoji-mcp.mjs';

let passed = 0;
function check(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  ✓ ${name}`);
  } catch (e) {
    console.error(`  ✕ ${name}\n    ${e.message}`);
    process.exitCode = 1;
  }
}

async function checkAsync(name, fn) {
  try {
    await fn();
    passed++;
    console.log(`  ✓ ${name}`);
  } catch (e) {
    console.error(`  ✕ ${name}\n    ${e.message}`);
    process.exitCode = 1;
  }
}

/** 假 backend：记录请求，返回预设响应。 */
function fakeBackend(responses = {}) {
  const seen = [];
  return {
    seen,
    base: 'http://fake:8765',
    async request(path, opts = {}) {
      seen.push({ path, params: opts.params || {}, method: opts.method || 'GET' });
      const r = responses[path];
      if (r instanceof Error) throw r;
      return r ?? JSON.stringify({ ok: true });
    },
  };
}

console.log('手机接口映射：');

await checkAsync('get_training_summary 带 weeks 参数打 /v1/summary', async () => {
  const b = fakeBackend({ '/v1/summary': '# 训练概要\n卧推…' });
  const out = await callTool('get_training_summary', { weeks: 12 }, b);
  assert.equal(b.seen[0].path, '/v1/summary');
  assert.equal(b.seen[0].params.weeks, 12);
  assert.match(out, /训练概要/);
});

await checkAsync('list_recent_sessions 透传 limit/from/to', async () => {
  const b = fakeBackend({ '/v1/sessions': '{"count":2,"sessions":[]}' });
  await callTool(
    'list_recent_sessions',
    { limit: 5, from: '2026-10-01', to: '2026-10-17' },
    b,
  );
  assert.deepEqual(b.seen[0].params, {
    limit: 5,
    from: '2026-10-01',
    to: '2026-10-17',
  });
});

await checkAsync('get_today_plan 打 /v1/today 并格式化 JSON', async () => {
  const b = fakeBackend({ '/v1/today': '{"planName":"薄肌","next7":[]}' });
  const out = await callTool('get_today_plan', {}, b);
  assert.equal(b.seen[0].path, '/v1/today');
  assert.match(out, /当前计划与日程：/);
  assert.match(out, /"planName": "薄肌"/); // 已缩进，人/模型都好读
});

await checkAsync('get_exercise_history 必须带 name', async () => {
  const b = fakeBackend({ '/v1/exercise': '{"prKg":100}' });
  await callTool('get_exercise_history', { name: '杠铃卧推', limit: 10 }, b);
  assert.equal(b.seen[0].params.name, '杠铃卧推');
  await assert.rejects(() => callTool('get_exercise_history', {}, b), /name/);
});

await checkAsync('get_exercise_history 透传稳定键 key', async () => {
  const b = fakeBackend({ '/v1/exercise': '{"prKg":100}' });
  await callTool(
    'get_exercise_history',
    { name: '哑铃飞鸟', key: '杠铃卧推', limit: 5 },
    b,
  );
  assert.equal(b.seen[0].params.key, '杠铃卧推');
  assert.equal(b.seen[0].params.name, '哑铃飞鸟');
});

await checkAsync('未知工具名报错', async () => {
  const b = fakeBackend();
  await assert.rejects(() => callTool('nope', {}, b), /未知工具/);
});

console.log('\nMCP 协议：');

await checkAsync('initialize 回 serverInfo 与 tools 能力', async () => {
  const handle = createHandler({ backend: fakeBackend() });
  const res = await handle({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: { protocolVersion: '2024-11-05', clientInfo: { name: 'x' } },
  });
  assert.equal(res.result.serverInfo.name, 'baoji-timer-bridge');
  assert.ok(res.result.capabilities.tools);
  assert.ok(res.result.protocolVersion);
});

await checkAsync('notifications/initialized 不产生响应（通知类）', async () => {
  const handle = createHandler({ backend: fakeBackend() });
  assert.equal(
    await handle({ jsonrpc: '2.0', method: 'notifications/initialized', params: {} }),
    null,
  );
});

await checkAsync('tools/list 返回 4 个工具且 schema 完整', async () => {
  const handle = createHandler({ backend: fakeBackend() });
  const res = await handle({ jsonrpc: '2.0', id: 2, method: 'tools/list' });
  const names = res.result.tools.map((t) => t.name);
  assert.equal(names.length, 4);
  for (const t of res.result.tools) {
    assert.ok(t.description && t.description.length > 10, `${t.name} 缺描述`);
    assert.equal(t.inputSchema.type, 'object');
  }
  assert.ok(names.includes('get_training_summary'));
});

await checkAsync('tools/call 成功返回 content[0].text', async () => {
  const handle = createHandler({
    backend: fakeBackend({ '/v1/today': '{"planName":"薄肌"}' }),
  });
  const res = await handle({
    jsonrpc: '2.0',
    id: 3,
    method: 'tools/call',
    params: { name: 'get_today_plan', arguments: {} },
  });
  assert.equal(res.result.isError, false);
  assert.match(res.result.content[0].text, /薄肌/);
});

await checkAsync('手机连不上时返回 isError+可读原因，而非协议级 error', async () => {
  const backend = fakeBackend({
    '/v1/summary': Object.assign(new Error('手机返回 401：未配对或令牌无效'), {
      status: 401,
    }),
  });
  const handle = createHandler({ backend });
  const res = await handle({
    jsonrpc: '2.0',
    id: 4,
    method: 'tools/call',
    params: { name: 'get_training_summary', arguments: {} },
  });
  assert.equal(res.error, undefined, '不应是协议级 error，模型就看不到原因了');
  assert.equal(res.result.isError, true);
  assert.match(res.result.content[0].text, /401|未配对/);
});

await checkAsync('未知方法与非法请求有恰当处理', async () => {
  const handle = createHandler({ backend: fakeBackend() });
  const r1 = await handle({ jsonrpc: '2.0', id: 5, method: 'foo/bar' });
  assert.equal(r1.error.code, -32601);
  const r2 = await handle({
    jsonrpc: '2.0',
    id: 6,
    method: 'tools/call',
    params: { name: 'unknown_tool', arguments: {} },
  });
  assert.equal(r2.result.isError, true);
});

console.log('\n配置热重读（配对后不必重启 AI 客户端）：');

await checkAsync('createReloadingBackend 每次请求都读最新配置', async () => {
  const cfgPath = join(tmpdir(), `baoji_selftest_${Date.now()}.json`);
  const prevCfgEnv = process.env.BAOJI_BRIDGE_CONFIG;
  process.env.BAOJI_BRIDGE_CONFIG = cfgPath;
  try {
    const calls = [];
    const backend = createReloadingBackend({
      fetchImpl: async (url, opts) => {
        calls.push({ url: String(url), auth: opts.headers.authorization });
        return { ok: true, status: 200, text: async () => '{"ok":1}' };
      },
    });

    // 先写一份配置（模拟第一次 pair）
    writeFileSync(
      cfgPath,
      JSON.stringify({ host: '10.0.0.1', port: 8765, token: 'tok-old' }),
    );
    await backend.request('/v1/health');
    assert.equal(calls[0].url, 'http://10.0.0.1:8765/v1/health');
    assert.equal(calls[0].auth, 'Bearer tok-old');

    // 模拟「手机重新配对」→ 配置文件被改写；不重启进程也该用上新令牌
    writeFileSync(
      cfgPath,
      JSON.stringify({ host: '10.0.0.9', port: 9999, token: 'tok-new' }),
    );
    await backend.request('/v1/today');
    assert.equal(calls[1].url, 'http://10.0.0.9:9999/v1/today');
    assert.equal(calls[1].auth, 'Bearer tok-new');
    assert.equal(backend.base, 'http://10.0.0.9:9999');
  } finally {
    if (prevCfgEnv === undefined) delete process.env.BAOJI_BRIDGE_CONFIG;
    else process.env.BAOJI_BRIDGE_CONFIG = prevCfgEnv;
    try {
      rmSync(cfgPath, { force: true });
    } catch {
      /* 清理失败无所谓 */
    }
  }
});

await checkAsync('配置缺失时给出"先配对"的可读提示', async () => {
  const prevCfgEnv = process.env.BAOJI_BRIDGE_CONFIG;
  process.env.BAOJI_BRIDGE_CONFIG = join(tmpdir(), `baoji_nope_${Date.now()}.json`);
  try {
    const backend = createReloadingBackend({
      fetchImpl: async () => {
        throw new Error('不该走到这里——配置缺失应当先抛错');
      },
    });
    await assert.rejects(() => backend.request('/v1/health'), /pair/);
  } finally {
    if (prevCfgEnv === undefined) delete process.env.BAOJI_BRIDGE_CONFIG;
    else process.env.BAOJI_BRIDGE_CONFIG = prevCfgEnv;
  }
});

await checkAsync('401 时附带"手机开关没开/需重配"的排查提示', async () => {
  const backend = createBackend(
    { host: 'h', port: 1, token: 't' },
    {
      fetchImpl: async () => ({
        ok: false,
        status: 401,
        text: async () => '{"error":"未配对或令牌无效"}',
      }),
    },
  );
  await assert.rejects(() => backend.request('/v1/summary'), /局域网连接|重新.*pair/);
});

console.log('\nHTTP 客户端：');
await checkAsync('请求自动带 Bearer 令牌、参数跳过空值', async () => {
  const calls = [];
  const backend = createBackend(
    { host: '192.168.1.5', port: 8765, token: 'abc123' },
    {
      fetchImpl: async (url, opts) => {
        calls.push({ url: String(url), headers: opts.headers });
        return { ok: true, status: 200, text: async () => '{"ok":1}' };
      },
    },
  );
  await backend.request('/v1/sessions', {
    params: { limit: 5, from: undefined, to: '' },
  });
  assert.equal(calls[0].url, 'http://192.168.1.5:8765/v1/sessions?limit=5');
  assert.equal(calls[0].headers.authorization, 'Bearer abc123');
});

await checkAsync('手机返回非 2xx 时抛出含状态的错误', async () => {
  const backend = createBackend(
    { host: 'h', port: 1, token: 't' },
    {
      fetchImpl: async () => ({
        ok: false,
        status: 403,
        text: async () => '{"error":"配对码连续输错已作废"}',
      }),
    },
  );
  await assert.rejects(
    () => backend.request('/v1/summary'),
    (e) => e.status === 403 && /作废/.test(e.message),
  );
});

console.log(`\n${passed} 项通过${process.exitCode ? '，存在失败' : '，全部通过 ✓'}`);
