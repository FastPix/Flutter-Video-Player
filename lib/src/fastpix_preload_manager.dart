import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'enums/fastpix_preload_status.dart';
import 'enums/fastpix_preload_strategy.dart';
import 'fastpix_player_configuration.dart';
import 'models/fastpix_player_data_source.dart';
import 'models/fastpix_player_event.dart';
import 'utils/fastpix_network_monitor.dart';
import 'utils/fastpix_drm_log.dart';
import 'utils/fastpix_fairplay_bridge.dart';
import 'utils/fastpix_warm_log.dart';
import 'models/fastpix_preload_event.dart';
import 'utils/fastpix_better_player_configuration.dart';
import 'utils/fastpix_manifest_warmer.dart';

/// Builds and prepares a detached player for [source].
///
/// Injectable so the manager's bookkeeping can be tested without a platform
/// channel; [FastPixPreloadManager] installs the real implementation.
typedef FastPixWarmedPlayerFactory =
    Future<BetterPlayerController> Function(
      FastPixPlayerDataSource source,
      BetterPlayerConfiguration configuration,
    );

/// One upcoming source and whatever has been warmed for it.
class _PreloadEntry {
  _PreloadEntry(this.source, this.strategy, this.fingerprint);

  final FastPixPlayerDataSource source;
  final FastPixPreloadStrategy strategy;

  /// Configuration this entry was warmed for.
  ///
  /// A warmed controller cannot change its configuration later, so it may only
  /// be adopted by a playback that wants the same one.
  final String fingerprint;

  FastPixPreloadStatus status = FastPixPreloadStatus.queued;
  BetterPlayerController? controller;
  DateTime? startedAt;

  /// Set when the entry leaves the window while its warm-up is still in
  /// flight. `setupDataSource` is not cancellable, so the warm-up checks this
  /// after each await and discards whatever it built.
  bool cancelled = false;
}

/// Warms upcoming sources so the next playback starts without paying for the
/// manifest fetch, the DRM licence and decoder setup at the tap.
///
/// ## The contract
///
/// Warming is an **optimisation, never a precondition**. A failed manifest
/// fetch, an exhausted decoder budget, a refused adoption or an entry that
/// simply has not finished all resolve to the same outcome: playback proceeds
/// exactly as it does today. Nothing here can make playback fail or wait.
///
/// ## Declarative, not imperative
///
/// [preload] takes the state of the world rather than a command. The manager
/// diffs it against what it holds and reconciles — cancelling departures,
/// preserving survivors, starting arrivals. That makes it safe to call on
/// every scroll frame, and removes the bug class where a fast-moving user
/// accumulates orphaned warm-ups that starve the decoder budget.
///
/// Everything here lives in memory for the app session.
class FastPixPreloadManager {
  FastPixPreloadManager._();

  static final FastPixPreloadManager instance = FastPixPreloadManager._();

  /// Hard cap on concurrently warmed platform players.
  ///
  /// Platform-specific because the two hold different things.
  ///
  /// Android is capped at 1. A warm there is a whole ExoPlayer — a full
  /// loading pipeline, its buffers, a decoder, and for DRM an open `MediaDrm`
  /// session that the device caps separately. A second warm would compete with
  /// the video already playing for a budget the device genuinely enforces.
  ///
  /// iOS is capped at 3, because a warm is lighter there and a detail page
  /// commonly needs a trailer *and* the feature. A smaller window risks one
  /// extra prewarm evicting the very title about to play.
  ///
  /// Exceeding the device cap does not fail the preload — it fails **live
  /// playback**, minutes later and far from the cause. Requests past the cap
  /// are dropped, not queued.
  static int get maxPlayerWindow => Platform.isAndroid ? 1 : 3;

  /// A warm-up that has not finished by now will not beat the user to the tap,
  /// so it is abandoned and its resources released.
  static const Duration warmTimeout = Duration(seconds: 12);

  /// Insertion-ordered so eviction can reason about arrival order.
  final LinkedHashMap<String, _PreloadEntry> _entries =
      LinkedHashMap<String, _PreloadEntry>();

  final FastPixPlayerEventManager _eventManager = FastPixPlayerEventManager();

  /// Preload lifecycle events. Deliberately separate from the playback error
  /// channel: a warm-up that did not finish is not a playback failure and must
  /// never render as one.
  FastPixPlayerEventManager get eventManager => _eventManager;

