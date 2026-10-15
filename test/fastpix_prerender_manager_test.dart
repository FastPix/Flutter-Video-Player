import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/fastpix_prerender_manager.dart';
import 'package:fastpix_video_player/src/utils/fastpix_prerender_channel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

FastPixPrerenderManager get manager => FastPixPrerenderManager.instance;
FastPixPreloadManager get preload => FastPixPreloadManager.instance;

class _FakePlatform implements FastPixPrerenderPlatform {
  bool supported = true;
  bool watchSupported = true;
  final Map<int, FastPixPrerenderRole> roles = <int, FastPixPrerenderRole>{};
  final List<int> watched = <int>[];
  final List<int> stopped = <int>[];
  final Map<int, Duration> positions = <int, Duration>{};
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
    positions[textureId] = position;
    return watchSupported;
  }

  @override
  Future<void> stopWatching(int textureId) async => stopped.add(textureId);

  @override
  Stream<int> get frameReady => frames.stream;

  @override
  Stream<int> get seekFailed => seeks.stream;
}

class _FakeOwner implements FastPixPrerenderOwner {
  @override
  FastPixPlayerPrerenderConfiguration prerenderConfiguration =
      const FastPixPlayerPrerenderConfiguration();

  @override
  FastPixPlayerConfiguration? prerenderPlayerConfiguration =
      PlayerTestHarness.configuration();

  @override
  String? prerenderActivePlaybackId = 'active';

  @override
  bool prerenderSurfaceAvailable = true;

  @override
  bool prerenderPipActive = false;

  @override
  bool prerenderExternalPlayback = false;

  @override
  double prerenderPlaybackRate = 1;

  final Map<String, int> indexes = <String, int>{};
  final List<FastPixPlayerEvent> events = <FastPixPlayerEvent>[];
  BetterPlayerController? hidden;

  @override
  int? prerenderPlaylistIndexOf(String playbackId) => indexes[playbackId];

  @override
  void emitPrerenderEvent(FastPixPlayerEvent event) => events.add(event);

  @override
  void onPrerenderEngineChanged(BetterPlayerController? engine) =>
      hidden = engine;

  List<String> get types => events.map((e) => e.type).toList();

  T last<T>() => events.whereType<T>().last;
}

/// Let the fake platform build a player: settle until more than [created]
/// exist, for at most 40 turns.
Future<void> _settleUntilBuilt(int created) async {
  final engines = PlayerTestHarness.platform;
  for (var i = 0; i < 40 && engines.created.length == created; i++) {
    await PlayerTestHarness.settle(1);
  }
}

