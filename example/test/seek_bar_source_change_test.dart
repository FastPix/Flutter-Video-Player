import 'dart:async';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fastpix_player_example/src/custom_ui/fastpix_seek_bar.dart';

/// A controller whose playback state is pushed by the test, recording how
/// each scrub finished.
class _SwitchingController extends FastPixPlayerController {
  final StreamController<FastPixPlaybackState> _states =
      StreamController<FastPixPlaybackState>.broadcast();

  FastPixPlaybackState _state = const FastPixPlaybackState(
    duration: Duration(minutes: 10),
  );
  bool _scrubbing = false;
  final List<Duration> ended = <Duration>[];
  int cancelled = 0;

  void publish(FastPixPlaybackState state) {
    _state = state;
    _states.add(state);
  }

  @override
  FastPixPlaybackState get playbackState => _state;

  @override
  Stream<FastPixPlaybackState> get playbackStateStream => _states.stream;

  @override
  bool get isScrubbing => _scrubbing;

  @override
  void beginScrub([Duration? position]) => _scrubbing = true;

  @override
  void updateScrub(Duration position) {}

  @override
  Future<void> endScrub(Duration position) async {
    _scrubbing = false;
    ended.add(position);
  }

  @override
  void cancelScrub() {
    if (!_scrubbing) return;
    _scrubbing = false;
    cancelled++;
  }
}

/// The source changing under the finger used to leave the scrub running: the
/// bar disabled itself when the duration went, a disabled slider drops its
/// release, and the time and preview froze while the video played on.
void main() {
  Future<void> pumpBar(WidgetTester tester, FastPixPlayerController c) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(width: 400, child: FastPixSeekBar(controller: c)),
            ),
          ),
        ),
      );

  testWidgets('losing the duration mid-drag abandons the scrub', (
    tester,
  ) async {
    final controller = _SwitchingController();
    await pumpBar(tester, controller);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(Slider)),
    );
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(controller.isScrubbing, isTrue);

    // The next source, with no duration yet.
    controller.publish(const FastPixPlaybackState());
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(controller.isScrubbing, isFalse);
    expect(controller.cancelled, 1);
    expect(
      controller.ended,
      isEmpty,
      reason: 'the old target must not be sought on the new source',
    );

    // The new source plays: the preview is gone and nothing is re-ended.
    controller.publish(
      const FastPixPlaybackState(duration: Duration(minutes: 90)),
    );
    await tester.pump();
    expect(find.byType(FastPixSeekPreview), findsNothing);
    expect(controller.ended, isEmpty);
  });

  testWidgets('a drag with its duration intact still seeks on release', (
    tester,
  ) async {
    final controller = _SwitchingController();
    await pumpBar(tester, controller);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(Slider)),
    );
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(controller.ended, hasLength(1));
    expect(controller.cancelled, 0);
  });
}
