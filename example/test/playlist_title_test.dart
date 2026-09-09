import 'dart:async';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fastpix_player_example/src/custom_ui/fastpix_playlist_title.dart';

/// A controller whose playlist position is driven by the test, for the same
/// reason the nav-button suite has one: the widget's contract is with the
/// published state, so publishing states is the whole of what it needs.
class _TestController extends FastPixPlayerController {
  final StreamController<FastPixPlaylistState> _states =
      StreamController<FastPixPlaylistState>.broadcast();

  FastPixPlaylistState _state = FastPixPlaylistState.empty;

  @override
  FastPixPlaylistState get playlistState => _state;

  @override
  Stream<FastPixPlaylistState> get playlistStateStream => _states.stream;

  void emit({required int index, required int count, String? title}) {
    _state = FastPixPlaylistState(
      index: index,
      item: title == null
          ? null
          : FastPixPlayerDataSource.hls(playbackId: 'id-$index', title: title),
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
        appBar: AppBar(
          title: FastPixPlaylistTitle(
            controller: controller,
            fallback: fallbackTitle,
          ),
        ),
      ),
    ),
  );
}

/// Shown when the active item carries no title of its own.
const String fallbackTitle = 'Opened on this';

/// A title the fake controller publishes for the active item.
const String multiTrackTitle = 'Multiple tracks';

void main() {
  testWidgets('names the item the player says is active, not the one the '
      'screen was opened on', (tester) async {
    final controller = _TestController();
    addTearDown(controller.close);

    await _pump(tester, controller);
    // No playlist yet: nothing has been published to name it by.
    expect(find.text(fallbackTitle), findsOneWidget);

    controller.emit(index: 0, count: 3, title: multiTrackTitle);
    await tester.pump();
    await tester.pump();
    expect(find.text(multiTrackTitle), findsOneWidget);

    // The advance the app bar used to miss.
    controller.emit(index: 1, count: 3, title: 'Big Buck Bunny');
    // Two pumps: the first delivers the stream event, the second paints the
    // frame the rebuild scheduled.
    await tester.pump();
    await tester.pump();
    expect(find.text('Big Buck Bunny'), findsOneWidget);
    expect(find.text(multiTrackTitle), findsNothing);
  });

  testWidgets('falls back when the active item carries no title',
      (tester) async {
    final controller = _TestController();
    addTearDown(controller.close);

    await _pump(tester, controller);
    controller.emit(index: 0, count: 2);
    await tester.pump();
    await tester.pump();

    expect(find.text(fallbackTitle), findsOneWidget);
  });
}
