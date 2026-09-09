import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/managers/fastpix_lifecycle_manager.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// Backgrounding the app is exactly what a viewer does *after* starting
/// Picture-in-Picture, so the rule that pauses playback on the way out has to
/// know about PiP or it freezes the window it just opened.
void main() {
  PlayerTestHarness.install();

  Future<(FastPixPlayerController, FastPixLifecycleManager)> playing({
    required bool Function() keepsPlaying,
  }) async {
    final controller = FastPixPlayerController();
    await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    await controller.play();
    await PlayerTestHarness.settle();
    final manager = FastPixLifecycleManager(
      () => controller.betterPlayerController,
      keepsPlaying,
    );
    return (controller, manager);
  }

  bool isPlaying(FastPixPlayerController controller) =>
      controller.betterPlayerController?.isPlaying() ?? false;

  test('pauses on backgrounding when nothing is playing in the background',
      () async {
    final (controller, manager) = await playing(keepsPlaying: () => false);
    expect(isPlaying(controller), isTrue);

    manager.didChangeAppLifecycleState(AppLifecycleState.paused);
    await PlayerTestHarness.settle();

    expect(isPlaying(controller), isFalse);
    await controller.dispose();
  });

  test('leaves playback alone while a PiP window is open', () async {
    final (controller, manager) = await playing(keepsPlaying: () => true);

    manager.didChangeAppLifecycleState(AppLifecycleState.paused);
    await PlayerTestHarness.settle();

    expect(isPlaying(controller), isTrue);
    await controller.dispose();
  });

  test('resumes on return only what it paused itself', () async {
    final (controller, manager) = await playing(keepsPlaying: () => false);
    manager.didChangeAppLifecycleState(AppLifecycleState.paused);
    await PlayerTestHarness.settle();

    manager.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await PlayerTestHarness.settle();

    expect(isPlaying(controller), isTrue);
    await controller.dispose();
  });

  test('a video the viewer paused stays paused across a trip to the '
      'background', () async {
    final (controller, manager) = await playing(keepsPlaying: () => false);
    await controller.pause();
    await PlayerTestHarness.settle();

    manager.didChangeAppLifecycleState(AppLifecycleState.paused);
    manager.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await PlayerTestHarness.settle();

    expect(isPlaying(controller), isFalse);
    await controller.dispose();
  });

  test('the PiP exception is asked at the moment of backgrounding, not at '
      'construction', () async {
    var inPip = false;
    final (controller, manager) = await playing(keepsPlaying: () => inPip);

    // PiP starts after the manager was built — the ordinary order of events.
    inPip = true;
    manager.didChangeAppLifecycleState(AppLifecycleState.paused);
    await PlayerTestHarness.settle();

    expect(isPlaying(controller), isTrue);
    await controller.dispose();
  });
}
