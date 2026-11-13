import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/novel_image_download_test.dart' as images;
import '../test/novel_reader_navigation_improvements_test.dart' as navigation;
import '../test/novel_reader_preferences_improvements_test.dart' as preferences;
import '../test/novel_reader_text_improvements_test.dart' as text;

class _ReadingIntegrationBinding extends IntegrationTestWidgetsFlutterBinding {
  // The reused widget fixtures enter text through TestTextInput. Register its
  // channel on Android too, so the real IME cannot overwrite synthetic drafts.
  @override
  bool get registerTestTextInput => true;
}

/// Synthetic failure and layout cases run visibly on Android in the isolated
/// .test package. They never read or write the production reading library.
void main() {
  final binding = _ReadingIntegrationBinding();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  group('notes and temporary navigation', navigation.main);
  group('text, annotations and semantics', text.main);
  group('comments and reading preferences', preferences.main);
  group('offline illustration files', images.main);
  tearDownAll(() {
    binding.reportData = {
      'scenario': '12 reading improvements on Android',
      'fixture': 'synthetic books and temporary app-private directories',
      'productionDataTouched': false,
      'nativeBrightness': 'mocked here; verify separately in the formal APK',
      'onlineNovelContent': 'verify separately in the formal APK',
    };
  });
}
