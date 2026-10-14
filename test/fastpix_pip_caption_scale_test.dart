import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/utils/fastpix_pip_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// Captions in an Android PiP window came out at full size some of the time.
///
/// The window scales the player down from the size it was drawn at on the
/// page, and captions shrink with it. Entering PiP marks the request pending at
/// once, but only the window *opening* is announced — and Android shrinks the
/// whole activity to the thumbnail in between. A widget that cached the
/// announced state still thought it was inline through that gap, laid its page
/// out at thumbnail size and measured *that* as the page size. The window then
/// scaled from a box already its own size: no scaling, full-size captions.
/// Only a later normal-size frame corrected it, hence "sometimes".
void main() {
  PlayerTestHarness.install();

  const channel = MethodChannel('fastpix_video_player/pip');
  const inline = Size(400, 225);
  const thumbnail = Size(192, 108);

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'enter' => 'ok',
        'isActive' => false,
        _ => true,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    FastPixPipChannel.debugReset();
  });

  Future<void> pumpFor(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// The size the PiP window scales the player down from.
  Size scaledFrom(WidgetTester tester) {
    final box = tester.widget<SizedBox>(
      find
          .descendant(
            of: find.byType(FittedBox),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    return Size(box.width!, box.height!);
  }

  for (final entry in <String, Widget Function(FastPixPlayerController)>{
    'FastPixPlayer': (c) => FastPixPlayer(controller: c),
    'FastPixVideoSurface': (c) => FastPixVideoSurface(controller: c),
  }.entries) {
    testWidgets('${entry.key}: the activity shrinking before the window is '
        'announced does not become the page size', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final controller = FastPixPlayerController();
      controller.pip.enabled = true;
      await tester.runAsync(
        () => PlayerTestHarness.load(controller, PlayerTestHarness.source('a')),
      );

      final activity = ValueNotifier<Size>(inline);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ValueListenableBuilder<Size>(
              valueListenable: activity,
              // Rebuilt with the size, as a real page is when the activity
              // resizes — a reused child would never be re-measured at all.
              builder: (_, size, _) => SizedBox.fromSize(
                size: size,
                child: entry.value(controller),
              ),
            ),
          ),
        ),
      );
      await pumpFor(tester);

      // The request: pending from here, not yet announced.
      await tester.runAsync(controller.pip.enterPip);
      expect(controller.pip.isPipActiveOrPending, isTrue);
      expect(controller.pip.isPipActive, isFalse);

      // Android resizes the activity into the thumbnail first...
      activity.value = thumbnail;
      await pumpFor(tester);

      // ...and only then reports the window open.
      controller.pip.notifyActive(true);
      await pumpFor(tester);

      expect(
        scaledFrom(tester),
        inline,
        reason: 'the thumbnail-size layout was measured as the page size, so '
            'the window would not scale captions down at all',
      );

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.dispose);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
