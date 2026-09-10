import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/utils/fastpix_fairplay_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every protected player is configured with its **own** video's FairPlay URLs.
///
/// The failure this guards against is silent and looks like a decoder problem.
/// A warm player is built in the background while another video is playing, so
/// if the URLs are held as a single process-wide pair, the warm player captures
/// the *playing* video's licence URL. It then acquires a licence the FastPix
/// server issues without complaint — the content id and the URL name different
/// videos and nothing rejects the mismatch — and the video plays as a black
/// frame once that warm player is adopted.
///
/// So the assertion is not "a licence was configured" but "the licence
/// configured for this video names this video".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fastpix_video_player/precache');
  final configured = <Map<String, String?>>[];
  // Resolved inside `setUp`: building the manager creates an HTTP client, and
  // the binding's override for that is only usable once a test is running.
  late FastPixPreloadManager manager;

  FastPixPlayerDataSource fairPlaySource(String id) =>
      FastPixPlayerDataSource.hls(
        playbackId: id,
        token: 'playback-token',
        drmConfiguration: const FastPixPlayerDrmConfiguration(
          drmToken: 'licence-token',
          drmType: FastPixDrmType.fairplay,
          customDomain: 'api.fastpix.com',
        ),
      );

  setUp(() {
    configured.clear();
    manager = FastPixPreloadManager.instance;
    FastPixFairPlayBridge.debugApplyOnEveryPlatform = true;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setFairPlayConfig') {
        configured.add(Map<String, String?>.from(
          (call.arguments as Map).cast<String, String?>(),
        ));
        // The patch reporting itself installed, which is what a device build
        // answers and what the bridge logs against.
        return true;
      }
      return null;
    });

    // Never builds a real player: what matters is what was configured before
    // the build was attempted, not the build.
    manager.warmedPlayerFactory =
        (_, _) => Completer<BetterPlayerController>().future;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    manager.warmedPlayerFactory = null;
    manager.clearAll();
    FastPixFairPlayBridge.debugApplyOnEveryPlatform = false;
  });

  test('a warm player is configured with its own video, not the last one',
      () async {
    await manager.preload(
      <FastPixPlayerDataSource>[fairPlaySource('a'), fairPlaySource('b')],
      strategy: FastPixPreloadStrategy.player,
      window: 2,
    );

    expect(configured.length, 2);
    for (final call in configured) {
      final playbackId = call['playbackId'];
      expect(playbackId, isNotNull);
      // The whole bug in one line: every URL must name the video it was sent
      // for. A cross-wired configuration fails here and nowhere else.
      expect(call['certificateUrl'], contains(playbackId!));
      expect(call['licenseUrl'], contains(playbackId));
    }
    expect(
      configured.map((call) => call['playbackId']),
      containsAll(<String>['a', 'b']),
    );
  });

  test('a network warm configures nothing, since it builds no player',
      () async {
    await manager.preload(
      <FastPixPlayerDataSource>[fairPlaySource('a')],
      strategy: FastPixPreloadStrategy.network,
      window: 1,
    );

    expect(configured, isEmpty);
  });

  test('a source without DRM is left alone', () async {
    await manager.preload(
      <FastPixPlayerDataSource>[FastPixPlayerDataSource.hls(playbackId: 'a')],
      strategy: FastPixPreloadStrategy.player,
      window: 1,
    );

    expect(configured, isEmpty);
  });
}
