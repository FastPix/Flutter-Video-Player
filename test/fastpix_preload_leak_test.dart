import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

// Read lazily: the singleton opens an HttpClient, which the test binding
// only allows inside a test.
FastPixPreloadManager get manager => FastPixPreloadManager.instance;

/// A warm that outlives [FastPixPreloadManager.warmTimeout] must not leave its
/// player behind. Measured on a device over a slow network before this was
/// fixed: 45 warms left 41 engine players alive against a window of 3.
///
/// The timeout is the real 12 seconds, so two of these run on the wall clock.
void main() {
  PlayerTestHarness.install();

  final platform = PlayerTestHarness.platform;
  const pastTimeout = Duration(milliseconds: 12500);

  tearDown(() {
    manager.warmedPlayerFactory = null;
    manager.debugForgetPlayerBuilds();
  });

  Future<void> startWarm(String id) async {
    unawaited(
      manager.preload(
        <FastPixPlayerDataSource>[PlayerTestHarness.source(id)],
        configuration: PlayerTestHarness.configuration(),
        strategy: FastPixPreloadStrategy.player,
        window: 1,
      ),
    );
    for (var i = 0; i < 40 && platform.created.isEmpty; i++) {
      await PlayerTestHarness.settle(1);
    }
    expect(platform.created, hasLength(1));
  }

  test(
    'a player that never initializes is released after the timeout',
    () async {
      await startWarm('stalled');

      await Future<void>.delayed(pastTimeout);
      await PlayerTestHarness.settle(10);

      expect(manager.statusOf('stalled'), FastPixPreloadStatus.failed);
      expect(platform.alive, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test(
    'a player that initializes after the warm timed out is released',
    () async {
      await startWarm('late');

      await Future<void>.delayed(pastTimeout);
      expect(manager.statusOf('late'), FastPixPreloadStatus.failed);

      // The network finally delivers, after the manager gave up on the warm.
      await PlayerTestHarness.reportReady();
      await PlayerTestHarness.settle(10);

      expect(platform.alive, isEmpty);
      expect(manager.consume('late', fingerprint: ''), isNull);
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test('evicted builds still count against the cap until they settle',
      () async {
    final gates = <Completer<BetterPlayerController>>[];
    manager.warmedPlayerFactory = (_, _) {
      final gate = Completer<BetterPlayerController>();
      gates.add(gate);
      return gate.future;
    };
    final sources = List<FastPixPlayerDataSource>.generate(
      FastPixPreloadManager.maxPlayerWindow * 2,
      (i) => PlayerTestHarness.source('s$i'),
    );
    final cap = FastPixPreloadManager.maxPlayerWindow;

    await manager.preload(
      sources.take(cap).toList(),
      configuration: PlayerTestHarness.configuration(),
      strategy: FastPixPreloadStrategy.player,
      window: cap,
    );
    await PlayerTestHarness.settle(1);
    expect(gates, hasLength(cap));

    // The window moves on; the first builds are evicted but still loading.
    await manager.preload(
      sources.skip(cap).toList(),
      configuration: PlayerTestHarness.configuration(),
      strategy: FastPixPreloadStrategy.player,
      window: cap,
    );
    await PlayerTestHarness.settle(1);
    expect(gates, hasLength(cap), reason: 'no new build while the cap is held');

    // One abandoned build settles, which frees one slot.
    gates.first.completeError(StateError('network gave up'));
    await PlayerTestHarness.settle(1);
    await manager.preload(
      sources.skip(cap).toList(),
      configuration: PlayerTestHarness.configuration(),
      strategy: FastPixPreloadStrategy.player,
      window: cap,
    );
    await PlayerTestHarness.settle(1);
    expect(gates, hasLength(cap + 1));
  });
}
