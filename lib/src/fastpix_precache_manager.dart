import 'dart:async';
import 'dart:io';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'enums/fastpix_precache_status.dart';
import 'models/fastpix_player_data_source.dart';
import 'models/fastpix_player_event.dart';
import 'models/fastpix_precache_event.dart';
import 'utils/fastpix_warm_log.dart';

/// Downloads one file into the platform cache. Injectable so the manager's
/// bookkeeping is testable without a platform channel.
typedef FastPixCacheWriter =
    Future<int> Function(BetterPlayerDataSource source);

/// Caches an HLS **master playlist** to disk, in the cache the player reads
/// from, so a later session starts one round trip closer to the first frame.
///
/// ## Why only the master playlist
///
/// Because it is the only file whose URL is stable, and a cache is worthless
/// unless the reader looks up the key the writer wrote.
///
/// media3 keys HLS cache entries by URI. Measured against FastPix, resolving
/// the same playback ID twice five seconds apart returns:
///
/// ```
/// fetch 1:  .../<BLOB-A>/video_270/1.m4s?expires=1790268189&signature=PQP…
/// fetch 2:  .../<BLOB-B>/video_270/1.m4s?expires=1790268194&signature=t99…
///            ^ rotates                     ^ rotates        ^ rotates
/// ```
///
/// Only `video_270/1.m4s` survives. Both the signed path prefix and the query
/// are regenerated on **every** manifest resolution, and playback re-resolves
/// on every start — so a precached segment can never be found again. Not
/// "usually misses": the key cannot match, ever. Caching segments would fill
/// the viewer's disk with bytes nothing will ever read, reporting success
/// throughout.
///
/// The master playlist is different — *conditionally*. Its URL is
/// `https://stream.fastpix.com/{playbackId}.m3u8`, so for an unsigned source
/// the path is the playback ID and the default URI key is already a stable
/// per-asset key.
///
/// ## The limit, stated plainly
///
/// For a **signed** source the URL carries `?token=<JWT>`, and media3 keys HLS
/// entries by the whole request URI. So a precache hits only when the URL is
/// byte-identical between the warm and playback. Re-resolve the playback token
/// in between and the warm is written under one key and read under another —
/// a silent miss, no error, and a log that still says "cached".
///
/// There is no way around this from here. The override that would fix it,
/// `BetterPlayerCacheConfiguration.key`, becomes `MediaItem.customCacheKey`,
/// which media3 honours for *progressive* sources only — `HlsMediaSource`
/// ignores it. Keying HLS by playback ID needs a custom `CacheKeyFactory`,
/// which means changing the engine rather than sitting beside it.
///
/// So: precaching pays off for sources whose URL is stable across sessions.
/// For sources whose token rotates per resolution, expect it to do nothing,
/// and prefer `FastPixPreloadManager` — which keys by playback ID in Dart and
/// is unaffected.
///
/// ## Is one playlist worth caching
///
/// It was measured to be. A production player that dropped its
/// master-playlist disk warm saw that fetch regress from **50–266 ms to
/// 1,073–1,264 ms**. It is small, it is first, and nothing else on the
/// critical path can start until it lands.
///
/// ## What it is not
///
/// Not segment precaching, and not offline playback. It removes one round trip
/// from a cold start; the media still streams.
///
/// Pair it with `FastPixPreloadManager` rather than instead of it — preloading
/// warms memory for the next tap and dies with the process, this survives a
/// restart. They share no state.
class FastPixPrecacheManager {
  FastPixPrecacheManager._();

  static final FastPixPrecacheManager instance = FastPixPrecacheManager._();

  static const MethodChannel _channel =
      MethodChannel('fastpix_video_player/precache');

  /// Byte ceiling for the request.
  ///
  /// A ceiling, not a target: the engine stops at end-of-file and a master
  /// playlist is a few KB. Generous enough for a long variant list, small
  /// enough that a misconfiguration cannot pull down a whole video.
  static const int manifestByteCeiling = 512 * 1024;

  final Map<String, FastPixPrecacheStatus> _statuses =
      <String, FastPixPrecacheStatus>{};

  /// Requests accepted but not yet finished writing.
  final Set<String> _inFlight = <String>{};

  final Map<String, int> _bytesWritten = <String, int>{};

  final FastPixPlayerEventManager _eventManager = FastPixPlayerEventManager();

  /// Precache lifecycle events. Separate from the playback error channel: a
  /// manifest that failed to cache is not a playback failure.
  FastPixPlayerEventManager get eventManager => _eventManager;

