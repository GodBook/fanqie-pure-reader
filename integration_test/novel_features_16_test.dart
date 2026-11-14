import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:integration_test/common.dart' show Failure;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
// The integration harness replaces this transitive platform interface so no
// fixture can resolve a persistent application-support directory.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// The Flutter standalone runner does not add plain test() results to its
// integration binding. Observe its active test to make failures visible to
// flutter drive as well. This is tied to the pinned Flutter/test_api version.
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:test_api/src/backend/invoker.dart';

import 'package:fqapp/services/secure_key_provider.dart';

import '../test/novel_discovery_extensions_test.dart' as discovery;
import '../test/novel_feature_backup_test.dart' as backup;
import '../test/novel_feature_pages_test.dart' as pages;
import '../test/novel_reader_research_features_test.dart' as reader;
import '../test/novel_shelf_download_queue_test.dart' as shelf;
import '../test/novel_local_reader_isolation_test.dart' as local_reader;
import '../test/novel_local_transfer_test.dart' as local_transfer;
import '../test/novel_space_usage_test.dart' as space;

class _FeatureIntegrationBinding extends IntegrationTestWidgetsFlutterBinding {
  @override
  bool get registerTestTextInput => true;
}

final class _FixtureIOOverrides extends IOOverrides {
  _FixtureIOOverrides(this.directory);
  final Directory directory;

  @override
  Directory getSystemTempDirectory() => directory;
}

class _FixturePaths extends PathProviderPlatform {
  _FixturePaths(this.directory);
  final Directory directory;

  @override
  Future<String?> getTemporaryPath() async => directory.path;

  @override
  Future<String?> getApplicationSupportPath() async => directory.path;

  @override
  Future<String?> getApplicationDocumentsPath() async => directory.path;

  @override
  Future<String?> getApplicationCachePath() async => directory.path;
}

/// Synthetic cases run in a disposable directory owned by the profile .test
/// package. They do not open the production library or fetch real book data.
void main() {
  final binding = _FeatureIntegrationBinding();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const packageName = 'com.fanqie.pure.reader.test';
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final caseResults = <String, String>{};
  final groups = <String>[
    'reader research',
    'discovery extensions',
    'backup and local books',
    'feature pages',
    'shelf and download queue',
    'local reader isolation',
    'local transfer',
    'cache space',
  ];
  Directory? fixture;
  IOOverrides? previousOverrides;
  PathProviderPlatform? previousPaths;
  var overridesInstalled = false;

  setUpAll(() async {
    try {
      if (!Platform.isAndroid) {
        throw StateError('This isolated profile suite requires Android.');
      }
      final cache = await getTemporaryDirectory();
      if (!cache.path.split(Platform.pathSeparator).contains(packageName)) {
        throw StateError(
          'Refusing a cache outside the isolated .test package.',
        );
      }
      fixture = await cache.createTemp('novel-features-16-');
      previousOverrides = IOOverrides.current;
      previousPaths = PathProviderPlatform.instance;
      overridesInstalled = true;
      IOOverrides.global = _FixtureIOOverrides(fixture!);
      PathProviderPlatform.instance = _FixturePaths(fixture!);
    } catch (error, stack) {
      binding.results['fixture setup'] = Failure(
        'fixture setup',
        '$error\n$stack',
      );
      rethrow;
    }
  });

  setUp(() {
    final live = Invoker.current?.liveTest;
    if (live == null) {
      final error = StateError('Cannot observe the active test result.');
      binding.results['test reporting'] = Failure('test reporting', '$error');
      throw error;
    }
    final name = live.test.name;
    live.onError.listen((error) {
      caseResults[name] = 'failed';
      binding.results['case: $name'] = Failure(
        name,
        '${error.error}\n${error.stackTrace}',
      );
    });
    live.onStateChange.listen((state) {
      if (state.status.name == 'complete' && state.result.name == 'success') {
        caseResults.putIfAbsent(name, () => 'passed');
      }
    });
    final secureValues = <String, String>{};
    SecureKeyProvider.instance.resetForTest();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(secureChannel, (
      call,
    ) async {
      final arguments = (call.arguments as Map?) ?? const {};
      final key = arguments['key'] as String?;
      switch (call.method) {
        case 'read':
          return secureValues[key];
        case 'write':
          secureValues[key!] = arguments['value'] as String;
        case 'delete':
          secureValues.remove(key);
      }
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      secureChannel,
      null,
    );
    SecureKeyProvider.instance.resetForTest();
  });

  group(groups[0], reader.main);
  group(groups[1], discovery.main);
  group(groups[2], backup.main);
  group(groups[3], pages.main);
  group(groups[4], shelf.main);
  group(groups[5], local_reader.main);
  group(groups[6], local_transfer.main);
  group(groups[7], space.main);

  tearDownAll(() async {
    try {
      for (final groupName in groups) {
        if (!caseResults.keys.any((name) => name.startsWith('$groupName '))) {
          binding.results['missing $groupName'] = Failure(
            'missing $groupName',
            'No completed test was recorded for this group.',
          );
        }
      }
      await Hive.close();
      final owned = fixture;
      if (owned != null && await owned.exists()) {
        await owned.delete(recursive: true);
      }
    } catch (error, stack) {
      binding.results['fixture cleanup'] = Failure(
        'fixture cleanup',
        '$error\n$stack',
      );
    } finally {
      if (overridesInstalled) {
        IOOverrides.global = previousOverrides;
        PathProviderPlatform.instance = previousPaths!;
      }
    }
    binding.reportData = {
      'scenario': 'features 16 synthetic Android checks',
      'recordedAt': DateTime.now().toUtc().toIso8601String(),
      'buildMode': 'profile',
      'package': packageName,
      'fixture':
          'temporary directory in isolated .test package; mock preferences and secure keys',
      'productionDataTouched': false,
      'onlineContent':
          'synthetic; verify real content separately in the formal APK',
      'groups': groups,
      'result': binding.failureMethodsDetails.isEmpty ? 'passed' : 'failed',
      'caseCount': caseResults.length,
      'cases': caseResults,
      'failures': [
        for (final failure in binding.failureMethodsDetails)
          {'case': failure.methodName, 'details': failure.details},
      ],
    };
  });
}
