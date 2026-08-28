import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// Precaching writes the HLS **master playlist** into the cache the player
/// reads from.
///
/// Only the master, and that limit is the whole design. media3 keys HLS cache
/// entries by URI, and measured against FastPix only the master URL is stable
/// — segment URLs regenerate their signed path prefix *and* their query on
/// every manifest resolution, so a precached segment can never be matched
/// again. Caching them would fill the viewer's disk with unreadable bytes
/// while reporting success throughout.
///
/// Two properties matter more than any other here, and both fail silently in
/// production: it must never affect playback, and the URL it writes must be
/// byte-identical to the one playback requests.
void main() {
  final manager = FastPixPrecacheManager.instance;

  FastPixPlayerDataSource source(
    String id, {
    StreamType streamType = StreamType.onDemand,
    bool cacheEnabled = true,
    FastPixPlayerDrmConfiguration? drm,
  }) => FastPixPlayerDataSource(
    playbackId: id,
    format: FastPixStreamingFormat.hls,
    streamType: streamType,
    cacheEnabled: cacheEnabled,
    token: drm == null ? null : 'playback-token',
    drmConfiguration: drm,
  );

  late List<FastPixPlayerEvent> events;
  late List<BetterPlayerDataSource> written;

  setUp(() {
    written = <BetterPlayerDataSource>[];
    // Android is the only platform where cached HLS bytes are ever read back.
    manager.platformSupportedOverride = true;
    manager.cacheWriter = (source) async {
      written.add(source);
      return 3128; // a real master playlist is a few KB
    };
    manager.clearStatuses();

    events = <FastPixPlayerEvent>[];
    for (final type in FastPixPlayerEventTypes.precache) {
      manager.eventManager.addEventListener(type, events.add);
    }
  });

  // Singleton: state leaks between tests without this.
  tearDown(() {
    manager.clearStatuses();
    manager.cacheWriter = null;
    manager.platformSupportedOverride = null;
    for (final type in FastPixPlayerEventTypes.precache) {
      manager.eventManager.removeAllEventListeners(type);
    }
  });

  List<String> reasons() => events
      .whereType<FastPixPrecacheFailedEvent>()
      .map((event) => event.reason)
      .toList();

  group('exactly one file is cached, and it is the master playlist', () {
    test('a successful request writes the master and nothing else', () async {
      final status = await manager.precacheManifest(source('abc123'));

      expect(status, FastPixPrecacheStatus.cached);
      expect(written, hasLength(1));
      expect(Uri.parse(written.single.url).path, '/abc123.m3u8');
    });

    // The master URL's path IS the playback ID, so media3's default
    // URI-derived key is already a stable per-asset key. That is the entire
    // reason this works where segment caching cannot.
    test('the cached URL is byte-identical to the playback URL', () async {
      final ds = source('abc123');
      await manager.precacheManifest(ds);

      expect(written.single.url, ds.url);
      expect(written.single.url, ds.toBetterPlayerDataSource().url);
    });

    // A CDN varying on headers would cache a different entry than the one
    // playback later asks for.
    test('headers match what playback sends', () async {
      final ds = source('abc123');
      await manager.precacheManifest(ds);

      expect(written.single.headers, ds.toBetterPlayerDataSource().headers);
    });

    // BetterPlayerCache.createCache is a singleton keyed on first use, so a
    // differing size hands back a different SimpleCache — the writer would
    // populate a cache the reader never opens.
    test('cache size matches playback, and the ceiling is playlist-sized',
        () async {
      final ds = source('abc123');
      await manager.precacheManifest(ds);

      final config = written.single.cacheConfiguration!;
      expect(config.useCache, isTrue);
      expect(
        config.maxCacheSize,
        ds.toBetterPlayerDataSource().cacheConfiguration?.maxCacheSize,
      );
      expect(
        config.preCacheSize,
        FastPixPrecacheManager.manifestByteCeiling,
      );
    });

    // Setting one would produce a cache that fills disk and is never read,
    // because playback looks up the default URI-derived key.
    test('no custom cache key is set', () async {
      await manager.precacheManifest(source('abc123'));
      expect(written.single.cacheConfiguration?.key, isNull);
    });
  });

  group('sources whose cached bytes would never be read are refused', () {
    // Each of these would otherwise consume the viewer's storage for bytes
    // nothing can read — the worst failure this feature has, because it looks
    // like success throughout.


    // DRM is NOT refused on Android. media3 keeps DrmSessionManager and
    // CacheDataSource orthogonal, and cached segments stay encrypted on disk —
    // the licence is fetched fresh at playback and decrypts them then. Only
    // *offline* playback needs a persistent licence.
    //
    // iOS is a different story, but it is already excluded by the platform
    // gate: caching and FairPlay both need the asset's single
    // AVAssetResourceLoader delegate.
    test('DRM is cached on Android, not refused', () async {
      final status = await manager.precacheManifest(
        source('drm',
            drm: const FastPixPlayerDrmConfiguration(drmToken: 'token')),
      );

      expect(status, FastPixPrecacheStatus.cached);
      expect(written, hasLength(1));
      expect(reasons(), isEmpty);
    });

    test('live is refused — the playlist is rewritten continuously', () async {
      final status = await manager.precacheManifest(
        source('live', streamType: StreamType.live),
      );

      expect(status, FastPixPrecacheStatus.unsupported);
      expect(written, isEmpty);
      expect(reasons().single, contains('live'));
    });

    test('cacheEnabled: false is honoured', () async {
      final status = await manager.precacheManifest(
        source('opted-out', cacheEnabled: false),
      );

      expect(status, FastPixPrecacheStatus.unsupported);
      expect(written, isEmpty);
    });

    // A platform with no implementation at all — neither media3 nor the iOS
    // segment cache. The reason must say so plainly, because "unsupported" on
    // its own reads as a bug to be retried rather than a boundary.
    test('an unsupported platform is refused', () async {
      manager.platformSupportedOverride = false;

      final status = await manager.precacheManifest(source('ios'));

      expect(status, FastPixPrecacheStatus.unsupported);
      expect(written, isEmpty);
      expect(reasons().single, contains('not implemented on this platform'));
    });

    // Unsupported is a design boundary, not a fault: it must not be retried
    // or alerted on the way a failure would be.
    test('unsupported is reported as unsupported, never as failed', () async {
      await manager.precacheManifest(source('live', streamType: StreamType.live));

      expect(
        events.whereType<FastPixPrecacheFailedEvent>().single.status,
        FastPixPrecacheStatus.unsupported,
      );
      expect(manager.statusOf('live'), FastPixPrecacheStatus.unsupported);
    });
  });

  group('failures never reach playback', () {
    // The caller is a fire-and-forget call alongside playback; an unhandled
    // error would surface as a crash for an optimisation nobody blocks on.
    test('a throwing cache writer never throws out', () async {
      manager.cacheWriter = (_) => Future<int>.error(StateError('disk full'));

      final status = await manager.precacheManifest(source('abc123'));

      expect(status, FastPixPrecacheStatus.failed);
      expect(manager.statusOf('abc123'), FastPixPrecacheStatus.failed);
      final event = events.whereType<FastPixPrecacheFailedEvent>().single;
      expect(event.status, FastPixPrecacheStatus.failed);
      expect(event.reason, contains('disk full'));
    });

    test('a duplicate request while dispatching is coalesced', () async {
      final gate = Completer<void>();
      manager.cacheWriter = (source) async {
        written.add(source);
        await gate.future;
        return 3128;
      };

      final first = manager.precacheManifest(source('abc123'));
      final second = await manager.precacheManifest(source('abc123'));

      expect(second, FastPixPrecacheStatus.cached);
      expect(written, hasLength(1), reason: 'the second must not dispatch');

      gate.complete();
      expect(await first, FastPixPrecacheStatus.cached);
    });

    // The trap this whole native rewrite exists to close: better_player's own
    // preCache reports success whether or not anything was enqueued, so a
    // cache that never works looks healthy indefinitely.
    test('a write that stores zero bytes is a failure, not a success',
        () async {
      manager.cacheWriter = (source) async {
        written.add(source);
        return 0;
      };

      final status = await manager.precacheManifest(source('abc123'));

      expect(status, FastPixPrecacheStatus.failed);
      expect(manager.statusOf('abc123'), FastPixPrecacheStatus.failed);
      expect(reasons().single, contains('0 bytes'));
    });

    test('a successful write records the byte count', () async {
      await manager.precacheManifest(source('abc123'));

      expect(manager.bytesWrittenFor('abc123'), 3128);
      expect(
        events.whereType<FastPixPrecacheCachedEvent>().single.bytesWritten,
        3128,
      );
    });

    test('statusOf is idle for anything never requested', () {
      expect(manager.statusOf('never'), FastPixPrecacheStatus.idle);
    });

    test('precacheAll skips ineligible sources without aborting the rest',
        () async {
      await manager.precacheAll(<FastPixPlayerDataSource>[
        source('a'),
        source('live', streamType: StreamType.live),
        source('c'),
      ]);

      expect(manager.statusOf('a'), FastPixPrecacheStatus.cached);
      expect(manager.statusOf('live'), FastPixPrecacheStatus.unsupported);
      expect(manager.statusOf('c'), FastPixPrecacheStatus.cached);
      expect(written, hasLength(2));
    });
  });

  group('it shares no state with preloading', () {
    // Preloading warms memory for the next tap and dies with the process;
    // precaching writes disk for the next session. Coupling them is how one
    // silently breaks the other.
    test('precache status survives clearing the preload window', () async {
      await manager.precacheManifest(source('abc123'));
      FastPixPreloadManager.instance.clearAll();

      expect(manager.statusOf('abc123'), FastPixPrecacheStatus.cached);
    });

    test('precache events are their own family', () {
      for (final type in FastPixPlayerEventTypes.precache) {
        expect(FastPixPlayerEventTypes.preload, isNot(contains(type)));
        expect(FastPixPlayerEventTypes.cast, isNot(contains(type)));
        expect(
          FastPixPlayerEventTypes.all,
          contains(type),
          reason: 'aggregate listeners would otherwise never see it',
        );
      }
    });
  });
}
