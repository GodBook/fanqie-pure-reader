import 'dart:async';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/reader_text_lookup.dart';
import 'package:fqapp/services/reader_word_boundary.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_text_lookup_dialog.dart';
import 'package:fqapp/widgets/reader/reader_text_selection.dart';

import 'support/fakes.dart';

const _body =
    '<p idx="0">——这也不是他的客厅。</p>'
    '<p idx="1">A wonderful story is here.</p>'
    '<p idx="2">最后一段。</p>';
const _wordBoundaryChannel = MethodChannel('fqapp/reader_word_boundary');

void _mockWordBoundary(
  WidgetTester tester,
  Future<dynamic> Function(MethodCall call) handler,
) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    _wordBoundaryChannel,
    handler,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _wordBoundaryChannel,
      null,
    ),
  );
}

class _Underlines extends ReaderUnderlineStore {
  _Underlines() : super(hive: null);

  @override
  Future<Map<String, ReaderUnderline>> load(
    String bookId,
    String chapterId,
  ) async => {};

  @override
  Future<List<ReaderRangeUnderline>> loadRanges(
    String bookId,
    String chapterId,
  ) async => [];
}

class _ProcessText implements ProcessTextService {
  final List<(String, String, bool)> calls = [];
  String? result;
  bool fail = false;

  @override
  Future<List<ProcessTextAction>> queryTextActions() async => const [
    ProcessTextAction('dictionary', '测试词典'),
  ];

  @override
  Future<String?> processTextAction(
    String id,
    String text,
    bool readOnly,
  ) async {
    calls.add((id, text, readOnly));
    if (fail) throw PlatformException(code: 'unavailable');
    return result;
  }
}

