import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/novel_app_update.dart';

class _RedirectClient implements HttpClient {
  _RedirectClient(this.uri);
  final Uri uri;
  final _client = HttpClient();
  @override
  set connectionTimeout(Duration? value) => _client.connectionTimeout = value;
  @override
  set userAgent(String? value) => _client.userAgent = value;
  @override
  Future<HttpClientRequest> getUrl(Uri _) => _client.getUrl(uri);
  @override
  void close({bool force = false}) => _client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final valid = {
    'schema': 1,
    'package': 'com.fanqie.pure.reader',
    'abi': 'arm64-v8a',
    'version': '1.3.1',
    'versionCode': 6,
    'bytes': 1024,
    'sha256': 'a' * 64,
    'apkUrl':
        'https://github.com/GodBook/fanqie-pure-reader/releases/download/v1.3.1/reader.apk',
    'notes': '发行说明',
  };

  Future<void> respond(
    String body,
    Future<void> Function(NovelAppUpdate) action, {
    int status = 200,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) {
      r.response.statusCode = status;
      r.response.write(body);
      unawaited(r.response.close());
    });
    final updater = NovelAppUpdate(
      clientFactory: () => _RedirectClient(
        Uri.parse('http://127.0.0.1:${server.port}/manifest'),
      ),
    );
    try {
      await action(updater);
    } finally {
      updater.cancel();
      await server.close(force: true);
    }
  }

  test(
    'checks a real HTTP response and decodes the published schema',
    () async {
      await respond(jsonEncode(valid), (updater) async {
        final release = await updater.check();
        expect(release.version, '1.3.1');
        expect(release.notes, '发行说明');
      });
    },
  );
  test(
    'missing release is a retryable error rather than a claim of latest',
    () async {
      await respond('Not Found', (updater) async {
        await expectLater(updater.check(), throwsA(isA<HttpException>()));
      }, status: 404);
    },
  );
  test('HTML failure response cannot be mistaken for an update', () async {
    await respond('<html>network error</html>', (updater) async {
      await expectLater(updater.check(), throwsFormatException);
    });
  });
  test('oversized manifest is bounded before decoding', () async {
    await respond('x' * 33000, (updater) async {
      await expectLater(updater.check(), throwsFormatException);
    });
  });
}
