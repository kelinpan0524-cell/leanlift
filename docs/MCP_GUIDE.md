# 让 AI 读你的训练记录（局域网 MCP 教程）

> 面向**第一次做这件事**的人：从零开始，手机端 + 电脑端一步步跟下来即可。
> 全程不需要服务器、不需要账号、不需要把数据传到任何云端。
>
> For first-timers: follow along step by step, phone side and computer side.
> No server, no account, no data leaving your Wi-Fi.

**这套东西在干什么？** 手机把你的训练记录（计划、历史、重量、PR、身体数据）在自家
Wi-Fi 里以一个**只读**接口开放出来，电脑上一个小脚本把它转成 AI 客户端能懂的 MCP，
于是你就能直接问 AI：「我最近卧推是不是停滞了？」「下周该练什么？」
—— 手机当数据源，电脑当 AI 大脑，数据不出你的局域网。

**总共要做的事**：装 Node.js → 手机开开关 → 电脑配对一次 → 电脑填一次配置。
做完之后，日常使用只需要「手机点一下开关」。

---

## 0. 先看清前提（1 分钟）

| 需要 | 说明 |
| --- | --- |
| 一台 Android 手机 | 装的是本 App（薄肌训练计时器），版本包含「局域网连接」功能 |
| 一台电脑 | macOS / Windows / Linux 都行，能装 Node.js |
| 同一个 Wi-Fi | **手机和电脑连的是同一个路由器**（手机别用蜂窝流量） |
| Node.js | 18 以上，推荐 20 或更高（第 1 步装） |
| 一个支持 MCP 的 AI 客户端 | Claude Desktop（本教程主推）或 Cursor |

**两个概念先记住，后面就顺了**：

- **配对码**：手机上显示的 6 位数字。只在**第一次**让某台电脑接入时用一次。
- **已配对设备**：配过之后手机会记住它（只记一段不可逆的摘要，不记令牌原文），
  所以以后重开开关不用再配。

---

## 1. 电脑上装 Node.js（只需一次）

**先检查有没有**：打开「终端」（macOS）或「命令提示符 / PowerShell」（Windows），输入：

```bash
node --version
```

- 显示 `v20.x.x` 之类 → 已经装好，跳到第 2 步。
- 显示「command not found」或「不是内部或外部命令」→ 接着往下装。

**安装**：去 <https://nodejs.org/> 下载 LTS 版本（左边那个按钮），一路默认下一步即可。
装完**新开一个终端窗口**再跑一次 `node --version` 确认。

> 为什么需要 Node？电脑端那个把数据转给 AI 的小脚本（`baoji-mcp.mjs`）是 Node 写的，
> 它不依赖任何第三方包，装了 Node 就能直接跑。

---

## 2. 拿到电脑端脚本（只需一次）

脚本在仓库里：`tools/mcp-bridge/baoji-mcp.mjs`。选一种方式拿到它：

**方式 A：已经克隆了仓库**（推荐，以后好更新）

```bash
git clone https://github.com/kelinpan0524-cell/leanlift.git
cd leanlift
```

**方式 B：只想下载这一个文件**

浏览器打开
<https://github.com/kelinpan0524-cell/leanlift/blob/main/tools/mcp-bridge/baoji-mcp.mjs>，
点右上角 **Raw** → 右键「另存为」存到任意文件夹（例如 `~/mcp`）。

下面命令里的路径按你的实际情况替换。**下面的示例假设你在仓库目录里。**

---

## 3. 手机端：开开关（每次用之前做，30 秒）

1. 打开 App → **设置** → **连接与智能** → **局域网连接**
2. 打开「**开启局域网连接**」开关
3. 记下页面上两样东西（**别关这个页面，一会儿要抄配对码**）：
   - **地址**：形如 `http://192.168.1.5:8765` —— 冒号前那段就是手机 IP
   - **配对码**：6 位数字，形如 `482913`

> **手机没连 Wi-Fi 时开不起来**：页面会提示「未找到局域网地址」。先连上 Wi-Fi 再开。
>
> **10 分钟没人用会自动关**（防止你忘了关）。这是有意的：关掉后电脑就够不着数据了。
> 重新要用就再来这一步——但因为手机会记住已配对的电脑，**这次不用再抄配对码、不用再配对**。
> 嫌每次手动开麻烦？看第 7 步的「**常驻模式**」：可以在自家 Wi-Fi 里让它自动开启。

---

## 4. 电脑端：配对（只需一次）

在第 2 步的目录里，把三处占位换成你自己的值：手机 IP、端口、配对码。

```bash
node tools/mcp-bridge/baoji-mcp.mjs pair --host 192.168.1.5 --port 8765 --code 482913
```

成功会打印：

```
配对成功 ✓
  手机：http://192.168.1.5:8765
  令牌已保存到 /Users/你的名字/.baoji-bridge.json
接下来把本脚本接到 AI 客户端： ...
```

