import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/novel_offline_resume_fix_test.dart' as resume_safety;

/// Run the exact protected-open flow on Android as well as on the host.
/// The test uses synthetic books in its own temporary encrypted Hive folder;
/// it is built with the separate .test package and never touches production.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  resume_safety.main();
  tearDownAll(() {
    binding.reportData = {
      'scenario': 'offline resume safety on Android',
      'fixture': 'synthetic book in a temporary encrypted store',
      'assertions': [
        'missing resume chapter asks before opening',
        'cancel preserves the original chapter identity',
        'unsuccessful online lookup preserves history',
        'explicit downloaded chapter selection opens its actual cached text',
        'history changes only after explicit chapter selection',
      ],
    };
  });
}
