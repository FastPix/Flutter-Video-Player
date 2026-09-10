import 'dart:async';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fastpix_player_example/src/custom_ui/fastpix_playlist_nav_buttons.dart';

/// A controller whose playlist position is driven by the test rather than by a
/// real load, so the custom-UI buttons can be exercised without an engine.
///
/// This is the same trick the cast-button suite uses: the widget's contract is
/// with the published playlist state, so a controller that publishes states is
/// all it needs to be held to it.
class _TestController extends FastPixPlayerController {
  final StreamController<FastPixPlaylistState> _states =
      StreamController<FastPixPlaylistState>.broadcast();

  FastPixPlaylistState _state = const FastPixPlaylistState(
    index: -1,
    item: null,
    count: 0,
    canGoNext: false,
    canGoPrevious: false,
  );

  int nextCalls = 0;
  int previousCalls = 0;

  @override
  FastPixPlaylistState get playlistState => _state;

  @override
  Stream<FastPixPlaylistState> get playlistStateStream => _states.stream;

  @override
  Future<bool> next() async {
    nextCalls++;
    return true;
  }

  @override
  Future<bool> previous() async {
    previousCalls++;
    return true;
  }

  void emit({
    required int index,
    required int count,
  }) {
    _state = FastPixPlaylistState(
      index: index,
      item: null,
      count: count,
      canGoNext: index >= 0 && index < count - 1,
      canGoPrevious: index > 0,
    );
    _states.add(_state);
  }

  void close() => _states.close();
}

Future<void> _pump(WidgetTester tester, _TestController controller) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FastPixPlaylistNavButton.previous(controller: controller),
            FastPixPlaylistNavButton.next(controller: controller),
          ],
        ),
      ),
    ),
  );
}

void main() {
  final Finder previous = find.byIcon(Icons.skip_previous_rounded);
  final Finder next = find.byIcon(Icons.skip_next_rounded);

  IconButton buttonFor(WidgetTester tester, Finder icon) => tester.widget(
        find.ancestor(of: icon, matching: find.byType(IconButton)),
      );

  testWidgets('nothing is drawn without a playlist', (tester) async {
    final controller = _TestController();
    await _pump(tester, controller);

    expect(previous, findsNothing);
    expect(next, findsNothing);
    controller.close();
  });

  testWidgets('a single item is not a playlist to navigate', (tester) async {
    final controller = _TestController()..emit(index: 0, count: 1);
    await _pump(tester, controller);

    expect(previous, findsNothing);
    expect(next, findsNothing);
    controller.close();
  });

  testWidgets('both glyphs appear once a playlist is published',
      (tester) async {
    final controller = _TestController();
    await _pump(tester, controller);
    expect(next, findsNothing);

    controller.emit(index: 1, count: 3);
    await tester.pump();

    expect(previous, findsOneWidget);
    expect(next, findsOneWidget);
    expect(buttonFor(tester, previous).onPressed, isNotNull);
    expect(buttonFor(tester, next).onPressed, isNotNull);
    controller.close();
  });

  testWidgets('the glyphs drive the controller', (tester) async {
    final controller = _TestController()..emit(index: 1, count: 3);
    await _pump(tester, controller);

    await tester.tap(next);
    await tester.tap(previous);
    await tester.pump();

    expect(controller.nextCalls, 1);
    expect(controller.previousCalls, 1);
    controller.close();
  });

  testWidgets('the ends dim rather than disappear', (tester) async {
    final controller = _TestController()..emit(index: 0, count: 2);
    await _pump(tester, controller);

    expect(previous, findsOneWidget);
    expect(buttonFor(tester, previous).onPressed, isNull);
    expect(buttonFor(tester, next).onPressed, isNotNull);

    controller.emit(index: 1, count: 2);
    await tester.pump();

    expect(buttonFor(tester, previous).onPressed, isNotNull);
    expect(buttonFor(tester, next).onPressed, isNull);
    controller.close();
  });
}
