import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'novel_color_theme.dart';
import 'reader_preferences.dart';

typedef PortableCapture = Future<Map<String, dynamic>> Function();
typedef PortableMerge = Future<void> Function(Map<String, dynamic> data);

/// Only reader choices, never a dump of preferences, paths or credentials.
class NovelPortableSettings {
  static final sections =
      <String, ({PortableCapture capture, PortableMerge merge})>{};
  static final validators = <String, void Function(Map<String, dynamic>)>{};
  static const sectionNames = {
    'library',
    'follow',
    'discovery',
    'topics',
    'readerProfiles',
    'readingMetrics',
    'localBooks',
  };

  static const _numbers = <String, (double, double)>{
    'reader_font_size': (10, 80),
    'reader_comment_font_size': (10, 80),
    'reader_font_weight': (100, 900),
    'reader_line_height': (1, 4),
    'reader_paragraph_spacing': (0, 100),
    'reader_horizontal_padding': (0, 120),
    'reader_letter_spacing': (-5, 20),
    'reader_vertical_padding': (0, 120),
    'reader_title_size': (10, 100),
    'reader_auto_turn_seconds': (3, 60),
    'reader_eink_refresh_interval': (1, 1000),
    'novel_feed_genre': (0, 100),
    'novel_feed_score': (0, 9.9),
    'novel_rest_interval_minutes_v1': (0, 90),
  };
  static const _booleans = {
    'novel_personal_recommendations_enabled',
    'reader_comment_defaults_v2',
    'reader_comment_font_follows_reading',
    'reader_show_reading_info',
    'reader_volume_key_turn',
    'reader_continuous_reading',
    'reader_instant_swipe_turn',
    'reader_tap_left_turns_next',
    'reader_show_paragraph_bubbles',
    'reader_dialogue_highlight',
    'novel_feed_hide_shelf',
    'novel_feed_hide_history',
  };
  static const _integerKeys = {
    'reader_font_weight',
    'reader_auto_turn_seconds',
    'reader_eink_refresh_interval',
    'novel_feed_genre',
    'novel_rest_interval_minutes_v1',
  };
  static const _enums = <String, Set<String>>{
    'theme_mode': {'system', 'light', 'dark'},
    'novel_color_theme': {
      'cinnabar',
      'pine',
      'indigo',
      'lake',
      'plum',
      'amber',
    },
    'reader_theme_preset': {'light', 'eyeCare', 'parchment', 'dark', 'eink'},
    'reader_title_alignment': {'start', 'center'},
    'reader_info_mode': {'hidden', 'compact', 'detailed'},
    'reader_page_mode': {'paged', 'scroll'},
    'reader_page_turn_style': {'cover', 'slide', 'curl', 'none'},
    'reader_scroll_chapter_mode': {'replace', 'joined'},
    'reader_dialogue_highlight_style': {'automatic', 'background', 'underline'},
    'novel_feed_status': {'any', 'ongoing', 'completed'},
    'novel_feed_sort': {'recommended', 'score', 'longest', 'shortest'},
    'novel_feed_words': {'any', 'under300k', 'from300k', 'from1m', 'from3m'},
  };

  static bool _valid(String key, Object? value) {
    if (key == 'novel_rest_interval_minutes_v1') {
      return value is num &&
          value.isFinite &&
          value == value.toInt() &&
          const {0, 1, 15, 30, 45, 60, 90}.contains(value.toInt());
    }
    if (_booleans.contains(key)) return value is bool;
    final bounds = _numbers[key];
    if (bounds != null) {
      return value is num &&
          value.isFinite &&
          (!_integerKeys.contains(key) || value == value.toInt()) &&
          value >= bounds.$1 &&
          value <= bounds.$2;
    }
    final choices = _enums[key];
    if (choices != null) return value is String && choices.contains(value);
    if (key == 'reader_tap_zones') {
      return value is List &&
          value.length == 9 &&
          value.contains('menu') &&
          value.every(
            (v) =>
                v is String &&
                const {
                  'none',
                  'menu',
                  'prevPage',
                  'nextPage',
                  'prevChapter',
                  'nextChapter',
                  'toc',
                }.contains(v),
          );
    }
    return false;
  }

