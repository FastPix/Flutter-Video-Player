import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// What a Picture-in-Picture window shows.
///
/// This file used to assert the opposite half of the same problem: that the
/// inline video was *covered* on iOS while PiP played. That cover existed only
/// because the engine's iOS PiP added a second `AVPlayerLayer` on the same
/// player and handed that one to AVKit, leaving the platform view underneath
/// still drawing — the same video in two places. The SDK owns PiP natively now
/// and attaches it to the layer that is already on screen, so AVKit lifts that
/// layer and leaves its own placeholder: no second video, nothing to hide.
///
/// The rule that replaces it is genuinely per-platform, which is why every test
/// pins one:
///
/// * **Android** resizes the whole activity into the PiP rectangle, so the
///   widget tree *is* the window and the SDK renders its window layout there.
/// * **iOS** floats a separate system window; the page carries on unchanged,
///   and replacing it would blank what the viewer returns to while changing
///   nothing about the window.
///
/// Note what a *surface* can and cannot do: it owns only its own subtree.
/// Interface a host draws around it stays the host's to collapse — which is
/// what the custom-UI demo does. What the SDK owes is that its own layout is
/// replaced, and that the player element survives either way, because losing it
/// disposes the engine controller and ends the playback the window is for.
/// Marks the window layout, so a test can tell which branch was taken.
const String windowLayoutMarker = 'window layout';

void main() {
  PlayerTestHarness.install();

  Future<void> pumpFor(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<FastPixPlayerController> mounted(
    WidgetTester tester, {
    FastPixPipBuilder? pipBuilder,
  }) async {
    final controller = FastPixPlayerController();
    await tester.runAsync(
      () => PlayerTestHarness.load(controller, PlayerTestHarness.source('a')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: FastPixVideoSurface(
            controller: controller,
            pipBuilder: pipBuilder,
          ),
        ),
      ),
    );
    await pumpFor(tester);
    return controller;
  }

  /// Marks the window layout, so a test can tell which branch was taken.
  FastPixPipBuilder marked() => (context, video) => Stack(
        fit: StackFit.expand,
        children: [video, const Text(windowLayoutMarker)],
      );

  testWidgets('Android renders the window layout, keeping the same player '
      'element', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final controller = await mounted(tester, pipBuilder: marked());
    final player = tester.element(find.byType(BetterPlayer));

    expect(find.text(windowLayoutMarker), findsNothing);

    controller.pip.notifyActive(true);
    await pumpFor(tester);

    expect(find.text(windowLayoutMarker), findsOneWidget);
    expect(find.byType(BetterPlayer), findsOneWidget);
    // The *same element*, not a rebuilt one. Replacing it unmounts the player,
    // which disposes the engine controller and ends the playback the window is
    // showing — the reason the video carries a GlobalKey across this switch.
    expect(tester.element(find.byType(BetterPlayer)), same(player));

    controller.pip.notifyActive(false);
    await pumpFor(tester);

    expect(find.text(windowLayoutMarker), findsNothing);
    expect(tester.element(find.byType(BetterPlayer)), same(player));

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.dispose);
    // Cleared inside the body: the framework asserts on a debug variable still
    // set when the test returns.
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS leaves the page alone, because the window is not this tree',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final controller = await mounted(tester, pipBuilder: marked());
    final player = tester.element(find.byType(BetterPlayer));

    controller.pip.notifyActive(true);
    await pumpFor(tester);

    // AVKit floats its own window and leaves a placeholder in the inline rect.
    // Rendering a window layout here would change nothing about the window and
    // would blank the page the viewer comes back to.
    expect(find.text(windowLayoutMarker), findsNothing);
    expect(find.byType(BetterPlayer), findsOneWidget);
    expect(tester.element(find.byType(BetterPlayer)), same(player));

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.dispose);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the default window layout keeps the player when no builder is '
      'supplied', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final controller = await mounted(tester);
    final player = tester.element(find.byType(BetterPlayer));

    controller.pip.notifyActive(true);
    await pumpFor(tester);

    expect(find.byType(BetterPlayer), findsOneWidget);
    expect(tester.element(find.byType(BetterPlayer)), same(player));

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.dispose);
    debugDefaultTargetPlatformOverride = null;
  });
}
