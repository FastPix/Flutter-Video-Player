import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Narrows down the `Unknown textureId` PlatformException seen when warm
/// players are released and re-warmed back to back.
///
/// Three questions, one test each:
///
/// 1. Which cycle throws — the first release, or only once several have run?
/// 2. Does it come from releasing, or from re-warming immediately after?
/// 3. Does letting the platform settle between the two make it go away?
///
/// Answering these separates a leak in this SDK's bookkeeping from a race
/// inside the engine's own teardown.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String assetA = '142c8d68-fce0-43e1-9322-7c282bd30966';
  const String assetB = '6d75bc7a-6ef7-4b20-ad0e-b11f11bab3e6';

  FastPixPlayerDataSource sourceFor(String id) =>
      FastPixPlayerDataSource(playbackId: id, format: FastPixStreamingFormat.hls);

  FastPixPlayerConfiguration configuration() => FastPixPlayerConfiguration(
    'diag-workspace',
    'diag-viewer',
    'metrix.ws.fastpix.io',
    controlsConfiguration:
        const FastPixPlayerControlsConfiguration(autoPlay: false),
  );

  Future<bool> waitReady(
    WidgetTester tester,
    String id, {
    Duration timeout = const Duration(seconds: 40),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (FastPixPreloadManager.instance.isReady(id)) return true;
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return FastPixPreloadManager.instance.isReady(id);
  }

  Future<void> warm(WidgetTester tester, String id) async {
    await FastPixPreloadManager.instance.preload(
      [sourceFor(id)],
      configuration: configuration(),
      strategy: FastPixPreloadStrategy.player,
      window: 1,
    );
    final ready = await waitReady(tester, id);
    expect(ready, isTrue, reason: 'warm for $id never became ready');
  }

  testWidgets('Q1: which cycle first throws, with no settle time', (
    tester,
  ) async {
    // Identical to the failing test, but reporting each step so the failure
    // can be attributed to a specific transition rather than to "12 cycles".
    for (var cycle = 0; cycle < 4; cycle++) {
      final id = cycle.isEven ? assetA : assetB;
      debugPrint('DIAG cycle=$cycle warming');
      await warm(tester, id);
      debugPrint('DIAG cycle=$cycle warmed, releasing');
      FastPixPreloadManager.instance.clearAll();
      debugPrint('DIAG cycle=$cycle released');
    }
    debugPrint('DIAG Q1 completed all 4 cycles');
  });

  testWidgets('Q2: releasing alone, with no re-warm afterwards', (
    tester,
  ) async {
    // If this is clean, releasing is not what throws — the exception belongs
    // to the re-warm that follows it.
    await warm(tester, assetA);
    FastPixPreloadManager.instance.clearAll();
    debugPrint('DIAG Q2 released once');

    // Give any in-flight platform call time to land and throw.
    await tester.pump(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(seconds: 2));
    debugPrint('DIAG Q2 survived the settle');
  });

  testWidgets('Q3: the same cycles, with a settle between release and re-warm',
      (tester) async {
    // If this passes where Q1 fails, the problem is a race in teardown rather
    // than a resource that was never handed back — the distinction that
    // decides whether this SDK has a bug or the engine does.
    for (var cycle = 0; cycle < 4; cycle++) {
      final id = cycle.isEven ? assetA : assetB;
      debugPrint('DIAG settled cycle=$cycle warming');
      await warm(tester, id);
      FastPixPreloadManager.instance.clearAll();
      await tester.pump(const Duration(milliseconds: 600));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      debugPrint('DIAG settled cycle=$cycle released');
    }
    debugPrint('DIAG Q3 completed all 4 settled cycles');
  });
}
