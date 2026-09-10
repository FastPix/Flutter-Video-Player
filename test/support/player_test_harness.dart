import 'dart:io';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_manifest_http.dart';
import 'fake_video_player_platform.dart';

/// Wires the fake platform and the fake manifest server around a group of
/// tests, so a [FastPixPlayerController] can be driven through real loads,
/// real engine players and real platform events without a device.
class PlayerTestHarness {
  PlayerTestHarness._();

  static final FakeVideoPlayerPlatform platform =
      FakeVideoPlayerPlatform.instance;

  static HttpOverrides? _previousOverrides;

  /// Call from `main()` of a test file, before any group.
  static void install() {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUpAll(() => _previousOverrides = FakeManifestHttpOverrides.install());
    tearDownAll(() => FakeManifestHttpOverrides.uninstall(_previousOverrides));
    setUp(platform.install);
    tearDown(() {
      platform.uninstall();
      FastPixPreloadManager.instance.clearAll();
    });
  }

  static FastPixPlayerConfiguration configuration() =>
      FastPixPlayerConfiguration('workspace', 'viewer', 'beacon.example.com');

  static FastPixPlayerDataSource source(String playbackId) =>
      FastPixPlayerDataSource.hls(playbackId: playbackId, title: playbackId);

  /// Let the engine's asynchronous plumbing — the platform channel round
  /// trips, the manifest parse, the value listeners — settle.
  static Future<void> settle([int rounds = 4]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Initialize [controller] on a source and bring the engine to the point
  /// where it reports a duration, as a real player does once it has the media.
  static Future<void> load(
    FastPixPlayerController controller,
    FastPixPlayerDataSource dataSource, {
    Duration duration = const Duration(minutes: 10),
  }) async {
    await controller.initialize(
      dataSource: dataSource,
      configuration: configuration(),
    );
    await reportReady(duration: duration);
  }

  /// Report `initialized` for the newest engine player, as the platform does
  /// once it has parsed the media.
  static Future<void> reportReady({
    Duration duration = const Duration(minutes: 10),
  }) async {
    final id = platform.created.last;
    await platform.emitInitialized(id, duration: duration);
    await settle();
  }

  /// Drive one progress tick, optionally moving the playhead first.
  ///
  /// The engine reports progress on a timer while playing; posting the event
  /// directly is the same signal, without spending the wall clock.
  static Future<void> progressTick(
    FastPixPlayerController controller, {
    Duration? position,
  }) async {
    final engine = controller.betterPlayerController;
    if (engine == null) return;
    if (position != null) {
      await engine.videoPlayerController?.seekTo(position);
    }
    engine.postEvent(BetterPlayerEvent(BetterPlayerEventType.progress));
    await settle();
  }

  /// Play the loaded source and let it run to completion, as a viewer watching
  /// an item to the end would.
  static Future<void> playThrough(FastPixPlayerController controller) async {
    await controller.play();
    await settle();
    await progressTick(controller, position: const Duration(seconds: 1));
    await platform.emitCompleted(platform.created.last);
    await settle();
  }

  /// A controller with a playlist loaded and its first item ready to play.
  ///
  /// SDK-driven warming is off by default here: it builds extra engine players
  /// of its own, which is the subject of its own tests rather than noise in
  /// everyone else's.
  static Future<FastPixPlayerController> withPlaylist(
    List<FastPixPlayerDataSource> items, {
    int startIndex = 0,
    int preloadRadius = 0,
    Duration duration = const Duration(minutes: 10),
  }) async {
    final controller = FastPixPlayerController()
      ..preloadRadius = preloadRadius;
    await controller.setPlaylist(
      items,
      startIndex: startIndex,
      configuration: configuration(),
    );
    await reportReady(duration: duration);
    return controller;
  }

  /// Sources named `item-0`, `item-1`, …
  static List<FastPixPlayerDataSource> playlist(int count) =>
      <FastPixPlayerDataSource>[
        for (var i = 0; i < count; i++) source('item-$i'),
      ];
}
