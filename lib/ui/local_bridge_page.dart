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
/// 交互原则：开关不落盘（每次主动开）、空闲自动关、只读、配对了才认令牌；
/// 页面把「地址 + 配对码 + 谁连上了」三件事摊在一屏，用户不用去翻日志。
class LocalBridgePage extends StatefulWidget {
  const LocalBridgePage({super.key});

  @override
  State<LocalBridgePage> createState() => _LocalBridgePageState();
}

class _LocalBridgePageState extends State<LocalBridgePage> {
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
        tx('已配对的电脑会立即断开，需要重新配对。',
            en: 'Paired computers will be disconnected and must pair again.'),
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
          _bullet(tx('不常驻：不进设置持久化，每次都要在这里手动开启；无请求 10 分钟自动关闭。',
              en: 'Not persistent: it is never remembered across launches — you switch it on here each time, and it stops itself after 10 idle minutes.')),
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
            tx('配对码只在电脑首次接入时用一次；配对成功后手机自动换新码。',
                en: 'The code is used once, when a computer first connects; the phone issues a fresh one right after.'),
            style: const TextStyle(color: AppTheme.textDim, fontSize: 11.5),
          ),
          const Divider(height: 24, color: AppTheme.cardHi),
          Text(
            tx('无请求 ${mins >= 1 ? '$mins 分钟' : '不到 1 分钟'}后自动关闭',
                en: 'Stops automatically in ${mins >= 1 ? '$mins min' : 'under 1 min'}'),
            style: const TextStyle(color: AppTheme.warn, fontSize: 12),
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
            tx('脚本在仓库 tools/mcp-bridge/ 下，不依赖任何第三方包。',
                en: 'The script lives in tools/mcp-bridge/ and needs no third-party packages.'),
            style: const TextStyle(color: AppTheme.textDim, fontSize: 11.5),
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
    final clients = b.clients;
    return SectionCard(
      title: tx('已配对的设备', en: 'Paired devices'),
      child: clients.isEmpty
          ? Text(
              tx('还没有设备接入。配对成功后这里会列出来，可随时断开。',
                  en: 'No device yet. Once a computer pairs, it shows here and you can revoke it anytime.'),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 12.5),
            )
          : Column(
              children: [
                for (final c in clients)
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
                              Text(c.address,
                                  style: const TextStyle(
                                      color: AppTheme.text, fontSize: 13.5)),
                              Text(
                                _clientSub(c),
                                style: const TextStyle(
                                    color: AppTheme.textDim, fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => b.revokeClient(c.address),
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

  String _clientSub(BridgeClient c) {
    final t = c.lastSeenAt;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final model = c.userAgent.isEmpty ? '' : ' · ${c.userAgent}';
    return tx('最近请求 $hh:$mm$model', en: 'last request $hh:$mm$model');
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
