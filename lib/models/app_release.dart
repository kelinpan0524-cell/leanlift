import 'package:flutter/foundation.dart';

/// 一次可用更新（GitHub Release 元数据）。
/// tag 约定为 "b<构建号>"，构建号即 Android versionCode（CI 的 run number），
/// App 端拿它与本地 versionCode 比较判断是否有新版。
@immutable
class AppRelease {
  const AppRelease({
    required this.buildNumber,
    required this.title,
    required this.notes,
    required this.apkUrl,
    required this.assetId,
    required this.apkSize,
    this.sha256,
  });

  final int buildNumber;
  final String title;
  final String notes;

  /// APK 资产的浏览器下载页地址（github.com 域，仅供人打开；
  /// 程序下载必须走 asset API——私仓的 browser_download_url
  /// 带 token 请求恒 404，GitHub 不在该域做 API 认证）。
  final String apkUrl;

  /// APK 资产在 Releases API 里的 id：下载地址由
  /// `https://api.github.com/repos/<repo>/releases/assets/<id>` 拼出，
  /// 带令牌请求 302 到签名 CDN。
  final int assetId;
  final int apkSize;
  final String? sha256;

  /// 从 GitHub Releases API 的 release JSON 解析。
  /// tag 不符约定或找不到 APK 资产时抛 [FormatException]。
  factory AppRelease.fromGithub(Map<String, dynamic> json) {
    final tag = (json['tag_name'] as String? ?? '').trim();
    final match = RegExp(r'^b(\d+)$').firstMatch(tag);
    if (match == null) {
      throw FormatException('release tag 不是 b<构建号> 格式: $tag');
    }
    Map<String, dynamic>? apk;
    for (final a in (json['assets'] as List? ?? const []).whereType<Map>()) {
      final name = (a['name'] as String? ?? '').toLowerCase();
      if (name.endsWith('.apk')) {
        apk = Map<String, dynamic>.from(a);
        break;
      }
    }
    if (apk == null) {
      throw const FormatException('release 里没有 APK 文件');
    }
    final assetId = apk['id'] as int? ?? 0;
    if (assetId <= 0) {
      throw const FormatException('APK 资产缺少 id，无法构造下载地址');
    }
    final rawDigest = (apk['digest'] as String? ?? '').trim().toLowerCase();
    final shaMatch = RegExp(r'^sha256:([0-9a-f]{64})$').firstMatch(rawDigest);
    return AppRelease(
      buildNumber: int.parse(match.group(1)!),
      title: (json['name'] as String? ?? '').trim(),
      notes: (json['body'] as String? ?? '').trim(),
      apkUrl: apk['browser_download_url'] as String? ?? '',
      assetId: assetId,
      apkSize: apk['size'] as int? ?? 0,
      sha256: shaMatch?.group(1),
    );
  }
}