**看到「配对成功 ✓」就说明手机端和电脑端已经通了。**

随时可以体检一下当前状态（推荐做，能提前发现 90% 的问题）：

```bash
node tools/mcp-bridge/baoji-mcp.mjs status
```

期望输出里有「这台电脑：已配对 ✓」。若显示未配对，回到第 3 步确认手机开关是开的。

---

## 5. 电脑端：接进 AI 客户端（只需一次）

### 5.1 Claude Desktop

**macOS**：编辑配置文件

```
~/Library/Application Support/Claude/claude_desktop_config.json
```

**Windows**：编辑

```
%APPDATA%\Claude\claude_desktop_config.json
```

（找不到文件就自己新建一个；`%APPDATA%` 一般是
`C:\Users\你的名字\AppData\Roaming`。）

在里面加上 `baoji-timer` 这一段（**路径换成你自己的绝对路径**）：

```json
{
  "mcpServers": {
    "baoji-timer": {
      "command": "node",
      "args": ["/Users/你的名字/leanlift/tools/mcp-bridge/baoji-mcp.mjs", "serve"]
    }
  }
}
```

如果文件里已经有 `mcpServers`（比如你接过别的 MCP），就把 `baoji-timer` 加进那个对象里，
**别把原有的覆盖掉**。

> Windows 路径要写成 `C:\\Users\\你的名字\\leanlift\\tools\\mcp-bridge\\baoji-mcp.mjs`（双反斜杠）。

**保存后彻底退出 Claude Desktop 再打开**（macOS：Cmd+Q；Windows：托盘右键退出），
不是关窗口——MCP 配置只在启动时读取。

打开后对话框右下角的工具按钮里应能看到 4 个 `baoji` 工具。

### 5.2 Cursor（可选）

Cursor → 设置 → **MCP** → Add new MCP server，填：

- Name：`baoji-timer`
- Type：`command`
- Command：`node /Users/你的名字/leanlift/tools/mcp-bridge/baoji-mcp.mjs serve`

保存后 Cursor 会自行拉起这个进程。

### 5.3 其他客户端

任何支持 MCP 的客户端都一样：**command = `node`，args = [脚本绝对路径, `serve`]**。
它的通信走标准 stdio，不需要端口、不需要网络配置。

---

## 6. 验证一下（1 分钟）

1. 回到手机，确认「局域网连接」开关**是开的**（10 分钟没动会自动关）
2. 在 AI 客户端里新开一个对话，问：

   > 用 baoji 工具看看我最近的训练记录，我这周练了几次？

3. 期望：AI 调用了 `baoji` 工具并念出你的真实数据（训练日、动作、重量）。

同时，手机上「局域网连接」页面的**「最近请求」**里会出现一条来自你电脑 IP 的记录。
这条记录是排障利器：**有记录 = 电脑连上了手机**（问题在电脑侧配置）；
**没记录 = 电脑根本没连上**（问题在网络或手机开关）。

---

## 7. 日常使用（配好之后）

1. 手机：设置 → 连接与智能 → 局域网连接 → 打开开关（**不用再配对**）
2. 电脑：直接问 AI（**不用重启 Claude/Cursor**，脚本每次请求都会重读配置）

就这两步。手机 10 分钟没人用会自动关，想省事就让它开着——用的时候再点一下。

### 7.1 更省事：常驻模式（可选，仅建议家里 Wi-Fi 开）

在手机的「局域网连接」页面打开「**常驻模式**」，手机会**记住当前这个局域网**：

- 以后只要 App 在运行、且连着**这个** Wi-Fi，桥就自动开启，也不会 10 分钟自动关
- 换到别的 Wi-Fi 或流量：**不会自动开启**（页面会提示「不在记住的局域网」）；就算手动开了，也会回到 10 分钟自动关
- 开关下面的风险提示是认真的：**仅建议在自家的 Wi-Fi 开**——家用路由器后面就你自己的设备；公司 / 咖啡馆 / 公共网络一律别开
- 「常驻」只是免掉手动开开关，跟「谁有资格连」（配对令牌）是两码事：已配对的电脑不受影响，没配对的照样进不来
- 想关掉随时关（关闭常驻不影响正在跑的服务）；App 从最近任务划掉则一切即刻停止

---

## 8. 常见问题（第一次做基本都会碰到）

**AI 说读不到数据 / 报 401，未配对或令牌无效**

按顺序查：