/// Tasks 6.1 - 6.7: the prerender manager.
void main() {
  PlayerTestHarness.install();
  final engines = PlayerTestHarness.platform;

  late _FakePlatform native;
  late _FakeOwner owner;

  setUp(() {
    native = _FakePlatform();
    owner = _FakeOwner();
    manager
      ..platform = native
      ..isForegroundOverride = (() => true)
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
    // Before the harness uninstalls the fake platform, so the engine's
    // asynchronous dispose of any warm player still reaches it.
    preload.clearAll();
    preload.debugForgetPlayerBuilds();
    await PlayerTestHarness.settle();
  });

  FastPixPlayerDataSource source(String id) => PlayerTestHarness.source(id);

  /// Start a request for [id] and bring its warm player up.
  Future<Future<FastPixPrerenderResult>> start(
    String id, {
    _FakeOwner? by,
    bool automatic = true,
  }) async {
    final created = engines.created.length;
    final result = manager.request(by ?? owner, source(id), automatic: automatic);
    await _settleUntilBuilt(created);
    expect(engines.created.length, created + 1, reason: 'warm player built');
    await engines.emitInitialized(engines.created.last);
    await PlayerTestHarness.settle();
    return result;
  }

  /// Bring [id] to frame-ready.
  Future<FastPixPrerenderResult> ready(String id, {_FakeOwner? by}) async {
    final pending = await start(id, by: by);
    native.frames.add(engines.created.last);
    final result = await pending;
    expect(result.status, FastPixPrerenderStatus.frameReady);
    return result;
  }

  group('state machine (6.1)', () {
    test('unknown playbackId is idle', () {
      expect(manager.statusOf(owner, 'never'), FastPixPrerenderStatus.idle);
    });

    test('preparing, then frameReady on the platform signal', () async {
      final pending = await start('next');
      final textureId = engines.created.last;

      expect(manager.statusOf(owner, 'next'), FastPixPrerenderStatus.preparing);
      expect(owner.hidden, isNotNull, reason: 'mounted in the hidden slot');
      expect(native.roles[textureId], FastPixPrerenderRole.prerender);
      expect(native.watched, [textureId]);

      native.frames.add(textureId);
      expect((await pending).status, FastPixPrerenderStatus.frameReady);
      expect(manager.statusOf(owner, 'next'), FastPixPrerenderStatus.frameReady);
      expect(owner.types, [
        FastPixPlayerEventTypes.prerenderRequested,
        FastPixPlayerEventTypes.prerenderReady,
      ]);
      expect(owner.last<FastPixPrerenderRequestedEvent>().automatic, isTrue);
    });

    test('the start position is handed to the native seek', () async {
      final pending = manager.request(
        owner,
        FastPixPlayerDataSource.hls(
          playbackId: 'later',
          startAt: const Duration(seconds: 42),
        ),
      );
      await _settleUntilBuilt(0);
      await engines.emitInitialized(engines.created.last);
      await PlayerTestHarness.settle();
      expect(native.positions[engines.created.last], const Duration(seconds: 42));
      native.frames.add(engines.created.last);
      await pending;
    });
  });

  group('admission (6.2)', () {
    final cases = <String, (void Function(_FakeOwner, _FakePlatform),
        FastPixPlayerDataSource, FastPixPrerenderErrorCode)>{
      'disabled': (
        (o, _) => o.prerenderConfiguration =
            const FastPixPlayerPrerenderConfiguration(enablePrerender: false),
        PlayerTestHarness.source('x'),
        FastPixPrerenderErrorCode.disabled,
      ),
      'live': (
        (_, _) {},
        FastPixPlayerDataSource.hls(playbackId: 'x', streamType: StreamType.live),
        FastPixPrerenderErrorCode.live,
      ),
      'drm': (
        (_, _) {},
        FastPixPlayerDataSource.hls(
          playbackId: 'x',
          token: 'token',
          drmConfiguration: const FastPixPlayerDrmConfiguration(
            drmToken: 'drm',
          ),
        ),
        FastPixPrerenderErrorCode.drm,
      ),
      'pip': (
        (o, _) => o.prerenderPipActive = true,
        PlayerTestHarness.source('x'),
        FastPixPrerenderErrorCode.pip,
      ),
      'externalPlayback': (
        (o, _) => o.prerenderExternalPlayback = true,
        PlayerTestHarness.source('x'),
        FastPixPrerenderErrorCode.externalPlayback,
      ),
      'navigationPolicy': (
        (_, _) {},
        PlayerTestHarness.source('active'),
        FastPixPrerenderErrorCode.navigationPolicy,
      ),
      'noSurface': (
        (o, _) => o.prerenderSurfaceAvailable = false,
        PlayerTestHarness.source('x'),
        FastPixPrerenderErrorCode.noSurface,
      ),
      'featureDisabled': (
        (_, p) => p.supported = false,
        PlayerTestHarness.source('x'),
        FastPixPrerenderErrorCode.featureDisabled,
      ),
    };

    for (final entry in cases.entries) {
      test(entry.key, () async {
        final (arrange, src, reason) = entry.value;
        arrange(owner, native);
        final result = await manager.request(owner, src);
        expect(result.status, FastPixPrerenderStatus.skipped);
        expect(result.errorCode, reason);
        final event = owner.events.single as FastPixPrerenderFailedEvent;
        expect(event.code, reason, reason: 'a skip fires the failed event');
        expect(event.playbackId, src.playbackId);
        expect(manager.statusOf(owner, src.playbackId),
            FastPixPrerenderStatus.skipped);
        expect(engines.created, isEmpty, reason: 'nothing built');
      });
    }

    test('background', () async {
      manager.isForegroundOverride = () => false;
      final result = await manager.request(owner, source('x'));
      expect(result.errorCode, FastPixPrerenderErrorCode.background);
    });

    test('decoderBudget: another owner holds the slot', () async {
      final other = _FakeOwner();
      await ready('a', by: other);
      final result = await manager.request(owner, source('b'));
      expect(result.errorCode, FastPixPrerenderErrorCode.decoderBudget);
      expect(manager.statusOf(other, 'a'), FastPixPrerenderStatus.frameReady);
    });

    test('featureDisabled after start keeps the warm player', () async {
      native.watchSupported = false;
      final result = await start('x');
      final outcome = await result;
      expect(outcome.status, FastPixPrerenderStatus.skipped,
          reason: 'skipped, not failed');
      expect(outcome.errorCode, FastPixPrerenderErrorCode.featureDisabled);
      expect(owner.hidden, isNull);
      expect(preload.isReady('x'), isTrue);
      expect(engines.disposed, isEmpty);
      expect(owner.last<FastPixPrerenderFailedEvent>().code,
          FastPixPrerenderErrorCode.featureDisabled);
    });
  });

  group('requests (6.3)', () {
    test('a duplicate request builds nothing and reports the entry', () async {
      final pending = await start('next');
      final created = engines.created.length;

      final again = await manager.request(owner, source('next'));
      expect(again.status, FastPixPrerenderStatus.preparing);
      expect(engines.created.length, created);

      native.frames.add(engines.created.last);
      await pending;
    });

    test('a warm player the window already holds is reused', () async {
      unawaited(preload.preload(
        [source('warm')],
        configuration: PlayerTestHarness.configuration(),
        strategy: FastPixPreloadStrategy.player,
        window: 1,
      ));
      await _settleUntilBuilt(0);
      await engines.emitInitialized(engines.created.last);
      await PlayerTestHarness.settle();

      final pending = manager.request(owner, source('warm'));
      await PlayerTestHarness.settle();
      expect(engines.created, hasLength(1));
      native.frames.add(engines.created.single);
      expect((await pending).status, FastPixPrerenderStatus.frameReady);
    });

    test('the prerender is muted', () async {
      final pending = await start('next');
      final setVolume = engines.calls
          .where((c) => c.method == 'setVolume')
          .map((c) => (c.arguments as Map)['volume']);
      expect(setVolume, contains(0.0));
      native.frames.add(engines.created.last);
      await pending;
    });

    test('loadFailed when the warm player cannot be built', () async {
      preload.warmedPlayerFactory = (_, _) async => throw StateError('HTTP 404');
      addTearDown(() => preload.warmedPlayerFactory = null);
      final result = await manager.request(owner, source('broken'));
      expect(result.status, FastPixPrerenderStatus.failed);
      expect(result.errorCode, FastPixPrerenderErrorCode.loadFailed);
      expect(owner.types.contains(FastPixPlayerEventTypes.error), isFalse);
    });

    test('timedOut when no frame arrives', () async {
      manager.deadlineOverride = const Duration(milliseconds: 200);
      final result = await (await start('slow'));
      expect(result.errorCode, FastPixPrerenderErrorCode.timedOut);
      await PlayerTestHarness.settle();
      expect(engines.alive, isEmpty);
    });

    test('seekFailed when native cannot position it', () async {
      final pending = await start('x');
      native.seeks.add(engines.created.last);
      expect((await pending).errorCode, FastPixPrerenderErrorCode.seekFailed);
    });

    test('surfaceUnavailable when the surface goes while preparing, keeping '
        'the warm player', () async {
      final pending = await start('x');
      manager.surfaceUnavailable(owner);
      expect((await pending).errorCode,
          FastPixPrerenderErrorCode.surfaceUnavailable);
      expect(owner.hidden, isNull);
      expect(preload.isReady('x'), isTrue);
    });
  });

  group('release (6.4)', () {
    final reasons = <String, void Function(_FakeOwner)>{
      'cancelled': (o) => manager.cancel(o, 'next'),
      'memoryPressure': (_) => manager.releaseAll('memoryPressure'),
      'backgrounded': (_) => manager.releaseAll('backgrounded'),
      'disposed': (o) => manager.forget(o),
      'policyChanged': (o) {
        o.prerenderPipActive = true;
        manager.reevaluatePolicy();
      },
    };

    for (final entry in reasons.entries) {
      test(entry.key, () async {
        await ready('next');
        entry.value(owner);
        await PlayerTestHarness.settle();

        expect(engines.disposed, hasLength(1));
        expect(owner.hidden, isNull);
        if (entry.key == 'disposed') {
          // A disposed owner's history goes with it.
          expect(manager.statusOf(owner, 'next'), FastPixPrerenderStatus.idle);
          return;
        }
        expect(manager.statusOf(owner, 'next'), FastPixPrerenderStatus.released);
      });
    }

    test('replaced by the same owner, explicit', () async {
      await ready('a');
      final pending = await start('b', automatic: false);
      expect(manager.statusOf(owner, 'a'), FastPixPrerenderStatus.released);
      native.frames.add(engines.created.last);
      await pending;
    });

    test('cancel with nothing live does nothing', () {
      manager.cancel(owner, 'nothing');
      expect(owner.events, isEmpty);
      expect(manager.statusOf(owner, 'nothing'), FastPixPrerenderStatus.idle);
    });

    test('runtime disable releases with policyChanged', () async {
      await ready('next');
      owner.prerenderConfiguration =
          const FastPixPlayerPrerenderConfiguration(enablePrerender: false);
      manager.reevaluatePolicy();
      expect(manager.statusOf(owner, 'next'), FastPixPrerenderStatus.released);
    });
  });

  group('holding (6.5)', () {
    test('a frameReady prerender is held until something releases it',
        () async {
      await ready('next');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await PlayerTestHarness.settle();

      expect(manager.statusOf(owner, 'next'), FastPixPrerenderStatus.frameReady);
      expect(engines.disposed, isEmpty);
    });
  });

  group('late results (6.6)', () {
    test('a warm that lands after cancel is released', () async {
      final created = engines.created.length;
      final pending = manager.request(owner, source('late'));
      await _settleUntilBuilt(created);
      manager.cancel(owner, 'late');
      expect((await pending).status, FastPixPrerenderStatus.released);

      await engines.emitInitialized(engines.created.last);
      await PlayerTestHarness.settle(10);
      expect(engines.alive, isEmpty);
      expect(owner.hidden, isNull);
      expect(manager.statusOf(owner, 'late'), FastPixPrerenderStatus.released);
    });

    test('a frame signal for a released prerender is ignored', () async {
      final pending = await start('x');
      final textureId = engines.created.last;
      manager.cancel(owner, 'x');
      await pending;
      native.frames.add(textureId);
      await PlayerTestHarness.settle();
      expect(manager.statusOf(owner, 'x'), FastPixPrerenderStatus.released);
    });
  });

  group('claims (6.7)', () {
    test('frameReady claim, then promotion', () async {
      await ready('next');
      final claim = manager.tryClaim(owner, 'next',
          fingerprint: _fingerprint(source('next')));
      expect(claim?.kind, FastPixPrerenderClaimKind.frameReady);

      // A release racing the promotion loses.
      manager.cancel(owner, 'next');
      manager.releaseAll('memoryPressure');

      manager.completeClaim(claim!, startupGap: const Duration(milliseconds: 16));
      await PlayerTestHarness.settle();
      expect(engines.disposed, isEmpty, reason: 'the player is now active');
      expect(manager.statusOf(owner, 'next'), FastPixPrerenderStatus.released);
      claim.engine.dispose(forceDispose: true);
    });

    test('warm claim while preparing', () async {
      final pending = await start('next');
      final claim = manager.tryClaim(owner, 'next',
          fingerprint: _fingerprint(source('next')));
      expect(claim?.kind, FastPixPrerenderClaimKind.warm);
      native.frames.add(engines.created.last);
      expect(await claim!.frame, isTrue);
      manager.completeClaim(claim);
      await pending;
      expect(manager.statusOf(owner, 'next'), FastPixPrerenderStatus.released);
      claim.engine.dispose(forceDispose: true);
    });

    final flips = <String, (void Function(_FakeOwner), String?)>{
      'pip': ((o) => o.prerenderPipActive = true, null),
      'Cast': ((o) => o.prerenderExternalPlayback = true, null),
      'fingerprint': ((_) {}, 'different'),
    };
    for (final flip in flips.entries) {
      test('policy re-checked at claim: ${flip.key}', () async {
        await ready('next');
        final (arrange, fingerprint) = flip.value;
        arrange(owner);
        final claim = manager.tryClaim(owner, 'next',
            fingerprint: fingerprint ?? _fingerprint(source('next')));
        expect(claim, isNull);
        expect(manager.statusOf(owner, 'next'), FastPixPrerenderStatus.released);
      });
    }

    test('another owner cannot claim it', () async {
      await ready('next');
      expect(manager.tryClaim(_FakeOwner(), 'next',
          fingerprint: _fingerprint(source('next'))), isNull);
    });
  });
}

String _fingerprint(FastPixPlayerDataSource source) =>
    betterPlayerConfigurationFingerprint(
      configuration: PlayerTestHarness.configuration(),
      dataSource: source,
    );
