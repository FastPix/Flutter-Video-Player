import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Device validation for playlists.
///
/// The unit suites cover the cursor, the events and the source-switching
/// contract against a fake platform. What a fake cannot answer is the part
/// this feature exists for: that advancing a playlist inside one controller
/// releases the outgoing ExoPlayer/AVPlayer, adopts the warmed one prepared
/// for the next item, keeps rendering, and keeps reporting — all of which is
/// platform behaviour.
///
/// So this suite uses no injection. It drives a playlist exactly as an app
/// would, against real streams, and reports what it observes.
///
/// Run it on an attached device:
///
/// ```
/// cd example
/// flutter test integration_test/playlist_device_test.dart -d <device-id>
/// ```
///
/// Watch the log for `FIRST FRAME … start=WARM (adopted)` after the advance:
/// that line, not a timing, is the proof the warm window paid off.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Public, un-tokenised FastPix assets.
  const String assetA = '142c8d68-fce0-43e1-9322-7c282bd30966';
  const String assetB = '6d75bc7a-6ef7-4b20-ad0e-b11f11bab3e6';

  FastPixPlayerDataSource sourceFor(String playbackId) =>
      FastPixPlayerDataSource(
        playbackId: playbackId,
        format: FastPixStreamingFormat.hls,
      );

  FastPixPlayerConfiguration configuration() => FastPixPlayerConfiguration(
    'device-test-workspace',
    'device-test-viewer',
    'metrix.ws.fastpix.io',
    controlsConfiguration: const FastPixPlayerControlsConfiguration(
      autoPlay: false,
    ),
  );

  /// Wait until [predicate] holds, or give up.
  ///
  /// `pumpAndSettle` is useless here: the work being waited on is a platform
  /// channel round trip and a network fetch, neither of which schedules a
  /// frame.
  Future<bool> waitFor(
    WidgetTester tester,
    bool Function() predicate, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (predicate()) return true;
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return predicate();
  }

  tearDown(FastPixPreloadManager.instance.clearAll);

  testWidgets('a playlist advances in place and adopts the warmed item',
      (tester) async {
    final controller = FastPixPlayerController();
    final events = <String>[];
    controller.addGlobalListener((event) => events.add(
          '${event.type} ${event.data?['playbackId']} '
          '#${event.data?['playlistIndex']}',
        ));

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: FastPixPlayer(controller: controller))),
    );

    await controller.setPlaylist(
      <FastPixPlayerDataSource>[sourceFor(assetA), sourceFor(assetB)],
      configuration: configuration(),
    );
    expect(
      await waitFor(tester, () => controller.betterPlayerController != null),
      isTrue,
      reason: 'the first item never loaded',
    );
    expect(controller.currentPlaylistIndex, 0);

    // The SDK declares the warm window after the load. Give it the dwell a
    // playlist really has — this is the whole reason a playlist is the best
    // case for warming.
    expect(
      await waitFor(
        tester,
        () => FastPixPreloadManager.instance.isReady(assetB),
        timeout: const Duration(seconds: 45),
      ),
      isTrue,
      reason: 'the next item was never warmed',
    );

    final firstPlayer = controller.betterPlayerController;
    expect(await controller.next(), isTrue);
    expect(
      await waitFor(
        tester,
        () => controller.betterPlayerController != null &&
            controller.betterPlayerController != firstPlayer,
      ),
      isTrue,
      reason: 'the advance never produced a new player',
    );

    expect(controller.currentPlaylistIndex, 1);
    expect(controller.dataSource?.playbackId, assetB);
    // Adoption, not a cold start: the warmed entry was consumed rather than
    // released by the warm declaration that follows the move.
    expect(
      FastPixPreloadManager.instance.statusOf(assetB),
      isNot(FastPixPreloadStatus.ready),
      reason: 'the warmed player should have been handed to playback',
    );

    // Every event says which item it belongs to.
    expect(
      events.where((line) => line.contains('#1')),
      isNotEmpty,
      reason: 'events after the advance must be attributed to item 1',
    );

    debugPrint('playlist device test events:\n${events.join('\n')}');
    await controller.dispose();
  });

  testWidgets('autoplay runs the playlist to its end and reports it',
      (tester) async {
    final controller = FastPixPlayerController()..autoPlayNext = true;
    var ended = false;
    controller.addEventListener(
      FastPixPlayerEventTypes.playlistEnded,
      (_) => ended = true,
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: FastPixPlayer(controller: controller))),
    );
    await controller.setPlaylist(
      <FastPixPlayerDataSource>[sourceFor(assetA), sourceFor(assetB)],
      configuration: configuration(),
    );
    expect(
      await waitFor(tester, () => controller.betterPlayerController != null),
      isTrue,
    );

    // Seek close to the end of each item rather than watching them through.
    for (var index = 0; index < 2; index++) {
      expect(
        await waitFor(
          tester,
          () => (controller.getTotalDuration() ?? Duration.zero) >
              Duration.zero,
        ),
        isTrue,
        reason: 'item $index never reported a duration',
      );
      await controller.play();
      final duration = controller.getTotalDuration()!;
      await controller.seekTo(duration - const Duration(seconds: 2));
      await waitFor(
        tester,
        () => controller.currentPlaylistIndex != index || ended,
        timeout: const Duration(seconds: 30),
      );
    }

    expect(ended, isTrue, reason: 'the end of the playlist was never reported');
    expect(controller.currentPlaylistIndex, 1);
    await controller.dispose();
  });
}
