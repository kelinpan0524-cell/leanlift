import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/lang.dart';
import '../models/app_release.dart';
import 'settings.dart';

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 应用内自更新：查 GitHub Releases（公开仓库免令牌；fork 到私有仓库自用时
/// 可在设置里配只读令牌）→ 下载 APK → 调系统安装器。
/// 联网范围仅限 https 的 GitHub 域名白名单；令牌只存手机本地，与 AI Key 同一存放策略。
class UpdateService {
  UpdateService(this._settings, {http.Client? client})
      : _client = client ?? http.Client();

  final Settings _settings;
  final http.Client _client;

  static const _repo = 'kelinpan0524-cell/leanlift';
  static const _timeout = Duration(seconds: 15);
  static const _channel = MethodChannel('baoji/updater');

  /// 带令牌的请求头；公开仓库匿名访问则不带 Authorization。
  Map<String, String> _authHeaders(String accept) {
    final token = _settings.ghUpdateToken.trim();
    return {
      'Accept': accept,
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  /// 当前安装的构建号（Android versionCode）。
  Future<int> installedBuildNumber() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 0;
  }

  /// 拉最新 Release；已是最新返回 null，有新版返回元数据。
  /// 公开仓库匿名可查；私有仓库需在设置里配令牌（401 时提示重新生成）。
  Future<AppRelease?> checkLatest() async {
    final http.Response resp;
    try {
      resp = await _client
          .get(
            Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
            headers: _authHeaders('application/vnd.github+json'),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw UpdateException(
          tx('检查更新超时，稍后再试', en: 'Update check timed out, try again later'));
    } on SocketException {
      throw UpdateException(tx('网络不可用', en: 'Network unavailable'));
    } on http.ClientException catch (e) {
      throw UpdateException(tx('网络请求失败：${e.message}',
          en: 'Network request failed: ${e.message}'));
    }
    switch (resp.statusCode) {
      case 200:
        break;
      case 401:
        throw UpdateException(tx('令牌无效或已过期，请在 GitHub 重新生成',
            en: 'Token invalid or expired, regenerate it on GitHub'));
      case 404:
        throw UpdateException(tx('还没有任何发布版本', en: 'No releases yet'));
      default:
        throw UpdateException(tx('检查更新失败（HTTP ${resp.statusCode}）',
            en: 'Update check failed (HTTP ${resp.statusCode})'));
    }
    final Map<String, dynamic> json;
    final AppRelease release;
    try {
      json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      release = AppRelease.fromGithub(json);
    } on FormatException {
      throw UpdateException(tx('发布版本信息异常（可能 CI 出包失败）',
          en: 'Invalid release info (CI build may have failed)'));
    } on TypeError {
      throw UpdateException(tx('发布版本信息异常（可能 CI 出包失败）',
          en: 'Invalid release info (CI build may have failed)'));
    }
    if (release.buildNumber <= await installedBuildNumber()) return null;
    return release;
  }

  /// 下载 APK 到应用缓存目录，返回文件路径。
  /// 走 Releases asset API（browser_download_url 带 token 恒 404）。
  ///
  /// 重定向走完整循环（2026-09-27 修复「安装包损坏」）：
  /// - 仓库改名后 api.github.com 会先回 301（改名跳转）再 302（签名 CDN），
  ///   旧实现只处理一跳且第二跳丢了 Accept: octet-stream——GitHub 对不带
  ///   该头的 asset 请求返回的是 1KB 的 JSON 元数据，被当 APK 存盘后
  ///   安装器必然报「损坏」。
  /// - 现在逐跳跟随（最多 5 跳）：api.github.com 域名上的跳转保留
  ///   Accept 头（有令牌也只在 API 域携带），到 CDN 后裸请求。
  /// - 下载完成后与 Release 元数据里的 apkSize 严格比对，不符即删重试。
  ///
  /// [tempDirPathOverride] 仅供单元测试注入临时目录。
  Future<String> downloadApk(AppRelease release,
      {void Function(int received, int total)? onProgress,
      @visibleForTesting String? tempDirPathOverride}) async {
    var url =
        'https://api.github.com/repos/$_repo/releases/assets/${release.assetId}';
    http.StreamedResponse stream;
    var hops = 0;
    while (true) {
      final isApiHost = Uri.parse(url).host == 'api.github.com';
      final req = http.Request('GET', Uri.parse(url))
        ..followRedirects = false;
      if (isApiHost) {
        // Accept: octet-stream 是「要文件本体而不是 JSON 元数据」的关键；
        // 令牌同样只在 API 域携带，跳到 CDN 后不再带。
        req.headers.addAll(_authHeaders('application/octet-stream'));
      }
      final resp = await _client.send(req).timeout(_timeout);
      final status = resp.statusCode;
      if (status == 301 || status == 302 || status == 303 || status == 307) {
        await resp.stream.drain<void>();
        final next = resp.headers['location'] ?? '';
        if (next.isEmpty) {
          throw UpdateException(
              tx('下载地址跳转异常', en: 'Download redirect missing location'));
        }
        final resolved = Uri.parse(url).resolve(next).toString();
        final urlError = downloadUrlError(resolved);
        if (urlError != null) throw UpdateException(urlError);
        url = resolved;
        if (++hops > 5) {
          throw UpdateException(
              tx('下载跳转次数过多', en: 'Too many download redirects'));
        }
        continue;
      }
      if (status != 200) {
        throw UpdateException(
            tx('下载失败（HTTP $status）', en: 'Download failed (HTTP $status)'));
      }
      stream = resp;
      break;
    }
    final total = stream.contentLength ?? release.apkSize;
    final String dirPath;
    if (tempDirPathOverride != null) {
      dirPath = tempDirPathOverride;
    } else {
      final dir = await getTemporaryDirectory();
      dirPath = dir.path;
    }
    final file = File('$dirPath/baoji_update.apk');
    final sink = file.openWrite();
    Digest? digest;
    final digestSink = ChunkedConversionSink<Digest>.withCallback(
        (chunks) => digest = chunks.single);
    final hashSink = sha256.startChunkedConversion(digestSink);
    var received = 0;
    try {
      try {
        await for (final chunk in stream.stream.timeout(_timeout)) {
          sink.add(chunk);
          hashSink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        hashSink.close();
        await sink.flush();
      } on TimeoutException {
        throw UpdateException(
            tx('下载超时，请重试', en: 'Download timed out, please try again'));
      } finally {
        await sink.close();
      }
    } catch (_) {
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // 缓存文件，残留无碍
      }
      rethrow;
    }
    // 完整性双保险：长度与 SHA-256 校验，任一不符一律删除并拒绝
    final expected = release.apkSize > 0 ? release.apkSize : total;
    if (expected > 0 && received != expected) {
      try {
        await file.delete();
      } on FileSystemException {
        // 缓存文件，残留无碍
      }
      throw UpdateException(
          tx('下载不完整（$received / $expected 字节），请重试',
              en: 'Download incomplete ($received / $expected bytes), please try again'));
    }
    final expectedSha = release.sha256;
    if (expectedSha != null && digest?.toString() != expectedSha) {
      try {
        await file.delete();
      } on FileSystemException {
        // 缓存文件，残留无碍
      }
      throw UpdateException(tx('安装包校验失败，请重试',
          en: 'Package verification failed, please try again'));
    }
    return file.path;
  }

  /// 是否已获得"安装未知应用"授权（Android 8+）。
  Future<bool> canRequestInstall() async =>
      await _channel.invokeMethod<bool>('canRequestInstall') ?? true;

  Future<void> openInstallPermissionSettings() =>
      _channel.invokeMethod<void>('openInstallPermissionSettings');

  /// 唤起系统安装器安装 [path] 指向的 APK。
  Future<void> installApk(String path) =>
      _channel.invokeMethod<void>('installApk', {'path': path});

  /// 启动时静默检查：有新版只点亮"设置"入口红点，绝不弹窗（训练专注红线）。
  Future<void> silentCheck() async {
    try {
      final release = await checkLatest();
      _settings.set(() => _settings.pendingUpdate = release);
    } on Exception {
      // 静默失败：启动检查不打扰用户，设置页里手动查会给出原因
    }
  }

  /// 下载/跳转地址安全校验（白名单外、非 https 一律拒绝），合法返回 null。
  @visibleForTesting
  static String? downloadUrlError(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('https')) {
      return tx('下载地址不安全（仅允许 https）',
          en: 'Unsafe download URL (https only)');
    }
    final host = uri.host;
    final allowed = host == 'api.github.com' ||
        host == 'github.com' ||
        host.endsWith('.github.com') ||
        host.endsWith('.githubusercontent.com');
    if (!allowed) {
      return tx('下载地址不在 GitHub 域名白名单内',
          en: 'Download URL not on the GitHub domain allowlist');
    }
    return null;
  }
}
