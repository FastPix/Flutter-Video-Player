import 'dart:async';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/fastpix_prerender_manager.dart';
import 'package:fastpix_video_player/src/utils/fastpix_prerender_channel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'player_test_harness.dart';

/// The native prerender side, recorded instead of performed.
class FakePrerenderPlatform implements FastPixPrerenderPlatform {
  bool supported = true;
  bool watchSupported = true;
  final Map<int, FastPixPrerenderRole> roles = <int, FastPixPrerenderRole>{};
  final List<int> watched = <int>[];
  final StreamController<int> frames = StreamController<int>.broadcast();
  final StreamController<int> seeks = StreamController<int>.broadcast();

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<void> setRole(int textureId, FastPixPrerenderRole role) async =>
      roles[textureId] = role;

  @override
  Future<bool> watchFirstFrame(
    int textureId, {
    required Duration position,
    required double rate,
  }) async {
    watched.add(textureId);
    return watchSupported;
  }

  @override
  Future<void> stopWatching(int textureId) async {}

  @override
  Stream<int> get frameReady => frames.stream;

  @override
  Stream<int> get seekFailed => seeks.stream;
}

/// Installs [FakePrerenderPlatform] around each test, with the app in the
/// foreground and no frames to wait for.
class PrerenderTestHarness {
  PrerenderTestHarness._();

  static late FakePrerenderPlatform native;
  static bool foreground = true;

  static FastPixPrerenderManager get manager =>
      FastPixPrerenderManager.instance;

  /// Call from `main()` after [PlayerTestHarness.install].
  static void install() {
    setUp(() {
      native = FakePrerenderPlatform();
      foreground = true;
      manager
        ..platform = native
        ..isForegroundOverride = (() => foreground)
        ..afterMountOverride = (() async {})
        ..deadlineOverride = null;
    });
    tearDown(() async {
      manager.debugReset();
      manager
        ..platform = null
        ..isForegroundOverride = null
        ..afterMountOverride = null
        ..deadlineOverride = null;
      FastPixPreloadManager.instance
        ..clearAll()
        ..debugForgetPlayerBuilds();
      await PlayerTestHarness.settle();
    });
  }

  /// Wait until the fake platform has built one more player than [before].
  static Future<void> waitForBuild(int before) async {
    final engines = PlayerTestHarness.platform;
    for (var i = 0; i < 60 && engines.created.length == before; i++) {
      await PlayerTestHarness.settle(1);
    }
    expect(engines.created.length, before + 1, reason: 'a player was built');
  }

  /// Prerender [playbackId] on [controller] through to frame-ready.
  static Future<int> ready(
    FastPixPlayerController controller,
    String playbackId,
  ) async {
    final engines = PlayerTestHarness.platform;
    final before = engines.created.length;
    final pending = controller.prerender(PlayerTestHarness.source(playbackId));
    await waitForBuild(before);
    final textureId = engines.created.last;
    await engines.emitInitialized(textureId);
    await PlayerTestHarness.settle();
    native.frames.add(textureId);
    final result = await pending;
    expect(result.status, FastPixPrerenderStatus.frameReady);
    return textureId;
  }

  /// Bring a warm player for the window's newest build to ready.
  static Future<int> warm() async {
    final engines = PlayerTestHarness.platform;
    final textureId = engines.created.last;
    await engines.emitInitialized(textureId);
    await PlayerTestHarness.settle();
    return textureId;
  }
}
