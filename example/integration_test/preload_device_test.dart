import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Device validation for preloading and precaching.
///
/// The unit tests cover the manager's bookkeeping by injecting a fake warmer
/// and a fake player factory. That is the right shape for logic, but it means
/// the part that actually does the work has never run: building a real
/// ExoPlayer with no surface attached, waiting for it to report `initialized`,
/// handing it to a second controller, and writing bytes into the cache
/// instance playback reads from. All of that is platform behaviour, and a fake
/// cannot tell you whether it holds.
///
/// So this suite deliberately uses **no injection**. It drives
/// `FastPixPreloadManager` and `FastPixPrecacheManager` exactly as an app
/// would, against real streams, and reports timings.
///
/// Run it on an attached device:
///
/// ```
/// cd example
/// flutter test integration_test/preload_device_test.dart -d <device-id>
/// ```
///
/// Debug-mode timings do not transfer to production — treat the numbers here
/// as proof that a path *executes*, and take the numbers that matter from a
/// profile build with `FastPixPlayStartTrace`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Public, un-tokenised FastPix assets. Two of them, because adoption can
  // only be shown to be per-source by warming one and asking for the other.
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
      // Off, so a warmed player that is adopted does not start playing audio
      // in the middle of a test run.
      autoPlay: false,
    ),
  );

  /// Wait until [predicate] holds, or give up.
  ///
  /// `pumpAndSettle` is useless here: the work being waited on is a platform
  /// channel round trip and a network fetch, neither of which schedules a
  /// frame, so a settle returns immediately and the assertion runs before
  /// anything has happened.
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

  tearDown(() {
    FastPixPreloadManager.instance.clearAll();
    FastPixPrecacheManager.instance.clearStatuses();
  });

  testWidgets('layer B: warming the playback hosts completes and never throws', (
    tester,
  ) async {
    final stopwatch = Stopwatch()..start();
    await warmPlaybackHosts();
    stopwatch.stop();

    debugPrint('RESULT hostWarm=${stopwatch.elapsedMilliseconds}ms');
    // No assertion on the duration: the requests are expected to fail (there
    // is no token) and only the DNS and TLS work survives. What is being
    // proven is that it returns rather than hanging or throwing into app
    // start.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  testWidgets('precache: the native warmer commits real bytes', (tester) async {
    // The unit test injects a `cacheWriter`, so this is the first time the
    // Kotlin path runs: BetterPlayerCache.createCache, a CacheWriter over an
    // unbounded DataSpec, and a byte count coming back. A zero here means the
    // manifest was fetched and then not stored — the exact silent failure this
    // implementation exists to avoid.
    final status = await FastPixPrecacheManager.instance.precacheManifest(
      sourceFor(assetA),
    );
    final bytes = FastPixPrecacheManager.instance.bytesWrittenFor(assetA);

    debugPrint('RESULT precache status=${status.name} bytes=$bytes');

    expect(status, FastPixPrecacheStatus.cached);
    expect(bytes, greaterThan(0), reason: 'nothing was committed to the cache');
  });

  testWidgets('preload/network: the manifest warmer reaches ready', (
    tester,
  ) async {
    final stopwatch = Stopwatch()..start();
    await FastPixPreloadManager.instance.preload(
      [sourceFor(assetA)],
      configuration: configuration(),
      strategy: FastPixPreloadStrategy.network,
      window: 1,
    );

    final ready = await waitFor(
      tester,
      () => FastPixPreloadManager.instance.isReady(assetA),
    );
    stopwatch.stop();

    debugPrint(
      'RESULT networkWarm ready=$ready in=${stopwatch.elapsedMilliseconds}ms '
      'status=${FastPixPreloadManager.instance.statusOf(assetA).name}',
    );
    expect(ready, isTrue);
  });

  testWidgets('preload/player: a real player warms and is adopted', (
    tester,
  ) async {
    // The headline test. No injected factory, so this exercises
    // _createWarmedPlayer for real: a BetterPlayerController is built with no
    // surface attached, setupDataSource is called, and the manager waits for
    // the platform to report `initialized`.
    final warmClock = Stopwatch()..start();
    await FastPixPreloadManager.instance.preload(
      [sourceFor(assetA)],
      configuration: configuration(),
      strategy: FastPixPreloadStrategy.player,
      window: 1,
    );

    final ready = await waitFor(
      tester,
      () => FastPixPreloadManager.instance.isReady(assetA),
      timeout: const Duration(seconds: 40),
    );
    warmClock.stop();

    debugPrint(
      'RESULT playerWarm ready=$ready in=${warmClock.elapsedMilliseconds}ms '
      'status=${FastPixPreloadManager.instance.statusOf(assetA).name}',
    );
    expect(
      ready,
      isTrue,
      reason:
          'a real ExoPlayer never reported initialized without a surface — '
          'which is the assumption the whole player strategy rests on',
    );

    // The warm time is the number that decides whether this is viable: it has
    // to fit inside dwell, the gap between the warm starting and the tap.
    expect(warmClock.elapsed, lessThan(const Duration(seconds: 40)));

    // Adoption. The fingerprint must be computed the same way
    // FastPixPlayerController does, or this returns null for a reason that has
    // nothing to do with the platform.
    final fingerprint = betterPlayerConfigurationFingerprint(
      configuration: configuration(),
      dataSource: sourceFor(assetA),
    );
    final adopted = FastPixPreloadManager.instance.consume(
      assetA,
      fingerprint: fingerprint,
    );

    debugPrint('RESULT adoption adopted=${adopted != null}');
    expect(adopted, isNotNull, reason: 'the warmed player was refused');

    // A warmed player is only useful if it is genuinely past initialisation —
    // that is what removes the manifest fetch and decoder setup from the tap.
    expect(adopted!.isVideoInitialized(), isTrue);

    // Ownership transferred, so the entry is gone and the caller owns disposal.
    expect(FastPixPreloadManager.instance.isReady(assetA), isFalse);
    adopted.dispose(forceDispose: true);
  });

  testWidgets('preload/player: a fingerprint mismatch is refused, not adopted', (
    tester,
  ) async {
    await FastPixPreloadManager.instance.preload(
      [sourceFor(assetA)],
      configuration: configuration(),
      strategy: FastPixPreloadStrategy.player,
      window: 1,
    );
    final ready = await waitFor(
      tester,
      () => FastPixPreloadManager.instance.isReady(assetA),
      timeout: const Duration(seconds: 40),
    );
    expect(ready, isTrue);

    // A player warmed for these settings cannot render correctly under
    // different ones, because BetterPlayerConfiguration is final on the
    // controller. Refusing is correct behaviour.
    final mismatched = FastPixPreloadManager.instance.consume(
      assetA,
      fingerprint: 'deliberately-not-the-warmed-fingerprint',
    );

    debugPrint('RESULT mismatchRefused=${mismatched == null}');
    expect(mismatched, isNull);
  });

  testWidgets('preload/player: asking for a source that was never warmed', (
    tester,
  ) async {
    await FastPixPreloadManager.instance.preload(
      [sourceFor(assetA)],
      configuration: configuration(),
      strategy: FastPixPreloadStrategy.player,
      window: 1,
    );
    await waitFor(
      tester,
      () => FastPixPreloadManager.instance.isReady(assetA),
      timeout: const Duration(seconds: 40),
    );

    // The cold path, which must stay available and silent.
    final other = FastPixPreloadManager.instance.consume(
      assetB,
      fingerprint: betterPlayerConfigurationFingerprint(
        configuration: configuration(),
        dataSource: sourceFor(assetB),
      ),
    );
    expect(other, isNull);
  });

  testWidgets('the decoder budget is handed back across repeated cycles', (
    tester,
  ) async {
    // Android caps concurrent decoders, and exceeding it does not fail the
    // preload — it fails live playback, minutes later and far from the cause.
    // Twelve warm/release cycles is enough to exhaust the budget on this
    // device if anything is leaking.
    for (var cycle = 0; cycle < 12; cycle++) {
      final id = cycle.isEven ? assetA : assetB;
      await FastPixPreloadManager.instance.preload(
        [sourceFor(id)],
        configuration: configuration(),
        strategy: FastPixPreloadStrategy.player,
        window: 1,
      );
      final ready = await waitFor(
        tester,
        () => FastPixPreloadManager.instance.isReady(id),
        timeout: const Duration(seconds: 40),
      );
      expect(ready, isTrue, reason: 'cycle $cycle never became ready — the '
          'decoder budget was probably exhausted by an earlier cycle');
      FastPixPreloadManager.instance.clearAll();
    }
    debugPrint('RESULT cycles=12 survived');
  });
}