  /// Overridable for tests. See [FastPixCacheWriter].
  @visibleForTesting
  FastPixCacheWriter? cacheWriter;

  /// Overridable for tests, since the platform gate is otherwise untestable.
  @visibleForTesting
  bool? platformSupportedOverride;

  /// Android only, and the limit is the engine's, not a choice made here.
  ///
  /// iOS precaching is implemented with `CachingPlayerItem`, a single-file
  /// downloader, so `CacheManager.isPreCacheSupported` excludes
  /// `application/vnd.apple.mpegurl` outright — a playlist is not one file, it
  /// is a list of them. A `preCache` call for an `.m3u8` is therefore dropped
  /// by the plugin with a log line and no error, which is why this refuses up
  /// front rather than reporting a success that wrote nothing.
  ///
  /// Not to be confused with iOS *playback* caching of HLS, which does exist:
  /// the engine routes m3u8 playback through an `HLSCachingReverseProxyServer`
  /// on localhost. That is a separate mechanism, it only runs during playback,
  /// and it cannot be primed ahead of time — so it is no help here.
  bool get _platformSupported =>
      platformSupportedOverride ?? (Platform.isAndroid || Platform.isIOS);

  /// Whether this platform caches through the iOS segment cache rather than
  /// media3.
  bool get _usesSegmentCache =>
      platformSupportedOverride == null && Platform.isIOS;

  /// Cache [source]'s master playlist.
  ///
  /// Best effort: never throws, and every failure resolves to playback
  /// fetching the manifest from the network exactly as it does today. Returns
  /// the resulting status rather than signalling by exception.
  ///
  /// Safe to call repeatedly — a request already dispatching for the same
  /// [FastPixPlayerDataSource.playbackId] is coalesced.
  Future<FastPixPrecacheStatus> precacheManifest(
    FastPixPlayerDataSource source,
  ) async {
    final key = source.playbackId;

    final refusal = _refusalFor(source);
    if (refusal != null) {
      _statuses[key] = FastPixPrecacheStatus.unsupported;
      FastPixWarmLog.precache('UNSUPPORTED — $refusal', playbackId: key);
      _emitFailure(key, FastPixPrecacheStatus.unsupported, refusal);
      return FastPixPrecacheStatus.unsupported;
    }

    if (_inFlight.contains(key) ||
        _statuses[key] == FastPixPrecacheStatus.cached) {
      FastPixWarmLog.precache(
        'already cached or in flight — request coalesced',
        playbackId: key,
      );
      return FastPixPrecacheStatus.cached;
    }
    _inFlight.add(key);

    FastPixWarmLog.precache(
      _usesSegmentCache
          ? 'caching playlists and opening segments from ${source.url}'
          : 'writing master playlist to disk from ${source.url}',
      playbackId: key,
    );

    _emit(
      FastPixPrecacheStartedEvent(timestamp: DateTime.now(), playbackId: key),
    );

    try {
      final int bytesWritten;
      if (cacheWriter != null) {
        bytesWritten = await cacheWriter!(_manifestDataSource(source));
      } else if (_usesSegmentCache) {
        bytesWritten = await _writeToSegmentCache(source);
      } else {
        bytesWritten = await _writeToPlatformCache(_manifestDataSource(source));
      }

      // Zero bytes is a failure, however cheerfully the platform reports it.
      // This is the exact trap better_player's own preCache falls into — it
      // returns success whether or not anything was enqueued — and it is why a
      // broken cache can look healthy for months.
      if (bytesWritten <= 0) {
        _statuses[key] = FastPixPrecacheStatus.failed;
        FastPixWarmLog.precache(
          'FAILED — the platform reported success but wrote 0 bytes',
          playbackId: key,
        );
        _emitFailure(
          key,
          FastPixPrecacheStatus.failed,
          'the platform reported success but wrote 0 bytes — the response was '
          'fetched and then not stored',
        );
        return FastPixPrecacheStatus.failed;
      }

      _statuses[key] = FastPixPrecacheStatus.cached;
      _bytesWritten[key] = bytesWritten;
      // The byte count is the honest signal — a "cached" that wrote nothing is
      // the failure this whole implementation exists to make visible.
      // The caveat differs by platform, and printing the wrong one is worse
      // than printing none: on iOS entries are keyed by playbackId and survive
      // a token refresh, which is exactly what media3 cannot do.
      FastPixWarmLog.precache(
        _usesSegmentCache
            ? 'CACHED $bytesWritten bytes to disk — keyed by playbackId, so a '
                  'rotated ?token= still hits'
            : 'CACHED $bytesWritten bytes to disk — playback will read this '
                  'only if it requests the identical URL (media3 keys HLS by '
                  'URI, so a rotated ?token= will miss)',
        playbackId: key,
      );
      _emit(
        FastPixPrecacheCachedEvent(
          timestamp: DateTime.now(),
          playbackId: key,
          bytesWritten: bytesWritten,
        ),
      );
      return FastPixPrecacheStatus.cached;
    } catch (error) {
      _statuses[key] = FastPixPrecacheStatus.failed;
      FastPixWarmLog.precache(
        'FAILED — playback is unaffected and will fetch the manifest from the '
        'network: $error',
        playbackId: key,
      );
      _emitFailure(key, FastPixPrecacheStatus.failed, error.toString());
      return FastPixPrecacheStatus.failed;
    } finally {
      _inFlight.remove(key);
    }
  }

