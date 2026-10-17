#!/usr/bin/env node
// 薄肌训练计时器 · 局域网数据桥的电脑端 MCP 代理（方案 B）
//
// 手机在局域网里开一个只读 HTTP 服务（App 设置页「局域网连接」），
// 本脚本把那个 HTTP 接口转译成 MCP 工具，接到 Claude Desktop / Cursor 等
// 支持 MCP 的 AI 客户端上——手机当数据源，电脑当 AI 大脑。
//
// 用法：
//   1) 配对（只需一次，配对码看手机设置页）
//      node baoji-mcp.mjs pair --host 192.168.1.5 --port 8765 --code 123456
//   2) 接进 AI 客户端（在 MCP 配置里把本脚本作为 command 启动）
//      node baoji-mcp.mjs serve
//
// 不依赖任何第三方包：HTTP 用 Node 内置 fetch，MCP 走 stdio 上的
// 行分隔 JSON-RPC 2.0（MCP 标准传输之一）。
//
// 环境变量（可选，覆盖配置文件）：
//   BAOJI_BRIDGE_HOST / BAOJI_BRIDGE_PORT / BAOJI_BRIDGE_TOKEN
//   BAOJI_BRIDGE_CONFIG   配置文件路径，默认 ~/.baoji-bridge.json

import { readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createInterface } from 'node:readline';

const API_VERSION = 1;
const SERVER_NAME = 'baoji-timer-bridge';
const SERVER_VERSION = '1.0.0';

// ---------------------------------------------------------------- 配置

export function configPath() {
  return process.env.BAOJI_BRIDGE_CONFIG || join(homedir(), '.baoji-bridge.json');
}

export function loadConfig() {
  let file = {};
  try {
    file = JSON.parse(readFileSync(configPath(), 'utf8'));
  } catch {
    file = {};
  }
  const cfg = {
    host: process.env.BAOJI_BRIDGE_HOST || file.host,
    port: Number(process.env.BAOJI_BRIDGE_PORT || file.port || 0),
    token: process.env.BAOJI_BRIDGE_TOKEN || file.token,
    apiVersion: file.apiVersion,
    pairedAt: file.pairedAt,
  };
  if (!cfg.host || !cfg.port || !cfg.token) {
    throw new Error(
      `还没配对或配置不完整。先运行：\n` +
        `  node ${process.argv[1]} pair --host <手机IP> --port 8765 --code <配对码>\n` +
        `配置文件位置：${configPath()}`,
    );
  }
  if (cfg.apiVersion && cfg.apiVersion !== API_VERSION) {
    process.stderr.write(
      `[baoji] 警告：手机端接口版本 v${cfg.apiVersion} 与本代理 v${API_VERSION} 不一致，` +
        `请升级两端后重新配对。\n`,
    );
  }
  return cfg;
}

function saveConfig(cfg) {
  writeFileSync(configPath(), JSON.stringify(cfg, null, 2) + '\n', { mode: 0o600 });
}

// ---------------------------------------------------------------- HTTP 客户端

export function createBackend(cfg, { fetchImpl = fetch } = {}) {
  const base = `http://${cfg.host}:${cfg.port}`;
  const defaultToken = cfg.token;
  return {
    base,
    async request(path, { params, method = 'GET', body, token } = {}) {
      const url = new URL(base + path);
      for (const [k, v] of Object.entries(params || {})) {
        if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, String(v));
      }
      const headers = { accept: 'application/json, text/markdown' };
      // 配对成功后令牌随配置常驻，serve 模式下每个请求自动带上
      const tok = token ?? defaultToken;
      if (tok) headers.authorization = `Bearer ${tok}`;
      if (body) headers['content-type'] = 'application/json';
      const res = await fetchImpl(url, {
        method,
        headers,
        body: body ? JSON.stringify(body) : undefined,
        signal: AbortSignal.timeout(30000),
      });
      const text = await res.text();
      if (!res.ok) {
        let msg = text;
        try {
          msg = JSON.parse(text).error || text;
        } catch {
          /* 保持原文 */
        }
        const err = new Error(`手机返回 ${res.status}：${msg}`);
        err.status = res.status;
        throw err;
      }
      return text;
    },
  };
}

