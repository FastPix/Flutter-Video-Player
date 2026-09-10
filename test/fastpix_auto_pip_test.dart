import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/managers/fastpix_lifecycle_manager.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// Automatic Picture-in-Picture: leaving the app while a video plays should
/// leave the video playing in a small window, the way every large video app
/// behaves.
///
/// The trigger is Android's `onUserLeaveHint`, which arrives *before*
/// `AppLifecycleState.paused` — that ordering is the whole design, and the last
/// group here holds it, because getting it wrong means the pause rule kills the
/// playback the PiP window was about to show.
void main() {
  PlayerTestHarness.install();

  tearDown(FastPixUserLeaveHint.debugReset);

  /// A playing controller and a lifecycle manager wired to [wantsAutoPip],
  /// recording the PiP requests it makes instead of asking a platform.
  Future<(FastPixPlayerController, FastPixLifecycleManager, List<int>)> playing({
    required bool Function() wantsAutoPip,
    bool Function()? keepsPlaying,
  }) async {
    final controller = FastPixPlayerController();
    await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    await controller.play();
    await PlayerTestHarness.settle();
    final requests = <int>[];
    final manager = FastPixLifecycleManager(
      () => controller.betterPlayerController,
      keepsPlaying ?? () => false,
      wantsAutoPip: wantsAutoPip,
      enterPip: () async => requests.add(1),
    );
    manager.attach();
    return (controller, manager, requests);
  }

  bool isPlaying(FastPixPlayerController controller) =>
      controller.betterPlayerController?.isPlaying() ?? false;

  group('what a hint does', () {
    test('leaving while playing opens a PiP window', () async {
      final (controller, manager, requests) =
          await playing(wantsAutoPip: () => true);

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();

      expect(requests, hasLength(1));
      manager.detach();
      await controller.dispose();
    });

    test('nothing happens when the host did not ask for it', () async {
      final (controller, manager, requests) =
          await playing(wantsAutoPip: () => false);

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();

      expect(requests, isEmpty);
      manager.detach();
      await controller.dispose();
    });

    test('a paused video is left alone — a still frame is not what the '
        'gesture meant', () async {
      final (controller, manager, requests) =
          await playing(wantsAutoPip: () => true);
      await controller.pause();
      await PlayerTestHarness.settle();

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();

      expect(requests, isEmpty);
      manager.detach();
      await controller.dispose();
    });

    test('a window already open is not asked for again', () async {
      final (controller, manager, requests) = await playing(
        wantsAutoPip: () => true,
        keepsPlaying: () => true,
      );

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();

      expect(requests, isEmpty);
      manager.detach();
      await controller.dispose();
    });

    test('the switch is read at the moment of leaving, not at construction',
        () async {
      var wanted = false;
      final (controller, manager, requests) =
          await playing(wantsAutoPip: () => wanted);

      wanted = true;
      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();

      expect(requests, hasLength(1));
      manager.detach();
      await controller.dispose();
    });
  });

  group('a detached manager is deaf', () {
    test('no PiP is requested after detach', () async {
      final (controller, manager, requests) =
          await playing(wantsAutoPip: () => true);
      manager.detach();

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();

      expect(requests, isEmpty);
      await controller.dispose();
    });
  });

  group('the two rules of leaving compose', () {
    test('a video that went to PiP is not then paused', () async {
      // The real ordering: the hint arrives while the activity can still enter
      // PiP, and `paused` follows once it is open.
      var inPip = false;
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await controller.play();
      await PlayerTestHarness.settle();

      final manager = FastPixLifecycleManager(
        () => controller.betterPlayerController,
        () => inPip,
        wantsAutoPip: () => true,
        enterPip: () async => inPip = true,
      )..attach();

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();
      manager.didChangeAppLifecycleState(AppLifecycleState.paused);
      await PlayerTestHarness.settle();

      expect(inPip, isTrue);
      expect(isPlaying(controller), isTrue,
          reason: 'the pause rule must not stop the video PiP is showing');
      manager.detach();
      await controller.dispose();
    });

    test('without auto-PiP, backgrounding still pauses as it always did',
        () async {
      final (controller, manager, _) =
          await playing(wantsAutoPip: () => false);

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();
      manager.didChangeAppLifecycleState(AppLifecycleState.paused);
      await PlayerTestHarness.settle();

      expect(isPlaying(controller), isFalse);
      manager.detach();
      await controller.dispose();
    });
  });

  group('the controller exposes the switch', () {
    test('it is off until the host asks', () async {
      final controller = FastPixPlayerController();
      expect(controller.pip.autoEnterOnBackground, isFalse);
      await controller.dispose();
    });

    test('it can be turned on', () async {
      final controller = FastPixPlayerController();
      controller.pip.autoEnterOnBackground = true;
      expect(controller.pip.autoEnterOnBackground, isTrue);
      await controller.dispose();
    });
  });
}
