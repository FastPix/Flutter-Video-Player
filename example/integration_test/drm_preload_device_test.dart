import 'package:fastpix_player_example/src/catalog.dart';
import 'package:fastpix_player_example/src/models/demo_stream.dart';
import 'package:fastpix_player_example/src/playback_config.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Does any of this work for **DRM** content?
///
/// Everything verified so far ran against unsigned, unprotected assets. That
/// leaves the two most expensive things on the tap path untested: the Widevine
/// licence acquisition, and whether a warmed player that holds a licence can
/// still be adopted.
///
/// It matters because DRM is where preloading should pay off most — the brief
/// measures licence acquisition at a fixed 690–1,099 ms that nothing else can
/// hide — and simultaneously where it is most likely to break: a licence
/// belongs to the player that acquired it, `MediaDrm` sessions are separately
/// capped by the device, and a warm that quietly fails to get one looks
/// identical to a warm that succeeded.
///
/// The DRM stream is read from the demo catalog on the device rather than
/// hard-coded, so no token is committed to the repo. Add a DRM stream in the
/// app first; the test skips cleanly if there is none, and reports plainly if
/// the token has expired rather than blaming the feature.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    FastPixPreloadManager.instance.clearAll();
    FastPixPrecacheManager.instance.clearStatuses();
  });

  testWidgets('a DRM source warms a real player and is adopted', (
    tester,
  ) async {
    final stream = await drmStream();
    if (stream == null) {
      debugPrint('DRM RESULT skipped — no DRM stream in the device catalog');
      return;
    }

    final source = stream.toDataSource();
    debugPrint('DRM RESULT testing playbackId=${source.playbackId}');
    debugPrint('DRM RESULT drmEnabled=${source.drmEnabled}');

    final clock = Stopwatch()..start();
    await FastPixPreloadManager.instance.preload(
      [source],
      configuration: demoPlayerConfiguration(),
      // The strategy that acquires a licence. `network` would only fetch the
      // manifest and prove nothing about DRM.
      strategy: FastPixPreloadStrategy.player,
      window: 1,
      // Explicit rather than relying on the default: this is the flag that
      // decides whether protected sources are warmed at all, and a test that
      // silently depended on its default would pass for the wrong reason.
      warmDrm: true,
    );

    final ready = await waitFor(
      tester,
      () => FastPixPreloadManager.instance.isReady(source.playbackId),
    );
    clock.stop();

    final status = FastPixPreloadManager.instance.statusOf(source.playbackId);
    debugPrint(
      'DRM RESULT playerWarm ready=$ready in=${clock.elapsedMilliseconds}ms '
      'status=${status.name}',
    );

    if (!ready) {
      // An expired token is a test-environment problem, not a feature defect,
      // and the two must not be reported as the same thing.
      debugPrint(
        'DRM RESULT warm did not complete — if the playback/DRM token has '
        'expired, refresh it in the app and re-run before treating this as a '
        'preload failure',
      );
    }
    expect(ready, isTrue, reason: 'the DRM warm never reached ready');

    // Adoption with a licence already held. This is the whole point: the
    // licence cannot be transferred between players, so it is only useful if
    // the player that acquired it is the one that plays.
    final adopted = FastPixPreloadManager.instance.consume(
      source.playbackId,
      fingerprint: betterPlayerConfigurationFingerprint(
        configuration: demoPlayerConfiguration(),
        dataSource: source,
      ),
    );
    debugPrint('DRM RESULT adopted=${adopted != null}');
    expect(adopted, isNotNull, reason: 'the warmed DRM player was refused');
    expect(adopted!.isVideoInitialized(), isTrue);

    adopted.dispose(forceDispose: true);
  });

  testWidgets('precaching a DRM manifest', (tester) async {
    final stream = await drmStream();
    if (stream == null) {
      debugPrint('DRM RESULT precache skipped — no DRM stream');
      return;
    }
    final source = stream.toDataSource();

    // A DRM source's URL always carries ?token=, so this is also the first
    // measurement of precaching against a *signed* URL — the case where the
    // media3 URI-derived cache key stops being stable across a token refresh.
    final status = await FastPixPrecacheManager.instance.precacheManifest(
      source,
    );
    final bytes = FastPixPrecacheManager.instance.bytesWrittenFor(
      source.playbackId,
    );
    debugPrint('DRM RESULT precache status=${status.name} bytes=$bytes');

    // Deliberately not asserted as cached: what this documents is the
    // behaviour, and a signed URL is exactly the case that can legitimately
    // fail to be reusable later.
    expect(status, isNot(FastPixPrecacheStatus.idle));
  });
}

/// Pumps until [predicate] holds, or the timeout expires.
///
/// Top-level rather than nested in `main` so the test bodies stay the only
/// thing `main` describes.
Future<bool> waitFor(
  WidgetTester tester,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return true;
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return predicate();
}

/// The first DRM stream in the on-device catalog, or null.
Future<DemoStream?> drmStream() async {
  await Catalog.instance.load();
  for (final stream in Catalog.instance.streams) {
    if (stream.drmEnabled && (stream.drmToken?.isNotEmpty ?? false)) {
      return stream;
    }
  }
  return null;
}