  FastPixManifestWarmer _warmer = FastPixManifestWarmer();

  /// How deep [FastPixPreloadStrategy.network] resolves.
  ///
  /// Defaults to master-only because warming is bounded by dwell — the gap
  /// between a warm starting and the user tapping — not by patience. Raise it
  /// only once your own dwell measurements say the budget is there.
  FastPixWarmDepth warmDepth = FastPixManifestWarmer.defaultDepth;

  /// Installed by the host to report a live Cast session.
  ///
  /// While casting, a locally warmed player spends a decoder on playback that
  /// will happen on the receiver. `FastPixCastController` is constructed by
  /// the host rather than being a singleton, so the manager cannot reach it
  /// directly — wire it up with
  /// `FastPixPreloadManager.instance.isCastActive = () => cast.isConnected;`
  bool Function()? isCastActive;

  /// Overridable for tests. See [FastPixWarmedPlayerFactory].
  @visibleForTesting
  FastPixWarmedPlayerFactory? warmedPlayerFactory;

  /// Replace the manifest warmer. For tests.
  @visibleForTesting
  set warmer(FastPixManifestWarmer value) {
    _warmer.close();
    _warmer = value;
  }

  /// Declare what is coming next.
  ///
  /// Idempotent: sources no longer in [upcoming] are cancelled and released,
  /// sources already warm are left untouched, and only genuinely new ones
  /// start work. Re-warming a survivor would be a defect, not a cost.
  ///
  /// [configuration] must be the same one passed to
  /// `FastPixPlayerController.initialize` for these sources, or the warmed
  /// player is refused at adoption time and the work is wasted.
  ///
  /// [window] is how many of [upcoming] are warmed; under
  /// [FastPixPreloadStrategy.player] it is clamped to [maxPlayerWindow].
  ///
  /// [warmDrm] controls whether protected sources are warmed. Defaults to true
  /// because the licence acquisition is the largest single item on the tap
  /// path — but a warm that is never tapped still burns a licence acquisition,
  /// so hosts with issuance quotas or DRM-metric concerns can turn it off.
  Future<void> preload(
    List<FastPixPlayerDataSource> upcoming, {
    FastPixPlayerConfiguration? configuration,
    FastPixPreloadStrategy strategy = FastPixPreloadStrategy.network,
    int window = 3,
    bool warmDrm = true,
  }) async {
    // Started here rather than at construction so an app that never preloads
    // never opens a connectivity listener. Idempotent, and never throws: a
    // platform that will not report leaves every event labelled `unknown`
    // rather than failing the warm-up.
    unawaited(FastPixNetworkMonitor.instance.start());

    final isPlayerStrategy = strategy == FastPixPreloadStrategy.player;
    final effectiveWindow = _effectiveWindow(isPlayerStrategy, window);

    final targets = upcoming.take(effectiveWindow).toList();
    final wanted = targets.map((source) => source.playbackId).toSet();

    FastPixWarmLog.preload(
      'preload() strategy=${strategy.name} requested=${upcoming.length} '
      'window=$window effective=$effectiveWindow warmDrm=$warmDrm',
    );
    // The running licence total, on the line that decides the window. A count
    // is only useful next to the decision that moved it — reading it off
    // scattered per-licence lines means counting them by hand in a log that is
    // mostly codec noise.
    FastPixDrmLog.logSummary();
    if (isPlayerStrategy && window > effectiveWindow) {
      // Silent clamping is how a caller ends up believing five titles are warm
      // when one is.
      FastPixWarmLog.preload(
        'window clamped $window -> $effectiveWindow (device cap on warm '
        'players; the excess is dropped, not queued)',
      );
    }

    // Evict first, so decoders are handed back before new ones are claimed.
    _evictOutside(wanted);

    // A live Cast session means local decoders would be spent on playback
    // that is not going to happen locally.
    final casting = isPlayerStrategy && _isCasting;

    for (final source in targets) {
      if (_entries.containsKey(source.playbackId)) {
        // Not re-warmed. Worth saying, or a repeated preload() looks ignored.
        FastPixWarmLog.preload(
          'already warm, left alone',
          playbackId: source.playbackId,
        );
        continue; // survivor
      }

      if (isPlayerStrategy) {
        final skipReason = _playerWarmSkipReason(
          source,
          casting: casting,
          warmDrm: warmDrm,
        );
        if (skipReason != null) {
          FastPixWarmLog.preload(skipReason, playbackId: source.playbackId);
          continue;
        }
      }

      final entry = _PreloadEntry(
        source,
        strategy,
        betterPlayerConfigurationFingerprint(
          configuration: configuration,
          dataSource: source,
        ),
      );
      _entries[source.playbackId] = entry;
      unawaited(_warm(entry, configuration));
    }
  }

