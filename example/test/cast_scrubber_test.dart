import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fastpix_player_example/src/widgets/cast_scrubber.dart';

/// The scrubber's whole reason for existing is that its touch target is the bar
/// and nothing else: a `Slider` in the same place claimed its entire parent box
/// and swallowed touches meant for the transport buttons above it. These tests
/// pin that down, since it is invisible on screen and easy to regress.
void main() {
  const duration = Duration(minutes: 100);

  /// Lays the bar out 300px wide inside a taller surface, with a button
  /// occupying the space above it — the arrangement the casting stage uses.
  Widget harness({
    required ValueChanged<Duration> onChanged,
    required VoidCallback onChangeEnd,
    VoidCallback? onTransportPressed,
    Duration position = Duration.zero,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 200,
            child: Stack(
              children: [
                // Fills the whole surface, the way better_player's own hit area
                // does: the bar has to win inside its band and lose everywhere
                // else, which is exactly what a Slider here failed to do.
                //
                // Opaque, as a real transport button is: without it this
                // stand-in has nothing to hit-test against and the test would
                // fail on the harness rather than on the widget.
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTransportPressed ?? () {},
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: CastScrubber(
                    position: position,
                    duration: duration,
                    onChanged: onChanged,
                    onChangeEnd: onChangeEnd,
                    onCancel: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a tap on the bar seeks to that fraction of the media', (
    tester,
  ) async {
    Duration? reported;
    var committed = false;

    await tester.pumpWidget(
      harness(
        onChanged: (value) => reported = value,
        onChangeEnd: () => committed = true,
      ),
    );

    final bar = tester.getRect(find.byType(CastScrubber));
    // A quarter of the way across a 100 minute item is 25 minutes.
    await tester.tapAt(Offset(bar.left + bar.width * 0.25, bar.center.dy));
    await tester.pump();

    expect(reported, isNotNull);
    expect(reported!.inMinutes, closeTo(25, 1));
    expect(committed, isTrue);
  });

  testWidgets('dragging reports continuously and commits once on release', (
    tester,
  ) async {
    final reported = <Duration>[];
    var commits = 0;

    await tester.pumpWidget(
      harness(
        onChanged: reported.add,
        onChangeEnd: () => commits++,
      ),
    );

    final bar = tester.getRect(find.byType(CastScrubber));
    final gesture = await tester.startGesture(
      Offset(bar.left + 10, bar.center.dy),
    );
    await gesture.moveBy(const Offset(100, 0));
    await gesture.moveBy(const Offset(50, 0));
    await gesture.up();
    await tester.pump();

    // Every move previews; only the release commits, so a drag is one network
    // round trip rather than one per frame.
    expect(reported.length, greaterThan(1));
    expect(commits, 1);
    expect(reported.last, greaterThan(reported.first));
  });

  testWidgets('a touch above the bar reaches the control behind, not the bar', (
    tester,
  ) async {
    Duration? reported;
    var transportTapped = false;

    await tester.pumpWidget(
      harness(
        onChanged: (value) => reported = value,
        onChangeEnd: () {},
        onTransportPressed: () => transportTapped = true,
      ),
    );

    final bar = tester.getRect(find.byType(CastScrubber));
    // Ten pixels above the bar's own box: this is where the old Slider still
    // claimed the touch and turned it into an absolute seek.
    await tester.tapAt(Offset(bar.center.dx, bar.top - 10));
    await tester.pump();

    expect(reported, isNull, reason: 'the bar took a touch that was not on it');
    expect(transportTapped, isTrue);

    // And the converse: inside the band the bar wins, so a deliberate scrub
    // cannot also fire whatever is underneath it.
    transportTapped = false;
    await tester.tapAt(bar.center);
    await tester.pump();

    expect(reported, isNotNull);
    expect(transportTapped, isFalse);
  });

  testWidgets('the touch target is no taller than the band it draws in', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(onChanged: (_) {}, onChangeEnd: () {}),
    );

    // 28 is the default touchHeight. The point is that it is a fixed band and
    // not derived from the screen: better_player's progress bar sizes its
    // gesture child to MediaQuery.size.height / 2, which is what let a touch
    // anywhere on the video seek.
    expect(tester.getSize(find.byType(CastScrubber)).height, 28);
  });

  testWidgets('a drag past either end clamps inside the media', (tester) async {
    final reported = <Duration>[];

    await tester.pumpWidget(
      harness(onChanged: reported.add, onChangeEnd: () {}),
    );

    final bar = tester.getRect(find.byType(CastScrubber));
    final gesture = await tester.startGesture(
      Offset(bar.left + 20, bar.center.dy),
    );
    await gesture.moveBy(const Offset(1000, 0));
    await gesture.moveBy(const Offset(-3000, 0));
    await gesture.up();
    await tester.pump();

    expect(reported.every((d) => d >= Duration.zero), isTrue);
    expect(reported.every((d) => d <= duration), isTrue);
  });
}
