import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/novel/ai_settings_page.dart';
import 'package:fqapp/services/novel_ai.dart';
import 'package:fqapp/services/novel_ai_retrieval.dart';
import 'package:fqapp/widgets/reader/novel_ai_sheet.dart';

const _book = NovelAiBookContext(
  bookId: 'book-1',
  title: '测试小说',
  author: '测试作者',
  chapterTitle: '第一章',
  currentText: '当前章节正文',
);

class _Store extends NovelAiStore {
  _Store({NovelAiSettings? initial, this.key})
    : _value = initial ?? const NovelAiSettings();

  NovelAiSettings _value;
  String? key;

  @override
  NovelAiSettings get settings => _value;

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> readApiKey() async => key;

  @override
  Future<void> save(NovelAiSettings settings, {String? apiKey}) async {
    _value = settings;
    if (apiKey != null) key = apiKey;
    notifyListeners();
  }

  @override
  Future<void> clearApiKey() async {
    key = null;
    notifyListeners();
  }
}

class _FailingSaveStore extends _Store {
  _FailingSaveStore()
    : super(initial: const NovelAiSettings(enabled: true), key: 'existing-key');

  @override
  Future<void> save(NovelAiSettings settings, {String? apiKey}) async {
    throw StateError('test storage failure');
  }
}

typedef _Response =
    Future<String> Function(
      int call,
      NovelAiBookContext book,
      NovelAiCancellation? cancellation,
    );

class _Client extends NovelAiClient {
  _Client(this.response);

  final _Response response;
  int calls = 0;
  final histories = <List<NovelAiMessage>>[];
  final cancellations = <NovelAiCancellation?>[];
  final books = <NovelAiBookContext>[];
  final configurations = <NovelAiSettings>[];
  final questions = <String>[];

  @override
  Future<String> ask({
    required NovelAiSettings settings,
    required String apiKey,
    required NovelAiBookContext book,
    required String question,
    List<NovelAiMessage> history = const [],
    NovelAiCancellation? cancellation,
  }) {
    calls++;
    histories.add(List.of(history));
    cancellations.add(cancellation);
    books.add(book);
    configurations.add(settings);
    questions.add(question);
    return response(calls, book, cancellation);
  }
}

Widget _sheetApp(
  _Store store,
  _Client client, {
  Future<NovelAiBookContext> Function(String question)? resolveBook,
  NovelAiContextResolver? resolveContext,
  NovelAiReadConfirmation? confirmReadBefore,
  ThemeData? readerTheme,
  bool dark = false,
  double textScale = 1,
  double keyboard = 0,
  bool reduceMotion = false,
}) => MaterialApp(
  theme: dark ? ThemeData.dark() : ThemeData.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      viewInsets: EdgeInsets.only(bottom: keyboard),
      disableAnimations: reduceMotion,
      accessibleNavigation: reduceMotion,
    ),
    child: child!,
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showNovelAiSheet(
          context,
          book: _book,
          store: store,
          client: client,
          readerTheme: readerTheme,
          resolveBook: resolveBook,
          resolveContext: resolveContext,
          confirmReadBefore: confirmReadBefore,
        ),
        child: const Text('打开面板'),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('打开面板'));
  await tester.pumpAndSettle();
}

Future<void> _reach(
  WidgetTester tester,
  Finder target, {
  bool settings = false,
}) async {
  final list = find.byKey(
    ValueKey(settings ? 'novel-ai-settings-scroll' : 'novel-ai-sheet-scroll'),
  );
  final scrollable = find.descendant(
    of: list,
    matching: find.byType(Scrollable),
  );
  await tester.scrollUntilVisible(target, 160, scrollable: scrollable.first);
  await tester.pump();
}

Future<void> _ask(WidgetTester tester, String question) async {
  final field = find.byKey(const ValueKey('novel-ai-question'));
  await _reach(tester, field);
  await tester.enterText(field, question);
  // Entering a long question changes the TextField's height, while the panel
  // may also have a queued scroll-to-latest callback. Let those changes lay
  // out, then verify the lazily-built button remains tappable after scrolling.
  await tester.pump();
  final send = find.byKey(const ValueKey('novel-ai-send'));
  for (var attempt = 0; attempt < 5; attempt++) {
    await _reach(tester, send);
    if (send.hitTestable().evaluate().isNotEmpty) break;
  }
  expect(send.hitTestable(), findsOneWidget);
  await tester.tap(send);
  await tester.pump();
}

