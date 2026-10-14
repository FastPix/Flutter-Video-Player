import 'dart:async';
import 'dart:collection';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'enums/fastpix_network_type.dart';
import 'enums/fastpix_preload_status.dart';
import 'enums/fastpix_prerender_error_code.dart';
import 'enums/fastpix_prerender_status.dart';
import 'fastpix_player_configuration.dart';
import 'fastpix_preload_manager.dart';
import 'models/fastpix_player_data_source.dart';
import 'models/fastpix_player_event.dart';
import 'models/fastpix_player_event_types.dart';
import 'models/fastpix_player_prerender_configuration.dart';
import 'models/fastpix_preload_event.dart';
import 'models/fastpix_prerender_event.dart';
import 'models/fastpix_prerender_result.dart';
import 'utils/fastpix_better_player_configuration.dart';
import 'utils/fastpix_network_monitor.dart';
import 'utils/fastpix_prerender_channel.dart';
import 'utils/fastpix_warm_log.dart';

/// What a controller tells the prerender manager about itself.
///
/// Read at every decision rather than cached, so a policy that changes between
/// a request and a promotion is seen at the promotion.
abstract interface class FastPixPrerenderOwner {
  /// The prerender settings in force.
  FastPixPlayerPrerenderConfiguration get prerenderConfiguration;

  /// The configuration sources are played with: it decides the engine
  /// fingerprint, which must match for a prerender to be promoted.
  FastPixPlayerConfiguration? get prerenderPlayerConfiguration;

  /// The playbackId playing now, if any.
  String? get prerenderActivePlaybackId;

  /// [playbackId]'s playlist position, or null when it is not in a playlist.
  int? prerenderPlaylistIndexOf(String playbackId);

  /// Whether a player surface is mounted inline, so a hidden slot exists.
  bool get prerenderSurfaceAvailable;

  /// Whether Picture-in-Picture is active or starting.
  bool get prerenderPipActive;

  /// Whether a Cast session is connected.
  bool get prerenderExternalPlayback;

  /// The playback rate a promoted player will play at.
  double get prerenderPlaybackRate;

  /// Emit [event] on this controller's event stream.
  void emitPrerenderEvent(FastPixPlayerEvent event);

  /// The engine to mount in the hidden slot, or null to unmount it.
  void onPrerenderEngineChanged(BetterPlayerController? engine);
}

/// How a load may take over a prerender.
enum FastPixPrerenderClaimKind {
  /// A frame is ready on the hidden surface: promote it.
  frameReady,

  /// The player is warm and mounted hidden but has no frame yet: keep the
  /// outgoing player on screen until [FastPixPrerenderClaim.frame] completes.
  warm,
}

/// A load's hold on a prerender, from [FastPixPrerenderManager.tryClaim]
/// until it is completed or abandoned.
class FastPixPrerenderClaim {
  FastPixPrerenderClaim._(this._entry, this.kind);

  final _Entry _entry;
  final FastPixPrerenderClaimKind kind;

  BetterPlayerController get engine => _entry.engine!;
  FastPixPlayerDataSource get source => _entry.source;

  /// Completes true when a frame is ready, false if one never will be.
  Future<bool> get frame => _entry.frame.future;
}

class _Entry {
  _Entry(this.owner, this.source, this.automatic, {this.silent = false});

  final FastPixPrerenderOwner owner;
  final FastPixPlayerDataSource source;
  final bool automatic;

  /// A warm player mounted hidden for one load's hand-off, not a prerender:
  /// it emits nothing and keeps no record.
  final bool silent;

  String get playbackId => source.playbackId;

  FastPixPrerenderStatus status = FastPixPrerenderStatus.preparing;
  BetterPlayerController? engine;
  int? textureId;
  final Stopwatch requestClock = Stopwatch()..start();
  Duration? timeToFirstFrame;
  Timer? deadline;
  final Completer<bool> frame = Completer<bool>();
  FastPixPrerenderClaim? claim;
  bool closed = false;

  /// Whether this prerender started the warm itself, rather than borrowing
  /// one the window already held. Such a warm is the prerender's to release.
  bool startedWarm = false;
}

