import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// A play/pause control bound to [FastPixPlayerController.playbackStateStream]
/// only ever learned about playback from progress ticks — and those stop when
/// playback does, so a pause left the last `isPlaying: true` snapshot standing
/// and the button kept its pause icon. The engine's own transport events now
/// publish a snapshot too.
///
/// The same handler throttles the play/pause pair iOS posts from its `rate` KVO
/// while a suspended background player fights the engine's stall handler, which
/// is what flooded the analytics dispatcher during a PiP session.
void main() {
  PlayerTestHarness.install();

  Future<FastPixPlayerController> playing() async {
    final controller = FastPixPlayerController();
    await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    await controller.play();
    await PlayerTestHarness.settle();
    return controller;
  }

  Future<void> post(
    FastPixPlayerController controller,
    BetterPlayerEventType type,
  ) async {
    controller.betterPlayerController?.postEvent(BetterPlayerEvent(type));
    await PlayerTestHarness.settle();
  }

  test('a pause publishes a playback snapshot', () async {
    final controller = await playing();
    final seen = <FastPixPlaybackState>[];
    final sub = controller.playbackStateStream.listen(seen.add);

    // No progress tick follows a pause, so this is the only chance a bound
    // control gets to hear about it.
    await controller.pause();
    await PlayerTestHarness.settle();

    expect(seen, isNotEmpty, reason: 'a pause must reach a bound control');
    expect(seen.last.isPlaying, isFalse);

    await sub.cancel();
    await controller.dispose();
  });

  test('a play publishes a playback snapshot', () async {
    final controller = await playing();
    await controller.pause();
    await PlayerTestHarness.settle();

    final seen = <FastPixPlaybackState>[];
    final sub = controller.playbackStateStream.listen(seen.add);

    await controller.play();
    await PlayerTestHarness.settle();

    expect(seen, isNotEmpty);
    expect(seen.last.isPlaying, isTrue);

    await sub.cancel();
    await controller.dispose();
  });

  test('a burst of alternating transport events is collapsed', () async {
    final controller = await playing();
    final seen = <FastPixPlaybackState>[];
    final sub = controller.playbackStateStream.listen(seen.add);

    // What the engine's stall loop posts: hundreds of flips with no gap.
    for (var i = 0; i < 200; i++) {
      controller.betterPlayerController?.postEvent(
        BetterPlayerEvent(
          i.isEven
              ? BetterPlayerEventType.pause
              : BetterPlayerEventType.play,
        ),
      );
    }
    await PlayerTestHarness.settle();

    expect(
      seen.length,
      lessThan(10),
      reason: 'the flood must not reach the app one event at a time',
    );

    await sub.cancel();
    await controller.dispose();
  });

  test('a deliberate toggle is never throttled away', () async {
    final controller = await playing();
    final seen = <FastPixPlaybackState>[];
    final sub = controller.playbackStateStream.listen(seen.add);

    // Far apart enough to be a viewer, not the engine.
    await post(controller, BetterPlayerEventType.pause);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    await post(controller, BetterPlayerEventType.play);

    expect(seen.length, greaterThanOrEqualTo(2));
    expect(seen.last.isPlaying, isTrue);

    await sub.cancel();
    await controller.dispose();
  });
}