  /// Cache several manifests, one after another.
  ///
  /// Sequential on purpose: these run alongside playback, and parallel
  /// requests would compete for bandwidth with the video being watched.
  Future<void> precacheAll(Iterable<FastPixPlayerDataSource> sources) async {
    for (final source in sources) {
      await precacheManifest(source);
    }
  }

  /// Why [source] cannot be precached, or null when it can.
  String? _refusalFor(FastPixPlayerDataSource source) {
    if (!_platformSupported) {
      return 'precaching is not implemented on this platform';
    }
    // iOS caches through our own resource loader, and an AVURLAsset has exactly
    // one delegate slot — FairPlay owns it on protected content. Taking it for
    // caching is what produces CoreMediaError -12642, so DRM sources keep their
    // plain https:// URL and are refused here.
    if (_usesSegmentCache && source.drmEnabled) {
      return 'iOS caching needs the asset\'s resource-loader delegate, which '
          'FairPlay already owns on protected content — taking it produces '
          'CoreMediaError -12642 and breaks playback';
    }
    if (source.streamType == StreamType.live) {
      return 'a live playlist is rewritten continuously, so a cached copy is '
          'stale on arrival';
    }
    if (!source.cacheEnabled) {
      return 'the data source sets cacheEnabled: false';
    }
    return null;
  }

