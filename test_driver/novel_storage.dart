import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final directory = Directory('build/novel-validation');
    await directory.create(recursive: true);
    final apk = File('build/app/outputs/flutter-apk/app-profile.apk');
    final stage = Platform.environment['NOVEL_STORAGE_STAGE'] ?? 'baseline';
    await File('${directory.path}/storage-$stage.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'recorded_at': DateTime.now().toUtc().toIso8601String(),
        'profile_apk_sha256': (await sha256.bind(apk.openRead()).first)
            .toString(),
        'results': data,
      }),
    );
  },
);
