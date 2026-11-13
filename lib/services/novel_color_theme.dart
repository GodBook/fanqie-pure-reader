import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App chrome colors; the reader's paper and typography remain independent.
enum NovelColorTheme {
  cinnabar(
    '朱砂',
    Color(0xFFB84A38),
    Color(0xFFF0A18E),
    Color(0xFF482117),
    Color(0xFFF7E6DF),
    Color(0xFF833525),
    Color(0xFF4C3029),
    Color(0xFFFFD9CE),
  ),
  pine(
    '松绿',
    Color(0xFF2D6A4F),
    Color(0xFF9BD5AE),
    Color(0xFF0B3926),
    Color(0xFFD9EDDF),
    Color(0xFF174D34),
    Color(0xFF244B36),
    Color(0xFFC0EDCE),
  ),
  indigo(
    '靛青',
    Color(0xFF465B9C),
    Color(0xFFB8C5FF),
    Color(0xFF202F63),
    Color(0xFFDFE3FA),
    Color(0xFF304579),
    Color(0xFF303C67),
    Color(0xFFDFE3FF),
  ),
  lake(
    '湖蓝',
    Color(0xFF19677A),
    Color(0xFF95D3E5),
    Color(0xFF003642),
    Color(0xFFD2ECF1),
    Color(0xFF004F61),
    Color(0xFF194956),
    Color(0xFFB4EAF5),
  ),
  plum(
    '藤紫',
    Color(0xFF76508F),
    Color(0xFFD8B6F0),
    Color(0xFF412353),
    Color(0xFFF0DEF8),
    Color(0xFF5C316F),
    Color(0xFF4D355B),
    Color(0xFFF1D8FF),
  ),
  amber(
    '琥珀',
    Color(0xFF80561B),
    Color(0xFFECC18B),
    Color(0xFF492E05),
    Color(0xFFF5E5CE),
    Color(0xFF684108),
    Color(0xFF563F20),
    Color(0xFFFFDFB0),
  );

  const NovelColorTheme(
    this.label,
    this.lightPrimary,
    this.darkPrimary,
    this._darkOnPrimary,
    this._lightPrimaryContainer,
    this._lightOnPrimaryContainer,
    this._darkPrimaryContainer,
    this._darkOnPrimaryContainer,
  );

  final String label;
  final Color lightPrimary;
  final Color darkPrimary;
  final Color _darkOnPrimary;
  final Color _lightPrimaryContainer;
  final Color _lightOnPrimaryContainer;
  final Color _darkPrimaryContainer;
  final Color _darkOnPrimaryContainer;

  ColorScheme scheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final seed = ColorScheme.fromSeed(
      seedColor: lightPrimary,
      brightness: brightness,
    );

    // Keep the original warm-paper palette exactly for the default theme.
    // Other palettes add only a little color to the same surface hierarchy.
    Color surface(Color neutral) => this == NovelColorTheme.cinnabar
        ? neutral
        : Color.lerp(neutral, dark ? darkPrimary : lightPrimary, 0.03)!;

    return seed.copyWith(
      primary: dark ? darkPrimary : lightPrimary,
      onPrimary: dark ? _darkOnPrimary : Colors.white,
      primaryContainer: dark ? _darkPrimaryContainer : _lightPrimaryContainer,
      onPrimaryContainer: dark
          ? _darkOnPrimaryContainer
          : _lightOnPrimaryContainer,
      surface: surface(
        dark ? const Color(0xFF1C1B19) : const Color(0xFFFAF8F4),
      ),
      surfaceContainerLow: surface(
        dark ? const Color(0xFF23221F) : const Color(0xFFFFFDFA),
      ),
      surfaceContainer: surface(
        dark ? const Color(0xFF292723) : const Color(0xFFF3EFE8),
      ),
      surfaceContainerHigh: surface(
        dark ? const Color(0xFF302D28) : const Color(0xFFEDE7DE),
      ),
      surfaceContainerHighest: surface(
        dark ? const Color(0xFF39352F) : const Color(0xFFE6DFD4),
      ),
      onSurface: dark ? const Color(0xFFEDE7DD) : const Color(0xFF2D2923),
      onSurfaceVariant: dark
          ? const Color(0xFFBEB6AA)
          : const Color(0xFF665E53),
      outline: dark ? const Color(0xFF91877A) : const Color(0xFF8D8274),
      outlineVariant: dark ? const Color(0xFF484239) : const Color(0xFFE3DBCF),
    );
  }
}

const novelColorThemeKey = 'novel_color_theme';

/// Persists local app colors independently of mode and reader preferences.
class NovelColorThemeStore extends ValueNotifier<NovelColorTheme> {
  NovelColorThemeStore({Future<bool> Function(String id)? persist})
    : _persist = persist ?? _persistToPreferences,
      super(NovelColorTheme.cinnabar);

  static final instance = NovelColorThemeStore();

  final Future<bool> Function(String id) _persist;
  Future<void> _writes = Future<void>.value();
  NovelColorTheme _persisted = NovelColorTheme.cinnabar;
  int _revision = 0;
  bool _disposed = false;

  /// Lets callers suppress an older save error after another selection.
  int get selectionRevision => _revision;

  static Future<bool> _persistToPreferences(String id) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.setString(novelColorThemeKey, id);
  }

  /// Applies a startup preference only if the user has not made a newer choice.
  void restore(String? id) {
    if (_revision != 0 || _disposed) return;
    final theme = NovelColorTheme.values.firstWhere(
      (candidate) => candidate.name == id,
      orElse: () => NovelColorTheme.cinnabar,
    );
    _persisted = theme;
    value = theme;
  }

  /// Applies immediately, then rolls back the latest choice if saving fails.
  Future<bool> select(NovelColorTheme theme) {
    final revision = ++_revision;
    final result = _writes.then((_) async {
      bool saved;
      try {
        saved = await _persist(theme.name);
      } catch (_) {
        saved = false;
      }
      if (saved) {
        _persisted = theme;
      } else if (revision == _revision && !_disposed) {
        value = _persisted;
      }
      return saved;
    });
    // Enqueue before notifying: a listener can select another theme itself.
    _writes = result.then<void>((_) {});
    value = theme;
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