  /// The master playlist, in the shape the engine's `preCache` expects.
  ///
  /// URL and headers come from the playback source so both sides agree: the
  /// engine keys by URI, so a manifest written under any other URL is never
  /// found, and a CDN varying on headers would cache a different entry.
  ///
  /// `maxCacheSize` is copied for a subtler reason — `BetterPlayerCache
  /// .createCache` is a singleton keyed on first use, so a differing size can
  /// hand back a *different* `SimpleCache` instance and the writer would
  /// populate a cache the reader never opens.
  ///
  /// No cache key is set, and that is not an omission — it is the only option.
  /// media3 derives the key from the request URI for HLS, and the one override
  /// that exists (`BetterPlayerCacheConfiguration.key`) is applied to
  /// progressive sources only, so setting it here would make the writer key by
  /// playback ID while the reader still keys by URI. That would turn a partial
  /// hit into a guaranteed miss.
  ///
  /// The consequence is that this only pays off while the URL is stable —
  /// see the class docs for what that means for signed sources.
  BetterPlayerDataSource _manifestDataSource(FastPixPlayerDataSource source) {
    final playbackSource = source.toBetterPlayerDataSource();
    return BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      playbackSource.url,
      headers: playbackSource.headers,
      videoFormat: playbackSource.videoFormat,
      cacheConfiguration: BetterPlayerCacheConfiguration(
        useCache: true,
        maxCacheSize:
            playbackSource.cacheConfiguration?.maxCacheSize ??
            100 * 1024 * 1024,
        preCacheSize: manifestByteCeiling,
      ),
    );
  }

  /// Writes the playlist into the player's cache, via this package's own
  /// native channel.
  ///
  /// **Not** `BetterPlayerController.preCache`. That path was tried first and
  /// cannot work here, for two reasons found on device:
  ///
  /// * It enqueues a `WorkManager` job, a batching scheduler that commonly runs
  ///   minutes later. Half the value of warming a playlist is the hot
  ///   connection it leaves moments before playback; a deferred job delivers
  ///   none of it.
  /// * It builds a *bounded* `DataSpec(uri, 0, preCacheSize)`. A playlist is a
  ///   few KB and is served with no `Content-Length`, so a request bounded at
  ///   the configured ceiling is never satisfied and nothing is committed —
  ///   while the job still reports success, because the engine's
  ///   `result.success(null)` sits outside the guard that decides whether
  ///   anything was enqueued.
  ///
  /// The native side runs immediately and reads to end-of-stream instead.
  ///
  /// Throws when the platform reports a real failure, and returns the number of
  /// bytes written otherwise — zero bytes is treated as a failure by the
  /// caller, since a write that stored nothing is not a success.
  Future<int> _writeToPlatformCache(BetterPlayerDataSource source) async {
    final written = await _channel.invokeMethod<int>('warmManifest', {
      'url': source.url,
      'headers': source.headers ?? <String, String>{},
      'maxCacheSize': source.cacheConfiguration?.maxCacheSize,
      'maxCacheFileSize': source.cacheConfiguration?.maxCacheFileSize,
    });
    return written ?? 0;
  }

  /// Cache [source] through the iOS segment cache.
  ///
  /// Unlike Android's single-file warm this walks master → variant → the
  /// opening segments, so it returns only once bytes have actually landed. The
  /// native side reports no completion, so the byte count is polled — a warm
  /// that wrote nothing must be reported as a failure rather than a silent
  /// success.
  Future<int> _writeToSegmentCache(FastPixPlayerDataSource source) async {
    // Without the AVURLAsset hook the cache can never be read back, so caching
    // into it would be work with no possible payoff.
    final ready =
        await _channel.invokeMethod<bool>('isSegmentCacheReady') ?? false;
    if (!ready) {
      throw StateError(
        'the AVURLAsset hook is not installed, so cached bytes could never be '
        'read back by playback',
      );
    }

    await _channel.invokeMethod<void>('precacheStart', {'url': source.url});

    // Poll until the byte count settles or the budget runs out.
    var bytes = 0;
    var stable = 0;
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final current = await _channel.invokeMethod<int>(
            'precachedBytes',
            {'key': source.playbackId},
          ) ??
          0;
      // Two consecutive identical readings with bytes on disk means the
      // downloads have finished; waiting the full budget every time would make
      // a UI that calls this feel broken.
      if (current > 0 && current == bytes) {
        if (++stable >= 2) break;
      } else {
        stable = 0;
      }
      bytes = current;
    }
    return bytes;
  }

  /// Cancel a queued request for [source].
  Future<void> stop(FastPixPlayerDataSource source) async {
    if (!_platformSupported) return;
    if (_usesSegmentCache) {
      try {
        await _channel.invokeMethod<void>('precacheStop', {'url': source.url});
      } catch (_) {
        // Stopping something that was never started is not an error.
      }
      _statuses.remove(source.playbackId);
      return;
    }
    final controller = BetterPlayerController(
      const BetterPlayerConfiguration(autoDispose: false),
    );
    try {
      await controller.stopPreCache(_manifestDataSource(source));
    } catch (_) {
      // Stopping something that was never started is not an error.
    } finally {
      controller.dispose(forceDispose: true);
    }
    _statuses.remove(source.playbackId);
  }

  /// What happened for [playbackId] in this process.
  ///
  /// [FastPixPrecacheStatus.cached] means bytes were genuinely committed — the
  /// native side returns the count and zero is treated as a failure. It is
  /// still not a live cache probe: eviction is LRU and engine-controlled, so an
  /// entry cached earlier may since have been dropped.
  FastPixPrecacheStatus statusOf(String playbackId) =>
      _statuses[playbackId] ?? FastPixPrecacheStatus.idle;

  /// Forget all bookkeeping. Does not evict anything from the platform cache.
  void clearStatuses() {
    _statuses.clear();
    _bytesWritten.clear();
    _inFlight.clear();
  }

  /// Bytes committed for [playbackId], or 0. The honest measure of whether
  /// this did anything.
  int bytesWrittenFor(String playbackId) => _bytesWritten[playbackId] ?? 0;

  void _emitFailure(
    String playbackId,
    FastPixPrecacheStatus status,
    String reason,
  ) => _emit(
    FastPixPrecacheFailedEvent(
      timestamp: DateTime.now(),
      playbackId: playbackId,
      status: status,
      reason: reason,
    ),
  );

  void _emit(FastPixPlayerEvent event) => _eventManager.emit(event);
}
