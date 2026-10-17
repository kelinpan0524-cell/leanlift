import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/lang.dart';
import '../services/local_bridge.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 局域网连接（方案 B，2026-10-17 Arono）：手机当只读数据源，
/// 电脑上的 AI（Claude 等）通过 MCP 代理读训练数据。
///
/// 交互原则：开关默认不落盘（每次主动开）、空闲自动关、只读、配对了才认令牌；
/// 「常驻」是显式例外——只在用户记住的那个局域网里生效（见服务层注释）。
/// 页面把「地址 + 配对码 + 谁连上了」三件事摊在一屏，用户不用去翻日志。
class LocalBridgePage extends StatefulWidget {
  const LocalBridgePage({super.key});

  @override
  State<LocalBridgePage> createState() => _LocalBridgePageState();
}

class _LocalBridgePageState extends State<LocalBridgePage> {
  /// 完整教程（仓库里 docs/MCP_GUIDE.md 的 GitHub 渲染页）。
  /// 不在 App 内置全文：教程会随小白反馈迭代，链接过去总能看到最新版。
  static const String _guideUrl =
      'https://github.com/kelinpan0524-cell/leanlift/blob/main/docs/MCP_GUIDE.md';

  LocalBridgeService? _bridge;
  Timer? _tick;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bridge = app(context).bridge;
    // 每秒重刷一次：让「剩余 X 分钟自动关闭」真的在走字。
    // 只在本页可见且服务在跑时重刷，未开启时零开销。
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (_bridge?.running ?? false)) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _toggle(LocalBridgeService b, bool on) async {
    if (!on) {
      final ok = await confirmDialog(
        context,
        tx('关闭局域网连接？', en: 'Turn off LAN connection?'),
        tx('已配对的电脑会立即断开，但手机仍记住它们，下次开启不用重新配对。',
            en: 'Paired computers are disconnected now but stay remembered — no re-pairing next time.'),
      );
      if (!ok) return;
      await b.stop();
      return;
    }
    final ok = await b.start();
    if (!ok && mounted) {
      toast(context, b.lastError ?? tx('启动失败', en: 'Failed to start'));
    }
  }

  /// 常驻开关：开启前必须过一遍风险提示（仅建议家用 Wi-Fi）；
  /// 关闭只清常驻两项，不动正在跑的服务、也不动已配对设备。
  Future<void> _togglePersistent(LocalBridgeService b, bool on) async {
    if (!on) {
      await b.disablePersistent();
      return;
    }
    final ok = await confirmDialog(
      context,
      tx('在这个局域网开启常驻？', en: 'Enable keep-alive on this network?'),
      tx('仅建议在自家的 Wi-Fi（家庭局域网）开启。开启后：只要 App 在运行且连着这个局域网，服务就自动开启、不会空闲自动关闭；换到别的网络不生效。已配对的电脑无需重新配对。',
          en: 'Recommended for your home Wi-Fi only. While the app runs inside this remembered network the bridge auto-starts and never idle-stops; other networks are ignored. Paired computers stay paired.'),
    );
    if (!ok) return;
    final done = await b.enablePersistent();
    if (!done) {
      if (mounted) {
        toast(context,
            tx('未找到局域网地址（请先连上 Wi-Fi）', en: 'No LAN address (connect to Wi-Fi first)'));
      }
      return;
    }
    // 用户既然开了常驻，当下多半就想用：顺手把服务拉起来
    if (!b.running) {
      final started = await b.start();
      if (!started && mounted) {
        toast(context, b.lastError ?? tx('启动失败', en: 'Failed to start'));
      }
    }
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    toast(context, tx('已复制$what', en: 'Copied $what'));
  }

  @override
  Widget build(BuildContext context) {
    final b = app(context).bridge;
    return ListenableBuilder(
      listenable: b,
      builder: (context, _) => Scaffold(
        backgroundColor: AppTheme.bg,
        appBar: AppBar(title: Text(tx('局域网连接', en: 'LAN Connection'))),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _introCard(),
              const SizedBox(height: 16),
              _switchCard(b),
              const SizedBox(height: 12),
              _persistentCard(b),
              if (b.running) ...[
                const SizedBox(height: 16),
                _connectionCard(b),
                const SizedBox(height: 16),
                _howToCard(),
                const SizedBox(height: 16),
                _clientsCard(b),
                const SizedBox(height: 16),
                _logCard(b),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _introCard() {
    return SectionCard(
      title: tx('这台手机当作数据源', en: 'Use this phone as a data source'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _bullet(tx('手机在局域网内开一个只读服务，电脑上的 AI 通过 MCP 代理读训练数据。',
              en: 'The phone serves your workout data read-only over your Wi-Fi; an AI assistant on your computer reads it through a small MCP proxy.')),
          _bullet(tx('只读：不响应任何写入，改不了计划、也删不了记录。',
              en: 'Read-only: nothing can be written back — plans and records stay untouched.')),
          _bullet(tx('不经过任何服务器：数据始终留在手机和局域网内。',
              en: 'No server involved: data never leaves the phone and your local network.')),
          _bullet(tx('默认不常驻：每次都要在这里手动开启；无请求 10 分钟自动关闭。',
              en: 'Not persistent by default: you turn it on here each time, and it stops itself after 10 idle minutes.')),
          _bullet(tx('可选「常驻」：只在你记住的局域网（建议家里 Wi-Fi）内自动开启、不自动关；换网不生效。',
              en: 'Optional keep-alive: auto-starts only inside the remembered network (home Wi-Fi recommended); other networks are ignored.')),
          _bullet(tx('配对一次就够：电脑配好之后会被记住，以后再开开关不用重配（想取消就点下面的「断开」）。',
              en: 'Pair once: a computer that has paired is remembered, so re-opening the switch needs no re-pairing (revoke it below anytime).')),
        ],
      ),
    );
  }

  Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 6, right: 8),
              child: Icon(Icons.circle, size: 6, color: AppTheme.textDim),
            ),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      color: AppTheme.textDim, fontSize: 13, height: 1.45)),
            ),
          ],
        ),
      );

  Widget _switchCard(LocalBridgeService b) {
    return SectionCard(
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: b.running,
        onChanged: (on) => _toggle(b, on),
        activeThumbColor: AppTheme.primary,
        title: Text(
          tx('开启局域网连接', en: 'Enable LAN connection'),
          style: const TextStyle(
              color: AppTheme.text, fontSize: 15.5, fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          b.running
              ? tx('运行中 · 端口 ${b.actualPort}',
                  en: 'Running · port ${b.actualPort}')
              : tx('关闭中', en: 'Off'),
          style: TextStyle(
              color: b.running ? AppTheme.primary : AppTheme.textDim,
              fontSize: 12.5),
        ),
      ),
    );
  }

  /// 常驻模式卡：显式开关 + 风险提示（仅家用 Wi-Fi）+ 不在记住局域网时的横幅。
  Widget _persistentCard(LocalBridgeService b) {
    final enabled = b.persistentEnabled;
    final lan = b.rememberedLan ?? '';
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: enabled,
            onChanged: (on) => _togglePersistent(b, on),
            activeThumbColor: AppTheme.primary,
            title: Text(
              tx('常驻模式', en: 'Keep-alive'),
              style: const TextStyle(
                  color: AppTheme.text,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              enabled
                  ? tx('已记住这个局域网（$lan.x）',
                      en: 'Remembered network: $lan.x')
                  : tx('关闭 · 开启后在这个局域网内自动连接、不自动关',
                      en: 'Off · auto-connects inside this network, never idle-stops'),
              style: TextStyle(
                  color: enabled ? AppTheme.primary : AppTheme.textDim,
                  fontSize: 12.5),
            ),
          ),
          Text(
            tx('仅建议在自家的 Wi-Fi 开启：常驻只对记住的这个局域网生效，连到其他 Wi-Fi 或流量时不会自动开启。App 从最近任务划掉即彻底停止。',
                en: 'Home Wi-Fi only: keep-alive applies solely to the remembered network; it never auto-starts on other Wi-Fi or mobile data. Swipe the app away to stop it for good.'),
            style: const TextStyle(
                color: AppTheme.warn, fontSize: 11.5, height: 1.45),
          ),
          // 两种"没生效"各说各话：跑着但换了网 / 启动时就不在家
          if (b.running && enabled && !b.persistentActive) ...[
            const SizedBox(height: 8),
            Text(
              tx('当前网络不是记住的那个局域网，常驻没生效（这次按空闲自动关闭）。',
                  en: 'Not on the remembered network — keep-alive is inactive (idle auto-stop applies).'),
              style:
                  const TextStyle(color: AppTheme.warn, fontSize: 12),
            ),
          ] else if (!b.running && enabled && b.persistentMismatch) ...[
            const SizedBox(height: 8),
            Text(
              tx('启动 App 时你不在记住的局域网，这次没有自动开启。',
                  en: 'You were not on the remembered network at startup — not auto-started this time.'),
              style:
                  const TextStyle(color: AppTheme.warn, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _connectionCard(LocalBridgeService b) {
    final mins = b.remainingUntilAutoStop.inMinutes;
    return SectionCard(
      title: tx('连接信息', en: 'Connection'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv(
            tx('地址', en: 'Address'),
            b.endpointHint,
            onCopy: () => _copy(b.endpointHint, tx('地址', en: 'address')),
          ),
          if (b.localIps.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                tx('其他网卡：${b.localIps.skip(1).join('、')}',
                    en: 'Other interfaces: ${b.localIps.skip(1).join(', ')}'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 11.5),
              ),
            ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tx('配对码', en: 'Pairing code'),
                        style: const TextStyle(
                            color: AppTheme.textDim, fontSize: 12.5)),
                    const SizedBox(height: 2),
                    Text(
                      b.pairingLocked
                          ? tx('已作废', en: 'Voided')
                          : b.pairingCode,
                      style: TextStyle(
                        color:
                            b.pairingLocked ? AppTheme.danger : AppTheme.primary,
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 6,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: b.regenerateCode,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(tx('换一个', en: 'New code')),
              ),
            ],
          ),
          Text(
            tx('配对码只在电脑第一次接入时用一次；配好后手机就把这台电脑记住了，以后重开开关不用再配。',
                en: 'The code is used only the first time a computer connects; the phone remembers it, so re-opening the switch needs no re-pairing.'),
            style: const TextStyle(color: AppTheme.textDim, fontSize: 11.5),
          ),
          const Divider(height: 24, color: AppTheme.cardHi),
          Text(
            b.persistentActive
                ? tx('常驻生效中：不会自动关闭（App 划掉即停）',
                    en: 'Keep-alive active: no idle stop (stops when the app is swiped away)')
                : tx('无请求 ${mins >= 1 ? '$mins 分钟' : '不到 1 分钟'}后自动关闭',
                    en: 'Stops automatically in ${mins >= 1 ? '$mins min' : 'under 1 min'}'),
            style: TextStyle(
                color: b.persistentActive ? AppTheme.primary : AppTheme.warn,
                fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _kv(String label, String value, {VoidCallback? onCopy}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(label,
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12.5)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    color: AppTheme.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600)),
          ),
          if (onCopy != null)
            IconButton(
              onPressed: onCopy,
              icon: const Icon(Icons.copy, size: 18, color: AppTheme.textDim),
              tooltip: tx('复制', en: 'Copy'),
            ),
        ],
      ),
    );
  }

  Widget _howToCard() {
    return SectionCard(
      title: tx('电脑端怎么接', en: 'How to connect from your computer'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _step(
            '1',
            tx('在电脑上配对（只需一次，配对码填上面那 6 位）',
                en: 'Pair on your computer once, using the 6-digit code above'),
            'node baoji-mcp.mjs pair --host <手机IP> --port ${_bridge?.actualPort ?? 8765} --code <配对码>',
          ),
          _step(
            '2',
            tx('把 MCP 服务接进你的 AI 客户端（Claude Desktop / Cursor 等）',
                en: 'Register the MCP server in your AI client (Claude Desktop / Cursor, …)'),
            'node baoji-mcp.mjs serve',
          ),
          const SizedBox(height: 4),
          Text(
            tx('脚本在仓库 tools/mcp-bridge/ 下，不依赖任何第三方包（只要有 Node.js）。',
                en: 'The script lives in tools/mcp-bridge/ and needs no third-party packages (just Node.js).'),
            style: const TextStyle(color: AppTheme.textDim, fontSize: 11.5),
          ),
          const Divider(height: 20, color: AppTheme.cardHi),
          // 小白第一次做这事一定会卡在某一步：本页只放骨架，详细步骤在文档里
          InkWell(
            onTap: () => _copy(_guideUrl, tx('教程链接', en: 'guide link')),
            child: Row(
              children: [
                const Icon(Icons.menu_book_outlined,
                    size: 18, color: AppTheme.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tx('查看完整图文教程（手机端 + 电脑端逐步）',
                            en: 'Full step-by-step guide (phone + computer)'),
                        style: const TextStyle(
                            color: AppTheme.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$_guideUrl  ·  ${tx('点击复制', en: 'tap to copy')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppTheme.textDim, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.copy, size: 16, color: AppTheme.textDim),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _step(String n, String desc, String cmd) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _chip(n),
              const SizedBox(width: 8),
              Expanded(
                child: Text(desc,
                    style: const TextStyle(
                        color: AppTheme.text, fontSize: 13, height: 1.4)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.bgDeep,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              cmd,
              style: const TextStyle(
                  color: AppTheme.accent, fontSize: 11.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String n) => Container(
        width: 20,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.primary.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(n,
            style: const TextStyle(
                color: AppTheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w800)),
      );

  Widget _clientsCard(LocalBridgeService b) {
    final devices = b.pairedDevices;
    return SectionCard(
      title: tx('已配对的设备', en: 'Paired devices'),
      child: devices.isEmpty
          ? Text(
              tx('还没有设备接入。配对成功后这里会列出来，且下次开开关不用重配；可随时断开。',
                  en: 'No device yet. Once a computer pairs it shows here, stays paired next time, and can be revoked anytime.'),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12.5),
            )
          : Column(
              children: [
                for (final d in devices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.computer,
                            size: 18, color: AppTheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(d.label,
                                  style: const TextStyle(
                                      color: AppTheme.text, fontSize: 13.5)),
                              Text(
                                _deviceSub(d),
                                style: const TextStyle(
                                    color: AppTheme.textDim, fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => b.revokeDevice(d.id),
                          child: Text(tx('断开', en: 'Revoke'),
                              style: const TextStyle(color: AppTheme.danger)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  String _deviceSub(BridgeDevice d) {
    final t = d.lastSeenAt;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ip = d.address.isEmpty ? '' : '${d.address} · ';
    final tag = d.id.substring(0, 8);
    return tx('$ip最近请求 $hh:$mm · $tag',
        en: '${ip}last request $hh:$mm · $tag');
  }

  Widget _logCard(LocalBridgeService b) {
    final log = b.accessLog;
    if (log.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: tx('最近请求', en: 'Recent requests'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in log)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Text(_hhmmss(e.at),
                      style: const TextStyle(
                          color: AppTheme.textDim,
                          fontSize: 11.5,
                          fontFeatures: [FontFeature.tabularFigures()])),
                  const SizedBox(width: 8),
                  Text(e.status >= 200 && e.status < 300 ? '✓' : '✕',
                      style: TextStyle(
                          color: e.status >= 200 && e.status < 300
                              ? AppTheme.primary
                              : AppTheme.danger,
                          fontSize: 12)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('${e.address} ${e.line} (${e.status})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppTheme.textDim, fontSize: 11.5)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _hhmmss(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';
}
