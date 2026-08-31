import 'dart:async';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// A warmer that records what it was asked to warm instead of doing it.
///
/// The network path is fully testable this way; the player path is not,
/// because `BetterPlayerController` hits method channels — so those tests
/// cover the bookkeeping around it via the injectable factory.
class _FakeWarmer implements FastPixManifestWarmer {
  _FakeWarmer({this.onWarm});

  final Future<void> Function(String url)? onWarm;
  final List<String> warmed = <String>[];
  bool closed = false;

  @override
  Future<void> warm(
    String manifestUrl, {
    Map<String, String>? headers,
    FastPixWarmDepth depth = FastPixWarmDepth.master,
    int segmentCount = 2,
  }) async {
    warmed.add(manifestUrl);
    if (onWarm != null) await onWarm!(manifestUrl);
  }

  @override
  bool get isClosed => closed;

  @override
  void close() => closed = true;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final manager = FastPixPreloadManager.instance;

  FastPixPlayerDataSource source(
    String id, {
    StreamType streamType = StreamType.onDemand,
  }) => FastPixPlayerDataSource(
    playbackId: id,
    format: FastPixStreamingFormat.hls,
    streamType: streamType,
  );

  FastPixPlayerConfiguration config() =>
      FastPixPlayerConfiguration('ws', 'viewer', 'https://beacon.example');

  late _FakeWarmer warmer;
  late List<FastPixPlayerEvent> events;

  setUp(() {
    warmer = _FakeWarmer();
    manager.warmer = warmer;
    manager.isCastActive = null;
    manager.warmedPlayerFactory = null;

    events = <FastPixPlayerEvent>[];
    for (final type in FastPixPlayerEventTypes.preload) {
      manager.eventManager.addEventListener(type, events.add);
    }
  });

  // The manager is a singleton, so state leaks between tests without this.
  tearDown(() {
    manager.clearAll();
    manager.isCastActive = null;
    manager.warmedPlayerFactory = null;
    for (final type in FastPixPlayerEventTypes.preload) {
      manager.eventManager.removeAllEventListeners(type);
    }
  });

  List<String> idsOf(String type) => events
      .whereType<FastPixPreloadEvent>()
      .where((event) => event.type == type)
      .map((event) => event.playbackId)
      .toList();

  group('the window is declarative', () {
    test('only the first `window` sources are warmed', () async {
      await manager.preload(
        [source('a'), source('b'), source('c'), source('d'), source('e')],
        configuration: config(),
        window: 2,
      );

      expect(idsOf(FastPixPlayerEventTypes.preloadStarted), ['a', 'b']);
      expect(manager.statusOf('c'), FastPixPreloadStatus.queued);
    });

    // Re-warming a survivor is a defect, not a cost: it spends bandwidth on
    // work already done and, under the player strategy, churns a decoder.
    test('a shifted window cancels departures and leaves survivors alone', () async {
      await manager.preload([source('a'), source('b')],
          configuration: config(), window: 2);
      events.clear();
      warmer.warmed.clear();

      await manager.preload([source('b'), source('c')],
          configuration: config(), window: 2);

      expect(idsOf(FastPixPlayerEventTypes.preloadCancelled), ['a']);
      expect(idsOf(FastPixPlayerEventTypes.preloadStarted), ['c']);
      expect(warmer.warmed.length, 1, reason: 'b must not be re-warmed');
    });

    test('calling twice with the same list is a no-op', () async {
      final upcoming = [source('a'), source('b')];
      await manager.preload(upcoming, configuration: config(), window: 2);
      events.clear();

      await manager.preload(upcoming, configuration: config(), window: 2);

      expect(events, isEmpty);
    });

    test('duplicate sources in the list are warmed once', () async {
      await manager.preload([source('a'), source('a'), source('b')],
          configuration: config(), window: 3);

      expect(idsOf(FastPixPlayerEventTypes.preloadStarted), ['a', 'b']);
    });

    test('an empty list releases everything', () async {
      await manager.preload([source('a')], configuration: config());
      events.clear();

      await manager.preload([], configuration: config());

      expect(idsOf(FastPixPlayerEventTypes.preloadCancelled), ['a']);
      expect(manager.isReady('a'), isFalse);
    });
  });

