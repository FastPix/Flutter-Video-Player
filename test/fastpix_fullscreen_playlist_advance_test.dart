import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// What a playlist advance does to the default skin's fullscreen route, as it
/// stands.
///
/// A characterization, not a specification: it pins today's behaviour so that
/// work drawing over the video can prove it left fullscreen alone.
/// Today the advance releases the engine player that owns the fullscreen
/// route, and:
///
/// * the route stays pushed, still built around the released player;
/// * the controller, now holding the new player, reports not-fullscreen;
/// * the released player's controls throw `Bad state: Cannot add new events
///   after calling close` from an animation tick.
///
/// The last one is a defect, recorded here only so that nothing new joins it.
/// If a change fixes it on purpose, this test is the one to update.
void main() {
  PlayerTestHarness.install();

  const wakelock =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi';

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    // The engine awaits the wakelock and the system UI calls before it pushes
    // the fullscreen route; unanswered, the push never happens.
    for (final method in <String>['toggle', 'isEnabled']) {
      messenger().setMockMessageHandler(
        '$wakelock.$method',
        (_) async => const StandardMessageCodec().encodeMessage(
          <Object?>[method == 'isEnabled' ? false : null],
        ),
      );
    }
    messenger().setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
  });

  tearDown(() {
    for (final method in <String>['toggle', 'isEnabled']) {
      messenger().setMockMessageHandler('$wakelock.$method', null);
    }
    messenger().setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpFor(WidgetTester tester, [int frames = 20]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  bool routePushed(WidgetTester tester) =>
      tester.state<NavigatorState>(find.byType(Navigator).first).canPop();

  testWidgets(
    'a playlist advance in fullscreen leaves the route up around the released '
    'player',
    (tester) async {
      late FastPixPlayerController controller;
      await tester.runAsync(() async {
        controller = await PlayerTestHarness.withPlaylist(
          PlayerTestHarness.playlist(2),
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FastPixPlayer(controller: controller)),
        ),
      );
      await pumpFor(tester, 8);

      final released = controller.betterPlayerController;
      controller.enterFullscreen();
      await pumpFor(tester);
      expect(routePushed(tester), isTrue);
      expect(controller.isFullscreen, isTrue);

      // Errors thrown while the released player's route animates are
      // collected rather than failing the test, so their kind can be pinned.
      final errors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = errors.add;
      try {
        await tester.runAsync(() async {
          final before = PlayerTestHarness.platform.created.length;
          final advance = controller.next();
          for (var i = 0;
              i < 40 && PlayerTestHarness.platform.created.length == before;
              i++) {
            await PlayerTestHarness.settle(1);
          }
          await PlayerTestHarness.reportReady();
          await advance;
        });
        await pumpFor(tester);
      } finally {
        FlutterError.onError = previousOnError;
      }

      expect(identical(released, controller.betterPlayerController), isFalse);
      expect(routePushed(tester), isTrue, reason: 'the route stays pushed');
      expect(released?.isFullScreen, isTrue);
      expect(controller.isFullscreen, isFalse);
      expect(
        errors.map((e) => e.exceptionAsString()).toSet(),
        everyElement(contains('Cannot add new events after calling close')),
        reason: 'no new kind of error may appear during the advance',
      );

      await tester.pumpWidget(const SizedBox());
      await pumpFor(tester, 8);
      await tester.runAsync(controller.dispose);
    },
  );
}
