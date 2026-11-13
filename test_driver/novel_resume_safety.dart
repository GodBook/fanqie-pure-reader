import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final report = File(
      'build/novel-validation/fixes-17-2026-11-12/android-resume-safety.json',
    );
    await report.parent.create(recursive: true);
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'recordedAt': DateTime.now().toUtc().toIso8601String(),
        'buildMode': 'profile',
        'package': 'com.fanqie.pure.reader.test',
        'data': data,
      }),
    );
  },
);
