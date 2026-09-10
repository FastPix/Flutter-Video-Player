import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// One drag is one seek, on every platform.
///
/// The engine's own progress bar seeks on every `onHorizontalDragUpdate`
/// (`better_player_material_progress_bar.dart:87`), so a single drag arrives as
/// a burst of `seekTo` events. Without collapsing them, each one dispatches a
/// pause/seeking/seeked/play cycle into analytics — dozens of beacons
/// describing seeks the viewer never made. The guard used to be iOS-only, on
/// the assumption that Android did not burst. It does.
void main() {
  PlayerTestHarness.install();

  Future<int> seekEventsFor(int seekToEvents) async {
    final controller = FastPixPlayerController();
    await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    // The analytics sequence only admits a seek from a playing state.
    await controller.play();
    await PlayerTestHarness.settle();

    var seeking = 0;
    controller.addEventListener(
      FastPixPlayerEventTypes.seeking,
      (_) => seeking++,
    );

    for (var i = 0; i < seekToEvents; i++) {
      // Posted through the engine controller, so the event takes exactly the
      // path a real drag takes.
      controller.betterPlayerController!.postEvent(
        BetterPlayerEvent(BetterPlayerEventType.seekTo),
      );
    }
    await PlayerTestHarness.settle();
    await controller.dispose();
    return seeking;
  }

  test('a burst of seekTo events dispatches one seek', () async {
    // 20 updates is a short drag.
    expect(await seekEventsFor(20), 1);
  });

  test('a single seek still dispatches', () async {
    expect(await seekEventsFor(1), 1);
  });
}