  group('player-strategy guards', () {
    // Exceeding the device decoder cap does not fail the preload — it fails
    // live playback, minutes later and far from the cause.
    test('the window is clamped to maxPlayerWindow', () async {
      manager.warmedPlayerFactory = (_, _) => Completer<Never>().future;

      await manager.preload(
        [source('a'), source('b'), source('c'), source('d'), source('e')],
        configuration: config(),
        strategy: FastPixPreloadStrategy.player,
        window: 5,
      );

      expect(
        idsOf(FastPixPlayerEventTypes.preloadStarted).length,
        FastPixPreloadManager.maxPlayerWindow,
      );
    });

    // A parked live player drifts behind the live edge for as long as it is
    // held, so it is warm in name only.
    test('live sources are skipped under the player strategy', () async {
      manager.warmedPlayerFactory = (_, _) => Completer<Never>().future;

      await manager.preload(
        [source('live', streamType: StreamType.live)],
        configuration: config(),
        strategy: FastPixPreloadStrategy.player,
      );

      expect(events, isEmpty);
    });

    test('live sources are still warmed under the network strategy', () async {
      await manager.preload(
        [source('live', streamType: StreamType.live)],
        configuration: config(),
      );

      expect(idsOf(FastPixPlayerEventTypes.preloadStarted), ['live']);
    });

    // While casting, a locally warmed player spends a decoder on playback
    // that is going to happen on the receiver.
    test('an active Cast session suppresses player warming', () async {
      manager.isCastActive = () => true;
      manager.warmedPlayerFactory = (_, _) => Completer<Never>().future;

      await manager.preload(
        [source('a')],
        configuration: config(),
        strategy: FastPixPreloadStrategy.player,
      );

      expect(events, isEmpty);
    });
  });

  group('adoption', () {
    test('consume returns null for an unknown source', () {
      expect(manager.consume('nope', fingerprint: 'x'), isNull);
    });

    // A network entry warms the CDN path; there is no player to hand over.
    test('consume returns null for a network-strategy entry', () async {
      await manager.preload([source('a')], configuration: config());
      await Future<void>.delayed(Duration.zero);

      expect(manager.isReady('a'), isTrue);
      expect(
        manager.consume(
          'a',
          fingerprint: betterPlayerConfigurationFingerprint(
            configuration: config(),
            dataSource: source('a'),
          ),
        ),
        isNull,
      );
    });

    // Dropping a loading entry would throw away work that may be milliseconds
    // from completing and useful to the next attempt.
    test('consume on a loading entry returns null and keeps the entry', () async {
      final gate = Completer<void>();
      manager.warmer = _FakeWarmer(onWarm: (_) => gate.future);

      await manager.preload([source('a')], configuration: config());

      expect(manager.consume('a', fingerprint: 'x'), isNull);
      expect(manager.statusOf('a'), FastPixPreloadStatus.loading);

      gate.complete();
    });

    // Unlike a loading entry, a fingerprint mismatch can never succeed —
    // adopting it would render permanently wrong, so the entry is dropped.
    test('a fingerprint mismatch drops the entry', () async {
      await manager.preload([source('a')], configuration: config());
      await Future<void>.delayed(Duration.zero);

      expect(manager.consume('a', fingerprint: 'a-different-fingerprint'), isNull);
      expect(manager.isReady('a'), isFalse);
      expect(idsOf(FastPixPlayerEventTypes.preloadCancelled), ['a']);
    });
  });

  group('failures never reach playback', () {
    test('a throwing warmer produces preloadFailed and status failed', () async {
      manager.warmer = _FakeWarmer(
        onWarm: (_) => Future<void>.error(StateError('boom')),
      );

      await manager.preload([source('a')], configuration: config());
      await Future<void>.delayed(Duration.zero);

      expect(idsOf(FastPixPlayerEventTypes.preloadFailed), ['a']);
      expect(manager.statusOf('a'), FastPixPreloadStatus.failed);
      expect(manager.isReady('a'), isFalse);
    });

    test('a failed entry is not reported as cancelled when released', () async {
      manager.warmer = _FakeWarmer(
        onWarm: (_) => Future<void>.error(StateError('boom')),
      );
      await manager.preload([source('a')], configuration: config());
      await Future<void>.delayed(Duration.zero);
      events.clear();

      manager.cancel('a');

      expect(idsOf(FastPixPlayerEventTypes.preloadCancelled), isEmpty);
    });
  });

  group('lifecycle', () {
    test('clearAll empties the window and reports one cancel per entry', () async {
      await manager.preload([source('a'), source('b')],
          configuration: config(), window: 2);
      events.clear();

      manager.clearAll();

      expect(idsOf(FastPixPlayerEventTypes.preloadCancelled), ['a', 'b']);
      expect(manager.statusOf('a'), FastPixPreloadStatus.queued);
    });

    // The manager is a singleton, so a dispose that left it dead would break
    // the next playback session in the same process.
    test('dispose leaves the manager usable', () async {
      await manager.preload([source('a')], configuration: config());
      manager.dispose();

      expect(warmer.closed, isTrue, reason: 'dispose must close the pool');
      expect(manager.statusOf('a'), FastPixPreloadStatus.queued);

      // A fresh warmer, because the one from setUp already recorded 'a'.
      final revived = _FakeWarmer();
      manager.warmer = revived;
      await manager.preload([source('b')], configuration: config());

      expect(revived.warmed.length, 1);
    });

    test('warming sends the same headers playback will use', () async {
      await manager.preload([source('a')], configuration: config());

      expect(warmer.warmed.single, contains('a'));
    });
  });
}
