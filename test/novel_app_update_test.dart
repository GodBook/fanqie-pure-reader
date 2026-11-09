import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/novel_app_update.dart';

Map<String, dynamic> manifest(List<int> bytes) => {
  'schema': 1,
  'package': 'com.fanqie.pure.reader',
  'abi': 'arm64-v8a',
  'version': '1.3.1',
  'versionCode': 6,
  'apkUrl':
      'https://github.com/GodBook/fanqie-pure-reader/releases/download/v1.3.1/reader.apk',
  'sha256': sha256.convert(bytes).toString(),
  'bytes': bytes.length,
  'notes': '更新说明',
};

class _LocalClient implements HttpClient {
  _LocalClient(this.url);
  final Uri url;
  final _client = HttpClient();
  @override
  set connectionTimeout(Duration? value) => _client.connectionTimeout = value;
  @override
  set userAgent(String? value) => _client.userAgent = value;
  @override
  Future<HttpClientRequest> getUrl(Uri _) => _client.getUrl(url);
  @override
  void close({bool force = false}) => _client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final bytes = List<int>.generate(4096, (i) => i % 251);
  test(
    'release rejects a different app, host, version path, ABI and invalid size/hash',
    () {
      expect(NovelRelease.parse(manifest(bytes)).code, 6);
      for (final change in [
        {'package': 'other.app'},
        {'abi': 'x86'},
        {'schema': 2},
        {'apkUrl': 'https://evil.example/reader.apk'},
        {
          'apkUrl':
              'http://github.com/GodBook/fanqie-pure-reader/releases/download/v1.3.1/reader.apk',
        },
        {
          'apkUrl':
              'https://github.com/GodBook/fanqie-pure-reader/releases/download/v1.0.0/reader.apk',
        },
        {
          'apkUrl':
          'https://github.com:444/GodBook/fanqie-pure-reader/releases/download/v1.3.1/reader.apk',
        },
        {'bytes': 500 * 1024 * 1024},
        {'bytes': -1},
        {'sha256': 'bad'},
      ]) {
        expect(
          () => NovelRelease.parse({...manifest(bytes), ...change}),
          throwsFormatException,
        );
      }
    },
  );

  Future<void> serve(
    Future<void> Function(NovelAppUpdate, Directory, HttpServer) run,
    void Function(HttpRequest) respond,
  ) async {
    final dir = await Directory.systemTemp.createTemp('novel-update-test-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(respond);
    final updater = NovelAppUpdate(
      clientFactory: () =>
          _LocalClient(Uri.parse('http://127.0.0.1:${server.port}/apk')),
    );
    try {
      await run(updater, dir, server);
    } finally {
      updater.cancel();
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  }

  test(
    'verified download writes the exact APK and reports real byte progress',
    () async {
      await serve(
        (updater, dir, _) async {
          final progress = <int>[];
          final file = await updater.download(
            NovelRelease.parse(manifest(bytes)),
            InstalledNovelApp('1.3.0', 5, dir.path),
            (n, _) => progress.add(n),
          );
          expect(await file.readAsBytes(), bytes);
          expect(progress.last, bytes.length);
          expect(
            await File('${dir.path}/app-updates/update.part').exists(),
            isFalse,
          );
        },
        (r) {
          r.response.add(bytes);
          unawaited(r.response.close());
        },
      );
    },
  );

  test(
    'same-size corruption is rejected and incomplete data is removed',
    () async {
      await serve(
        (updater, dir, _) async {
          await expectLater(
            updater.download(
              NovelRelease.parse(manifest(bytes)),
              InstalledNovelApp('1.3.0', 5, dir.path),
              (_, _) {},
            ),
            throwsFormatException,
          );
          expect(
            await Directory('${dir.path}/app-updates').list().isEmpty,
            isTrue,
          );
        },
        (r) {
          r.response.add(List.filled(bytes.length, 0));
          unawaited(r.response.close());
        },
      );
    },
  );

  test(
    'truncated response is rejected rather than handed to the installer',
    () async {
      await serve(
        (updater, dir, _) async {
          await expectLater(
            updater.download(
              NovelRelease.parse(manifest(bytes)),
              InstalledNovelApp('1.3.0', 5, dir.path),
              (_, _) {},
            ),
            throwsFormatException,
          );
          expect(
            await Directory('${dir.path}/app-updates').list().isEmpty,
            isTrue,
          );
        },
        (r) {
          r.response.add(bytes.take(1024).toList());
          unawaited(r.response.close());
        },
      );
    },
  );

  test(
    'cancelling an active transfer removes the partial APK and permits retry',
    () async {
      await serve(
        (updater, dir, _) async {
          await expectLater(
            updater.download(
              NovelRelease.parse(manifest(bytes)),
              InstalledNovelApp('1.3.0', 5, dir.path),
              (_, _) => updater.cancel(),
            ),
            throwsA(isA<NovelUpdateCancelled>()),
          );
          expect(
            await Directory('${dir.path}/app-updates').list().isEmpty,
            isTrue,
          );
          final retried = await updater.download(
            NovelRelease.parse(manifest(bytes)),
            InstalledNovelApp('1.3.0', 5, dir.path),
            (_, _) {},
          );
          expect(await retried.length(), bytes.length);
        },
        (r) async {
          r.response.add(bytes.take(1024).toList());
          try {
            await r.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 100));
            r.response.add(bytes.skip(1024).toList());
            await r.response.close();
          } catch (_) {
            /* A cancelled client's socket closes by design. */
          }
        },
      );
    },
  );
}
