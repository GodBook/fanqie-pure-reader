import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'novel_release.dart';

class InstalledNovelApp {
  const InstalledNovelApp(this.version, this.code, this.cacheDirectory);
  final String version;
  final int code;
  final String cacheDirectory;

  static const channel = MethodChannel('fqapp/app_update');
  static Future<InstalledNovelApp> load() async {
    final info = await channel.invokeMapMethod<String, dynamic>('info');
    if (info == null) throw const FormatException('无法读取应用版本');
    return InstalledNovelApp(
      info['version'] as String,
      info['code'] as int,
      info['cacheDirectory'] as String,
    );
  }
}

class NovelRelease {
  const NovelRelease({
    required this.version,
    required this.code,
    required this.url,
    required this.sha256Hex,
    required this.bytes,
    required this.notes,
  });
  final String version;
  final int code;
  final Uri url;
  final String sha256Hex;
  final int bytes;
  final String notes;

  factory NovelRelease.parse(Map<String, dynamic> json) {
    final version = json['version'];
    final code = json['versionCode'];
    final bytes = json['bytes'];
    final hash = json['sha256'];
    final url = Uri.tryParse(json['apkUrl']?.toString() ?? '');
    if (json['schema'] != 1 ||
        json['package'] != 'com.fanqie.pure.reader' ||
        json['abi'] != 'arm64-v8a' ||
        version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        code is! int ||
        code < 1 ||
        bytes is! int ||
        bytes < 1024 ||
        bytes > 100 * 1024 * 1024 ||
        hash is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash) ||
        url == null ||
        url.scheme != 'https' ||
        url.host != 'github.com' ||
        url.hasPort ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        !url.path.startsWith(
          '/GodBook/fanqie-pure-reader/releases/download/v$version/',
        ) ||
        !url.path.endsWith('.apk')) {
      throw const FormatException('更新信息无效，请稍后重试');
    }
    return NovelRelease(
      version: version,
      code: code,
      url: url,
      sha256Hex: hash.toLowerCase(),
      bytes: bytes,
      notes: (json['notes']?.toString() ?? '').substring(
        0,
        (json['notes']?.toString() ?? '').length.clamp(0, 4000),
      ),
    );
  }
}

class NovelUpdateCancelled implements Exception {
  const NovelUpdateCancelled();
}

/// One request owner per settings screen. Closing it aborts network work and
/// removes incomplete APKs. Nothing runs during application bootstrap.
class NovelAppUpdate {
  NovelAppUpdate({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;
  final HttpClient Function() _clientFactory;
  HttpClient? _active;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _active?.close(force: true);
  }

  HttpClient _begin() {
    _cancelled = false;
    final client = _active = _clientFactory();
    client.connectionTimeout = const Duration(seconds: 15);
    client.userAgent = 'FanqiePureReader';
    return client;
  }

  Future<HttpClientResponse> _get(HttpClient client, Uri url) async {
    final request = await client
        .getUrl(url)
        .timeout(const Duration(seconds: 20));
    // GitHub redirects downloads to its HTTPS asset CDN.
    request.maxRedirects = 5;
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('GitHub 暂时无法访问（${response.statusCode}）');
    }
    return response;
  }

  Future<NovelRelease> check() async {
    final client = _begin();
    try {
      final response = await _get(client, Uri.parse(novelUpdateManifest));
      final data = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        data.addAll(chunk);
        if (data.length > 32 * 1024) throw const FormatException('更新信息过大');
      }
      if (_cancelled) throw const NovelUpdateCancelled();
      return NovelRelease.parse(
        jsonDecode(utf8.decode(data)) as Map<String, dynamic>,
      );
    } finally {
      client.close(force: true);
      if (identical(_active, client)) _active = null;
    }
  }

  Future<File> download(
    NovelRelease release,
    InstalledNovelApp installed,
    void Function(int received, int total) onProgress,
  ) async {
    final directory = Directory('${installed.cacheDirectory}/app-updates');
    await directory.create(recursive: true);
    final file = File('${directory.path}/update.apk');
    final partial = File('${directory.path}/update.part');
    final client = _begin();
    IOSink? sink;
    var success = false;
    try {
      // Never reuse a previous file as though it belonged to this manifest.
      if (await file.exists()) await file.delete();
      final response = await _get(client, release.url);
      if (response.contentLength >= 0 &&
          response.contentLength != release.bytes) {
        throw const FormatException('安装包大小不符，请重新下载');
      }
      sink = partial.openWrite();
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 25))) {
        if (_cancelled) throw const NovelUpdateCancelled();
        received += chunk.length;
        if (received > release.bytes) throw const FormatException('安装包大小不符');
        sink.add(chunk);
        // Backpressure keeps large downloads bounded in memory.
        await sink.flush();
        onProgress(received, release.bytes);
      }
      await sink.close();
      sink = null;
      if (_cancelled) throw const NovelUpdateCancelled();
      if (received != release.bytes ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              release.sha256Hex) {
        throw const FormatException('安装包校验失败，请重新下载');
      }
      if (_cancelled) throw const NovelUpdateCancelled();
      await partial.rename(file.path);
      success = true;
      return file;
    } catch (_) {
      if (_cancelled) throw const NovelUpdateCancelled();
      rethrow;
    } finally {
      client.close(force: true);
      if (identical(_active, client)) _active = null;
      await sink?.close();
      if (!success && await partial.exists()) await partial.delete();
    }
  }

  static Future<String> install(File file, NovelRelease release) async =>
      await InstalledNovelApp.channel.invokeMethod<String>('install', {
        'path': file.path,
        'versionCode': release.code,
        'sha256': release.sha256Hex,
      }) ??
      'unavailable';
}