  /// How many of the requested sources are actually warmed.
  ///
  /// A player warm is capped by the device's decoder budget, because exceeding
  /// it fails live playback rather than the preload; a network warm only has
  /// to be non-negative.
  static int _effectiveWindow(bool isPlayerStrategy, int window) {
    if (isPlayerStrategy) return window.clamp(0, maxPlayerWindow);
    return window < 0 ? 0 : window;
  }

  /// Release every entry that is no longer in [wanted].
  void _evictOutside(Set<String> wanted) {
    for (final key in _entries.keys.toList()) {
      if (!wanted.contains(key)) _release(key, cancelled: true);
    }
  }

  /// Whether the host reports a live Cast session. False when it never wired
  /// [isCastActive] up, which is the same answer as "not casting".
  bool get _isCasting => isCastActive?.call() ?? false;

  /// Why [source] must not get a warmed player, or null when it may have one.
  ///
  /// Every reason here leaves playback perfectly functional, which is exactly
  /// why each one is phrased to be logged: otherwise "nothing was warmed" is
  /// indistinguishable from "preloading is broken".
  String? _playerWarmSkipReason(
    FastPixPlayerDataSource source, {
    required bool casting,
    required bool warmDrm,
  }) {
    if (casting) {
      return 'skipped: a Cast session is live, so a local decoder would be '
          'spent on playback happening on the receiver';
    }
    // A parked live player drifts behind the live edge for as long as it is
    // held, so it is warm in name only.
    if (source.streamType == StreamType.live) {
      return 'skipped: live stream — a parked player drifts behind the live '
          'edge and is warm in name only';
    }
    if (source.drmEnabled && !warmDrm) {
      FastPixDrmLog.skipped(
        playbackId: source.playbackId,
        reason: 'warmDrm=false',
      );
      return 'skipped: DRM source and warmDrm=false';
    }
    return null;
  }