Future<void> _top(WidgetTester tester) async {
  final scrollable = find.descendant(
    of: find.byKey(const ValueKey('novel-ai-sheet-scroll')),
    matching: find.byType(Scrollable),
  );
  tester.state<ScrollableState>(scrollable.first).position.jumpTo(0);
  await tester.pump();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('settings save is opt-in, masks the key and retains正文 choice', (
    tester,
  ) async {
    final store = _Store();
    final client = _Client((_, _, _) async => '测试成功');
    await tester.pumpWidget(
      MaterialApp(
        home: NovelAiSettingsPage(store: store, client: client),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.settings.enabled, isFalse);
    expect(store.settings.includeChapter, isFalse);
    expect(find.textContaining('询问作品介绍时才附带简介'), findsOneWidget);
    expect(find.textContaining('近期问答'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('novel-ai-enabled')));
    final keyField = find.byKey(const ValueKey('novel-ai-api-key'));
    await _reach(tester, keyField, settings: true);
    final textField = tester.widget<TextField>(
      find.descendant(of: keyField, matching: find.byType(TextField)),
    );
    expect(textField.obscureText, isTrue);
    await tester.enterText(keyField, 'fake-key');
    await _reach(
      tester,
      find.byKey(const ValueKey('novel-ai-include-chapter')),
      settings: true,
    );
    await tester.tap(find.byKey(const ValueKey('novel-ai-include-chapter')));
    await _reach(
      tester,
      find.byKey(const ValueKey('novel-ai-save')),
      settings: true,
    );
    await tester.tap(find.byKey(const ValueKey('novel-ai-save')));
    await tester.pumpAndSettle();
    expect(store.settings.enabled, isTrue);
    expect(store.settings.includeChapter, isTrue);
    expect(await store.readApiKey(), 'fake-key');
    await _reach(tester, find.text('设置已保存'), settings: true);
    expect(find.text('设置已保存'), findsOneWidget);
    expect(client.calls, 0);
  });

  testWidgets('disabling still works with incomplete unsaved fields', (
    tester,
  ) async {
    final store = _Store(
      initial: const NovelAiSettings(enabled: true),
      key: 'fake-key',
    );
    await tester.pumpWidget(
      MaterialApp(home: NovelAiSettingsPage(store: store)),
    );
    await tester.pumpAndSettle();
    await _reach(
      tester,
      find.byKey(const ValueKey('novel-ai-base-url')),
      settings: true,
    );
    await tester.enterText(find.byKey(const ValueKey('novel-ai-base-url')), '');
    await _reach(
      tester,
      find.byKey(const ValueKey('novel-ai-model')),
      settings: true,
    );
    await tester.enterText(find.byKey(const ValueKey('novel-ai-model')), '');
    await tester.drag(
      find.byKey(const ValueKey('novel-ai-settings-scroll')),
      const Offset(0, 800),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('novel-ai-enabled')));
    await _reach(
      tester,
      find.byKey(const ValueKey('novel-ai-save')),
      settings: true,
    );
    await tester.tap(find.byKey(const ValueKey('novel-ai-save')));
    await tester.pumpAndSettle();
    expect(store.settings.enabled, isFalse);
    expect(store.settings.baseUrl, 'https://api.deepseek.com');
    expect(store.settings.model, 'deepseek-chat');
    expect(await store.readApiKey(), 'fake-key');
    await _reach(tester, find.textContaining('未保存无效'), settings: true);
    expect(find.textContaining('未保存无效'), findsOneWidget);
  });

  testWidgets('clearing a saved key disables the feature', (tester) async {
    final store = _Store(
      initial: const NovelAiSettings(enabled: true),
      key: 'fake-key',
    );
    await tester.pumpWidget(
      MaterialApp(home: NovelAiSettingsPage(store: store)),
    );
    await tester.pumpAndSettle();
    final clear = find.byKey(const ValueKey('novel-ai-clear-key'));
    await _reach(tester, clear, settings: true);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(store.settings.enabled, isFalse);
    expect(await store.readApiKey(), isNull);
  });

  testWidgets('connection test uses synthetic book data and no chapter', (
    tester,
  ) async {
    final store = _Store(
      initial: const NovelAiSettings(includeChapter: true),
      key: 'fake-key',
    );
    final client = _Client((_, _, _) async => '连接成功');
    await tester.pumpWidget(
      MaterialApp(
        home: NovelAiSettingsPage(store: store, client: client),
      ),
    );
    await tester.pumpAndSettle();
    final url = find.byKey(const ValueKey('novel-ai-base-url'));
    await _reach(tester, url, settings: true);
    await tester.enterText(url, 'http://localhost:9000');
    await tester.pump();
    expect(find.text('HTTP 明文仅限本机 localhost / 127.0.0.1'), findsOneWidget);
    final test = find.byKey(const ValueKey('novel-ai-test'));
    await _reach(tester, test, settings: true);
    await tester.tap(test);
    await tester.pumpAndSettle();
    expect(client.calls, 1);
    expect(client.books.single.title, '连接测试');
    expect(client.books.single.currentText, isEmpty);
    expect(client.configurations.single.includeChapter, isFalse);
    expect(client.configurations.single.enabled, isTrue);
    expect(store.settings.enabled, isFalse);
  });

  testWidgets('unconfigured reader offers settings without sending a request', (
    tester,
  ) async {
    final store = _Store();
    final client = _Client((_, _, _) async => '不应请求');
    await tester.pumpWidget(_sheetApp(store, client));
    await _open(tester);
    expect(find.textContaining('未启用或未配置 API Key'), findsOneWidget);
    expect(find.textContaining('近期问答'), findsOneWidget);
    expect(find.byKey(const ValueKey('novel-ai-send')), findsNothing);
    expect(
      find.byKey(const ValueKey('novel-ai-open-settings')),
      findsOneWidget,
    );
    expect(client.calls, 0);
  });

  testWidgets('正文授权必须确认，保留服务配置及密钥且不自动提问', (tester) async {
    final store = _Store(
      initial: const NovelAiSettings(
        enabled: true,
        baseUrl: 'https://example.org',
        model: 'existing-model',
      ),
      key: 'existing-key',
    );
    final client = _Client((_, _, _) async => '书籍资料回答');
    await tester.pumpWidget(_sheetApp(store, client));
    await _open(tester);
    await _ask(tester, '书籍简介是什么？');
    await tester.pumpAndSettle();
    expect(client.calls, 1);
    expect(client.configurations.single.includeChapter, isFalse);
    expect(find.text('书籍资料回答'), findsOneWidget);

    await _top(tester);
    final enable = find.byKey(const ValueKey('novel-ai-enable-chapter'));
    await _reach(tester, enable);
    expect(tester.getSize(enable).height, greaterThanOrEqualTo(48));
    await tester.tap(enable);
    await tester.pumpAndSettle();
    expect(find.textContaining('不检索未读章节'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.settings.includeChapter, isFalse);
    expect(client.calls, 1);
    await _top(tester);
    await _reach(tester, find.text('书籍资料回答'));
    expect(find.text('书籍资料回答'), findsOneWidget);

    await _top(tester);
    await _reach(tester, enable);
    await tester.tap(enable);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('novel-ai-confirm-enable-chapter')),
    );
    await tester.pumpAndSettle();
    expect(store.settings.includeChapter, isTrue);
    expect(store.settings.enabled, isTrue);
    expect(store.settings.baseUrl, 'https://example.org');
    expect(store.settings.model, 'existing-model');
    expect(await store.readApiKey(), 'existing-key');
    expect(find.text('书籍资料回答'), findsNothing);
    await _top(tester);
    await _reach(tester, find.text('设置已更改，对话已清空'));
    expect(find.text('设置已更改，对话已清空'), findsOneWidget);
    expect(client.calls, 1);
  });

  testWidgets('正文授权保存失败时保留原选择与密钥', (tester) async {
    final store = _FailingSaveStore();
    final client = _Client((_, _, _) async => '不应请求');
    await tester.pumpWidget(_sheetApp(store, client));
    await _open(tester);
    final enable = find.byKey(const ValueKey('novel-ai-enable-chapter'));
    await _reach(tester, enable);
    await tester.tap(enable);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('novel-ai-confirm-enable-chapter')),
    );
    await tester.pumpAndSettle();
    expect(store.settings.includeChapter, isFalse);
    expect(await store.readApiKey(), 'existing-key');
    expect(client.calls, 0);
    await _top(tester);
    final error = find.text('启用未确认，请检查服务设置后重试');
    await _reach(tester, error);
    expect(error, findsOneWidget);
  });

  testWidgets('the supplied reading theme is used for the panel', (
    tester,
  ) async {
    final store = _Store();
    final client = _Client((_, _, _) async => '回答');
    await tester.pumpWidget(
      _sheetApp(store, client, readerTheme: ThemeData.dark()),
    );
    await _open(tester);
    final panelContext = tester.element(find.text('小说 AI'));
    expect(Theme.of(panelContext).brightness, Brightness.dark);
  });

  testWidgets('a character shortcut only fills a draft and requires a name', (
    tester,
  ) async {
    final store = _Store(
      initial: const NovelAiSettings(enabled: true),
      key: 'fake-key',
    );
    final client = _Client((_, _, _) async => '回答');
    await tester.pumpWidget(_sheetApp(store, client));
    await _open(tester);
    final prompt = find.text('问人物');
    await _reach(tester, prompt);
    await tester.tap(prompt);
    await tester.pump();
    expect(client.calls, 0);
    final field = find.byKey(const ValueKey('novel-ai-question'));
    await _reach(tester, field);
    expect(
      tester.widget<TextField>(field).controller!.text,
      contains('【人物名称】'),
    );
    final send = find.byKey(const ValueKey('novel-ai-send'));
    await _reach(tester, send);
    await tester.tap(send);
    await tester.pump();
    expect(client.calls, 0);
    expect(find.text('请先填写想了解的人物或情节名称'), findsOneWidget);
  });

  testWidgets('failed question retries with bounded resolved book context', (
    tester,
  ) async {
    final store = _Store(
      initial: const NovelAiSettings(enabled: true, includeChapter: true),
      key: 'fake-key',
    );
    var resolutions = 0;
    final client = _Client((call, book, _) async {
      expect(book.bookId, _book.bookId);
      expect(book.excerpts.single.text, '相关缓存摘录');
      if (call == 1) throw const NovelAiException('模拟请求失败');
      return '这是根据资料给出的回答';
    });
    await tester.pumpWidget(
      _sheetApp(
        store,
        client,
        resolveBook: (question) async {
          resolutions++;
          expect(question, '主角是谁？');
          return const NovelAiBookContext(
            bookId: 'book-1',
            title: '测试小说',
            excerpts: [NovelAiExcerpt(chapterTitle: '第一章', text: '相关缓存摘录')],
          );
        },
      ),
    );
    await _open(tester);
    await _ask(tester, '主角是谁？');
    await tester.pumpAndSettle();
    expect(find.text('模拟请求失败'), findsOneWidget);
    final retry = find.byKey(const ValueKey('novel-ai-retry'));
    await _reach(tester, retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(find.text('这是根据资料给出的回答'), findsOneWidget);
    expect(client.calls, 2);
    expect(resolutions, 2);
    expect(client.histories.every((history) => history.isEmpty), isTrue);
  });

  testWidgets('追问检索使用最近问题线索，模型收到原句且换话题不会沿用旧线索', (tester) async {
    final store = _Store(
      initial: const NovelAiSettings(enabled: true, includeChapter: true),
      key: 'fake-key',
    );
    final client = _Client((_, _, _) async => '根据已读原文回答');
    final queries = <String>[];
    final matched = <Set<String>>[];
    final chapters = [
      for (var i = 0; i < 30; i++)
        NovelAiSourceChapter(
          bookId: 'book-1',
          id: 'chapter-$i',
          title: '第 ${i + 1} 章',
          index: i,
          text: i == 2 ? '沈檐拿到青铜钥匙后打开北塔侧门，躲避潮水。' : '第 $i 页只记载漫长的雨夜和窗外的景色。',
        ),
    ];
    await tester.pumpWidget(
      _sheetApp(
        store,
        client,
        resolveContext: (question, cancellation, _) async {
          queries.add(question);
          final result = await retrieveNovelAiContext(
            bookId: 'book-1',
            allowedChapterIds: chapters.map((chapter) => chapter.id).toSet(),
            chapters: chapters,
            question: question,
            cancellation: cancellation,
          );
          matched.add(
            result.excerpts.map((excerpt) => excerpt.chapterId).toSet(),
          );
          return _book;
        },
      ),
    );
    await _open(tester);

    const first = '沈檐拿到青铜钥匙后具体做了什么？';
    const followUp = '他为什么要这么做？';
    await _ask(tester, first);
    await tester.pumpAndSettle();
    await _ask(tester, followUp);
    await tester.pumpAndSettle();
    expect(queries[0], first);
    expect(queries[1], startsWith('$followUp\n'));
    expect(queries[1], contains(first));
    expect(matched[1], contains('chapter-2'));
    expect(client.questions.take(2), [first, followUp]);

    await _ask(tester, '后来呢？');
    await tester.pumpAndSettle();
    expect(queries.last, startsWith('后来呢？\n'));
    expect(queries.last, contains(followUp));
    expect(queries.last, contains(first));
    expect(client.questions.last, '后来呢？');

    await _ask(tester, '为什么呢？');
    await tester.pumpAndSettle();
    expect(queries.last, startsWith('为什么呢？\n'));
    expect(queries.last, contains('后来呢？'));
    expect(queries.last, contains(first));
    expect(matched.last, contains('chapter-2'));

    const newSubject = '顾澜的朋友为什么帮他？';
    await _ask(tester, newSubject);
    await tester.pumpAndSettle();
    expect(queries.last, newSubject);
    expect(client.questions.last, newSubject);
    await _ask(tester, '请问，他后来去了哪里？');
    await tester.pumpAndSettle();
    expect(queries.last, contains(newSubject));
    expect(queries.last, isNot(contains('沈檐')));
    expect(client.questions.last, '请问，他后来去了哪里？');

    await _ask(tester, '顾澜是谁？');
    await tester.pumpAndSettle();
    expect(queries.last, '顾澜是谁？');
    await _ask(tester, '他后来去了哪里？');
    await tester.pumpAndSettle();
    expect(queries.last, contains('顾澜是谁？'));
    expect(queries.last, isNot(contains('沈檐')));
    await _ask(tester, '换个话题，他的朋友呢？');
    await tester.pumpAndSettle();
    expect(queries.last, '换个话题，他的朋友呢？');
    expect(client.questions.last, '换个话题，他的朋友呢？');
  });

  testWidgets('关闭正文时不检索，启用后兼容解析器同样接收追问线索', (tester) async {
    final store = _Store(
      initial: const NovelAiSettings(enabled: true),
      key: 'fake-key',
    );
    final client = _Client((_, _, _) async => '回答');
    final queries = <String>[];
    await tester.pumpWidget(
      _sheetApp(
        store,
        client,
        resolveBook: (question) async {
          queries.add(question);
          return _book;
        },
      ),
    );
    await _open(tester);
    await _ask(tester, '沈檐拿到青铜钥匙后做了什么？');
    await tester.pumpAndSettle();
    await _ask(tester, '他为什么这么做？');
    await tester.pumpAndSettle();
    expect(queries, isEmpty);

    await store.save(store.settings.copyWith(includeChapter: true));
    await tester.pumpAndSettle();
    await _ask(tester, '他为什么这么做？');
    await tester.pumpAndSettle();
    expect(queries.single, '他为什么这么做？');
    const first = '沈檐拿到青铜钥匙后做了什么？';
    await _ask(tester, first);
    await tester.pumpAndSettle();
    await _ask(tester, '他为什么这么做？');
    await tester.pumpAndSettle();
    expect(queries.last, startsWith('他为什么这么做？\n'));
    expect(queries.last, contains(first));
    expect(client.questions.last, '他为什么这么做？');
  });

  testWidgets('清空会话、补录和设置变化后不保留追问线索', (tester) async {
    final store = _Store(
      initial: const NovelAiSettings(enabled: true, includeChapter: true),
      key: 'fake-key',
    );
    final client = _Client((_, _, _) async => '回答');
    final queries = <String>[];
    await tester.pumpWidget(
      _sheetApp(
        store,
        client,
        resolveContext: (question, _, _) async {
          queries.add(question);
          return _book;
        },
        confirmReadBefore: (_, _) async => _book,
      ),
    );
    await _open(tester);
    const first = '沈檐拿到青铜钥匙后做了什么？';
    const followUp = '他为什么这么做？';
    Future<void> askAndSettle(String question) async {
      await _ask(tester, question);
      await tester.pumpAndSettle();
    }

    await askAndSettle(first);
    await _top(tester);
    await tester.tap(find.byKey(const ValueKey('novel-ai-clear-conversation')));
    await tester.pumpAndSettle();
    await askAndSettle(followUp);
    expect(queries.last, followUp);

    await askAndSettle(first);
    await _top(tester);
    final backfill = find.byKey(const ValueKey('novel-ai-read-before'));
    await _reach(tester, backfill);
    await tester.tap(backfill);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('novel-ai-confirm-read-before')),
    );
    await tester.pumpAndSettle();
    await askAndSettle(followUp);
    expect(queries.last, followUp);

    await askAndSettle(first);
    await store.save(store.settings.copyWith(model: 'changed-model'));
    await tester.pumpAndSettle();
    await askAndSettle(followUp);
    expect(queries.last, followUp);
  });

  testWidgets('追问检索按 Unicode 字符计数并优先保留完整当前问题', (tester) async {
    final store = _Store(
      initial: const NovelAiSettings(enabled: true, includeChapter: true),
      key: 'fake-key',
    );
    final client = _Client((_, _, _) async => '回答');
    final queries = <String>[];
    await tester.pumpWidget(
      _sheetApp(
        store,
        client,
        resolveContext: (question, _, _) async {
          queries.add(question);
          return _book;
        },
      ),
    );
    await _open(tester);
    final first = '沈檐拿到青铜钥匙后${'😀' * 900}';
    final followUp = '他${'甲' * 1550}😀';
    await _ask(tester, first);
    await tester.pumpAndSettle();
    await _ask(tester, followUp);
    await tester.pumpAndSettle();
    expect(queries.last, startsWith('$followUp\n'));
    expect(queries.last, contains('沈檐拿到青铜钥匙'));
    expect(queries.last.runes.length, 2000);
    expect(
      queries.last.runes.where((rune) => rune >= 0xd800 && rune <= 0xdfff),
      isEmpty,
    );
    expect(client.questions.last, followUp);

    await _ask(tester, '他${'甲' * 2000}');
    await tester.pumpAndSettle();
    expect(queries, hasLength(2));
    expect(client.questions, hasLength(2));
    expect(find.text('问题过长，请控制在 2000 字以内'), findsOneWidget);
  });

  testWidgets('显示本次实际发送的有界原文与资料缺口', (tester) async {
    final store = _Store(
      initial: const NovelAiSettings(enabled: true, includeChapter: true),
      key: 'fake-key',
    );
    final longExcerpt = '甲' * 1900;
    final raw = NovelAiBookContext(
      bookId: 'book-1',
      title: '测试小说',
      chapterIndex: 3,
      chapterTitle: '第四章',
      currentText: '当前已显示原文',
      scopeDescription: '已确认读过的章节可能不连续',
      readChapterCount: 3,
      availableChapterCount: 2,
      missingChapterCount: 1,
      coverageIncomplete: true,
      excerpts: [
        NovelAiExcerpt(chapterTitle: '第二章', chapterIndex: 1, text: longExcerpt),
        const NovelAiExcerpt(
          chapterTitle: '第五章',
          chapterIndex: 4,
          text: '未来章节不应发送',
        ),
      ],
    );
    final client = _Client((_, _, _) async => '依据第二章回答。');
    await tester.pumpWidget(
      _sheetApp(store, client, resolveContext: (_, _, _) async => raw),
    );
    await _open(tester);
    await _ask(tester, '甲是谁？');
    await tester.pumpAndSettle();
    expect(client.calls, 1);
    final sent = client.books.single;
    expect(sent.excerpts, hasLength(1));
    expect(sent.excerpts.single.text.runes.length, 1800);
    expect(sent.excerpts.single.text, isNot(longExcerpt));

    await _top(tester);
    final warning = find.byKey(const ValueKey('novel-ai-coverage-warning'));
    await _reach(tester, warning);
    expect(find.textContaining('1 章确认已读但缺少完整正文'), findsOneWidget);
    await _reach(tester, find.text('本次资料不完整，可能遗漏相关内容。'));
    expect(find.text('本次范围：已确认读过的章节可能不连续'), findsOneWidget);
    final references = find.byKey(const ValueKey('novel-ai-references'));
    await _reach(tester, references);
    await tester.tap(find.text('参考原文'));
    await tester.pumpAndSettle();
    expect(find.text('第 2 章 · 第二章'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == sent.currentText,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data == sent.excerpts.single.text,
      ),
      findsOneWidget,
    );
    expect(find.text('未来章节不应发送'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('停止同步取消本地检索，迟到结果不发送且可重试', (tester) async {
    final store = _Store(
      initial: const NovelAiSettings(enabled: true, includeChapter: true),
      key: 'fake-key',
    );
    final first = Completer<NovelAiBookContext>();
    final tokens = <NovelAiCancellation>[];
    final client = _Client((_, _, _) async => '重试回答');
    await tester.pumpWidget(
      _sheetApp(
        store,
        client,
        resolveContext: (_, cancellation, progress) {
          tokens.add(cancellation);
          progress('正在查找已读前文 1/2');
          return tokens.length == 1 ? first.future : Future.value(_book);
        },
      ),
    );
    await _open(tester);
    await _ask(tester, '主角是谁？');
    expect(find.text('正在查找已读前文 1/2'), findsOneWidget);
    final stop = find.byKey(const ValueKey('novel-ai-stop'));
    await _reach(tester, stop);
    await tester.tap(stop);
    await tester.pump();
    expect(tokens.single.isCancelled, isTrue);
    first.complete(_book);
    await tester.pump();
    expect(client.calls, 0);
    final retry = find.byKey(const ValueKey('novel-ai-retry'));
    await _reach(tester, retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(tokens, hasLength(2));
    expect(tokens.last.isCancelled, isFalse);
    expect(client.calls, 1);
    expect(find.text('重试回答'), findsOneWidget);
  });

  testWidgets('确认前不会补录已读前文，确认后刷新范围', (tester) async {
    final store = _Store(
      initial: const NovelAiSettings(enabled: true, includeChapter: true),
      key: 'fake-key',
    );
    final client = _Client((_, _, _) async => '回答');
    var confirmations = 0;
    await tester.pumpWidget(
      _sheetApp(
        store,
        client,
        confirmReadBefore: (cancellation, progress) async {
          confirmations++;
          expect(cancellation.isCancelled, isFalse);
          progress('正在补录');
          return _book.copyWith(scopeDescription: '前文章节已确认');
        },
      ),
    );
    await _open(tester);
    final entry = find.byKey(const ValueKey('novel-ai-read-before'));
    await _reach(tester, entry);
    expect(tester.getSize(entry).height, greaterThanOrEqualTo(48));
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.textContaining('请仅在你确实读过'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(confirmations, 0);

    await tester.tap(entry);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('novel-ai-confirm-read-before')),
    );
    await tester.pumpAndSettle();
    expect(confirmations, 1);
    await _top(tester);
    expect(find.text('前文章节已确认'), findsOneWidget);
    expect(client.calls, 0);
  });

  testWidgets('没有可用原文时明确提示，而不是伪造参考来源', (tester) async {
    final store = _Store(
      initial: const NovelAiSettings(enabled: true, includeChapter: true),
      key: 'fake-key',
    );
    final client = _Client((_, _, _) async => '当前资料不足');
    await tester.pumpWidget(
      _sheetApp(
        store,
        client,
        resolveContext: (_, _, _) async =>
            const NovelAiBookContext(bookId: 'book-1', title: '测试小说'),
      ),
    );
    await _open(tester);
    await _ask(tester, '问一个人物');
    await tester.pumpAndSettle();
    await _top(tester);
    final noEvidence = find.textContaining('本次未找到可发送的已读原文');
    await _reach(tester, noEvidence);
    expect(noEvidence, findsOneWidget);
    expect(find.byKey(const ValueKey('novel-ai-references')), findsNothing);
  });

  testWidgets('closing cancels an in-flight request and ignores a late reply', (
    tester,
  ) async {
    final store = _Store(
      initial: const NovelAiSettings(enabled: true),
      key: 'fake-key',
    );
    final reply = Completer<String>();
    final client = _Client((_, _, _) => reply.future);
    await tester.pumpWidget(_sheetApp(store, client));
    await _open(tester);
    await _ask(tester, '这本书讲什么？');
    expect(client.calls, 1);
    final close = find.byKey(const ValueKey('novel-ai-close'));
    final list = find.byKey(const ValueKey('novel-ai-sheet-scroll'));
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    tester.state<ScrollableState>(scrollable.first).position.jumpTo(0);
    await tester.pump();
    await tester.tap(close);
    expect(client.cancellations.single!.isCancelled, isTrue);
    await tester.pumpAndSettle();
    reply.complete('迟到回答');
    await tester.pump();
    expect(find.text('迟到回答'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backgrounding cancels while local context is being resolved', (
    tester,
  ) async {
    addTearDown(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );
    final store = _Store(
      initial: const NovelAiSettings(enabled: true, includeChapter: true),
      key: 'fake-key',
    );
    final resolved = Completer<NovelAiBookContext>();
    final client = _Client((_, _, _) async => '不应请求');
    await tester.pumpWidget(
      _sheetApp(store, client, resolveBook: (_) => resolved.future),
    );
    await _open(tester);
    await _ask(tester, '主角是谁？');
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    resolved.complete(_book);
    await tester.pump();
    expect(client.calls, 0);
    expect(find.textContaining('已离开前台'), findsOneWidget);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('后台取消会传给新的本地检索，迟到进度和结果均失效', (tester) async {
    addTearDown(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );
    final store = _Store(
      initial: const NovelAiSettings(enabled: true, includeChapter: true),
      key: 'fake-key',
    );
    final resolved = Completer<NovelAiBookContext>();
    late NovelAiCancellation token;
    late void Function(String) progress;
    final client = _Client((_, _, _) async => '不应请求');
    await tester.pumpWidget(
      _sheetApp(
        store,
        client,
        resolveContext: (_, cancellation, report) {
          token = cancellation;
          progress = report;
          return resolved.future;
        },
      ),
    );
    await _open(tester);
    await _ask(tester, '人物是谁？');
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(token.isCancelled, isTrue);
    progress('不应显示的迟到进度');
    resolved.complete(_book);
    await tester.pump();
    expect(client.calls, 0);
    expect(find.text('不应显示的迟到进度'), findsNothing);
    expect(find.textContaining('已离开前台'), findsOneWidget);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  for (final viewport in [const Size(320, 720), const Size(640, 320)]) {
    testWidgets('已读授权、补录和依据适配夜间两倍字号 $viewport', (tester) async {
      await tester.binding.setSurfaceSize(viewport);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _Store(
        initial: const NovelAiSettings(enabled: true),
        key: 'fake-key',
      );
      final client = _Client((_, _, _) async => '可核对的回答');
      await tester.pumpWidget(
        _sheetApp(
          store,
          client,
          dark: true,
          textScale: 2,
          reduceMotion: true,
          resolveContext: (_, _, _) async => const NovelAiBookContext(
            bookId: 'book-1',
            title: '测试小说',
            chapterTitle: '第二章',
            chapterIndex: 1,
            excerpts: [
              NovelAiExcerpt(
                chapterTitle: '第一章',
                chapterIndex: 0,
                text: '原文依据',
              ),
            ],
          ),
          confirmReadBefore: (_, _) async =>
              _book.copyWith(scopeDescription: '已确认前文'),
        ),
      );
      await _open(tester);
      final enable = find.byKey(const ValueKey('novel-ai-enable-chapter'));
      await _reach(tester, enable);
      expect(tester.getSize(enable).height, greaterThanOrEqualTo(48));
      await tester.tap(enable);
      await tester.pumpAndSettle();
      final confirmEnable = find.byKey(
        const ValueKey('novel-ai-confirm-enable-chapter'),
      );
      await tester.ensureVisible(confirmEnable);
      await tester.tap(confirmEnable);
      await tester.pumpAndSettle();
      expect(store.settings.includeChapter, isTrue);

      await _top(tester);
      final confirmRead = find.byKey(const ValueKey('novel-ai-read-before'));
      await _reach(tester, confirmRead);
      expect(tester.getSize(confirmRead).height, greaterThanOrEqualTo(48));
      await tester.tap(confirmRead);
      await tester.pumpAndSettle();
      final confirmed = find.byKey(
        const ValueKey('novel-ai-confirm-read-before'),
      );
      await tester.ensureVisible(confirmed);
      await tester.tap(confirmed);
      await tester.pumpAndSettle();
      await _top(tester);
      expect(find.text('已确认前文'), findsOneWidget);

      await _top(tester);
      await _ask(tester, '谁做了什么？');
      await tester.pumpAndSettle();
      await _top(tester);
      final references = find.byKey(const ValueKey('novel-ai-references'));
      await _reach(tester, references);
      await tester.tap(find.text('参考原文'));
      await tester.pumpAndSettle();
      expect(find.text('第 1 章 · 第一章'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'changing settings clears conversation before a new provider sees it',
    (tester) async {
      final store = _Store(
        initial: const NovelAiSettings(enabled: true),
        key: 'fake-key',
      );
      final client = _Client((call, _, _) async => '回答 $call');
      await tester.pumpWidget(_sheetApp(store, client));
      await _open(tester);
      await _ask(tester, '第一个问题');
      await tester.pumpAndSettle();
      expect(find.text('回答 1'), findsOneWidget);
      await store.save(
        store.settings.copyWith(baseUrl: 'https://other.example'),
      );
      await tester.pumpAndSettle();
      expect(find.text('回答 1'), findsNothing);
      expect(find.text('设置已更改，对话已清空'), findsOneWidget);
      await _ask(tester, '第二个问题');
      await tester.pumpAndSettle();
      expect(client.histories, hasLength(2));
      expect(client.histories.last, isEmpty);
    },
  );

  testWidgets('dark 2x narrow sheet remains scrollable with keyboard inset', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = _Store(
      initial: const NovelAiSettings(enabled: true),
      key: 'fake-key',
    );
    final client = _Client((_, _, _) async => '回答');
    await tester.pumpWidget(
      _sheetApp(store, client, dark: true, textScale: 2, keyboard: 240),
    );
    await _open(tester);
    await _reach(tester, find.byKey(const ValueKey('novel-ai-question')));
    await tester.enterText(
      find.byKey(const ValueKey('novel-ai-question')),
      '问题',
    );
    await _reach(tester, find.byKey(const ValueKey('novel-ai-send')));
    expect(
      tester.getSize(find.byKey(const ValueKey('novel-ai-send'))).height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.takeException(), isNull);
  });

  for (final viewport in [
    (size: const Size(320, 720), keyboard: 240.0),
    (size: const Size(640, 320), keyboard: 110.0),
  ]) {
    testWidgets(
      'settings remain usable at 2x with keyboard: ${viewport.size}',
      (tester) async {
        await tester.binding.setSurfaceSize(viewport.size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final store = _Store();
        final response = Completer<String>();
        final client = _Client((_, _, _) => response.future);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                viewInsets: EdgeInsets.only(bottom: viewport.keyboard),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: NovelAiSettingsPage(store: store, client: client),
          ),
        );
        await tester.pumpAndSettle();

        final enabled = find.byKey(const ValueKey('novel-ai-enabled'));
        await _reach(tester, enabled, settings: true);
        await tester.tap(enabled);
        await tester.pump();

        final url = find.byKey(const ValueKey('novel-ai-base-url'));
        final model = find.byKey(const ValueKey('novel-ai-model'));
        final key = find.byKey(const ValueKey('novel-ai-api-key'));
        await _reach(tester, url, settings: true);
        await tester.enterText(url, 'http://localhost:9000');
        await _reach(tester, model, settings: true);
        await tester.enterText(model, 'test-model');
        await _reach(tester, key, settings: true);
        await tester.enterText(key, 'fake-key');
        expect(tester.takeException(), isNull);

        final save = find.byKey(const ValueKey('novel-ai-save'));
        await _reach(tester, save, settings: true);
        expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
        await tester.tap(save);
        await tester.pump();
        expect(store.settings.enabled, isTrue);
        expect(store.settings.baseUrl, 'http://localhost:9000');
        expect(store.settings.model, 'test-model');
        expect(await store.readApiKey(), 'fake-key');

        final test = find.byKey(const ValueKey('novel-ai-test'));
        await _reach(tester, test, settings: true);
        expect(tester.getSize(test).height, greaterThanOrEqualTo(48));
        await tester.tap(test);
        await tester.pump();
        expect(client.calls, 1);
        final stop = find.widgetWithText(TextButton, '停止测试');
        await _reach(tester, stop, settings: true);
        expect(tester.getSize(stop).height, greaterThanOrEqualTo(48));
        await tester.tap(stop);
        await tester.pump();
        expect(client.cancellations.single!.isCancelled, isTrue);
        response.complete('迟到的连接测试');
        await tester.pump();

        final scroll = find.byKey(const ValueKey('novel-ai-settings-scroll'));
        await tester.drag(scroll, const Offset(0, 5000));
        await tester.pumpAndSettle();
        await _reach(tester, url, settings: true);
        await tester.enterText(url, 'http://example.com');
        await _reach(tester, test, settings: true);
        await tester.tap(test);
        await tester.pumpAndSettle();
        await tester.drag(scroll, const Offset(0, 5000));
        await tester.pumpAndSettle();
        final error = find.textContaining('明文 HTTP 仅支持本机地址');
        await _reach(tester, error, settings: true);
        expect(error, findsOneWidget);
        expect(client.calls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