class _Record {
  _Record(this.status);

  FastPixPrerenderStatus status;
  FastPixPrerenderErrorCode? errorCode;
}

class _Book {
  final LinkedHashMap<String, _Record> records =
      LinkedHashMap<String, _Record>();

  static const int _limit = 32;

  _Record put(String playbackId, _Record record) {
    records.remove(playbackId);
    records[playbackId] = record;
    while (records.length > _limit) {
      records.remove(records.keys.first);
    }
    return record;
  }
}

/// Holds at most one prerender across the app: a warm player, muted and
/// paused at its start position, mounted on a hidden surface beneath its
/// controller's active video, with a frame confirmed ready by the platform.
///
/// Prerendering is an optimisation, never a precondition: every refusal is a
/// skip, every failure is informational, and anything that is not a valid
/// frame-ready prerender at the moment of a load leaves that load on its
/// normal path.
class FastPixPrerenderManager {
  FastPixPrerenderManager._();

  static final FastPixPrerenderManager instance = FastPixPrerenderManager._();

  /// The bound on everything from the request to the first frame.
  Duration get deadline => deadlineOverride ?? FastPixPreloadManager.warmTimeout;

  /// Replaces [deadline]. For tests, which cannot wait 12 s per case.
  @visibleForTesting
  Duration? deadlineOverride;

  FastPixPrerenderPlatform? _platformOverride;
  FastPixPrerenderPlatform get _platform =>
      _platformOverride ?? FastPixPrerenderChannel.instance;

  /// Replace the native side. For tests.
  @visibleForTesting
  set platform(FastPixPrerenderPlatform? value) {
    _frameSubscription?.cancel();
    _frameSubscription = null;
    _seekSubscription?.cancel();
    _seekSubscription = null;
    _platformOverride = value;
  }

  /// Whether the app is in the foreground. Overridable for tests.
  @visibleForTesting
  bool Function()? isForegroundOverride;

  /// Waits until a newly mounted hidden view has been laid out. Overridable
  /// for tests, which have no frames to wait for.
  @visibleForTesting
  Future<void> Function()? afterMountOverride;

  FastPixPreloadManager get _preload => FastPixPreloadManager.instance;

  _Entry? _live;
  final Map<FastPixPrerenderOwner, _Book> _books =
      <FastPixPrerenderOwner, _Book>{};
  StreamSubscription<int>? _frameSubscription;
  StreamSubscription<int>? _seekSubscription;
  StreamSubscription<FastPixNetworkType>? _networkSubscription;

