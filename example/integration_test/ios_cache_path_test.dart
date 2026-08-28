import 'dart:io';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Does enabling the iOS HLS cache actually still play?
///
/// Turning `useCache` on for unprotected iOS HLS routes playback through the
/// engine's local `HLSCachingReverseProxyServer` (`127.0.0.1:8080`, PINCache)
/// instead of straight at the CDN. That is a **behaviour change to working
/// playback**, and the historical failure mode for iOS HLS caching is
/// `CoreMediaError -12642` — a hard failure, not a slow start.
///
/// It was tried. It fails: an unprotected stream, no DRM anywhere, returned
/// `CoreMediaErrorDomain error -12642` within a second. So this test now locks
/// the cache **off** for iOS HLS and proves playback works without it — and it
/// is the place to re-run if anyone wants to try the proxy path again.
///
/// DRM is deliberately not exercised: protected sources keep `useCache: false`
/// and take the untouched code path, and a simulator has no FairPlay anyway.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String unprotected = '142c8d68-fce0-43e1-9322-7c282bd30966';

  testWidgets('an unprotected iOS HLS source plays through the cache path', (
    tester,
  ) async {
    if (!Platform.isIOS) return;

    const source = FastPixPlayerDataSource(
      playbackId: unprotected,
      format: FastPixStreamingFormat.hls,
    );

    // Caching is OFF for iOS HLS, and this asserts it stays off.
    //
    // It was enabled once, on the reasoning that the engine's reverse-proxy
    // path is ordinary HTTP and therefore safe. It is not: an unprotected
    // stream failed immediately with `CoreMediaErrorDomain error -12642`. This
    // guard exists so that reasoning cannot be re-applied without the failure
    // being reproduced first.
    final built = source.toBetterPlayerDataSource();
    debugPrint('IOS RESULT useCache=${built.cacheConfiguration?.useCache}');
    expect(
      built.cacheConfiguration?.useCache,
      isFalse,
      reason: 'iOS HLS caching is enabled again — it fails with -12642',
    );

    final errors = <String>[];
    final controller = FastPixPlayerController();
    controller.addGlobalListener((event) {
      if (event is FastPixPlayerErrorEvent) {
        errors.add(event.message);
        debugPrint('IOS RESULT playback error: ${event.message}');
      }
    });

    final clock = Stopwatch()..start();
    await controller.initialize(
      dataSource: source,
      configuration: FastPixPlayerConfiguration(
        'ios-cache-test',
        'viewer',
        'metrix.ws.fastpix.io',
        controlsConfiguration:
            const FastPixPlayerControlsConfiguration(autoPlay: true),
      ),
    );

    // Wait for real media, not just for setup to return.
    var initialised = false;
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      if (controller.betterPlayerController?.isVideoInitialized() == true) {
        initialised = true;
        break;
      }
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    clock.stop();

    debugPrint(
      'IOS RESULT cachePath initialised=$initialised '
      'in=${clock.elapsedMilliseconds}ms errors=${errors.length}',
    );

    expect(
      initialised,
      isTrue,
      reason:
          'playback never initialised through the reverse-proxy cache path — '
          'this is the -12642 class of failure and the gate should be reverted',
    );
    // -12642 surfaces as a playback error rather than a timeout, so both are
    // checked; either one means the cache path is not safe to ship.
    expect(errors, isEmpty, reason: 'errors: $errors');

    await controller.dispose();
  });
}
