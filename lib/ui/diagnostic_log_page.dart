import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/lang.dart';
import '../services/diagnostic_log.dart';
import 'theme.dart';

/// 本地诊断日志查看页（2026-10-22）：
/// 只读展示最近 200 条错误/生命周期记录，可一键复制到剪贴板。
/// 数据只存在本机 prefs，不上传、不经过任何网络。
class DiagnosticLogPage extends StatelessWidget {
  const DiagnosticLogPage({super.key, required this.log});

  final DiagnosticLog log;

  static String timeOf(DiagEntry e) {
    final d = DateTime.fromMillisecondsSinceEpoch(e.at);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  static String entryText(DiagEntry e) =>
      '${timeOf(e)} [${e.tag}] ${e.message}';

  String get _allText => [for (final e in log.entries) entryText(e)].join('\n');

  @override
  Widget build(BuildContext context) {
    final entries = log.entries.reversed.toList();
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: Text(tx('诊断日志', en: 'Diagnostic Log')),
        actions: [
          if (entries.isNotEmpty)
            IconButton(
              tooltip: tx('复制全部', en: 'Copy all'),
              icon: const Icon(Icons.copy_all_outlined, size: 20),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _allText));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(tx('已复制到剪贴板', en: 'Copied')),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              tx(
                '只保存在本机，不上传；保留最近 200 条。出现闪退后可以在这里查看退出前的错误和前后台事件。',
                en:
                    'Stored on this device only; nothing is uploaded. '
                    'The latest 200 entries are kept. After a crash, '
                    'check here for errors and lifecycle events.',
              ),
              style: const TextStyle(
                color: AppTheme.textDim,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      tx('暂无记录', en: 'No entries yet'),
                      style: const TextStyle(
                        color: AppTheme.textDim,
                        fontSize: 14,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      final isError = e.tag == 'flutter' || e.tag == 'async';
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.card,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isError
                                ? AppTheme.warn.withValues(alpha: 0.35)
                                : Colors.white.withValues(alpha: 0.035),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  timeOf(e),
                                  style: const TextStyle(
                                    color: AppTheme.textDim,
                                    fontSize: 11.5,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        (isError
                                                ? AppTheme.warn
                                                : AppTheme.primary)
                                            .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    e.tag,
                                    style: TextStyle(
                                      color: isError
                                          ? AppTheme.warn
                                          : AppTheme.primary,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            SelectableText(
                              e.message,
                              style: TextStyle(
                                color: isError
                                    ? AppTheme.warn
                                    : AppTheme.textDim,
                                fontSize: 12.5,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
