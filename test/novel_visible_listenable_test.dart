import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/novel/visible_listenable_builder.dart';

class _TrackedNotifier extends ValueNotifier<int> {
  _TrackedNotifier(super.value);
  bool get observed => hasListeners;
}

void main() {
  testWidgets('hidden tab skips updates and returns with latest snapshot', (
    tester,
  ) async {
    final source = ValueNotifier<int>(0);
    addTearDown(source.dispose);
    var builds = 0;
    var visible = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return TickerMode(
              enabled: visible,
              child: NovelVisibleListenableBuilder(
                listenable: source,
                builder: (_, _) {
                  builds++;
                  return Text('snapshot ${source.value}');
                },
              ),
            );
          },
        ),
      ),
    );
    update(() => visible = false);
    await tester.pump();
    final hiddenBuilds = builds;
    for (var i = 1; i <= 30; i++) {
      source.value = i;
      await tester.pump();
    }
    expect(builds, hiddenBuilds);
    update(() => visible = true);
    await tester.pump();
    expect(find.text('snapshot 30'), findsOneWidget);
    source.value = 31;
    await tester.pump();
    expect(find.text('snapshot 31'), findsOneWidget);
  });

  testWidgets('covered route defers updates until returning', (tester) async {
    final source = ValueNotifier<int>(0);
    addTearDown(source.dispose);
    final navigator = GlobalKey<NavigatorState>();
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: NovelVisibleListenableBuilder(
            listenable: source,
            builder: (_, _) {
              builds++;
              return Text('snapshot ${source.value}');
            },
          ),
        ),
      ),
    );
    navigator.currentState!.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('reader'))),
    );
    await tester.pumpAndSettle();
    final coveredBuilds = builds;
    for (var i = 1; i <= 30; i++) {
      source.value = i;
      await tester.pump();
    }
    expect(builds, coveredBuilds);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('snapshot 30'), findsOneWidget);
  });

  testWidgets('background pauses snapshots and resume reads latest', (
    tester,
  ) async {
    final source = ValueNotifier<int>(0);
    addTearDown(source.dispose);
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelVisibleListenableBuilder(
          listenable: source,
          builder: (_, _) {
            builds++;
            return Text('snapshot ${source.value}');
          },
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final backgroundBuilds = builds;
    source.value = 9;
    await tester.pump();
    expect(builds, backgroundBuilds);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('snapshot 9'), findsOneWidget);
  });

  testWidgets('changing source and disposal do not leave subscriptions', (
    tester,
  ) async {
    final first = _TrackedNotifier(0);
    final second = _TrackedNotifier(4);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    var source = first;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return NovelVisibleListenableBuilder(
              listenable: source,
              builder: (_, _) => Text('snapshot ${source.value}'),
            );
          },
        ),
      ),
    );
    expect(first.observed, isTrue);
    update(() => source = second);
    await tester.pump();
    expect(first.observed, isFalse);
    expect(second.observed, isTrue);
    expect(find.text('snapshot 4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(second.observed, isFalse);
  });
}