// ---------------------------------------------------------------- 工具定义

const TOOLS = [
  {
    name: 'get_training_summary',
    description:
      '获取手机里最近若干周的力量训练数据包（Markdown）：训练概要、每次训练明细、' +
      '各动作累计容量、身体数据。适合做整体趋势分析、阶段复盘、发现停滞动作。',
    inputSchema: {
      type: 'object',
      properties: {
        weeks: {
          type: 'integer',
          description: '回溯周数，默认 8，范围 1-52',
          minimum: 1,
          maximum: 52,
        },
      },
    },
  },
  {
    name: 'list_recent_sessions',
    description:
      '列出训练记录明细（结构化 JSON）：日期、训练日标题、时长、主观自评、' +
      '每个动作的目标与实际各组（重量/次数/余力 RIR）。用于查看具体某几次练了什么。',
    inputSchema: {
      type: 'object',
      properties: {
        limit: {
          type: 'integer',
          description: '取最近多少次训练，默认 20，范围 1-500',
          minimum: 1,
          maximum: 500,
        },
        from: { type: 'string', description: '起始日期 yyyy-MM-dd（与 to 一起用）' },
        to: { type: 'string', description: '结束日期 yyyy-MM-dd（与 from 一起用）' },
      },
    },
  },
  {
    name: 'get_today_plan',
    description:
      '获取当前使用中的训练计划与未来 7 天安排：今天练什么（含动作、组数、次数区间、' +
      '休息秒数），以及后续几天的训练日/休息日。',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'get_exercise_history',
    description:
      '获取单个动作的战绩：历史最高重量（PR）、上次训练的全部正式组、以及历史正式组序列。' +
      '用于判断某个动作是否该加重、最近是否停滞。',
    inputSchema: {
      type: 'object',
      properties: {
        name: {
          type: 'string',
          description: '动作名称，需与 App 里的叫法一致，例如「杠铃卧推」',
        },
        limit: {
          type: 'integer',
          description: '历史组返回条数上限，默认 40',
          minimum: 1,
          maximum: 2000,
        },
      },
      required: ['name'],
    },
  },
];

/** 工具名 → 手机接口。抽出来便于单测（selftest.mjs 直接调它）。 */
export async function callTool(name, args, backend) {
  switch (name) {
    case 'get_training_summary': {
      const text = await backend.request('/v1/summary', {
        params: { weeks: args?.weeks },
      });
      return text;
    }
    case 'list_recent_sessions': {
      const text = await backend.request('/v1/sessions', {
        params: { limit: args?.limit, from: args?.from, to: args?.to },
      });
      return `训练记录：\n${pretty(text)}`;
    }
    case 'get_today_plan': {
      const text = await backend.request('/v1/today');
      return `当前计划与日程：\n${pretty(text)}`;
    }
    case 'get_exercise_history': {
      const n = (args?.name || '').trim();
      if (!n) throw new Error('必须提供动作名称 name');
      const text = await backend.request('/v1/exercise', {
        params: { name: n, limit: args?.limit },
      });
      return `动作「${n}」的战绩：\n${pretty(text)}`;
    }
    default:
      throw new Error(`未知工具：${name}`);
  }
}

function pretty(text) {
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    return text;
  }
}

// ---------------------------------------------------------------- MCP 服务

/**
 * 单个 JSON-RPC 消息 → 响应（通知类返回 null，不响应）。
 * 与传输层解耦，selftest 可直接喂消息进来断言。
 */
