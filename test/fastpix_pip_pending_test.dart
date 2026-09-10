import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/managers/fastpix_lifecycle_manager.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// A PiP window that is *opening* must count as open for the pause rule.
///
/// `enterPip()` is asynchronous — an audio-session claim and a platform round
/// trip — while `AppLifecycleState.paused` arrives immediately. Reading only
/// `isPipActive` there reads `false` for a window that is on its way, and
/// pauses the video inside it. Measured on device: the pause was emitted, and
/// the surface resized to the PiP window a beat later.
void main() {
  PlayerTestHarness.install();

  test('a requested PiP counts as active before the platform confirms',
      () async {
    final controller = FastPixPlayerController();
    controller.pip.enabled = true;

    expect(controller.pip.isPipActive, isFalse);
    expect(controller.pip.isPipActiveOrPending, isFalse);

    // Not awaited: this is the state the lifecycle callback races with.
    // ignore: unawaited_futures
    controller.pip.enterPip();

    expect(
      controller.pip.isPipActiveOrPending,
      isTrue,
      reason: 'the request must be visible before the platform answers',
    );
    // Untouched: it is still true that no window is open yet.
    expect(controller.pip.isPipActive, isFalse);

    await controller.dispose();
  });

  test('the platform reporting a window open clears the pending flag',
      () async {
    final controller = FastPixPlayerController();
    controller.pip.enabled = true;
    // ignore: unawaited_futures
    controller.pip.enterPip();

    controller.pip.notifyActive(true);

    expect(controller.pip.isPipActive, isTrue);
    expect(controller.pip.isPipActiveOrPending, isTrue);

    controller.pip.notifyActive(false);

    expect(controller.pip.isPipActive, isFalse);
    expect(
      controller.pip.isPipActiveOrPending,
      isFalse,
      reason: 'a closed window must not leave playback un-pausable',
    );

    await controller.dispose();
  });

  test('a new source clears a pending request', () async {
    // Otherwise a request that never resolved would keep the next video from
    // ever pausing on backgrounding.
    final controller = FastPixPlayerController();
    controller.pip.enabled = true;
    // ignore: unawaited_futures
    controller.pip.enterPip();

    controller.pip.resetForNewSource();

    expect(controller.pip.isPipActiveOrPending, isFalse);
    await controller.dispose();
  });

  test('backgrounding while PiP is still opening does not pause playback',
      () async {
    // The whole point: this is the sequence the device produced.
    final controller = FastPixPlayerController();
    await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    await controller.play();
    await PlayerTestHarness.settle();
    controller.pip.enabled = true;

    final manager = FastPixLifecycleManager(
      () => controller.betterPlayerController,
      () => controller.pip.isPipActiveOrPending,
    );

    // ignore: unawaited_futures
    controller.pip.enterPip();
    manager.didChangeAppLifecycleState(AppLifecycleState.paused);
    await PlayerTestHarness.settle();

    expect(
      controller.betterPlayerController?.isPlaying(),
      isTrue,
      reason: 'the video must keep playing into the PiP window',
    );

    await controller.dispose();
  });

  test('backgrounding with no PiP requested still pauses', () async {
    // The rule this fix must not weaken.
    final controller = FastPixPlayerController();
    await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    await controller.play();
    await PlayerTestHarness.settle();

    final manager = FastPixLifecycleManager(
      () => controller.betterPlayerController,
      () => controller.pip.isPipActiveOrPending,
    );

    manager.didChangeAppLifecycleState(AppLifecycleState.paused);
    await PlayerTestHarness.settle();

    expect(controller.betterPlayerController?.isPlaying(), isFalse);
    await controller.dispose();
  });
}