  bool get _foreground {
    final override = isForegroundOverride;
    if (override != null) return override();
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  _Book _bookOf(FastPixPrerenderOwner owner) =>
      _books.putIfAbsent(owner, _Book.new);

  // --- Reading ------------------------------------------------------------

  /// [playbackId]'s status for [owner]; idle when it never asked.
  FastPixPrerenderStatus statusOf(
    FastPixPrerenderOwner owner,
    String playbackId,
  ) {
    final live = _live;
    if (live != null &&
        identical(live.owner, owner) &&
        live.playbackId == playbackId) {
      return live.status;
    }
    return _books[owner]?.records[playbackId]?.status ??
        FastPixPrerenderStatus.idle;
  }

  /// The engine mounted in [owner]'s hidden slot, or null.
  BetterPlayerController? hiddenEngineOf(FastPixPrerenderOwner owner) {
    final live = _live;
    if (live == null || !identical(live.owner, owner)) return null;
    return live.engine;
  }

  /// The playbackId [owner] is prerendering, or null.
  String? livePlaybackIdOf(FastPixPrerenderOwner owner) {
    final live = _live;
    if (live == null || !identical(live.owner, owner)) return null;
    return live.playbackId;
  }

  // --- Requesting ---------------------------------------------------------

  /// Prerender [source] for [owner].
  ///
  /// Completes when the request settles: frame-ready, skipped or failed. A
  /// duplicate request answers with the existing entry's status at once.
  Future<FastPixPrerenderResult> request(
    FastPixPrerenderOwner owner,
    FastPixPlayerDataSource source, {
    bool automatic = false,
  }) async {
    final playbackId = source.playbackId;
    final live = _live;
    if (live != null &&
        identical(live.owner, owner) &&
        live.playbackId == playbackId) {
      return FastPixPrerenderResult(status: live.status);
    }

    final refusal = await _admission(owner, source, automatic: automatic);
    if (refusal != null) return _skip(owner, source, refusal);

    // The await above may have let another request in.
    final current = _live;
    if (current != null) {
      final replaceable =
          identical(current.owner, owner) && current.claim == null;
      if (!replaceable) {
        return _skip(owner, source, FastPixPrerenderErrorCode.decoderBudget);
      }
      _release(current, 'replaced');
    }

    final configuration = owner.prerenderPlayerConfiguration;
    final fingerprint = betterPlayerConfigurationFingerprint(
      configuration: configuration,
      dataSource: source,
    );
    final engine = _preload.lend(playbackId, fingerprint: fingerprint);
    final hadWarm = _preload.statusOf(playbackId) != FastPixPreloadStatus.queued;
    if (engine == null &&
        !_preload.warmOne(source, configuration: configuration)) {
      return _skip(owner, source, FastPixPrerenderErrorCode.decoderBudget);
    }

    final entry = _Entry(owner, source, automatic)
      ..startedWarm = engine == null && !hadWarm;
    _live = entry;
    _bookOf(owner).put(playbackId, _Record(FastPixPrerenderStatus.preparing));
    _ensureListening();
    FastPixWarmLog.preload(
      'PRERENDER requested (${automatic ? "automatic" : "explicit"})',
      playbackId: playbackId,
    );
    _emit(
      entry,
      FastPixPrerenderRequestedEvent(
        timestamp: DateTime.now(),
        playbackId: playbackId,
        playlistIndex: owner.prerenderPlaylistIndexOf(playbackId),
        automatic: automatic,
      ),
    );
    entry.deadline = Timer(deadline, () {
      _fail(entry, FastPixPrerenderErrorCode.timedOut, 'no frame within '
          '${deadline.inSeconds} s');
    });

    await _prepare(entry, engine, fingerprint);
    return _resultOf(owner, playbackId);
  }

  /// Take [entry] from its warm player — [lent], or the one being built — to
  /// a hidden mount watched for its first frame. Stops at the first step that
  /// cannot proceed, with the entry already closed, failed or skipped.
  Future<void> _prepare(
    _Entry entry,
    BetterPlayerController? lent,
    String fingerprint,
  ) async {
    final owner = entry.owner;
    final engine = lent ?? await _waitForWarm(entry, fingerprint);
    if (entry.closed) return;
    if (engine == null) {
      _fail(entry, FastPixPrerenderErrorCode.loadFailed, 'the warm player '
          'could not be built');
      return;
    }
    entry.engine = engine;

    final textureId = fastPixEngineTextureId(engine);
    if (textureId == null) {
      _fail(entry, FastPixPrerenderErrorCode.loadFailed, 'the warm player '
          'has no view');
      return;
    }
    entry.textureId = textureId;

    // Silent from the moment it is ours, and marked before its view exists so
    // native owners never see it as a candidate.
    await engine.setVolume(0);
    await _platform.setRole(textureId, FastPixPrerenderRole.prerender);
    if (entry.closed) return;
    if (!owner.prerenderSurfaceAvailable) {
      _fail(entry, FastPixPrerenderErrorCode.surfaceUnavailable,
          'the player surface went away');
      return;
    }
    owner.onPrerenderEngineChanged(engine);
    await (afterMountOverride?.call() ?? _afterMount());
    if (entry.closed) return;

    final watching = await _platform.watchFirstFrame(
      textureId,
      position: entry.source.startAt ?? Duration.zero,
      rate: owner.prerenderPlaybackRate,
    );
    if (entry.closed) return;
    if (!watching) {
      _skipLive(entry, FastPixPrerenderErrorCode.featureDisabled);
      return;
    }

    await entry.frame.future;
  }

  /// Record that [owner]'s navigation ruled out prerendering [source], for
  /// [reason]: a skipped status, nothing built.
  void skip(
    FastPixPrerenderOwner owner,
    FastPixPlayerDataSource source,
    FastPixPrerenderErrorCode reason,
  ) => unawaited(_skip(owner, source, reason));

  /// Completes once the frames now being built have been presented: what a
  /// hand-off waits for before releasing the outgoing player.
  Future<void> afterFrames() => afterMountOverride?.call() ?? _afterMount();

  /// Cancel [owner]'s prerender of [playbackId]. Nothing happens when there
  /// is none.
  void cancel(FastPixPrerenderOwner owner, String playbackId) {
    final live = _live;
    if (live == null ||
        !identical(live.owner, owner) ||
        live.playbackId != playbackId ||
        live.claim != null) {
      return;
    }
    _release(live, 'cancelled');
  }

  /// Release [owner]'s prerender, if it has one; [reason] is for the log.
  /// [keepWarm] returns its player to the warm window instead of releasing
  /// it. [force] releases it even mid-promotion, which only dispose does.
  void releaseFor(
    FastPixPrerenderOwner owner,
    String reason, {
    bool keepWarm = false,
    bool force = false,
  }) {
    final live = _live;
    if (live == null || !identical(live.owner, owner)) return;
    _release(live, reason, keepWarm: keepWarm, force: force);
  }

  /// Mark [engine]'s native view for [role]. Used by the controller at a
  /// hand-off, for both the incoming and the outgoing player.
  Future<void> setRole(
    BetterPlayerController engine,
    FastPixPrerenderRole role,
  ) async {
    final textureId = fastPixEngineTextureId(engine);
    if (textureId != null) await _platform.setRole(textureId, role);
  }

  /// Release whatever prerender is live; [reason] is for the log.
  void releaseAll(String reason) {
    final live = _live;
    if (live != null) _release(live, reason);
  }

  /// Release a prerender whose policy no longer holds: Picture-in-Picture,
  /// external playback, or the owner switching prerendering off.
  void reevaluatePolicy() {
    final live = _live;
    if (live == null || live.claim != null) return;
    final owner = live.owner;
    if (!owner.prerenderConfiguration.enablePrerender ||
        owner.prerenderPipActive ||
        owner.prerenderExternalPlayback ||
        _cellularBlocked(owner)) {
      _release(live, 'policyChanged');
    }
  }

  /// [owner]'s surface is gone. A prerender still preparing fails; a ready
  /// one is released. Either way the warm player is kept for the window.
  void surfaceUnavailable(FastPixPrerenderOwner owner) {
    final live = _live;
    if (live == null || !identical(live.owner, owner) || live.claim != null) {
      return;
    }
    if (live.status == FastPixPrerenderStatus.preparing) {
      _fail(live, FastPixPrerenderErrorCode.surfaceUnavailable,
          'the player surface was unmounted', keepWarm: true);
    } else {
      _release(live, 'policyChanged', keepWarm: true);
    }
  }

  /// Forget [owner] entirely, releasing its prerender. Called on dispose.
  void forget(FastPixPrerenderOwner owner) {
    releaseFor(owner, 'disposed', force: true);
    _books.remove(owner);
  }

  // --- Promotion ----------------------------------------------------------

  /// Take [owner]'s prerender of [playbackId] for a load, re-checking every
  /// policy now rather than trusting the request-time answer.
  ///
  /// Returns null whenever the load must take its normal path; a prerender
  /// that can no longer be promoted is released.
  FastPixPrerenderClaim? tryClaim(
    FastPixPrerenderOwner owner,
    String playbackId, {
    required String fingerprint,
  }) {
    final live = _live;
    if (live == null || live.claim != null) return null;
    if (!identical(live.owner, owner) || live.playbackId != playbackId) {
      return null;
    }
    if (owner.prerenderPipActive || owner.prerenderExternalPlayback) {
      _release(live, 'policyChanged');
      return null;
    }
    final built = betterPlayerConfigurationFingerprint(
      configuration: owner.prerenderPlayerConfiguration,
      dataSource: live.source,
    );
    if (built != fingerprint) {
      _release(live, 'configurationChanged');
      return null;
    }
    if (!owner.prerenderSurfaceAvailable) {
      _release(live, 'policyChanged', keepWarm: true);
      return null;
    }
    if (live.engine == null) {
      // Still waiting for its warm player: nothing to hand over yet.
      _release(live, 'replaced');
      return null;
    }
    final kind = live.status == FastPixPrerenderStatus.frameReady
        ? FastPixPrerenderClaimKind.frameReady
        : FastPixPrerenderClaimKind.warm;
    final claim = FastPixPrerenderClaim._(live, kind);
    live.claim = claim;
    return claim;
  }

  /// Borrow [source]'s ready warm player for one load's hand-off: mount it
  /// hidden beneath [owner]'s active video and watch for its first frame, so
  /// the outgoing player can stay on screen until it has one.
  ///
  /// Not a prerender: no event, no record, no admission beyond what the hand-
  /// off itself needs. Returns null whenever the load must take its normal
  /// path; nothing is borrowed then.
  Future<FastPixPrerenderClaim?> claimWarm(
    FastPixPrerenderOwner owner,
    FastPixPlayerDataSource source, {
    required String fingerprint,
  }) async {
    if (!_mayClaimWarm(owner, source)) return null;
    if (!await _platform.isSupported()) return null;
    if (_live != null || !owner.prerenderSurfaceAvailable) return null;
    final engine = _preload.lend(source.playbackId, fingerprint: fingerprint);
    if (engine == null) return null;
    final textureId = fastPixEngineTextureId(engine);
    final entry = _Entry(owner, source, false, silent: true)
      ..engine = engine
      ..textureId = textureId;
    if (textureId == null) {
      _teardown(entry, keepWarm: true);
      return null;
    }
    _live = entry;
    final claim = FastPixPrerenderClaim._(entry, FastPixPrerenderClaimKind.warm);
    entry.claim = claim;
    _ensureListening();

    await engine.setVolume(0);
    await _platform.setRole(textureId, FastPixPrerenderRole.prerender);
    if (entry.closed) return null;
    owner.onPrerenderEngineChanged(engine);
    await (afterMountOverride?.call() ?? _afterMount());
    if (entry.closed) return null;
    final watching = await _platform.watchFirstFrame(
      textureId,
      position: source.startAt ?? Duration.zero,
      rate: owner.prerenderPlaybackRate,
    );
    if (entry.closed) return null;
    if (!watching && !entry.frame.isCompleted) entry.frame.complete(false);
    return claim;
  }

  /// Whether [owner]'s load of [source] may borrow its warm player now: the
  /// slot is free, the source is clear, the app is in the foreground, and
  /// nothing — prerendering off, no surface, PiP, external playback — rules a
  /// hidden mount out.
  bool _mayClaimWarm(
    FastPixPrerenderOwner owner,
    FastPixPlayerDataSource source,
  ) {
    if (_live != null || source.drmEnabled || !_foreground) return false;
    if (!owner.prerenderConfiguration.enablePrerender) return false;
    if (!owner.prerenderSurfaceAvailable) return false;
    if (owner.prerenderPipActive || owner.prerenderExternalPlayback) {
      return false;
    }
    return _preload.isReady(source.playbackId);
  }

  /// The claimed player is now the active one. Records the promotion, ends
  /// the loan without releasing the player, and frees the slot.
  ///
  /// [startupGap] is how long the swap took to present the promoted frame;
  /// it is logged.
  void completeClaim(FastPixPrerenderClaim claim, {Duration? startupGap}) {
    final entry = claim._entry;
    if (entry.closed) return;
    final promoted = claim.kind == FastPixPrerenderClaimKind.frameReady &&
        entry.status == FastPixPrerenderStatus.frameReady;
    _close(entry);
    final textureId = entry.textureId;
    if (textureId != null) unawaited(_platform.stopWatching(textureId));
    _preload.giveBack(entry.playbackId, promoted: true);

    _recordOf(entry).status = FastPixPrerenderStatus.released;
    if (promoted) {
      FastPixWarmLog.preload(
        'PRERENDER promoted'
        '${startupGap == null ? '' : ' — swap gap ${startupGap.inMilliseconds}ms'}',
        playbackId: entry.playbackId,
      );
    }
  }

  /// The load gave up on [claim] before the player became active. The player
  /// is released; [reason] is for the log.
  void abandonClaim(
    FastPixPrerenderClaim claim,
    String reason, {
    bool keepWarm = false,
  }) {
    final entry = claim._entry;
    if (entry.closed) return;
    entry.claim = null;
    _release(entry, reason, keepWarm: keepWarm);
  }

  // --- Internals ----------------------------------------------------------

  Future<FastPixPrerenderErrorCode?> _admission(
    FastPixPrerenderOwner owner,
    FastPixPlayerDataSource source, {
    required bool automatic,
  }) async {
    final config = owner.prerenderConfiguration;
    if (!config.enablePrerender) return FastPixPrerenderErrorCode.disabled;
    if (!_foreground) return FastPixPrerenderErrorCode.background;
    if (source.streamType == StreamType.live) {
      return FastPixPrerenderErrorCode.live;
    }
    if (source.drmEnabled) return FastPixPrerenderErrorCode.drm;
    if (owner.prerenderPipActive) return FastPixPrerenderErrorCode.pip;
    if (owner.prerenderExternalPlayback) {
      return FastPixPrerenderErrorCode.externalPlayback;
    }
    if (_cellularBlocked(owner)) {
      return FastPixPrerenderErrorCode.networkPolicy;
    }
    if (source.playbackId == owner.prerenderActivePlaybackId) {
      return FastPixPrerenderErrorCode.navigationPolicy;
    }
    if (!owner.prerenderSurfaceAvailable) {
      return FastPixPrerenderErrorCode.noSurface;
    }
    final live = _live;
    if (live != null) {
      // The owner's own prerender gives way to its newer request, explicit or
      // automatic: a different target means the live one is no longer valid
      // for where this owner is going. Anyone else's is left alone.
      final mine = identical(live.owner, owner) && live.claim == null;
      if (!mine) return FastPixPrerenderErrorCode.decoderBudget;
    }
    if (!await _platform.isSupported()) {
      return FastPixPrerenderErrorCode.featureDisabled;
    }
    return null;
  }

  bool _cellularBlocked(FastPixPrerenderOwner owner) =>
      !owner.prerenderConfiguration.prerenderOnCellular &&
      FastPixNetworkMonitor.instance.current.isMetered;

  Future<FastPixPrerenderResult> _skip(
    FastPixPrerenderOwner owner,
    FastPixPlayerDataSource source,
    FastPixPrerenderErrorCode reason,
  ) async {
    final playbackId = source.playbackId;
    FastPixWarmLog.preload('PRERENDER skipped: ${reason.value}',
        playbackId: playbackId);
    _bookOf(owner).put(
      playbackId,
      _Record(FastPixPrerenderStatus.skipped)..errorCode = reason,
    );
    owner.emitPrerenderEvent(
      FastPixPrerenderFailedEvent(
        timestamp: DateTime.now(),
        playbackId: playbackId,
        playlistIndex: owner.prerenderPlaylistIndexOf(playbackId),
        code: reason,
        message: _skipMessage(reason),
      ),
    );
    return FastPixPrerenderResult(
      status: FastPixPrerenderStatus.skipped,
      errorCode: reason,
    );
  }

  /// A live entry that turned out to be impossible after it started: the
  /// native hook is missing. Skipped, not failed, and the warm player stays.
  void _skipLive(_Entry entry, FastPixPrerenderErrorCode reason) {
    FastPixWarmLog.preload('PRERENDER skipped: ${reason.value}',
        playbackId: entry.playbackId);
    _teardown(entry, keepWarm: true);
    _recordOf(entry)
      ..status = FastPixPrerenderStatus.skipped
      ..errorCode = reason;
    _emit(
      entry,
      FastPixPrerenderFailedEvent(
        timestamp: DateTime.now(),
        playbackId: entry.playbackId,
        playlistIndex: entry.owner.prerenderPlaylistIndexOf(entry.playbackId),
        code: reason,
        message: _skipMessage(reason),
      ),
    );
  }

  /// What a skip's failed event says about [reason].
  static String _skipMessage(FastPixPrerenderErrorCode reason) =>
      switch (reason) {
        FastPixPrerenderErrorCode.disabled => 'prerendering is turned off',
        FastPixPrerenderErrorCode.networkPolicy =>
          'cellular prerendering is turned off',
        FastPixPrerenderErrorCode.decoderBudget =>
          'the prerender slot is taken',
        FastPixPrerenderErrorCode.drm => 'the source is DRM-protected',
        FastPixPrerenderErrorCode.live => 'the source is a live stream',
        FastPixPrerenderErrorCode.pip => 'Picture-in-Picture is active',
        FastPixPrerenderErrorCode.externalPlayback =>
          'Cast is active',
        FastPixPrerenderErrorCode.background => 'the app is in the background',
        FastPixPrerenderErrorCode.navigationPolicy =>
          'there is no navigation target',
        FastPixPrerenderErrorCode.noSurface => 'no player surface is mounted',
        FastPixPrerenderErrorCode.featureDisabled =>
          'first-frame detection is unavailable',
        _ => 'skipped: ${reason.value}',
      };

  void _fail(
    _Entry entry,
    FastPixPrerenderErrorCode code,
    String message, {
    bool keepWarm = false,
  }) {
    if (entry.closed || entry.claim != null) return;
    FastPixWarmLog.preload('PRERENDER failed: ${code.value} — $message',
        playbackId: entry.playbackId);
    _teardown(entry, keepWarm: keepWarm);
    _recordOf(entry)
      ..status = FastPixPrerenderStatus.failed
      ..errorCode = code;
    _emit(
      entry,
      FastPixPrerenderFailedEvent(
        timestamp: DateTime.now(),
        playbackId: entry.playbackId,
        playlistIndex: entry.owner.prerenderPlaylistIndexOf(entry.playbackId),
        code: code,
        message: message,
      ),
    );
  }

  /// The single release path: cancel, replace, policy, memory,
  /// background and dispose all come through here. Promotion does not; it
  /// hands the player over in [completeClaim] instead.
  ///
  /// [reason] is for the log. [force] releases it even mid-promotion, which
  /// only dispose does.
  void _release(
    _Entry entry,
    String reason, {
    bool keepWarm = false,
    bool force = false,
  }) {
    if (entry.closed) return;
    if (entry.claim != null && !force) {
      // Mid-promotion: whichever got there first wins, and that was the load.
      return;
    }
    FastPixWarmLog.preload('PRERENDER released: $reason',
        playbackId: entry.playbackId);
    _teardown(entry, keepWarm: keepWarm);
    _recordOf(entry).status = FastPixPrerenderStatus.released;
  }

  /// Unmount, stop watching and end the loan. [keepWarm] returns the player
  /// to the warm window, audible again, instead of releasing it.
  void _teardown(_Entry entry, {required bool keepWarm}) {
    _close(entry);
    final engine = entry.engine;
    // The owner's hidden slot only ever holds the live entry's engine.
    if (engine != null) entry.owner.onPrerenderEngineChanged(null);
    final textureId = entry.textureId;
    if (textureId != null) {
      unawaited(_platform.stopWatching(textureId));
      unawaited(_platform.setRole(textureId, FastPixPrerenderRole.released));
    }
    if (engine == null) {
      // Never lent. A warm this prerender started is its to stop — the window
      // discards it when it lands; one the window already held stays there.
      if (entry.startedWarm) _preload.cancel(entry.playbackId);
      return;
    }
    if (keepWarm) {
      unawaited(engine.setVolume(1));
      _preload.giveBack(entry.playbackId, promoted: false, keepWarm: true);
    } else {
      _preload.giveBack(entry.playbackId, promoted: false);
    }
  }

  void _close(_Entry entry) {
    entry.closed = true;
    entry.deadline?.cancel();
    if (!entry.frame.isCompleted) entry.frame.complete(false);
    if (identical(_live, entry)) _live = null;
  }

  _Record _recordOf(_Entry entry) {
    // A hand-off's warm player is not a prerender and keeps no history.
    if (entry.silent) return _Record(entry.status);
    final book = _bookOf(entry.owner);
    return book.records[entry.playbackId] ??
        book.put(entry.playbackId, _Record(entry.status));
  }

  FastPixPrerenderResult _resultOf(
    FastPixPrerenderOwner owner,
    String playbackId,
  ) {
    final record = _books[owner]?.records[playbackId];
    final live = _live;
    if (live != null &&
        identical(live.owner, owner) &&
        live.playbackId == playbackId) {
      return FastPixPrerenderResult(status: live.status);
    }
    return FastPixPrerenderResult(
      status: record?.status ?? FastPixPrerenderStatus.idle,
      errorCode: record?.errorCode,
    );
  }

  void _emit(_Entry entry, FastPixPlayerEvent event) {
    if (entry.silent) return;
    entry.owner.emitPrerenderEvent(event);
  }

  Future<void> _afterMount() async {
    // Two frames: one to build the hidden view, one for the platform to
    // create it.
    await SchedulerBinding.instance.endOfFrame;
    await SchedulerBinding.instance.endOfFrame;
  }

  /// Wait for [entry]'s warm player to be ready, then borrow it.
  Future<BetterPlayerController?> _waitForWarm(
    _Entry entry,
    String fingerprint,
  ) async {
    final playbackId = entry.playbackId;
    final settled = Completer<void>();
    void onEvent(FastPixPlayerEvent event) {
      if (event is FastPixPreloadEvent &&
          event.playbackId == playbackId &&
          !settled.isCompleted) {
        settled.complete();
      }
    }

    const types = <String>[
      FastPixPlayerEventTypes.preloadReady,
      FastPixPlayerEventTypes.preloadFailed,
      FastPixPlayerEventTypes.preloadCancelled,
    ];
    final events = _preload.eventManager;
    for (final type in types) {
      events.addEventListener(type, onEvent);
    }
    try {
      // It may have become ready between the lend and the listener.
      if (!_preload.isReady(playbackId)) {
        await Future.any<void>([settled.future, entry.frame.future]);
      }
    } finally {
      for (final type in types) {
        events.removeEventListener(type, onEvent);
      }
    }
    if (entry.closed) return null;
    return _preload.lend(playbackId, fingerprint: fingerprint);
  }

  void _onFrameReady(int textureId) {
    final entry = _live;
    if (entry == null ||
        entry.closed ||
        entry.textureId != textureId ||
        entry.status != FastPixPrerenderStatus.preparing) {
      return;
    }
    entry.deadline?.cancel();
    entry.status = FastPixPrerenderStatus.frameReady;
    entry.timeToFirstFrame = entry.requestClock.elapsed;
    _recordOf(entry).status = FastPixPrerenderStatus.frameReady;
    FastPixWarmLog.preload(
      'PRERENDER frameReady in ${entry.timeToFirstFrame!.inMilliseconds}ms',
      playbackId: entry.playbackId,
    );
    _emit(
      entry,
      FastPixPrerenderReadyEvent(
        timestamp: DateTime.now(),
        playbackId: entry.playbackId,
        playlistIndex: entry.owner.prerenderPlaylistIndexOf(entry.playbackId),
        timeToFirstFrame: entry.timeToFirstFrame!,
      ),
    );
    if (!entry.frame.isCompleted) entry.frame.complete(true);
  }

  void _onSeekFailed(int textureId) {
    final entry = _live;
    if (entry == null || entry.textureId != textureId) return;
    _fail(entry, FastPixPrerenderErrorCode.seekFailed,
        'could not position at ${entry.source.startAt ?? Duration.zero}');
  }

  void _ensureListening() {
    _frameSubscription ??= _platform.frameReady.listen(_onFrameReady);
    _seekSubscription ??= _platform.seekFailed.listen(_onSeekFailed);
    _networkSubscription ??= FastPixNetworkMonitor.instance.changes.listen(
      (_) => reevaluatePolicy(),
    );
  }

  /// Drop all state. For tests: the manager is a singleton.
  @visibleForTesting
  void debugReset() {
    final live = _live;
    if (live != null) _release(live, 'disposed', force: true);
    _books.clear();
    _frameSubscription?.cancel();
    _frameSubscription = null;
    _seekSubscription?.cancel();
    _seekSubscription = null;
    _networkSubscription?.cancel();
    _networkSubscription = null;
  }
}