  Future<void> _warm(
    _PreloadEntry entry,
    FastPixPlayerConfiguration? configuration,
  ) async {
    entry.status = FastPixPreloadStatus.loading;
    entry.startedAt = DateTime.now();
    FastPixWarmLog.preload(
      'warm started strategy=${entry.strategy.name} '
      'drm=${entry.source.drmEnabled} '
      'network=${FastPixNetworkMonitor.instance.current.name}',
      playbackId: entry.source.playbackId,
    );
    _emit(
      FastPixPreloadStartedEvent(
        timestamp: entry.startedAt!,
        playbackId: entry.source.playbackId,
        strategy: entry.strategy,
        networkType: FastPixNetworkMonitor.instance.current,
      ),
    );

    try {
      switch (entry.strategy) {
        case FastPixPreloadStrategy.network:
          await _warmNetworkSerialised(entry).timeout(warmTimeout);
        case FastPixPreloadStrategy.player:
          await _warmPlayer(entry, configuration).timeout(warmTimeout);
      }

      // The entry may have left the window while an await was in flight.
      // `setupDataSource` cannot be cancelled, so this is where the result of
      // an abandoned warm-up is discarded.
      if (entry.cancelled) {
        FastPixWarmLog.preload(
          'warm finished but the entry had already left the window — '
          'discarding it',
          playbackId: entry.source.playbackId,
        );
        _disposeController(entry);
        return;
      }

      entry.status = FastPixPreloadStatus.ready;
      FastPixWarmLog.preload(
        'READY in ${DateTime.now().difference(entry.startedAt!).inMilliseconds}ms '
        '— ${entry.strategy == FastPixPreloadStrategy.player ? "a player is "
            "warmed and adoptable" : "manifest warmed; playback still builds "
            "its own player"}',
        playbackId: entry.source.playbackId,
      );
      _emit(
        FastPixPreloadReadyEvent(
          timestamp: DateTime.now(),
          playbackId: entry.source.playbackId,
          strategy: entry.strategy,
          networkType: FastPixNetworkMonitor.instance.current,
          elapsed: DateTime.now().difference(entry.startedAt!),
        ),
      );
    } catch (error) {
      entry.status = FastPixPreloadStatus.failed;
      FastPixWarmLog.preload(
        'FAILED after '
        '${DateTime.now().difference(entry.startedAt!).inMilliseconds}ms — '
        'playback is unaffected and will cold-start: $error',
        playbackId: entry.source.playbackId,
      );
      _disposeController(entry);
      _emit(
        FastPixPreloadFailedEvent(
          timestamp: DateTime.now(),
          playbackId: entry.source.playbackId,
          strategy: entry.strategy,
          networkType: FastPixNetworkMonitor.instance.current,
          reason: error.toString(),
        ),
      );
    }
  }

  /// Serialises network warms so they run one at a time.
  ///
  /// Measured on a real device over cellular: three master playlists warming
  /// concurrently turned a 5 KB fetch into 1,331 ms, and a DRM play running
  /// alongside them took 2,678 ms to first frame against a ~1,640 ms median.
  /// The payload is trivial — the contention is connection setup on a radio
  /// that only has so much to give.
  ///
  /// A warm-up exists to make the next tap faster. One that competes with the
  /// video the viewer is *currently waiting for* has made things worse, and it
  /// does so invisibly, because the cost lands on a different playback than
  /// the one being warmed.
  Future<void> _networkWarmQueue = Future<void>.value();

  Future<void> _warmNetworkSerialised(_PreloadEntry entry) {
    final next = _networkWarmQueue.then((_) {
      // The entry may have left the window while queued; warming it now would
      // spend a request on something already discarded.
      if (entry.cancelled) return Future<void>.value();
      return _warmNetwork(entry);
    });
    // Errors are handled by the caller's try/catch; the queue itself must
    // never become a failed future or every later warm is skipped.
    _networkWarmQueue = next.catchError((_) {});
    return next;
  }

  Future<void> _warmNetwork(_PreloadEntry entry) async {
    // Reuse the real data source so the warm-up sends the same headers the
    // player will. A CDN that varies on them would otherwise be warmed for a
    // different cache entry than the one playback reads.
    final betterPlayerSource = entry.source.toBetterPlayerDataSource();

    // On iOS, hand the same warm to AVFoundation as well. `FastPixManifestWarmer`
    // uses `dart:io`, whose connection pool the native player never touches, so
    // on its own it warms DNS and the CDN edge but leaves AVFoundation's own
    // stack cold. The native warmer closes that gap.
    //
    // Additive and best effort: it is not awaited alongside the Dart warm
    // because a platform channel failure must not fail the entry.
    unawaited(_warmNativeAsset(entry, betterPlayerSource.headers));

    return _warmer.warm(
      entry.source.url,
      headers: betterPlayerSource.headers,
      depth: warmDepth,
    );
  }

  /// Ask the iOS side to warm an `AVURLAsset` for [entry].
  ///
  /// iOS only, and deliberately silent about failure. There is no adoption on
  /// iOS — the engine builds its own asset at playback — so this warms the
  /// network path and nothing more. Treating a failure here as a preload
  /// failure would report a broken warm for something that never had a
  /// guarantee attached.
  Future<void> _warmNativeAsset(
    _PreloadEntry entry,
    Map<String, String>? headers,
  ) async {
    if (!Platform.isIOS) return;
    try {
      await _nativeChannel.invokeMethod<void>('preloadStart', {
        // playbackId, never the URL: the token rotates, so a URL key is
        // written under one token and looked up under another.
        'key': entry.source.playbackId,
        'url': entry.source.url,
        'headers': headers ?? const <String, String>{},
      });
    } catch (_) {
      // A missing plugin, an old host app, a refused argument — all resolve to
      // the ordinary cold load.
    }
  }

  /// Tell the iOS side to drop the asset warmed for [playbackId].
  Future<void> _stopNativeAsset(String playbackId) async {
    if (!Platform.isIOS) return;
    try {
      await _nativeChannel.invokeMethod<void>('preloadStop', {
        'key': playbackId,
      });
    } catch (_) {
      // Stopping something that was never started is not an error.
    }
  }

  /// Shared with the precache manager: one channel, one native plugin.
  static const MethodChannel _nativeChannel = MethodChannel(
    'fastpix_video_player/precache',
  );

  Future<void> _warmPlayer(
    _PreloadEntry entry,
    FastPixPlayerConfiguration? configuration,
  ) async {
    final warmConfiguration = buildBetterPlayerConfiguration(
      configuration: configuration,
      dataSource: entry.source,
    ).copyWith(
      // A parked player must not play — otherwise a warmed video plays audio
      // offscreen.
      autoPlay: false,
      // The manager owns this controller's lifetime. Without this a widget
      // that never displayed it could still tear it down underneath us.
      autoDispose: false,
      // No widget is attached, so there is no app-lifecycle owner. Leaving
      // this on makes a backgrounded app pause a player nobody is watching
      // and emit spurious events into metrics.
      handleLifecycle: false,
    );

    if (entry.source.drmEnabled) {
      // Counted here rather than in preload(), because this is the point of no
      // return: a warm player acquires its licence while setting up, for a
      // video nobody has asked for yet, and pays for another one if the window
      // moves and this entry is evicted before it is ever played.
      FastPixDrmLog.armed(
        playbackId: entry.source.playbackId,
        reason: FastPixDrmLog.reasonPreload,
        host: Uri.tryParse(
              entry.source.drmConfiguration?.resolvedBaseUrl ?? '',
            )?.host ??
            '',
      );
    }

    // Before the player is built, never after: the engine installs its
    // resource-loader delegate during that build, and the FairPlay patch
    // substitutes ours at that moment or not at all. Without this the warm
    // player captures whichever video was configured last — the one currently
    // playing — and acquires a licence that cannot decrypt the video it was
    // warmed for. Playback then adopts it and shows a black frame.
    //
    // Best effort, and a no-op off iOS or on a source without FairPlay.
    await FastPixFairPlayBridge.configure(entry.source);

    final factory = warmedPlayerFactory ?? _createWarmedPlayer;
    final controller = await factory(entry.source, warmConfiguration);
    entry.controller = controller;
  }

  Future<BetterPlayerController> _createWarmedPlayer(
    FastPixPlayerDataSource source,
    BetterPlayerConfiguration configuration,
  ) async {
    final controller = BetterPlayerController(configuration);

    final ready = Completer<void>();
    void listener(BetterPlayerEvent event) {
      if (ready.isCompleted) return;
      switch (event.betterPlayerEventType) {
        case BetterPlayerEventType.initialized:
          ready.complete();
        case BetterPlayerEventType.exception:
          ready.completeError(
            event.parameters?['exception'] ?? 'preload failed',
          );
        default:
          break;
      }
    }

    controller.addEventsListener(listener);
    try {
      await controller.setupDataSource(source.toBetterPlayerDataSource());
      // `setupDataSource` returns once the source is handed to the platform.
      // `initialized` is what says a first frame is actually decodable — and
      // for DRM, that the licence has been acquired.
      await ready.future;
      return controller;
    } catch (_) {
      controller.dispose(forceDispose: true);
      rethrow;
    } finally {
      controller.removeEventsListener(listener);
    }
  }

  /// Hand over the warmed player for [playbackId], removing it from the window.
  ///
  /// Returns null whenever no warm player can be adopted — warmed over the
  /// network only, still in flight, failed, or warmed for a different
  /// configuration. **Callers must treat null as the normal case** and take
  /// the cold path.
  ///
  /// Ownership transfers to the caller, which must dispose with
  /// `forceDispose: true` — a warmed player is configured `autoDispose: false`
  /// and a plain `dispose()` on it is a no-op that leaks its decoder.
  BetterPlayerController? consume(
    String playbackId, {
    required String fingerprint,
  }) {
    final entry = _entries[playbackId];
    if (entry == null) {
      FastPixWarmLog.preload(
        'COLD START — nothing was warmed for this source',
        playbackId: playbackId,
      );
      return null;
    }

    // Still loading: leave the entry in place. It may yet become useful for a
    // later attempt, and dropping it here would throw away work that is
    // seconds from completing.
    if (entry.status != FastPixPreloadStatus.ready) {
      FastPixWarmLog.preload(
        'COLD START — the warm was still ${entry.status.name} at the tap '
        '(dwell was shorter than the warm needed)',
        playbackId: playbackId,
      );
      return null;
    }

    // A warmed controller's configuration is final. Adopting one built for
    // different settings would silently render with the wrong controls, fit
    // and screen-sleep behaviour for the whole session — worse than the cold
    // start it would have saved. Unlike the loading case this can never
    // succeed, so the entry is dropped.
    if (entry.fingerprint != fingerprint) {
      // The most confusing failure in the whole feature: everything warmed
      // perfectly and is then refused. Both fingerprints are printed because
      // the difference is the diagnosis.
      FastPixWarmLog.preload(
        'COLD START — configuration mismatch, warmed player refused.\n'
        '  warmed with : ${entry.fingerprint}\n'
        '  playing with: $fingerprint\n'
        '  preload() and initialize() must be passed the same configuration.',
        playbackId: playbackId,
      );
      _release(playbackId, cancelled: true);
      return null;
    }

    final controller = entry.controller;
    if (controller == null) {
      FastPixWarmLog.preload(
        'COLD START — warmed over the network only, so there is no player to '
        'adopt (use FastPixPreloadStrategy.player for adoption)',
        playbackId: playbackId,
      );
      return null;
    }

    // Ownership transfers, so the entry is dropped without disposing what it
    // held.
    entry.controller = null;
    _entries.remove(playbackId);
    // The line to grep for. Its presence is the difference between preloading
    // working and preloading merely running.
    FastPixWarmLog.preload(
      'ADOPTED — playback is starting from the warmed player, skipping the '
      'manifest fetch, DRM licence and decoder setup',
      playbackId: playbackId,
    );
    _emit(
      FastPixPreloadConsumedEvent(
        timestamp: DateTime.now(),
        playbackId: playbackId,
        strategy: entry.strategy,
        networkType: FastPixNetworkMonitor.instance.current,
      ),
    );
    return controller;
  }

  /// Whether [playbackId] has been warmed to the point of being useful.
  bool isReady(String playbackId) =>
      _entries[playbackId]?.status == FastPixPreloadStatus.ready;

  /// Window bookkeeping only. Anything other than
  /// [FastPixPreloadStatus.ready] means the next playback takes the cold path.
  FastPixPreloadStatus statusOf(String playbackId) =>
      _entries[playbackId]?.status ?? FastPixPreloadStatus.queued;

  /// Release one entry and cancel its warm-up.
  ///
  /// Call this on eviction or teardown — **never on player mount**. Adoption
  /// happens after mount, and a warm needs several hundred milliseconds, so
  /// cancelling at mount throws away exactly the work about to be adopted.
  void cancel(String playbackId) => _release(playbackId, cancelled: true);

  /// Release everything. For queue teardown or memory pressure.
  void clearAll() {
    for (final key in _entries.keys.toList()) {
      _release(key, cancelled: true);
    }
  }

  /// Release every resource and reset the shared HTTP client.
  ///
  /// The manager stays usable afterwards — it is a singleton, so leaving it
  /// dead would break the next playback session in the same process.
  void dispose() {
    clearAll();
    _warmer.close();
    _warmer = FastPixManifestWarmer();
  }

  void _release(String playbackId, {required bool cancelled}) {
    final entry = _entries.remove(playbackId);
    if (entry == null) return;

    // An in-flight warm-up cannot be interrupted mid-await; flagging it makes
    // it discard its own result when it lands.
    entry.cancelled = true;
    _disposeController(entry);
    // The native iOS warm is a separate resource with its own pool, so it has
    // to be released explicitly — the Dart entry going away does not free it.
    unawaited(_stopNativeAsset(playbackId));

    if (cancelled && entry.status != FastPixPreloadStatus.failed) {
      entry.status = FastPixPreloadStatus.cancelled;
      _emit(
        FastPixPreloadCancelledEvent(
          timestamp: DateTime.now(),
          playbackId: playbackId,
          strategy: entry.strategy,
          networkType: FastPixNetworkMonitor.instance.current,
        ),
      );
    }
  }

  void _disposeController(_PreloadEntry entry) {
    // `dispose()` returns early when `autoDispose` is false, so without
    // `forceDispose` the decoder — and for DRM the MediaDrm session — leaks.
    // That is the exact failure this feature exists to avoid causing.
    entry.controller?.dispose(forceDispose: true);
    entry.controller = null;
  }

  void _emit(FastPixPlayerEvent event) => _eventManager.emit(event);
}
