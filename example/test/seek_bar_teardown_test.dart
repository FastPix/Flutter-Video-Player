import 'dart:async';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fastpix_player_example/src/custom_ui/fastpix_seek_bar.dart';

/// Scrub state held here, as the SDK holds it, so a test can see whether a
/// torn-down bar left a scrub behind and where it was sought to.
class _ScrubController extends FastPixPlayerController {
  final StreamController<FastPixPlaybackState> _states =
      StreamController<FastPixPlaybackState>.broadcast();

  bool _scrubbing = false;
  Duration _scrubTarget = Duration.zero;
  Duration _playhead = const Duration(minutes: 1);
  final List<Duration> seeks = [];
  int cancels = 0;

  FastPixPlaybackState get _state => FastPixPlaybackState(
    position: _scrubbing ? _scrubTarget : _playhead,
    duration: const Duration(minutes: 10),
  );

  @override
  FastPixPlaybackState get playbackState => _state;

  @override
  Stream<FastPixPlaybackState> get playbackStateStream => _states.stream;

  @override
  bool get isScrubbing => _scrubbing;

  /// A progress tick from the engine.
  void tick(Duration playhead) {
    _playhead = playhead;
    _states.add(_state);
  }

  @override
  void beginScrub([Duration? position]) {
    _scrubbing = true;
    _scrubTarget = position ?? _playhead;
    _states.add(_state);
  }

  @override
  void updateScrub(Duration position) {
    if (!_scrubbing) return;
    _scrubTarget = position;
    _states.add(_state);
  }

  @override
  Future<void> endScrub(Duration position) async {
    _scrubbing = false;
    seeks.add(position);
    _playhead = position;
    _states.add(_state);
  }

  @override
  void cancelScrub() {
    if (!_scrubbing) return;
    cancels++;
    _scrubbing = false;
    _states.add(_state);
  }
}

/// Stands in for the watch screen: [layout] swaps the tree the bar sits in —
/// inline, fullscreen (a different parent, as `_appFullscreen` does), or none
/// at all (the controls collapsing while PiP is active).
enum _Layout { inline, fullscreen, pip }

Widget _host(_ScrubController controller, ValueNotifier<_Layout> layout) {
  Widget bar() => FastPixSeekBar(controller: controller);
  return MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder<_Layout>(
        valueListenable: layout,
        builder: (_, value, _) => switch (value) {
          _Layout.inline => Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(width: 400, child: bar()),
          ),
          _Layout.fullscreen => Stack(
            fit: StackFit.expand,
            children: [Positioned(left: 0, right: 0, bottom: 0, child: bar())],
          ),
          _Layout.pip => const SizedBox.shrink(),
        },
      ),
    ),
  );
}

Future<TestGesture> _dragMidway(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(Slider)),
  );
  await gesture.moveBy(const Offset(40, 0));
  await tester.pump();
  await gesture.moveBy(const Offset(40, 0));
  await tester.pump();
  return gesture;
}

void main() {
  for (final target in [_Layout.fullscreen, _Layout.pip]) {
    testWidgets(
      'entering ${target.name} mid-drag seeks to the dragged position',
      (tester) async {
        final controller = _ScrubController();
        final layout = ValueNotifier(_Layout.inline);
        await tester.pumpWidget(_host(controller, layout));

        final gesture = await _dragMidway(tester);
        expect(controller.isScrubbing, isTrue);
        expect(find.byType(FastPixSeekPreview), findsOneWidget);
        final dragged = controller.playbackState.position;
        expect(dragged, greaterThan(const Duration(minutes: 5)));

        layout.value = target; // the switch, finger still down
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        expect(controller.isScrubbing, isFalse);
        expect(controller.cancels, 0);
        // Committed where the finger was, not snapped back to where it began.
        expect(controller.seeks, [dragged]);

        // Back to a layout with a bar (PiP closing, or already fullscreen).
        if (target == _Layout.pip) layout.value = _Layout.inline;
        await tester.pumpAndSettle();
        expect(find.byType(FastPixSeekPreview), findsNothing);

        // The time label follows playback again.
        controller.tick(const Duration(minutes: 2, seconds: 5));
        await tester.pump(); // delivers the tick
        await tester.pump(); // draws it
        expect(find.text('2:05'), findsOneWidget);

        // And the next drag behaves as any other: one seek, on release.
        final next = await _dragMidway(tester);
        expect(find.byType(FastPixSeekPreview), findsOneWidget);
        await next.up();
        await tester.pump();
        expect(controller.isScrubbing, isFalse);
        expect(controller.seeks, hasLength(2));
        expect(controller.cancels, 0);
      },
    );
  }

  testWidgets('switching layout after a release seeks nothing more', (
    tester,
  ) async {
    final controller = _ScrubController();
    final layout = ValueNotifier(_Layout.inline);
    await tester.pumpWidget(_host(controller, layout));

    final gesture = await _dragMidway(tester);
    await gesture.up();
    await tester.pump();
    expect(controller.seeks, hasLength(1));

    layout.value = _Layout.fullscreen;
    await tester.pumpAndSettle();
    layout.value = _Layout.pip;
    await tester.pumpAndSettle();

    expect(controller.cancels, 0);
    expect(controller.seeks, hasLength(1));
  });
}
