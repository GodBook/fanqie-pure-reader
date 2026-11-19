import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/novel_ai.dart';
import 'package:fqapp/services/novel_ai_read_scope.dart';
import 'package:fqapp/services/novel_ai_recap.dart';
import 'package:fqapp/widgets/reader/novel_ai_recap_sheet.dart';

const _fact = '林远把信交给守门人，决定去北塔寻找失散的同伴。';

NovelAiRecapInput _input() => buildNovelAiRecapInput(
  scope: NovelAiReadScopeSnapshot(
    bookId: 'book',
    chapters: [
      NovelAiAllowedChapter(
        chapterId: 'previous',
        title: '渡口重逢',
        index: 1,
        revision: 'previous-revision',
        segments: const [NovelAiReadSegment(start: 12, text: _fact)],
      ),
    ],
    persistentStorageAvailable: true,
  ),
  boundary: const NovelAiRecapBoundary(
    bookId: 'book',
    chapterId: 'current',
    chapterIndex: 2,
    offset: 20,
    revision: 'current-revision',
  ),
  title: '测试小说',
  chapterTitle: '第三章',
);

class _Store extends NovelAiStore {
  _Store({bool enabled = true, bool body = true})
    : _settings = NovelAiSettings(enabled: enabled, includeChapter: body);

  NovelAiSettings _settings;
  int keyReads = 0;

  @override
  NovelAiSettings get settings => _settings;

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> readApiKey() async {
    keyReads++;
    return 'synthetic-key';
  }

  @override
  Future<void> save(NovelAiSettings settings, {String? apiKey}) async {
    _settings = settings;
    notifyListeners();
  }
}

class _Client extends NovelAiClient {
  _Client({this.reply});
  final Future<String> Function()? reply;
  int calls = 0;
  NovelAiCancellation? cancellation;

  @override
  Future<String> ask({
    required NovelAiSettings settings,
    required String apiKey,
    required NovelAiBookContext book,
    required String question,
    List<NovelAiMessage> history = const [],
    NovelAiCancellation? cancellation,
  }) async {
    calls++;
    this.cancellation = cancellation;
    return reply == null ? _validAnswer() : reply!();
  }
}

String _validAnswer() => jsonEncode({
  'plot': [
    {'source': 1, 'quote': _fact},
  ],
  'characters': [],
});

Widget _app(
  _Store store,
  _Client client, {
  void Function(NovelAiRecapItem?)? onSelected,
  NovelAiRecapResolver? resolve,
  double scale = 1,
  bool dark = false,
  bool reducedMotion = false,
  GlobalKey<NavigatorState>? navigatorKey,
  String chapterTitle = '第三章',
}) => MaterialApp(
  navigatorKey: navigatorKey,
  theme: dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData(useMaterial3: true),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      disableAnimations: reducedMotion,
      accessibleNavigation: reducedMotion,
    ),
    child: child!,
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          final selected = await showNovelAiRecapSheet(
            context,
            title: '测试小说',
            chapterTitle: chapterTitle,
            store: store,
            resolve: resolve ?? (_) async => _input(),
            service: NovelAiRecapService(client: client),
          );
          onSelected?.call(selected);
        },
        child: const Text('打开回顾'),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('打开回顾'));
  await tester.pumpAndSettle();
}

