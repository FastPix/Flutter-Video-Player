import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// A source that failed while the device had no network.
///
/// The platform player never recovers one: a failed `AVPlayerItem` is failed
/// for good, so the network coming back reached nothing and the video stayed
/// stuck — the viewer had to load another source and come back, which built a
/// new player and was the only reason it ever played. The SDK reloads it for
/// them instead.
void main() {
  PlayerTestHarness.install();

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await FastPixNetworkMonitor.instance.stop();
  });

  Future<FastPixPlayerController> failedOffline({
    Duration? at,
    String message =
        'Failed to load video: The Internet connection appears to be offline.',
  }) async {
    final controller = FastPixPlayerController();
    await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    if (at != null) {
      await PlayerTestHarness.progressTick(controller, position: at);
    }
    await PlayerTestHarness.platform.emitError(
      PlayerTestHarness.platform.created.last,
      message,
    );
    await PlayerTestHarness.settle();
    // The device really is offline at the moment of the failure; the monitor's
    // own first reading is not reported, so this stands in for the transition
    // the platform delivered when the WiFi went off.
    FastPixNetworkMonitor.instance.debugSetNetwork(FastPixNetworkType.none);
    await PlayerTestHarness.settle();
    return controller;
  }

  test('reloads once the network comes back', () async {
    final controller = await failedOffline();
    final generationBefore = controller.sourceGeneration.value;

    FastPixNetworkMonitor.instance.debugSetNetwork(FastPixNetworkType.wifi);
    // A whole load, not just the reset: the engine player is rebuilt from the
    // fake platform, which takes several turns.
    await PlayerTestHarness.settle(20);

    expect(
      controller.sourceGeneration.value,
      greaterThan(generationBefore),
      reason: 'a failed player is unrecoverable; a fresh load is the only cure',
    );
    await controller.dispose();
  });

  test('resumes where it stopped rather than from the beginning', () async {
    const stoppedAt = Duration(minutes: 3);
    final controller = await failedOffline(at: stoppedAt);

    FastPixNetworkMonitor.instance.debugSetNetwork(FastPixNetworkType.wifi);
    await PlayerTestHarness.settle();

    expect(controller.dataSource?.startAt, stoppedAt);
    await controller.dispose();
  });

  test('staying offline is not a reason to reload', () async {
    final controller = await failedOffline();
    final generationBefore = controller.sourceGeneration.value;

    // A network that reports itself again, still with nothing behind it.
    FastPixNetworkMonitor.instance.debugSetNetwork(FastPixNetworkType.unknown);
    await PlayerTestHarness.settle(20);

    expect(controller.sourceGeneration.value, generationBefore);
    await controller.dispose();
  });

  test('only the first return reloads, not every later change', () async {
    final controller = await failedOffline();
    final generationBefore = controller.sourceGeneration.value;

    FastPixNetworkMonitor.instance.debugSetNetwork(FastPixNetworkType.wifi);
    await PlayerTestHarness.settle(20);
    final afterFirst = controller.sourceGeneration.value;
    FastPixNetworkMonitor.instance.debugSetNetwork(FastPixNetworkType.mobile);
    await PlayerTestHarness.settle(20);

    expect(afterFirst, greaterThan(generationBefore));
    expect(controller.sourceGeneration.value, afterFirst);
    await controller.dispose();
  });

  test('an error that is not about the network arms nothing', () async {
    final controller = await failedOffline(message: 'Source error');
    final generationBefore = controller.sourceGeneration.value;

    FastPixNetworkMonitor.instance.debugSetNetwork(FastPixNetworkType.wifi);
    await PlayerTestHarness.settle();

    expect(controller.sourceGeneration.value, generationBefore);
    await controller.dispose();
  });

  test('Android\'s bare "Source error" reloads when it failed offline',
      () async {
    // ExoPlayer keeps the network cause native; only the device being
    // offline at the failure tells it apart from a bad source.
    await FastPixNetworkMonitor.instance.start();
    FastPixNetworkMonitor.instance.debugSetNetwork(FastPixNetworkType.none);
    final controller = await failedOffline(
      message: 'Video player had error '
          'androidx.media3.exoplayer.ExoPlaybackException: Source error',
    );
    final generationBefore = controller.sourceGeneration.value;

    FastPixNetworkMonitor.instance.debugSetNetwork(FastPixNetworkType.wifi);
    await PlayerTestHarness.settle(20);

    expect(controller.sourceGeneration.value, greaterThan(generationBefore));
    await controller.dispose();
  });

  test('play on a failed player loads the source again', () async {
    final controller = await failedOffline(message: 'Source error');
    final playersBefore = PlayerTestHarness.platform.created.length;

    await controller.play();
    await PlayerTestHarness.settle(20);

    expect(
      PlayerTestHarness.platform.created.length,
      greaterThan(playersBefore),
      reason: 'a failed player never plays again; play must not be dead',
    );
    await controller.dispose();
  });

  test('a disposed controller reloads nothing', () async {
    final controller = await failedOffline();
    await controller.dispose();
    final playersBefore = PlayerTestHarness.platform.created.length;

    FastPixNetworkMonitor.instance.debugSetNetwork(FastPixNetworkType.wifi);
    await PlayerTestHarness.settle();

    expect(PlayerTestHarness.platform.created.length, playersBefore);
  });
}
