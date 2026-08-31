import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Baseline: does `Unknown textureId` happen without preloading involved?
///
/// The preload cycle test throws
/// `PlatformException(Unknown textureId, No video player associated with
/// texture id N)` intermittently. Before treating that as a defect in
/// `FastPixPreloadManager`, it has to be established whether the engine does
/// the same thing on its own.
///
/// This test touches none of the FastPix SDK. It builds a
/// `BetterPlayerController` directly, waits for it to initialise, disposes it
/// and repeats — the plain create/dispose cycle every app performs when a
/// viewer moves between videos.
///
/// If this throws, the exception is pre-existing engine behaviour and
/// preloading only surfaces it more often, by disposing more players in less
/// time. If it stays clean, the fault is in this SDK's release path.
///
/// The suspected mechanism is in better_player_plus 1.0.8:
/// `BetterPlayerController.dispose()` calls `pause()` — which is async and is
/// **not awaited** — and then immediately disposes the underlying
/// `VideoPlayerController`, freeing the texture. The in-flight `pause` platform
/// call can land after the texture is gone.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String assetA = '142c8d68-fce0-43e1-9322-7c282bd30966';
  const String assetB = '6d75bc7a-6ef7-4b20-ad0e-b11f11bab3e6';

  Future<BetterPlayerController> build(WidgetTester tester, String id) async {
    final controller = BetterPlayerController(
      const BetterPlayerConfiguration(
        autoPlay: false,
        autoDispose: false,
        handleLifecycle: false,
      ),
    );

    final ready = Completer<void>();
    void listener(BetterPlayerEvent event) {
      if (ready.isCompleted) return;
      if (event.betterPlayerEventType == BetterPlayerEventType.initialized) {
        ready.complete();
      } else if (event.betterPlayerEventType ==
          BetterPlayerEventType.exception) {
        ready.completeError(event.parameters?['exception'] ?? 'failed');
      }
    }

    controller.addEventsListener(listener);
    await controller.setupDataSource(
      BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        'https://stream.fastpix.com/$id.m3u8',
        videoFormat: BetterPlayerVideoFormat.hls,
      ),
    );

    // Pump while waiting; the completer is driven by a platform event stream.
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (!ready.isCompleted && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    controller.removeEventsListener(listener);
    return controller;
  }

  testWidgets('plain engine create/dispose cycles, no FastPix SDK involved', (
    tester,
  ) async {
    // 20, not 8. The fault being attributed is intermittent — the SDK arm
    // survived 4 cycles and failed at 12 — so a short clean run proves
    // nothing. This has to outlast the point where the other arm broke.
    for (var cycle = 0; cycle < 20; cycle++) {
      final id = cycle.isEven ? assetA : assetB;
      debugPrint('BASELINE cycle=$cycle building');
      final controller = await build(tester, id);
      expect(controller.isVideoInitialized(), isTrue,
          reason: 'cycle $cycle never initialised');
      debugPrint('BASELINE cycle=$cycle disposing');
      controller.dispose(forceDispose: true);
      await tester.pump(const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      debugPrint('BASELINE cycle=$cycle disposed');
    }
    debugPrint('BASELINE completed all 8 cycles clean');
  });
}