1. 手机上开关是不是开着？（默认不常驻，重开 App 后要再点一次；若开了「常驻模式」，确认手机连的还是**记住的那个** Wi-Fi，页面会提示常驻有没有生效）
2. 电脑跑 `node tools/mcp-bridge/baoji-mcp.mjs status`：
   - 「手机在线 ✓」+「已配对 ✓」→ 手机侧正常，问题在客户端配置（第 5 步的路径/JSON）
   - 「手机在线 ✓」+「未配对」→ 手机侧把这台电脑忘了（可能你点过「断开」），
     回第 3 步抄新配对码，再跑一次 `pair`
   - **连不上 / 超时** → 电脑根本连不到手机（见下一条）
3. 手机上「最近请求」有没有记录？没记录说明请求都没到达手机。

**电脑连不上手机（status 就超时）**

按可能性从高到低查：

1. **手机和电脑不是同一个 Wi-Fi**：手机连的是"5G 蜂窝"或另一个频段/另一个 SSID 都会不通。
2. **手机 IP 变了**：路由器给手机重新分了 IP。手机上重新开一次开关，把新的 IP 告诉电脑：
   `node tools/mcp-bridge/baoji-mcp.mjs pair --host <新IP> --port 8765 --code <新配对码>`
   （换 IP 不影响已配对身份，但代理要知道新地址）
3. **路由器开了「AP 隔离」/「访客网络隔离」**：常见于公共 Wi-Fi、部分家用路由的访客网络。
   同一个 Wi-Fi 下的设备互相都看不见，这种网络下本功能用不了——换回主网络。
4. **Windows 防火墙**：首次运行可能弹窗询问是否允许 Node 联网，选「允许」。
   没弹过就手动检查：Windows 安全中心 → 防火墙 → 允许应用通过。
5. **手机开了「客户端隔离」的省电/安全类 App**：某些安全软件会拦局域网访问，临时关掉试试。

**手机锁屏一会儿就连不上了**

手机进入深度睡眠时可能暂停后台网络。解决：把 App 加入系统「电池优化白名单」
（App 内首次启动时的权限引导里有这一项），或使用期间让手机屏幕亮着、插着电。

**配对码输错 5 次被作废了**

正常，这是防暴力猜的机制。回到手机点「**换一个**」拿新码，重新 `pair` 即可。

**手机上看到「已配对的设备」里有一台陌生电脑**

点它右边的「**断开**」撤销授权，然后点「换一个」换配对码，防止别人再配进来。
日常也别让配对码在别人面前长时间停留。

**我想彻底不用这个功能**

手机：设置 → 局域网连接 → 关闭开关（或把已配对设备逐个「断开」）。
电脑：删掉 `~/.baoji-bridge.json`，并从 AI 客户端配置里删掉 `baoji-timer` 那一节。
删完手机侧也就没有入口了——这个功能默认关闭，不开就完全不存在。

**它会不会偷偷把我的数据传出去？**

不会。四条边界是写进代码并有测试守着的：

- **只读**：不响应任何写入，改不了计划、删不了记录
- **默认不常驻**：开关不进设置，每次都要你手动开；空闲 10 分钟自动关。可在家用 Wi-Fi 开「常驻」，但它只在记住的那个局域网内生效，换网立即失效
- **凭证**：6 位一次性配对码换 256 位随机令牌；手机会记住的只是**令牌的不可逆摘要**
- **不出网**：手机只在你自己的 Wi-Fi 里应答，不经任何云端（App 也没有服务器）

---

## 附：四个工具分别能读到什么

| 工具 | 你问 AI 什么时它会被用到 | 读到的东西 |
| --- | --- | --- |
| `get_training_summary` | 「我最近训练什么趋势？」 | 近 N 周训练概要、每次明细、各动作累计容量、身体数据 |
| `list_recent_sessions` | 「上周三我练了什么？」 | 日期、训练日、时长、自评、每个动作的目标与实际各组 |
| `get_today_plan` | 「我明天该练什么？」 | 当前计划与未来 7 天安排（动作、组数、次数、休息） |
| `get_exercise_history` | 「我卧推停滞了吗？」 | 某动作历史最高（PR）、上次成绩、历史组序列 |

英文版见下方 —— English version below.

---

# Making Your Workout Data Readable by AI (LAN MCP Guide)

> For first-timers: follow along step by step, phone side and computer side.
> No server, no account, no data leaving your Wi-Fi.

**What this does:** the phone exposes your workout records (plan, history, weights, PRs,
body metrics) as a **read-only** endpoint on your own Wi-Fi; a small script on your
computer turns it into MCP so your AI client can read it. You can then ask:
"Is my bench press stalling?" — phone as the data source, computer as the AI brain.

**Total work:** install Node.js → flip the switch on the phone → pair once → configure
your AI client once. After that, daily use is just "tap the switch on the phone".

## 0. Prerequisites

- An Android phone with this app (the build that includes **LAN Connection**)
- A computer (macOS / Windows / Linux) able to install Node.js **20+**
- Phone and computer on the **same Wi-Fi** (phone not on cellular)
- An MCP-capable client: **Claude Desktop** (recommended) or Cursor

