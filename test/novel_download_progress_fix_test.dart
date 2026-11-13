import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/novel_download_manager.dart';

import 'support/fakes.dart';

Chapter _chapter(String id, int number) =>
    Chapter(itemId: '$id-$number', title: '第 $number 章', volumeName: '');

CachedBook _book(String id, int count) => CachedBook(
  id: id,
  title: '测试书 $id',
  chapters: List.generate(count, (index) => _chapter(id, index + 1)),
);

String _content(Chapter chapter) =>
    parseChapterContent('<p>${chapter.itemId} 的章节正文</p>').toCacheText();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('自动追更时仍可看见并继续暂停的手动任务', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = MemoryChapterCache();
    final manual = _book('manual', 4);
    final followed = _book('followed', 1);
    final manualStarted = Completer<void>();
    final pendingManual = Completer<String>();
    final autoStarted = Completer<void>();
    final pendingAuto = Completer<String>();
    var firstManual = true;
    final manager = NovelDownloadManager(
      cache: cache,
      directoryLoader: (_) async => _book('followed', 2).chapters,
      contentLoader: (chapter) {
        if (chapter.itemId == 'manual-2' && firstManual) {
          firstManual = false;
          manualStarted.complete();
          return pendingManual.future;
        }
        if (chapter.itemId == 'followed-2') {
          autoStarted.complete();
          return pendingAuto.future;
        }
        return Future.value(_content(chapter));
      },
      connectivity: () async => (online: true, metered: false),
      downloadedBooks: () async => [followed],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      manager.dispose();
    });
    await manager.start(manual, startIndex: 1, count: 2);
    await manualStarted.future;
    manager.pause();
    pendingManual.complete(_content(manual.chapters[1]));
    final check = manager.checkUpdates();
    await autoStarted.future;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NovelDownloadProgressList(manager: manager),
          ),
        ),
      ),
    );
    final auto = find.byKey(const ValueKey('download-progress-auto-followed'));
    final manualProgress = find.byKey(
      const ValueKey('download-progress-manual-manual'),
    );
    expect(auto, findsOneWidget);
    expect(manualProgress, findsOneWidget);
    expect(
      find.descendant(of: auto, matching: find.text('自动追更')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: manualProgress, matching: find.text('手动下载')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: manualProgress, matching: find.text('继续')),
    );
    for (
      var i = 0;
      i < 20 && manager.manualTask.value?.value.completed != 2;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(await cache.cachedChapterIds(manual.id), {'manual-2', 'manual-3'});
    final resumed = manager.manualTask.value;
    pendingAuto.complete(_content(_chapter('followed', 2)));
    await check;
    await tester.pump();
    expect(manager.active.value, same(resumed));
    expect(
      find.byKey(const ValueKey('download-progress-manual-manual')),
      findsOneWidget,
    );
  });
}
