import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final directory = Directory('build/novel-validation');
    await directory.create(recursive: true);
    final offline = Platform.environment['NOVEL_E2E_OFFLINE'] == 'true';
    final buildMode = Platform.environment['NOVEL_E2E_BUILD_MODE'] ?? 'profile';
    final apk = File('build/app/outputs/flutter-apk/app-$buildMode.apk');
    final digest = await sha256.bind(apk.openRead()).first;
    final report = {
      'recorded_at': DateTime.now().toUtc().toIso8601String(),
      'mode': offline ? 'offline' : 'online',
      'build_mode': buildMode,
      'apk_sha256': digest.toString(),
      if (buildMode == 'profile') 'profile_apk_sha256': digest.toString(),
      'results': data,
    };
    await File(
      '${directory.path}/${offline ? 'offline' : 'online'}${buildMode == 'profile' ? '' : '-$buildMode'}.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  },
);
