import 'dart:async';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fastpix_player_example/src/custom_ui/fastpix_seek_bar.dart';

/// A controller whose playback state and scrub are driven by the test rather
/// than by an engine, so the seek bar's preview can be exercised on its own.
class _TestController extends FastPixPlayerController {
  final StreamController<FastPixPlaybackState> _states =
      StreamController<FastPixPlaybackState>.broadcast();

  bool _scrubbing = false;
  FastPixPlaybackState _state = const FastPixPlaybackState(
    duration: Duration(minutes: 10),
  );

  @override
  FastPixPlaybackState get playbackState => _state;

  @override
  Stream<FastPixPlaybackState> get playbackStateStream => _states.stream;

  @override
  bool get isScrubbing => _scrubbing;

  void _publish(Duration position) {
    _state = _state.copyWith(position: position);
    _states.add(_state);
  }

  @override
  void beginScrub([Duration? position]) {
    _scrubbing = true;
    _publish(position ?? Duration.zero);
  }

  @override
  void updateScrub(Duration position) => _publish(position);

  @override
  Future<void> endScrub(Duration position) async {
    _scrubbing = false;
    _publish(position);
  }
}

void main() {
  testWidgets('the preview follows a drag and hides on release', (
    tester,
  ) async {
    final controller = _TestController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 400,
              child: FastPixSeekBar(controller: controller),
            ),
          ),
        ),
      ),
    );

    final preview = find.byType(FastPixSeekPreview);
    expect(preview, findsNothing);

    final slider = find.byType(Slider);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();

    expect(controller.isScrubbing, isTrue);
    expect(preview, findsOneWidget);
    // Above the bar, and inside it horizontally.
    final previewRect = tester.getRect(preview);
    final sliderRect = tester.getRect(slider);
    expect(previewRect.bottom, lessThanOrEqualTo(sliderRect.top));
    expect(previewRect.left, greaterThanOrEqualTo(sliderRect.left));
    expect(previewRect.right, lessThanOrEqualTo(sliderRect.right));
    // No spritesheet on this controller: the preview shows the dragged-to time.
    final position = controller.playbackState.position;
    expect(position, greaterThan(const Duration(minutes: 5)));

    await gesture.up();
    await tester.pump();

    expect(controller.isScrubbing, isFalse);
    expect(preview, findsNothing);
  });

  testWidgets('dragging to the far end keeps the preview within the bar', (
    tester,
  ) async {
    final controller = _TestController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 400,
              child: FastPixSeekBar(controller: controller, showLabels: false),
            ),
          ),
        ),
      ),
    );

    final slider = find.byType(Slider);
    final start = tester.getCenter(slider);
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(tester.getTopRight(slider) + const Offset(-2, 10));
    await tester.pump();

    final previewRect = tester.getRect(find.byType(FastPixSeekPreview));
    expect(previewRect.right, lessThanOrEqualTo(tester.getRect(slider).right));
    await gesture.up();
    await tester.pump();
  });
}