Future<void> _reach(WidgetTester tester, String key) async {
  final scroll = find
      .descendant(
        of: find.byKey(const ValueKey('novel-ai-recap-scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(
    find.byKey(ValueKey(key)),
    160,
    scrollable: scroll,
  );
  await tester.pump();
}

Future<void> _generate(WidgetTester tester) async {
  await _reach(tester, 'novel-ai-recap-generate');
  await tester.tap(find.byKey(const ValueKey('novel-ai-recap-generate')));
  await tester.pumpAndSettle();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets(
    'opening never reads key, resolves body, or generates; explicit action yields exact source',
    (tester) async {
      final store = _Store();
      final client = _Client();
      var resolves = 0;
      NovelAiRecapItem? selected;
      addTearDown(store.dispose);
      await tester.pumpWidget(
        _app(
          store,
          client,
          onSelected: (item) => selected = item,
          resolve: (_) async {
            resolves++;
            return _input();
          },
        ),
      );
      await _open(tester);
      expect(client.calls, 0);
      expect(resolves, 0);
      expect(store.keyReads, 0);
      await _generate(tester);
      expect(client.calls, 1);
      expect(resolves, 1);
      expect(store.keyReads, 1);
      await _reach(tester, 'novel-ai-recap-source-plot-0');
      expect(find.text(_fact), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('novel-ai-recap-source-plot-0')),
      );
      await tester.pumpAndSettle();
      expect(selected?.source.chapterId, 'previous');
      expect(selected?.start, 12);
      expect(selected?.quote, _fact);
    },
  );

  testWidgets(
    'AI off and body off never request; consent still requires Generate',
    (tester) async {
      final store = _Store(enabled: false, body: false);
      final client = _Client();
      addTearDown(store.dispose);
      await tester.pumpWidget(_app(store, client));
      await _open(tester);
      expect(
        find.byKey(const ValueKey('novel-ai-recap-generate')),
        findsNothing,
      );
      expect(client.calls, 0);
      await store.save(store.settings.copyWith(enabled: true));
      await tester.pumpAndSettle();
      await _reach(tester, 'novel-ai-recap-enable-body');
      await tester.tap(
        find.byKey(const ValueKey('novel-ai-recap-enable-body')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.settings.includeChapter, isFalse);
      expect(client.calls, 0);
      await tester.tap(
        find.byKey(const ValueKey('novel-ai-recap-enable-body')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('novel-ai-recap-confirm-body')),
      );
      await tester.pumpAndSettle();
      expect(store.settings.includeChapter, isTrue);
      expect(client.calls, 0);
      expect(store.keyReads, 0);
      await _generate(tester);
      expect(client.calls, 1);
    },
  );

  testWidgets('unverified raw answer never becomes visible', (tester) async {
    const raw = '模型记忆中的秘密结局，不能显示到产品里。';
    final store = _Store();
    final client = _Client(reply: () async => raw);
    addTearDown(store.dispose);
    await tester.pumpWidget(_app(store, client));
    await _open(tester);
    await _generate(tester);
    expect(find.text(raw), findsNothing);
    expect(find.textContaining('模型原始回答未显示'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('novel-ai-recap-source-plot-0')),
      findsNothing,
    );
  });

  testWidgets('Stop cancels active work and ignores late valid output', (
    tester,
  ) async {
    final store = _Store();
    final pending = Completer<String>();
    final client = _Client(reply: () => pending.future);
    addTearDown(store.dispose);
    await tester.pumpWidget(_app(store, client));
    await _open(tester);
    await _generate(tester);
    await _reach(tester, 'novel-ai-recap-stop');
    await tester.tap(find.byKey(const ValueKey('novel-ai-recap-stop')));
    await tester.pumpAndSettle();
    expect(client.cancellation!.isCancelled, isTrue);
    pending.complete(_validAnswer());
    await tester.pumpAndSettle();
    expect(find.text(_fact), findsNothing);
    expect(find.text('已停止，可手动重试'), findsOneWidget);
  });

  testWidgets('background and return do not restart cancelled generation', (
    tester,
  ) async {
    final store = _Store();
    final pending = Completer<String>();
    final client = _Client(reply: () => pending.future);
    addTearDown(store.dispose);
    await tester.pumpWidget(_app(store, client));
    await _open(tester);
    await _generate(tester);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(client.cancellation!.isCancelled, isTrue);
    pending.complete(_validAnswer());
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(client.calls, 1);
    expect(find.text(_fact), findsNothing);
    expect(find.text('应用已离开前台，请手动重试'), findsOneWidget);
  });

  testWidgets(
    'system back cancels before a late response can update the reader',
    (tester) async {
      final store = _Store();
      final pending = Completer<String>();
      final client = _Client(reply: () => pending.future);
      final navigator = GlobalKey<NavigatorState>();
      addTearDown(store.dispose);
      await tester.pumpWidget(_app(store, client, navigatorKey: navigator));
      await _open(tester);
      await _generate(tester);
      navigator.currentState!.pop();
      await tester.pump();
      expect(client.cancellation!.isCancelled, isTrue);
      pending.complete(_validAnswer());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('novel-ai-recap-sheet')), findsNothing);
      expect(find.text(_fact), findsNothing);
    },
  );

  testWidgets('changing settings cancels and clears the ephemeral result', (
    tester,
  ) async {
    final store = _Store();
    final pending = Completer<String>();
    final client = _Client(reply: () => pending.future);
    addTearDown(store.dispose);
    await tester.pumpWidget(_app(store, client));
    await _open(tester);
    await _generate(tester);
    await store.save(store.settings.copyWith(includeChapter: false));
    await tester.pump();
    expect(client.cancellation!.isCancelled, isTrue);
    pending.complete(_validAnswer());
    await tester.pumpAndSettle();
    expect(find.text(_fact), findsNothing);
    expect(find.byKey(const ValueKey('novel-ai-recap-generate')), findsNothing);
    expect(client.calls, 1);
  });

  for (final size in [const Size(320, 640), const Size(800, 360)]) {
    testWidgets('dark 2x text and reduced motion remain scrollable at $size', (
      tester,
    ) async {
      await binding.setSurfaceSize(size);
      addTearDown(() => binding.setSurfaceSize(null));
      final store = _Store();
      final client = _Client();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        _app(
          store,
          client,
          scale: 2,
          dark: true,
          reducedMotion: true,
          chapterTitle: '很长的章节标题用来检查大字与横屏下当前阅读范围能够完整换行显示',
        ),
      );
      await _open(tester);
      await _generate(tester);
      await _reach(tester, 'novel-ai-recap-source-plot-0');
      final button = find.byKey(const ValueKey('novel-ai-recap-source-plot-0'));
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
      expect(client.calls, 1);
    });
  }
}