Future<void> _mountReader(
  WidgetTester tester, {
  bool dark = false,
  String pageMode = 'scroll',
}) async {
  setSingleChapterPrefs({
    'reader_page_mode': pageMode,
    if (dark) 'reader_theme_preset': 'dark',
  });
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: ReaderPage(
        bookId: 'word-test',
        title: '测试书',
        chapters: [Chapter(itemId: 'c1', title: '第一章', volumeName: '')],
        startIndex: 0,
        novelOnly: true,
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
        underlineStore: _Underlines(),
        chapterLoader: (_) async => parseChapterContent(_body).toCacheText(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _layer(String text) => find.byWidgetPredicate(
  (widget) =>
      widget is ReaderBlockMarkLayer && widget.block.text.contains(text),
);

Future<Offset> _wordPoint(WidgetTester tester, String text, String word) async {
  final finder = _layer(text);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  final layer = tester.widget<ReaderBlockMarkLayer>(finder);
  final painter = ReaderChapterLayout.blockPainter(layer.block, layer.spec);
  final offset = layer.block.text.indexOf(word);
  final boxes = painter.getBoxesForSelection(
    TextSelection(baseOffset: offset + 1, extentOffset: offset + 2),
  );
  expect(boxes, isNotEmpty);
  final box = boxes.first;
  final render = tester.renderObject<RenderBox>(finder);
  final point = render.localToGlobal(
    Offset((box.left + box.right) / 2, (box.top + box.bottom) / 2),
  );
  painter.dispose();
  return point;
}

Future<void> _longPressWord(
  WidgetTester tester,
  String text,
  String word,
) async {
  final point = await _wordPoint(tester, text, word);
  await tester.longPressAt(point);
  await tester.pumpAndSettle();
}

String _selected(WidgetTester tester, String text) {
  final layer = tester.widget<ReaderBlockMarkLayer>(_layer(text));
  final selection = layer.selection!;
  return layer.block.text.substring(
    selection.start - layer.block.start,
    selection.end - layer.block.start,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lookup dialog follows the reader night theme', (tester) async {
    await _mountReader(tester, dark: true);
    await _longPressWord(tester, 'wonderful', 'wonderful');
    final lookup = find.byKey(const ValueKey('reader-action-dictionary'));
    await tester.ensureVisible(lookup);
    await tester.pump();
    await tester.tap(lookup);
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(Theme.of(tester.element(dialog)).brightness, Brightness.dark);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chinese long press selects a word and copy failure can retry', (
    tester,
  ) async {
    var fail = true;
    final copied = <String>[];
    _mockWordBoundary(tester, (call) async {
      expect(call.method, 'wordBoundary');
      final args = call.arguments as Map;
      final text = args['text'] as String;
      final start = text.indexOf('客厅');
      expect(text, '——这也不是他的客厅。');
      expect(args['offset'], start);
      return {'start': start, 'end': start + '客厅'.length};
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          if (fail) throw PlatformException(code: 'clipboard');
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _mountReader(tester);
    await _longPressWord(tester, '客厅', '客厅');
    expect(_selected(tester, '客厅'), '客厅');
    await tester.tap(find.byKey(const ValueKey('reader-action-copy')));
    await tester.pump();
    expect(find.text('复制失败，请重试'), findsOneWidget);
    expect(_selected(tester, '客厅'), '客厅');
    fail = false;
    await tester.tap(find.byKey(const ValueKey('reader-action-copy')));
    await tester.pumpAndSettle();
    expect(copied, ['客厅']);
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('English word can expand to the whole paragraph', (tester) async {
    var nativeCalls = 0;
    _mockWordBoundary(tester, (_) async {
      nativeCalls++;
      return null;
    });
    await _mountReader(tester);
    await _longPressWord(tester, 'wonderful', 'wonderful');
    expect(_selected(tester, 'wonderful'), 'wonderful');
    final whole = find.byKey(const ValueKey('reader-action-select-paragraph'));
    await tester.ensureVisible(whole);
    await tester.tap(whole);
    await tester.pumpAndSettle();
    expect(_selected(tester, 'wonderful'), 'A wonderful story is here.');
    expect(nativeCalls, 0);
  });

  for (final pageMode in ['scroll', 'paged']) {
    testWidgets('delayed word survives frames and finger jitter: $pageMode', (
      tester,
    ) async {
      final pending = Completer<dynamic>();
      String? paragraph;
      _mockWordBoundary(tester, (call) {
        paragraph = (call.arguments as Map)['text'] as String;
        return pending.future;
      });
      await _mountReader(tester, pageMode: pageMode);
      final point = await _wordPoint(tester, '客厅', '厅');
      final gesture = await tester.startGesture(point);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
      await tester.pump();
      expect(_selected(tester, '客厅'), '厅');

      await gesture.moveBy(const Offset(1, .5));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveBy(const Offset(-.5, .5));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_selected(tester, '客厅'), '厅');

      final start = paragraph!.indexOf('客厅');
      pending.complete({'start': start, 'end': start + '客厅'.length});
      await tester.pump();
      await tester.pump();
      expect(_selected(tester, '客厅'), '客厅');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_selected(tester, '客厅'), '客厅');
    });

    testWidgets('late word cannot override a long-press drag: $pageMode', (
      tester,
    ) async {
      final pending = Completer<dynamic>();
      String? paragraph;
      _mockWordBoundary(tester, (call) {
        paragraph = (call.arguments as Map)['text'] as String;
        return pending.future;
      });
      await _mountReader(tester, pageMode: pageMode);
      final point = await _wordPoint(tester, '客厅', '厅');
      final gesture = await tester.startGesture(point);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
      await tester.pump();
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      final afterDrag = _selected(tester, '客厅');
      final start = paragraph!.indexOf('客厅');
      pending.complete({'start': start, 'end': start + '客厅'.length});
      await tester.pump();
      await tester.pump();
      expect(_selected(tester, '客厅'), afterDrag);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_selected(tester, '客厅'), afterDrag);
    });
  }

  testWidgets('late word result cannot replace an expanded paragraph', (
    tester,
  ) async {
    final pending = Completer<dynamic>();
    String? paragraph;
    _mockWordBoundary(tester, (call) {
      paragraph = (call.arguments as Map)['text'] as String;
      return pending.future;
    });
    await _mountReader(tester);
    await _longPressWord(tester, '客厅', '客厅');
    expect(_selected(tester, '客厅'), '客');
    final whole = find.byKey(const ValueKey('reader-action-select-paragraph'));
    await tester.ensureVisible(whole);
    await tester.tap(whole);
    await tester.pumpAndSettle();
    expect(_selected(tester, '客厅'), '——这也不是他的客厅。');
    final start = paragraph!.indexOf('客厅');
    pending.complete({'start': start, 'end': start + '客厅'.length});
    await tester.pumpAndSettle();
    expect(_selected(tester, '客厅'), '——这也不是他的客厅。');
  });

  testWidgets('late word result cannot replace a handle drag', (tester) async {
    final pending = Completer<dynamic>();
    String? paragraph;
    _mockWordBoundary(tester, (call) {
      paragraph = (call.arguments as Map)['text'] as String;
      return pending.future;
    });
    await _mountReader(tester);
    await _longPressWord(tester, '客厅', '客厅');
    final handle = find.byWidgetPredicate(
      (widget) => widget is ReaderSelectionHandle && widget.isStart,
    );
    expect(handle, findsOneWidget);
    for (final label in ['选区起点', '选区终点']) {
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == label &&
              widget.properties.hint == '拖动调整选中文字',
        ),
        findsOneWidget,
      );
    }
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    final afterDrag = _selected(tester, '客厅');
    expect(afterDrag, isNot('客厅'));
    final start = paragraph!.indexOf('客厅');
    pending.complete({'start': start, 'end': start + '客厅'.length});
    await tester.pumpAndSettle();
    expect(_selected(tester, '客厅'), afterDrag);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('invalid and unavailable native boundaries fall back safely', (
    tester,
  ) async {
    _mockWordBoundary(tester, (_) async => {'start': 0, 'end': 2});
    expect(await ReaderWordBoundary.resolve('甲👨‍👩‍👧‍👦乙', 0), isNull);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _wordBoundaryChannel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    expect(await ReaderWordBoundary.resolve('客厅', 0), isNull);
  });

  test('drag crosses and returns while keeping its original anchor', () {
    final drag = ReaderSelectionDrag(
      const ReaderTextSelection(start: 2, end: 5),
      isStart: true,
    );
    ReaderTextSelection at(int offset) => drag.update(
      offset: offset,
      previousBoundary: (value) => value - 1,
      nextBoundary: (value) => value + 1,
    );
    expect(at(7), const ReaderTextSelection(start: 5, end: 7));
    expect(drag.crossed, isTrue);
    expect(at(9), const ReaderTextSelection(start: 5, end: 9));
    expect(at(3), const ReaderTextSelection(start: 3, end: 5));
    expect(drag.crossed, isFalse);
  });

  test('meeting endpoints respects emoji and combining characters', () {
    final layout = ReaderChapterLayout(
      title: '章',
      content: ChapterContent(
        blocks: const [ChapterParagraph('A👨‍👩‍👧‍👦e\u0301B')],
      ),
      spec: ReaderLayoutSpec(
        viewport: const Size(400, 800),
        textScaler: TextScaler.noScaling,
        preferences: const ReaderPreferences(),
        fontFamily: null,
      ),
    );
    final block = layout.blocks[1];
    final emojiStart = block.start + 1;
    final emojiEnd = emojiStart + '👨‍👩‍👧‍👦'.length;
    expect(nextReaderCharacterBoundary(layout, emojiStart), emojiEnd);
    expect(previousReaderCharacterBoundary(layout, emojiEnd), emojiStart);
    final drag = ReaderSelectionDrag(
      ReaderTextSelection(start: block.start, end: emojiStart),
      isStart: true,
    );
    expect(
      drag.update(
        offset: emojiStart,
        previousBoundary: (x) => previousReaderCharacterBoundary(layout, x),
        nextBoundary: (x) => nextReaderCharacterBoundary(layout, x),
      ),
      ReaderTextSelection(start: emojiStart, end: emojiEnd),
    );
    expect(
      nextReaderCharacterBoundary(layout, emojiEnd),
      emojiEnd + 'e\u0301'.length,
    );
  });

  test(
    'lookup rejects full chapters and overlong excerpts without truncation',
    () {
      expect(
        ReaderTextLookupService.validate(
          '短章',
          kind: ReaderTextLookupKind.translate,
          wholeChapter: true,
        ),
        contains('整章'),
      );
      expect(
        ReaderTextLookupService.validate(
          '字' * 65,
          kind: ReaderTextLookupKind.dictionary,
          wholeChapter: false,
        ),
        contains('64'),
      );
      expect(
        ReaderTextLookupService.validate(
          '字' * 501,
          kind: ReaderTextLookupKind.translate,
          wholeChapter: false,
        ),
        contains('500'),
      );
      final translation = ReaderTextLookupService.webpage(
        ReaderTextLookupKind.translate,
        '客厅',
      );
      expect(translation.scheme, 'https');
      expect(translation.host, 'cn.bing.com');
      expect(translation.path, '/translator');
      expect(translation.queryParameters, {
        'from': 'zh-Hans',
        'to': 'en',
        'text': '客厅',
      });
      final english = ReaderTextLookupService.webpage(
        ReaderTextLookupKind.translate,
        'hello & world',
      );
      expect(english.queryParameters, {
        'from': 'auto-detect',
        'to': 'zh-Hans',
        'text': 'hello & world',
      });
      final dictionary = ReaderTextLookupService.webpage(
        ReaderTextLookupKind.dictionary,
        'hello & world',
      );
      expect(dictionary.scheme, 'https');
      expect(dictionary.queryParameters['word'], 'hello & world');
    },
  );

  testWidgets(
    'lookup sends only after choosing an explicitly named destination',
    (tester) async {
      final process = _ProcessText()..result = '客厅释义';
      final opened = <Uri>[];
      final lookup = ReaderTextLookupService(
        processText: process,
        webLauncher: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showReaderTextLookup(
                  context,
                  kind: ReaderTextLookupKind.dictionary,
                  text: '客厅',
                  wholeChapter: false,
                  service: lookup,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(process.calls, isEmpty);
      expect(find.text('选中的文字将交给你选择的网站或应用处理。'), findsOneWidget);
      await tester.tap(find.text('测试词典'));
      await tester.pumpAndSettle();
      expect(process.calls, [('dictionary', '客厅', true)]);
      expect(find.text('客厅释义'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-lookup-web')));
      await tester.pumpAndSettle();
      expect(opened.single.host, 'dict.youdao.com');
      expect(opened.single.queryParameters['word'], '客厅');
    },
  );
}
