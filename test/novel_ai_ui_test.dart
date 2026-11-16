import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/novel/ai_settings_page.dart';
import 'package:fqapp/services/novel_ai.dart';
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
    return response(calls, book, cancellation);
  }
}

Widget _sheetApp(
  _Store store,
  _Client client, {
  Future<NovelAiBookContext> Function(String question)? resolveBook,
  ThemeData? readerTheme,
  bool dark = false,
  double textScale = 1,
  double keyboard = 0,
}) => MaterialApp(
  theme: dark ? ThemeData.dark() : ThemeData.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      viewInsets: EdgeInsets.only(bottom: keyboard),
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
  await _reach(tester, find.byKey(const ValueKey('novel-ai-send')));
  await tester.tap(find.byKey(const ValueKey('novel-ai-send')));
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
    expect(find.textContaining('书名、作者、简介'), findsOneWidget);
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