export function createHandler({ backend, protocolVersion = '2024-11-05' } = {}) {
  return async function handle(msg) {
    const { id, method, params } = msg || {};
    const isNotification = id === undefined || id === null;
    switch (method) {
      case 'initialize':
        return ok(id, {
          protocolVersion: params?.protocolVersion || protocolVersion,
          capabilities: { tools: {} },
          serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        });
      case 'notifications/initialized':
      case 'notifications/cancelled':
        return null;
      case 'ping':
        return isNotification ? null : ok(id, {});
      case 'tools/list':
        return ok(id, { tools: TOOLS });
      case 'tools/call': {
        // MCP 要求工具名在 params.name；参数在 params.arguments
        const toolName = params?.name;
        if (!TOOLS.some((t) => t.name === toolName)) {
          return ok(id, toolResult(`未知工具：${toolName}`, true));
        }
        try {
          const text = await callTool(toolName, params?.arguments, backend);
          return ok(id, toolResult(text, false));
        } catch (e) {
          // 返回 isError 而不是 JSON-RPC error：模型能看到具体原因（未配对/手机没开）
          return ok(id, toolResult(`读取失败：${e.message}`, true));
        }
      }
      default:
        if (isNotification) return null;
        return err(id, -32601, `不支持的方法：${method}`);
    }
  };
}

const ok = (id, result) => ({ jsonrpc: '2.0', id, result });
const err = (id, code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });
const toolResult = (text, isError) => ({
  content: [{ type: 'text', text }],
  isError,
});

/** stdio 传输：逐行 JSON-RPC（MCP 标准 stdio 传输格式）。 */
export async function serveStdio(backend) {
  const handle = createHandler({ backend });
  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of rl) {
    const raw = line.trim();
    if (!raw) continue;
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      process.stderr.write(`[baoji] 忽略无法解析的消息：${raw.slice(0, 200)}\n`);
      continue;
    }
    try {
      const res = await handle(msg);
      if (res) process.stdout.write(JSON.stringify(res) + '\n');
    } catch (e) {
      if (msg && msg.id != null) {
        process.stdout.write(
          JSON.stringify(err(msg.id, -32603, String(e && e.message))) + '\n',
        );
      }
    }
  }
}

// ---------------------------------------------------------------- CLI

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const val = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : 'true';
      out[key] = val;
    } else {
      out._.push(a);
    }
  }
  return out;
}

async function cmdPair(argv) {
  const a = parseArgs(argv);
  const host = a.host;
  const port = Number(a.port || 8765);
  const code = a.code;
  if (!host || !code) {
    throw new Error('用法：node baoji-mcp.mjs pair --host <手机IP> --port 8765 --code <配对码>');
  }
  const backend = createBackend({ host, port });
  const body = await backend.request('/v1/pair', {
    method: 'POST',
    body: { code: String(code) },
  });
  const { token } = JSON.parse(body);
  saveConfig({
    host,
    port,
    token,
    apiVersion: API_VERSION,
    pairedAt: new Date().toISOString(),
  });
  process.stdout.write(
    `配对成功 ✓\n  手机：http://${host}:${port}\n  令牌已保存到 ${configPath()}\n` +
      `接下来把本脚本接到 AI 客户端：\n` +
      `  {"command":"node","args":["${process.argv[1]}","serve"]}\n`,
  );
}

async function cmdStatus() {
  const cfg = loadConfig();
  const backend = createBackend(cfg);
  const text = await backend.request('/v1/health');
  process.stdout.write(`手机在线 ✓ ${backend.base}\n${text}\n`);
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  switch (cmd) {
    case 'pair':
      await cmdPair(rest);
      break;
    case 'status':
      await cmdStatus();
      break;
    case 'serve': {
      const cfg = loadConfig();
      await serveStdio(createBackend(cfg));
      break;
    }
    default:
      process.stdout.write(
        '薄肌训练计时器 · 局域网数据桥（MCP 代理）\n\n' +
          '  node baoji-mcp.mjs pair   --host <手机IP> --port 8765 --code <配对码>\n' +
          '  node baoji-mcp.mjs status\n' +
          '  node baoji-mcp.mjs serve\n\n' +
          '手机上：设置 → 连接与智能 → 局域网连接 → 开启。\n',
      );
  }
}

// 被 import 时不执行 CLI（selftest 依赖这一点）
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => {
    process.stderr.write(`[baoji] ${e.message}\n`);
    process.exit(1);
  });
}