  static Map<String, dynamic> validate(dynamic raw) {
    if (raw is! Map ||
        raw['version'] != 1 ||
        raw['preferences'] is! Map ||
        raw['features'] is! Map) {
      throw const FormatException('阅读设置备份格式无效');
    }
    final preferences = <String, dynamic>{};
    for (final entry in (raw['preferences'] as Map).entries) {
      if (entry.key is! String || !_valid(entry.key as String, entry.value)) {
        throw const FormatException('备份包含不支持的阅读设置');
      }
      final key = entry.key as String;
      preferences[key] = _integerKeys.contains(key)
          ? (entry.value as num).toInt()
          : _numbers.containsKey(key)
          ? (entry.value as num).toDouble()
          : entry.value;
    }
    final features = <String, dynamic>{};
    for (final entry in (raw['features'] as Map).entries) {
      if (!sectionNames.contains(entry.key) || entry.value is! Map) {
        throw const FormatException('新增功能备份类型无效');
      }
      _validateTree(entry.value, 0);
      features[entry.key as String] = Map<String, dynamic>.from(
        entry.value as Map,
      );
    }
    return {'version': 1, 'preferences': preferences, 'features': features};
  }

  static void _validateTree(dynamic value, int depth) {
    if (depth > 12) throw const FormatException('备份数据层级过深');
    if (value == null || value is bool || value is String) {
      if (value is String && value.length > 1024 * 1024) {
        throw const FormatException('备份字段过长');
      }
      return;
    }
    if (value is num && value.isFinite) return;
    if (value is List && value.length <= 20000) {
      for (final item in value) {
        _validateTree(item, depth + 1);
      }
      return;
    }
    if (value is Map &&
        value.length <= 20000 &&
        value.keys.every((k) => k is String)) {
      for (final item in value.values) {
        _validateTree(item, depth + 1);
      }
      return;
    }
    throw const FormatException('备份字段无效');
  }

  static Future<Map<String, dynamic>> capture() async {
    await ReaderPreferences.load();
    final store = await SharedPreferences.getInstance();
    final preferences = <String, dynamic>{};
    for (final key in {
      ..._numbers.keys,
      ..._booleans,
      ..._enums.keys,
      'reader_tap_zones',
    }) {
      final value = store.get(key);
      if (value != null && _valid(key, value)) preferences[key] = value;
    }
    final features = <String, dynamic>{};
    for (final section in sections.entries) {
      if (!sectionNames.contains(section.key)) throw StateError('不支持的备份模块');
      features[section.key] = await section.value.capture();
    }
    return validate({
      'version': 1,
      'preferences': preferences,
      'features': features,
    });
  }

  static Future<void> _put(
    SharedPreferences store,
    String key,
    Object? value,
  ) async {
    final saved = switch (value) {
      null => await store.remove(key),
      bool v => await store.setBool(key, v),
      int v => await store.setInt(key, v),
      double v => await store.setDouble(key, v),
      String v => await store.setString(key, v),
      List v => await store.setStringList(key, v.cast<String>()),
      _ => false,
    };
    if (!saved) throw StateError('阅读设置保存失败');
  }

  static Future<void> restore(Map<String, dynamic> input) async {
    final data = validate(input);
    requireAvailable(data);
    final preferences = Map<String, dynamic>.from(data['preferences'] as Map);
    final features = Map<String, dynamic>.from(data['features'] as Map);
    if (features.keys.any((key) => !sections.containsKey(key))) {
      throw const FormatException('当前版本未准备好恢复全部功能数据，请重新进入后重试');
    }
    await ReaderPreferences.load();
    final store = await SharedPreferences.getInstance();
    final previous = {for (final key in preferences.keys) key: store.get(key)};
    try {
      for (final entry in preferences.entries) {
        if (entry.key == novelColorThemeKey) continue;
        await _put(store, entry.key, entry.value);
      }
      if (preferences[themeModeKey] is String) {
        themeModeNotifier.value = themeModeFromName(
          preferences[themeModeKey] as String,
        );
      }
    } catch (_) {
      for (final entry in previous.entries) {
        await _put(store, entry.key, entry.value);
      }
      rethrow;
    }
    for (final entry in features.entries) {
      await sections[entry.key]!.merge(
        Map<String, dynamic>.from(entry.value as Map),
      );
    }
    final color = preferences['novel_color_theme'];
    if (color is String) {
      final selected = NovelColorTheme.values.firstWhere(
        (v) => v.name == color,
      );
      if (!await NovelColorThemeStore.instance.select(selected)) {
        throw StateError('主题颜色恢复失败');
      }
    }
  }

  static void requireAvailable(Map<String, dynamic> input) {
    final data = validate(input);
    final features = data['features'] as Map;
    if (features.keys.any(
      (key) => !sections.containsKey(key) || !validators.containsKey(key),
    )) {
      throw const FormatException('当前版本未准备好恢复全部功能数据，请重新进入后重试');
    }
    for (final entry in features.entries) {
      validators[entry.key]!(Map<String, dynamic>.from(entry.value as Map));
    }
  }
}