**Pairing code**: the 6 digits shown on the phone. Used **once**, when a computer first
connects. **Paired devices**: the phone remembers them (only an irreversible digest of the
token, never the token itself), so re-opening the switch needs no re-pairing.

## 1. Install Node.js on the computer (once)

```bash
node --version     # already v20+? skip to step 2
```

Otherwise install the LTS build from <https://nodejs.org/>, then open a **new** terminal
window and check again.

## 2. Get the proxy script (once)

```bash
git clone https://github.com/kelinpan0524-cell/leanlift.git
cd leanlift
```

Or download just
[tools/mcp-bridge/baoji-mcp.mjs](https://github.com/kelinpan0524-cell/leanlift/blob/main/tools/mcp-bridge/baoji-mcp.mjs).
It needs no third-party packages.

## 3. Phone: turn the switch on (each time you use it, ~30s)

Settings → Connections → **LAN Connection** → enable. Note the **address**
(`http://192.168.1.5:8765` — the part before `:` is the phone IP) and the **6-digit code**.

It stops itself after 10 idle minutes — that is deliberate. Re-opening needs no re-pairing.
Tired of flipping the switch each time? See **Keep-alive** in section 7 (home Wi-Fi only).

## 4. Computer: pair (once)

```bash
node tools/mcp-bridge/baoji-mcp.mjs pair --host 192.168.1.5 --port 8765 --code 482913
node tools/mcp-bridge/baoji-mcp.mjs status
```

Look for `配对成功 ✓` and `这台电脑：已配对 ✓`.

## 5. Computer: register with your AI client (once)

**Claude Desktop** — edit `~/Library/Application Support/Claude/claude_desktop_config.json`
(macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "baoji-timer": {
      "command": "node",
      "args": ["/absolute/path/to/leanlift/tools/mcp-bridge/baoji-mcp.mjs", "serve"]
    }
  }
}
```

Then **fully quit and relaunch** the client (Cmd+Q — closing the window is not enough).

**Cursor**: Settings → MCP → Add new MCP server → Type `command` →
`node /absolute/path/to/leanlift/tools/mcp-bridge/baoji-mcp.mjs serve`.

## 6. Verify

Phone switch on → ask your AI: *"Use the baoji tools and tell me what I trained this week."*
The phone's **Recent requests** list should show an entry from your computer.
Entry present = the computer reached the phone; no entry = networking/switch problem.

## 7. Daily use

Turn the switch on (no re-pairing) → ask your AI (no client restart — the script re-reads
its config on every request).

### 7.1 Optional: keep-alive (home Wi-Fi only)

On the phone's LAN Connection page enable **Keep-alive**; the phone remembers *this*
network:

- While the app runs inside **that** Wi-Fi, the bridge auto-starts and never idle-stops
- On any other Wi-Fi or mobile data it **never auto-starts** (the page says so), and a
  manually started bridge goes back to the 10-minute idle stop
- The warning under the switch is serious: enable it on your **home** network only —
  never on office / café / public networks
- Keep-alive only spares you the switch flip; pairing tokens still guard the data
- Turning keep-alive off doesn't touch a running bridge; swiping the app away stops
  everything immediately

## 8. Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| 401 "unpaired or invalid token" | Switch off on phone → turn it on (keep-alive users: confirm the phone is on the **remembered** network). Then run `status`: if it says not paired, re-run `pair` with a fresh code. |
| `status` times out | Phone and computer on different Wi-Fi; phone IP changed (re-run `pair` with the new IP); router "AP isolation"/guest network (switch to the main network); Windows firewall blocking Node. |
| Works, then stops after a while | Phone deep sleep — whitelist the app from battery optimization, or keep the screen on. |
| Code voided | Five wrong tries void it by design. Tap **New code** on the phone and pair again. |
| Unknown computer listed | Tap **Revoke** and rotate the code. |
| Want it gone entirely | Switch off / revoke all on the phone; delete `~/.baoji-bridge.json`; remove the `baoji-timer` block from your client config. |

**Privacy:** read-only (no write path at all), not persistent by default (you enable it
each time and it auto-stops after 10 idle minutes; the optional keep-alive is bound to one
remembered network and never auto-starts elsewhere), credentials are a one-time 6-digit
code exchanged for a 256-bit token whose digest — not the token — is what the phone
remembers, and nothing ever leaves your local network.

## Tools exposed

| Tool | Reads |
| --- | --- |
| `get_training_summary` | Recent weeks overview, per-session detail, per-exercise volume, body metrics |
| `list_recent_sessions` | Date, day title, duration, self-rating, target vs. actual sets |
| `get_today_plan` | Current plan and the next 7 days (exercises, sets, reps, rest) |
| `get_exercise_history` | PR, last session, full working-set history for one exercise |
