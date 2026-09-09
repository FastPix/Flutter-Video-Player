import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_flutter_core_data/fastpix_flutter_core_data.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_windowmanager_plus/flutter_windowmanager_plus.dart';
import 'managers/fastpix_lifecycle_manager.dart';
import 'models/valid_events.dart';
import 'utils/fastpix_fairplay_bridge.dart';

// Custom-UI mechanism (additive). The managers, models, events, enum and cast
// controller these members use all reach this file through the package barrel
// (`package:fastpix_video_player/fastpix_video_player.dart`) already imported
// above, which now re-exports them. Nothing existing above is changed.

/// Controller for FastPix Player
class FastPixPlayerController implements PlayerObserver {
  FastPixPlayerController() {
    // Every event this player emits says which item it describes, including
    // the ones the managers raise. One place to get right.
    _eventManager.attributionProvider = _eventAttribution;
  }

  /// Fallback message used when the platform player reports a failure without
  /// an exception string.
  static const String _unknownErrorMessage = 'Unknown error';

  BetterPlayerController? _betterPlayerController;
  FastPixPlayerDataSource? _dataSource;
  FastPixPlayerConfiguration? _configuration;
  FastPixPlayerState _currentState = FastPixPlayerState.initialized;

  /// The configuration this controller was initialized with, or null before
  /// [initialize].
  ///
  /// Read-only: reconfiguring goes through [initialize], not through mutating
  /// what is returned here. Exposed so the widget layer can read presentation
  /// flags such as
  /// [FastPixPlayerControlsConfiguration.showPlaylistControls] without a
  /// second copy of the configuration being threaded through it.
  FastPixPlayerConfiguration? get configuration => _configuration;

  /// Event manager for handling player events
  final FastPixPlayerEventManager _eventManager = FastPixPlayerEventManager();

  /// Get the event manager for adding/removing listeners
  FastPixPlayerEventManager get eventManager => _eventManager;

  /// Add a listener for a specific event type
  void addEventListener(String eventType, FastPixPlayerEventListener listener) {
    _eventManager.addEventListener(eventType, listener);
  }

  /// Add a listener for all events
  void addGlobalListener(FastPixPlayerEventListener listener) {
    _eventManager.addGlobalListener(listener);
  }

  /// Remove a listener for a specific event type
  void removeEventListener(
    String eventType,
    FastPixPlayerEventListener listener,
  ) {
    _eventManager.removeEventListener(eventType, listener);
  }

  /// Remove a global listener
  void removeGlobalListener(FastPixPlayerEventListener listener) {
    _eventManager.removeGlobalListener(listener);
  }

  /// Remove all listeners for a specific event type
  void removeAllEventListeners(String eventType) {
    _eventManager.removeAllEventListeners(eventType);
  }

  /// Remove all listeners
  void removeAllListeners() {
    _eventManager.removeAllListeners();
  }

  // -------------------------------------------------------------------------
  // Custom-UI mechanism (additive)
  //
  // A headless, functionality-only API for apps that build their own player
  // interface. Playback control is separated from presentation: these members
  // never require the default skin, and the default skin is unaffected by them.
  // Each capability is delegated to an independent manager (Principle 3), and
  // every model returned is FastPix-owned so the engine never leaks (Principle
  // 4). All managers read the live engine through `() => _betterPlayerController`
  // so they always talk to whichever player this controller currently owns —
  // including one adopted from the preload manager.
  // -------------------------------------------------------------------------

  late final FastPixPlaybackRateManager _rateManager =
      FastPixPlaybackRateManager(() => _betterPlayerController, _eventManager);
  late final FastPixScrubController _scrubController = FastPixScrubController(
    seekTo,
    _eventManager,
  );
  late final FastPixQualityManager _qualityManager = FastPixQualityManager(
    () => _betterPlayerController,
    _eventManager,
  );
  late final FastPixAudioTrackManager _audioManager = FastPixAudioTrackManager(
    () => _betterPlayerController,
    _eventManager,
  );
  late final FastPixSubtitleTrackManager _subtitleManager =
      FastPixSubtitleTrackManager(() => _betterPlayerController, _eventManager);
  // Takes only the event bus now. It used to take the engine accessor and the
  // surface key as well, because it drove the engine's PiP and needed a
  // laid-out widget to anchor an iOS window. PiP is owned natively now, so the
  // native side finds its own layer and there is nothing here to hand it.
  late final FastPixPipManager _pipManager = FastPixPipManager(
    _eventManager,
    hasPreparedSource: () => _betterPlayerController != null,
    onWindowTransport: _handleWindowTransport,
  );

  /// The viewer played or paused from inside the Picture-in-Picture window.
  ///
  /// Routed through the same transport machinery as any other play or pause,
  /// so the reported state, the playback-state stream and analytics all agree
  /// with what the window is doing. Without it the app believes the video is
  /// still playing: those taps never touch Dart, and the engine's own report of
  /// them came from a branch keyed on its PiP controller, which this SDK no
  /// longer builds.
  void _handleWindowTransport(bool playing) {
    if (_disposed) return;
    _handleTransportEvent(playing ? PlayerEvent.play : PlayerEvent.pause);
    _emitPlaybackState();
  }

  /// Keeps the engine's own layout box on the video's shape.
  ///
  /// Foreground/background pausing, owned here rather than by the engine so
  /// that a PiP window — which is what the viewer left the app to watch — is
  /// not paused by the very act of leaving.
  late final FastPixLifecycleManager _lifecycleManager = FastPixLifecycleManager(
    () => _betterPlayerController,
    // Pending, not just active: the pause rule runs on the way out of the
    // app, which is exactly when a PiP window is still opening.
    () => _pipManager.isPipActiveOrPending,
    wantsAutoPip: () => _pipManager.enabled && _pipManager.autoEnterOnBackground,
    enterPip: () => _pipManager.enterPip(),
    reconcilePip: () => _pipManager.reconcileWithPlatform(),
  );

  /// The [GlobalKey] of the on-screen video surface, used to anchor a PiP
  /// window (required on iOS). Registered by [FastPixVideoSurface] while it is
  /// mounted; the last surface to register wins, which is the right choice when
  /// several surfaces are bound to one controller.
  GlobalKey? _pipSurfaceKey;

  /// Called by [FastPixVideoSurface] when it mounts, so PiP can anchor to it.
  void registerPipSurfaceKey(GlobalKey key) => _pipSurfaceKey = key;

  /// Called by [FastPixVideoSurface] when it unmounts. Clears the key only if
  /// it is still the one registered, so a surface leaving does not steal a key
  /// a newer surface installed.
  void unregisterPipSurfaceKey(GlobalKey key) {
    if (identical(_pipSurfaceKey, key)) _pipSurfaceKey = null;
  }

  final StreamController<FastPixPlaybackState> _playbackStateController =
      StreamController<FastPixPlaybackState>.broadcast();

  /// Whether the *Ready event for each track family has already fired for the
  /// current source. Reset by [initialize]; flipped once the engine has parsed
  /// tracks, so the ready signal is emitted exactly once per source.
  bool _qualityTracksReady = false;
  bool _audioTracksReady = false;
  bool _subtitleTracksReady = false;

  /// Continuous playback state for reactive UI binding (Feature 3).
  ///
  /// Emits on every progress tick with a fresh [FastPixPlaybackState]. Broadcast
  /// and non-replaying: seed a `StreamBuilder` with [playbackState] so it is not
  /// blank until the first tick. While a scrub is in progress the reported
  /// position follows the scrub target, not the live playhead, so a bound
  /// seekbar tracks the user's finger.
  Stream<FastPixPlaybackState> get playbackStateStream =>
      _playbackStateController.stream;

  // ---- Feature 2: Playback controls ----

  /// Toggle between play and pause.
  Future<void> togglePlayPause() async {
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  /// Seek forward by [offset] (default 10s), clamped to the media duration.
  Future<void> seekForward([Duration offset = const Duration(seconds: 10)]) {
    final duration = getTotalDuration() ?? Duration.zero;
    var target = (getCurrentPosition() ?? Duration.zero) + offset;
    if (duration > Duration.zero && target > duration) target = duration;
    if (target < Duration.zero) target = Duration.zero;
    return seekTo(target);
  }

  /// Seek backward by [offset] (default 10s), clamped to the start.
  Future<void> seekBackward([Duration offset = const Duration(seconds: 10)]) {
    var target = (getCurrentPosition() ?? Duration.zero) - offset;
    if (target < Duration.zero) target = Duration.zero;
    return seekTo(target);
  }

  /// Set the playback speed, clamped to [supportedPlaybackRates]' range rather
  /// than throwing on an out-of-range value.
  Future<void> setPlaybackRate(double rate) async {
    if (_betterPlayerController == null) {
      _emitCustomUiError(
        'Cannot set playback rate before the player is ready.',
        FastPixCustomUIErrorCode.playerNotReady,
      );
      return;
    }
    await _rateManager.setRate(rate);
  }

  /// The current playback speed, where `1.0` is normal.
  double get playbackRate => _rateManager.rate;

  /// The playback speeds a menu should offer.
  List<double> get supportedPlaybackRates =>
      FastPixPlaybackRateManager.supportedRates;

  /// Enter fullscreen.
  void enterFullscreen() {
    _betterPlayerController?.enterFullScreen();
    _emitFullscreen(true);
  }

  /// Exit fullscreen.
  void exitFullscreen() {
    _betterPlayerController?.exitFullScreen();
    _emitFullscreen(false);
  }

  /// Toggle fullscreen.
  void toggleFullscreen() {
    final controller = _betterPlayerController;
    if (controller == null) return;
    controller.toggleFullScreen();
    _emitFullscreen(controller.isFullScreen);
  }

  /// Whether the player is currently in fullscreen.
  bool get isFullscreen => _betterPlayerController?.isFullScreen ?? false;

  /// Last fullscreen state broadcast. Two paths funnel through
  /// [_emitFullscreen] — the manual calls in [enterFullscreen]/[exitFullscreen]/
  /// [toggleFullscreen], and the engine's own `openFullscreen`/`hideFullscreen`
  /// events (which also fire for the system back button, a path the manual
  /// methods never see) — and either can arrive first. Deduping here means the
  /// event fires once per real change, and, crucially, that returning from
  /// fullscreen via the back button still emits `false` so a custom control's
  /// fullscreen button cannot keep a stale "exit" icon.
  bool? _lastFullscreenEmitted;

  void _emitFullscreen(bool isFullscreen) {
    if (_lastFullscreenEmitted == isFullscreen) return;
    _lastFullscreenEmitted = isFullscreen;
    _eventManager.emit(
      FastPixPlayerFullscreenChangedEvent(
        timestamp: DateTime.now(),
        isFullscreen: isFullscreen,
      ),
    );
  }

  // ---- Feature 3: Seekbar support ----

  /// Current playhead position.
  Duration get position => getCurrentPosition() ?? Duration.zero;

  /// Total media duration ([Duration.zero] when unknown / live).
  Duration get duration => getTotalDuration() ?? Duration.zero;

  /// How far the media has buffered ahead of the playhead.
  Duration get bufferedPosition => _bufferedPosition();

  /// Whether the engine is stalled waiting for data.
  bool get isBuffering =>
      _betterPlayerController?.videoPlayerController?.value.isBuffering ??
      false;

  /// A one-shot snapshot of the current playback state.
  FastPixPlaybackState get playbackState => _buildPlaybackState();

  /// Whether a scrub interaction is in progress.
  bool get isScrubbing => _scrubController.isScrubbing;

  /// Begin a scrub interaction (Feature 3). While scrubbing, [playbackStateStream]
  /// reports the scrub position rather than the live playhead.
  void beginScrub([Duration? position]) {
    _scrubController.beginScrub(position ?? this.position);
    _emitPlaybackState();
  }

  /// Update the scrub position without seeking.
  void updateScrub(Duration position) {
    _scrubController.updateScrub(position);
    _emitPlaybackState();
  }

  /// End the scrub and seek once to [position].
  Future<void> endScrub(Duration position) async {
    await _scrubController.endScrub(position);
    _emitPlaybackState();
  }

  // ---- Feature 4: Track selection ----

  /// Available quality levels, leading with [FastPixQualityLevel.automatic].
  List<FastPixQualityLevel> getQualityLevels() => _qualityManager.getLevels();

  /// The active quality level, or null before tracks are known.
  FastPixQualityLevel? getCurrentQualityLevel() => _qualityManager.current;

  /// Switch to a specific quality level.
  Future<void> setQualityLevel(FastPixQualityLevel level) =>
      _qualityManager.setLevel(level);

  /// Reset quality selection to automatic.
  Future<void> setQualityAuto() => _qualityManager.setAuto();

  /// Whether quality selection is automatic.
  bool get isQualityAuto => _qualityManager.isAuto;

  /// Available audio tracks.
  List<FastPixAudioTrack> getAudioTracks() => _audioManager.getTracks();

  /// The active audio track, or null before one is known.
  FastPixAudioTrack? getCurrentAudioTrack() => _audioManager.current;

  /// Switch to a specific audio track.
  Future<void> setAudioTrack(FastPixAudioTrack track) =>
      _audioManager.setTrack(track);

  /// Available subtitle tracks (excluding the "off" entry).
  List<FastPixSubtitleTrack> getSubtitleTracks() =>
      _subtitleManager.getTracks();

  /// The active subtitle track, or null when subtitles are off.
  FastPixSubtitleTrack? getCurrentSubtitleTrack() => _subtitleManager.current;

  /// Switch to a specific subtitle track.
  Future<void> setSubtitleTrack(FastPixSubtitleTrack track) =>
      _subtitleManager.setTrack(track);

  /// Turn subtitles off.
  Future<void> disableSubtitles() => _subtitleManager.disable();

  // ---- Feature 5: Chromecast control ----

  FastPixCastController? _cast;

  /// The attached cast controller, or null when none has been attached.
  ///
  /// Attach one with [attachCastController]; the app owns its lifecycle, so this
  /// controller's [dispose] never disposes it (a session is expected to outlive
  /// the player screen).
  FastPixCastController? get cast => _cast;

  /// Attach a [FastPixCastController] so [toggleCast]/[isCasting] and the
  /// existing handoff (`startCastingFrom`/`stopCastingTo`) can drive it from
  /// application-owned UI.
  void attachCastController(FastPixCastController controller) {
    _cast = controller;
  }

  /// Whether a cast session is active.
  bool get isCasting => _cast?.isConnected ?? false;

  /// Connect to the nearest receiver and hand playback over, or stop casting and
  /// resume locally if a session is already active. Reuses the existing
  /// handoff, so behaviour matches the built-in cast button.
  Future<void> toggleCast() async {
    final cast = _cast;
    if (cast == null) {
      _emitCustomUiError(
        'No cast controller is attached. Call attachCastController first.',
        FastPixCustomUIErrorCode.castUnavailable,
      );
      return;
    }
    if (cast.isConnected) {
      await cast.stopCastingTo(this);
      return;
    }
    final devices = cast.devices;
    if (devices.isEmpty) {
      _emitCustomUiError(
        'No Cast receiver is available to cast to.',
        FastPixCustomUIErrorCode.castUnavailable,
      );
      return;
    }
    await cast.startCastingFrom(this, devices.first);
  }

  // ---- Feature: Picture-in-Picture ----

  /// Picture-in-Picture control.
  ///
  /// Use `controller.pip.enterPip()` / `togglePip()` / `exitPip()`, and
  /// `controller.pip.isPipActive` / `isPipAvailable()`. PiP needs a
  /// [FastPixVideoSurface] mounted to anchor to on iOS, and app-side platform
  /// config (Android `supportsPictureInPicture`; iOS background-audio mode).
  FastPixPipManager get pip => _pipManager;

  // ---- Custom-UI internals ----

  Duration _bufferedPosition() {
    final ranges =
        _betterPlayerController?.videoPlayerController?.value.buffered;
    if (ranges == null || ranges.isEmpty) return Duration.zero;
    // The furthest buffered edge is what a seekbar paints as "loaded".
    return ranges.last.end;
  }

  FastPixPlaybackState _buildPlaybackState() {
    final scrubbing = _scrubController.isScrubbing;
    return FastPixPlaybackState(
      position:
          scrubbing
              ? _scrubController.scrubPosition
              : (getCurrentPosition() ?? Duration.zero),
      duration: getTotalDuration() ?? Duration.zero,
      bufferedPosition: _bufferedPosition(),
      isPlaying: isPlaying,
      isBuffering: isBuffering,
      playbackRate: _rateManager.rate,
    );
  }

  void _emitPlaybackState() {
    if (_playbackStateController.isClosed) return;
    _playbackStateController.add(_buildPlaybackState());
  }

  /// Emit the *Ready events once, the first tick after the engine has parsed
  /// each track family. Cheap: the `hasTracks` checks are list-empty tests.
  void _detectTrackReadiness() {
    if (!_qualityTracksReady && _qualityManager.hasTracks) {
      _qualityTracksReady = true;
      _eventManager.emit(
        FastPixQualityLevelsReadyEvent(
          timestamp: DateTime.now(),
          levels: _qualityManager.getLevels(),
        ),
      );
    }
    if (!_audioTracksReady && _audioManager.hasTracks) {
      _audioTracksReady = true;
      _eventManager.emit(
        FastPixAudioTracksReadyEvent(
          timestamp: DateTime.now(),
          tracks: _audioManager.getTracks(),
        ),
      );
    }
    if (!_subtitleTracksReady && _subtitleManager.hasTracks) {
      _subtitleTracksReady = true;
      _eventManager.emit(
        FastPixSubtitleTracksReadyEvent(
          timestamp: DateTime.now(),
          tracks: _subtitleManager.getTracks(),
        ),
      );
    }
  }

  /// Surface a custom-UI failure on the existing `error` channel, so an app
  /// already listening for playback errors sees it without a new transport.
  void _emitCustomUiError(String message, FastPixCustomUIErrorCode code) {
    _eventManager.emit(
      FastPixPlayerErrorEvent(
        timestamp: DateTime.now(),
        message: message,
        code: code.value,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Playlist (additive)
  //
  // The controller owns the sequence: which item is active, how the viewer
  // moves between items, what happens when one finishes, and what is warmed
  // ahead of them. A host that plays a single video is unaffected — every
  // setting here defaults to the behaviour that existed before.
  // -------------------------------------------------------------------------

  /// The cursor. Engine-free, and the only thing that knows what is playing.
  final FastPixPlaylistManager _playlist = FastPixPlaylistManager();

  late final FastPixSkipManager _skipManager = FastPixSkipManager(
    _eventManager,
  );

  final StreamController<FastPixPlaylistState> _playlistStateController =
      StreamController<FastPixPlaylistState>.broadcast();

  /// Configuration used for every item after the first, so a playlist advance
  /// derives the same preload fingerprint as the load that preceded it.
  FastPixPlayerConfiguration? _playlistConfiguration;

  /// Whether reaching the end of an item moves to the next one.
  ///
  /// Off by default, so single-source behaviour is unchanged.
  bool autoPlayNext = false;

  /// What happens when an item finishes.
  ///
  /// Independent of [FastPixPlayerDataSource.loop], which continues to mean
  /// that one source repeats indefinitely at the engine.
  FastPixPlaylistRepeatMode repeatMode = FastPixPlaylistRepeatMode.off;

  /// How many items either side of the active one the SDK warms after a load.
  ///
  /// Set to `0` to declare nothing and leave warming entirely to the host.
  int preloadRadius = 2;

  /// Whether a playlist is set.
  bool get hasPlaylist => _playlist.count > 0;

  /// How many items the playlist holds.
  int get playlistCount => _playlist.count;

  /// Position of the active item, or `-1` when the playlist is on no item —
  /// which is what loading a source outside the playlist leaves behind.
  int get currentPlaylistIndex => _playlist.currentIndex;

  /// The active item, or null when there is none.
  FastPixPlayerDataSource? get currentPlaylistItem => _playlist.currentItem;

  /// The item at [index], or null when [index] is outside the playlist.
  ///
  /// This is what lets a host draw an up-next list from the player alone: the
  /// items are the sources it supplied, with every descriptive field intact.
  FastPixPlayerDataSource? playlistItemAt(int index) => _playlist.itemAt(index);

  /// Whether a later item exists to move to.
  bool get canGoNext => _playlist.canGoNext;

  /// Whether an earlier item exists to move to.
  bool get canGoPrevious => _playlist.canGoPrevious;

  /// A snapshot of where the playlist is.
  FastPixPlaylistState get playlistState => _playlist.state;

  /// Playlist position, published on every change of the active item.
  ///
  /// Broadcast and non-replaying, like [playbackStateStream]: seed a
  /// `StreamBuilder` with [playlistState] so it is not blank until the first
  /// change. Closed when the controller is disposed.
  Stream<FastPixPlaylistState> get playlistStateStream =>
      _playlistStateController.stream;

  /// Play an ordered list of sources.
  ///
  /// The items are [FastPixPlayerDataSource]s — the same type [initialize]
  /// takes — so an item can express everything a directly prepared source can:
  /// DRM, resolution caps, subtitles, buffering, skip segments.
  ///
  /// Rejects an empty list, an entry without a playback ID, and a [startIndex]
  /// outside the list, by throwing [FastPixPlaylistException] and emitting the
  /// failure as an error event. A rejected playlist changes nothing: no
  /// playlist is adopted, no source is switched, and playback continues.
  ///
  /// Supplying a playlist while an item is playing preserves that playback
  /// when the item is still present in the new list — appending to or
  /// reordering a playlist should not restart a video the viewer is part-way
  /// through.
  Future<void> setPlaylist(
    List<FastPixPlayerDataSource> items, {
    int startIndex = 0,
    FastPixPlayerConfiguration? configuration,
  }) async {
    _validatePlaylist(items, startIndex);

    // Wait for a load that is already in flight before deciding whether the
    // playing item is in this list.
    //
    // `initialize()` is routinely called without `await` — it is a
    // fire-and-forget call from `initState` — and until it completes there is
    // no engine player and no current source. Deciding here would then read
    // "nothing is playing" and load item 0, which is a second manifest fetch,
    // a second DRM licence and a second adoption attempt for the very video
    // that is already loading. The wait costs nothing when nothing is in
    // flight, and a failed load must not stop the playlist being set.
    final inFlight = _loadInFlight;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {}
      if (_disposed) return;
    }

    _playlistConfiguration =
        configuration ?? _playlistConfiguration ?? _configuration;

    // Keep playing if the playing item is still in the list, wherever it has
    // moved to. Matching on playback ID keeps the rule simple and observable.
    final playingId = _dataSource?.playbackId;
    final keptIndex =
        playingId == null || _betterPlayerController == null
            ? -1
            : items.indexWhere((item) => item.playbackId == playingId);

    _playlist.setItems(items, startIndex: keptIndex >= 0 ? keptIndex : -1);
    _emitPlaylistChanged();

    if (keptIndex >= 0) {
      _publishPlaylistState();
      _declareWarmWindow();
      return;
    }

    await _loadItem(startIndex, FastPixPlaylistItemChangeReason.initial);
  }

  /// Play a playlist supplied as JSON.
  ///
  /// Accepts a top-level array of objects, or an object carrying that array
  /// under an `items` key. Each entry needs a non-empty `playbackId`;
  /// everything else is optional and unknown keys are ignored, so a producer
  /// can add fields without breaking integrations already in the field. See
  /// [FastPixPlayerDataSource.fromJson] for the shape of one entry.
  ///
  /// The decoded JSON is not retained: it is converted to sources and the
  /// playlist proceeds exactly as the list form does.
  Future<void> setPlaylistFromJson(
    String json, {
    int startIndex = 0,
    FastPixPlayerConfiguration? configuration,
  }) async {
    // Async so a parse failure arrives the same way a validation failure does
    // — as a rejected future — rather than as a synchronous throw the caller
    // has to guard separately.
    return setPlaylist(
      _parsePlaylistJson(json),
      startIndex: startIndex,
      configuration: configuration,
    );
  }

  /// Drop the playlist.
  ///
  /// The current item keeps playing — clearing a playlist is not a reason to
  /// stop a video — and navigation is no longer available.
  void clearPlaylist() {
    if (!hasPlaylist) return;
    _playlist.clear();
    _emitPlaylistChanged();
    _publishPlaylistState();
  }

  /// Move to the next item, reporting whether the position moved.
  ///
  /// Movement that cannot be performed — past the end, with no playlist —
  /// reports `false`, raises nothing and leaves playback alone.
  Future<bool> next() => jumpTo(_playlist.currentIndex + 1);

  /// Move to the previous item, reporting whether the position moved.
  Future<bool> previous() => jumpTo(_playlist.currentIndex - 1);

  /// Move to [index], reporting whether the position moved.
  ///
  /// An out-of-range index, or the index already playing, reports `false`
  /// without restarting anything.
  Future<bool> jumpTo(int index) async {
    if (_disposed) return false;
    if (index < 0 || index >= _playlist.count) return false;
    if (index == _playlist.currentIndex) return false;
    await _loadItem(index, FastPixPlaylistItemChangeReason.userJump);
    return true;
  }

  /// Play [source] on this controller, replacing what is playing.
  ///
  /// When the source is one of the playlist's items, the active index moves to
  /// it and navigation continues from there. When it is not, it plays and the
  /// playlist reports no active position until navigation or a new playlist.
  Future<void> loadPlaybackId(FastPixPlayerDataSource source) async {
    if (_disposed) return;
    final index = _playlist.indexOfPlaybackId(source.playbackId);
    final previousIndex = _playlist.currentIndex;
    _playlist.repointTo(index);
    if (index >= 0 && index != previousIndex) {
      _emitItemChanged(
        index,
        previousIndex,
        FastPixPlaylistItemChangeReason.userJump,
      );
    }
    _publishPlaylistState();
    await _loadSource(
      source,
      configuration: _playlistConfiguration ?? _configuration,
    );
    if (_disposed) return;
    _declareWarmWindow();
  }

  /// The segment playback is currently inside, or null.
  FastPixSkipSegment? get activeSkipSegment => _skipManager.activeSegment;

  /// Jump to the end of the active skip segment.
  ///
  /// Reports `true` when playback moved. With no segment active, or while the
  /// player cannot seek, a typed skip failure is emitted and playback is left
  /// exactly as it was.
  Future<bool> skipCurrentSegment() async {
    // Seekability is checked first, and deliberately: with no player, or none
    // that knows its duration, the engine's own seek throws rather than
    // returning, and "the player cannot seek yet" is the more actionable of
    // the two answers.
    final duration = getTotalDuration();
    if (_betterPlayerController == null ||
        duration == null ||
        duration <= Duration.zero) {
      _skipManager.reportFailure(
        FastPixSkipFailureReason.seekUnavailable,
        'The player cannot seek yet, so nothing can be skipped.',
        segment: _skipManager.activeSegment,
      );
      return false;
    }
    final segment = _skipManager.activeSegment;
    if (segment == null) {
      _skipManager.reportFailure(
        FastPixSkipFailureReason.noActiveSegment,
        'No skip segment is active at the current position.',
      );
      return false;
    }
    await seekTo(segment.end);
    _skipManager.notifySkipped(segment);
    return true;
  }

  // ---- Playlist internals ----

  /// Reject a playlist that cannot be played, naming what is wrong.
  ///
  /// Rejection rather than silence: an empty or malformed playlist almost
  /// always means the caller's own fetch or filter returned nothing, and the
  /// failure mode of silence is a blank player with no diagnostic.
  void _validatePlaylist(List<FastPixPlayerDataSource> items, int startIndex) {
    if (items.isEmpty) {
      throw _rejectPlaylist(
        const FastPixPlaylistException(
          FastPixPlaylistErrorCode.emptyPlaylist,
          'A playlist needs at least one item.',
        ),
      );
    }
    for (var index = 0; index < items.length; index++) {
      if (items[index].playbackId.isEmpty) {
        throw _rejectPlaylist(
          FastPixPlaylistException(
            FastPixPlaylistErrorCode.missingPlaybackId,
            'Every playlist item needs a non-empty playback ID.',
            itemIndex: index,
          ),
        );
      }
    }
    if (startIndex < 0 || startIndex >= items.length) {
      throw _rejectPlaylist(
        FastPixPlaylistException(
          FastPixPlaylistErrorCode.startIndexOutOfRange,
          'Start index $startIndex is outside a playlist of '
          '${items.length} items.',
        ),
      );
    }
  }

  /// Report a rejected playlist on the error channel, and hand the exception
  /// back to be thrown. The caller sees both, which is the point: the throw is
  /// for the code path, the event for whatever is listening.
  FastPixPlaylistException _rejectPlaylist(FastPixPlaylistException failure) {
    _eventManager.emit(
      FastPixPlayerErrorEvent(
        timestamp: DateTime.now(),
        message: failure.message,
        code: failure.code.value,
      ),
    );
    return failure;
  }

  List<FastPixPlayerDataSource> _parsePlaylistJson(String json) {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (error) {
      throw _rejectPlaylist(
        FastPixPlaylistException(
          FastPixPlaylistErrorCode.malformedJson,
          'The playlist JSON could not be parsed: ${error.message}',
        ),
      );
    }

    final List<dynamic> entries;
    if (decoded is List) {
      entries = decoded;
    } else if (decoded is Map && decoded['items'] is List) {
      entries = decoded['items'] as List<dynamic>;
    } else {
      throw _rejectPlaylist(
        const FastPixPlaylistException(
          FastPixPlaylistErrorCode.malformedJson,
          'Playlist JSON must be an array of items, or an object with an '
          '"items" array.',
        ),
      );
    }

    final items = <FastPixPlayerDataSource>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      if (entry is! Map) {
        throw _rejectPlaylist(
          FastPixPlaylistException(
            FastPixPlaylistErrorCode.malformedEntry,
            'Every playlist entry must be an object.',
            itemIndex: index,
          ),
        );
      }
      try {
        items.add(
          FastPixPlayerDataSource.fromJson(
            Map<String, dynamic>.from(entry),
            itemIndex: index,
          ),
        );
      } on FastPixPlaylistException catch (failure) {
        throw _rejectPlaylist(failure);
      }
    }
    return items;
  }

  /// Move the active item to [index] and load it.
  ///
  /// The cursor moves *before* the load, so every event the load raises is
  /// already attributed to the item it belongs to, and a host's highlight
  /// follows the tap rather than the buffering.
  Future<void> _loadItem(
    int index,
    FastPixPlaylistItemChangeReason reason,
  ) async {
    final item = _playlist.itemAt(index);
    if (item == null || _disposed) return;

    final previousIndex = _playlist.currentIndex;
    _playlist.repointTo(index);
    _emitItemChanged(index, previousIndex, reason);
    _publishPlaylistState();

    try {
      await _loadSource(
        item,
        configuration: _playlistConfiguration ?? _configuration,
      );
    } on FastPixDrmException {
      // Already emitted on the error channel, carrying this item's playback ID
      // and index. The playlist stops here rather than skipping onward: a list
      // of expired tokens would otherwise walk itself to the end in seconds,
      // showing a black screen, which from the viewer's side is
      // indistinguishable from a playlist that never worked.
      return;
    }
    if (_disposed) return;
    _declareWarmWindow();
  }

  /// Declare the items around the active one to the preload manager.
  ///
  /// Called only *after* a load has completed. Declaring before it would evict
  /// the very entry the load is about to adopt — the warm thrown away
  /// microseconds before it would have paid off, which measured on device as
  /// nine completed warm-ups and not one warm start.
  void _declareWarmWindow() {
    if (_disposed || preloadRadius <= 0 || !hasPlaylist) return;
    final upcoming = _playlist.warmWindow(radius: preloadRadius);
    if (upcoming.isEmpty) return;
    unawaited(
      FastPixPreloadManager.instance.preload(
        upcoming,
        // Must match what the load passes, or adoption is refused on a
        // fingerprint mismatch — silently, and it looks like a cold start.
        configuration: _playlistConfiguration ?? _configuration,
        // A playlist is the one place a full player warm is worth a hardware
        // decoder: the dwell is the whole of the current video. The manager
        // clamps the window to what the device can hold.
        strategy: FastPixPreloadStrategy.player,
        window: upcoming.length,
      ),
    );
  }

  /// Decide what a finished item leads to.
  ///
  /// Ordered by precedence: repeat-one replays whatever the other settings
  /// say; a live Cast session suppresses local advance, since the local player
  /// is not the surface the viewer is watching; autoplay-next advances; and
  /// repeat-all wraps only because it is a rule about automatic advancing.
  void _handlePlaylistCompletion() {
    if (_disposed) return;

    if (repeatMode == FastPixPlaylistRepeatMode.one) {
      unawaited(_repeatCurrentItem());
      return;
    }
    if (!hasPlaylist || _playlist.currentIndex < 0) return;
    if (isCasting) return;
    if (!autoPlayNext) return;

    if (_playlist.canGoNext) {
      unawaited(
        _loadItem(
          _playlist.currentIndex + 1,
          FastPixPlaylistItemChangeReason.autoAdvance,
        ),
      );
      return;
    }
    if (repeatMode == FastPixPlaylistRepeatMode.all) {
      unawaited(_loadItem(0, FastPixPlaylistItemChangeReason.repeat));
      return;
    }
    _eventManager.emit(
      FastPixPlaylistEndedEvent(
        timestamp: DateTime.now(),
        count: _playlist.count,
      ),
    );
  }

  /// Replay the active item from its start.
  ///
  /// A seek rather than the engine's looping flag, so there is one mechanism
  /// for "replay" instead of two and the emitted sequence stays honest — an
  /// engine-level loop either suppresses completion, so analytics see one
  /// endless view, or re-fires it, which makes the completion de-duplication
  /// load-bearing in a way it was not designed for. Per-source
  /// [FastPixPlayerDataSource.loop] still drives the engine flag and is
  /// untouched.
  Future<void> _repeatCurrentItem() async {
    if (_disposed || _betterPlayerController == null) return;
    _isEndedCalled = false;
    _lastEndedAt = null;
    await seekTo(Duration.zero);
    if (_disposed) return;
    await play();
  }

  void _emitPlaylistChanged() {
    _eventManager.emit(
      FastPixPlaylistChangedEvent(
        timestamp: DateTime.now(),
        count: _playlist.count,
        currentIndex: _playlist.currentIndex,
      ),
    );
  }

  void _emitItemChanged(
    int index,
    int previousIndex,
    FastPixPlaylistItemChangeReason reason,
  ) {
    final item = _playlist.itemAt(index);
    if (item == null || index == previousIndex) return;
    _eventManager.emit(
      FastPixPlaylistItemChangedEvent(
        timestamp: DateTime.now(),
        index: index,
        previousIndex: previousIndex,
        playbackId: item.playbackId,
        reason: reason,
      ),
    );
  }

  void _publishPlaylistState() {
    if (_playlistStateController.isClosed) return;
    _playlistStateController.add(_playlist.state);
  }

  /// Which item every emitted event describes.
  ///
  /// Attached at the single emission point rather than at each of the several
  /// dozen construction sites — including the managers', which hold no
  /// playlist of their own. Without it, "pause" and "error" in a playlist's
  /// event log cannot be attributed to a video.
  Map<String, dynamic>? _eventAttribution() {
    final playbackId = _dataSource?.playbackId;
    if (playbackId == null) return null;
    final index = _playlist.currentIndex;
    return <String, dynamic>{
      'playbackId': playbackId,
      if (hasPlaylist && index >= 0) 'playlistIndex': index,
    };
  }

  /// Get the current player state
  FastPixPlayerState get currentState => _currentState;

  /// Get the underlying BetterPlayerController
  BetterPlayerController? get betterPlayerController => _betterPlayerController;

  /// Get the current data source
  FastPixPlayerDataSource? get dataSource => _dataSource;

  /// Null until [initialize] has built it. It stays null when initialization
  /// fails early — an invalid DRM setup rejects the source before metrics
  /// exist — so every use has to tolerate its absence: a controller must be
  /// disposable whether or not it was ever successfully initialized.
  FastPixMetrics? _fastPixMetrics;
  ErrorModel? _errorModel;
  FastPixDrmException? _lastDrmError;
  FastPixPlayerErrorEvent? _lastError;

  /// Most recent DRM failure, or `null` when DRM playback has not failed.
  ///
  /// Cleared by [reset].
  FastPixDrmException? get lastDrmError => _lastDrmError;

  /// Most recent playback error of any kind, DRM or not.
  ///
  /// Retained so a widget that mounts after the failure can still render it.
  /// Cleared by [reset].
  FastPixPlayerErrorEvent? get lastError => _lastError;

  /// Initialize the controller with data source and configuration
  ///
  /// When [FastPixPreloadManager] holds a player warmed for [dataSource] under
  /// a matching configuration, it is adopted and playback starts without the
  /// manifest round trip, the DRM licence acquisition or decoder setup. That
  /// is an optimisation and never a precondition: if no warm player is
  /// available, or it was warmed for different settings, this takes exactly
  /// the path it always has.
  Future<void> initialize({
    required FastPixPlayerDataSource dataSource,
    FastPixPlayerConfiguration? configuration,

    /// Whether a player warmed by [FastPixPreloadManager] may be adopted.
    ///
    /// Set false to force a cold start — when measuring baseline startup
    /// latency, for example, since an adopted player reports a near-zero
    /// time-to-first-frame and would otherwise pollute the comparison.
    bool adoptPreloaded = true,
  }) async {
    // Re-initialising a controller the host disposed is a deliberate,
    // supported path, so this is the one place the flag is cleared.
    //
    // It stays here rather than moving into [_loadSource] with the rest of the
    // per-source work. A source change — an automatic playlist advance, a
    // switch queued behind one — must never revive a controller the host has
    // already thrown away: such a controller would build an engine player
    // nothing will ever release, and start accepting events again, while
    // looking entirely correct from the outside.
    _disposed = false;
    await _loadSource(
      dataSource,
      configuration: configuration,
      adoptPreloaded: adoptPreloaded,
    );
  }

  /// The load currently in flight, whether or not anyone is still awaiting it.
  ///
  /// Source changes are serialised through this: the engine swap is
  /// asynchronous, and a playlist UI generates rapid repeat taps. Two
  /// overlapping loads can leave an orphaned engine player alive — the leak
  /// this path exists to fix, reintroduced by a different route.
  Future<void>? _loadInFlight;

  /// Incremented per request so a superseded load can stand down. The last
  /// request wins: intermediate ones are skipped rather than played briefly.
  int _loadRequestId = 0;

  /// Number of sources this controller has loaded.
  ///
  /// Exposed as a listenable so a mounted view can re-read
  /// [betterPlayerController] when the source changes, rather than latching the
  /// engine player it saw at mount and rendering one that has been released.
  ValueListenable<int> get sourceGeneration => _sourceGeneration;
  final ValueNotifier<int> _sourceGeneration = ValueNotifier<int>(0);

  /// Replace the playing source, on the same controller.
  ///
  /// The one path both first initialization and every later source change take,
  /// so per-source correctness cannot diverge between them: the outgoing engine
  /// player is released, every piece of per-source state is reset, the metrics
  /// session is recycled, and the analytics event sequence is reopened.
  Future<void> _loadSource(
    FastPixPlayerDataSource dataSource, {
    FastPixPlayerConfiguration? configuration,
    bool adoptPreloaded = true,
  }) {
    final int request = ++_loadRequestId;
    final Future<void>? previous = _loadInFlight;

    final Future<void> load = () async {
      if (previous != null) {
        // A failed load must not stop the one queued behind it.
        try {
          await previous;
        } catch (_) {}
      }
      // Disposal during the wait, or a newer request having arrived, both mean
      // this load has nothing left to do.
      if (_disposed) return;
      if (request != _loadRequestId) return;
      await _performLoad(
        dataSource,
        configuration: configuration,
        adoptPreloaded: adoptPreloaded,
      );
    }();

    _loadInFlight = load;
    return load;
  }

  Future<void> _performLoad(
    FastPixPlayerDataSource dataSource, {
    FastPixPlayerConfiguration? configuration,
    bool adoptPreloaded = true,
  }) async {
    // Started before any work so the measurement covers the whole load,
    // including the DRM validation and the adoption attempt.
    _playStartClock = Stopwatch()..start();
    _firstFrameReported = false;

    // Fail fast on an unusable DRM setup: the exception carries an actionable
    // message and is also emitted as an error event so listeners see it.
    //
    // Checked before anything is torn down, so a source that cannot play never
    // costs the viewer the source that is playing.
    if (dataSource.drmEnabled) {
      try {
        dataSource.drmConfiguration!.validate(
          playbackId: dataSource.playbackId,
          hasPlaybackToken: dataSource.token?.isNotEmpty == true,
        );
      } on FastPixDrmException catch (exception) {
        _handleDrmException(exception);
        rethrow;
      }
    }

    // The outgoing player goes before the replacement is built, so at most one
    // engine player — and one decoder, and one MediaDrm session — is ever held.
    _releaseEngine();

    // Nothing from the previous source may leak into this one.
    _resetForNewSource();

    // Held pending until this source's duration is known, then validated once
    // against it — never against the previous item's.
    _skipManager.setSegments(dataSource.skipSegments);

    await _recycleMetricsSession(dataSource, configuration);
    // Closing the previous session yields; the host may have disposed us.
    if (_disposed) return;

    // FairPlay only, iOS only, and always before the engine builds its player:
    // the engine installs its resource-loader delegate during that build, and
    // the patch substitutes ours at that moment or not at all.
    //
    // Best effort. A false answer changes nothing here — playback proceeds on
    // the engine's own path exactly as it does without the patch.
    await FastPixFairPlayBridge.configure(dataSource);
    if (_disposed) return;

    final betterPlayerDataSource = dataSource.toBetterPlayerDataSource();
    final betterPlayerConfiguration = _createBetterPlayerConfiguration();

    // A warmed player is already past the manifest fetch, the DRM licence and
    // decoder setup, which is what makes playback start instantly. It is never
    // guaranteed to exist: the window may have moved on, the warm-up may have
    // failed or still be in flight, the source may have been warmed over the
    // network only, or it may have been warmed for a different configuration.
    // Every one of those resolves to the same thing — a normal cold start.
    //
    // The fingerprint is computed from `_configuration`, not the `configuration`
    // parameter: the two differ when the caller passes null, and using the
    // parameter would make every adoption fail to match.
    final BetterPlayerController? preloaded =
        adoptPreloaded
            ? FastPixPreloadManager.instance.consume(
              dataSource.playbackId,
              fingerprint: betterPlayerConfigurationFingerprint(
                configuration: _configuration,
                dataSource: dataSource,
              ),
            )
            : null;

    _startedFromWarmPlayer = preloaded != null;

    // After the adoption decision, never before it. An adopted player already
    // holds its licence and acquires nothing further, so counting here — where
    // the answer is known — is the difference between "one licence per play"
    // and a number that double counts every warm start.
    if (dataSource.drmEnabled) {
      final host = Uri.tryParse(
            dataSource.drmConfiguration?.resolvedBaseUrl ?? '',
          )?.host ??
          '';
      if (preloaded != null) {
        FastPixDrmLog.reused(
          playbackId: dataSource.playbackId,
          detail: 'adopted a warm player that already holds its licence',
        );
      } else {
        FastPixDrmLog.armed(
          playbackId: dataSource.playbackId,
          reason: FastPixDrmLog.reasonPlayback,
          host: host,
        );
      }
    }
    final BetterPlayerController player =
        preloaded ??
        BetterPlayerController(
          betterPlayerConfiguration,
          betterPlayerDataSource: betterPlayerDataSource,
        );

    // Disposal can have landed between the guard above and here — the engine
    // constructor runs synchronously but adoption does not. A player built for
    // a controller that is gone would be held by nothing and released by
    // nobody, so it goes straight back.
    if (_disposed) {
      player.dispose(forceDispose: true);
      return;
    }

    _betterPlayerController = player;
    if (preloaded != null) {
      _adoptPreloadedController(preloaded, betterPlayerConfiguration);
    }

    // Both branches above replaced the player, so any fullscreen overlay the
    // host registered is still pointing at the previous one.
    _rebindFullscreenOverlay();
    _setupEventListeners();
    _lifecycleManager.attach();
    // Hold the playback audio category from the start of every source, not
    // only when PiP opens, and through our own plugin rather than the engine's
    // per-player `setMixWithOthers` — which answers with a
    // MissingPluginException when called before the platform player is
    // registered, as it is here. See [FastPixAudioSession].
    unawaited(_pipManager.applyAudioSession());
    await _applySecureScreen(dataSource);
    _currentState = FastPixPlayerState.ready;

    // Last, so anything that re-reads the controller on this signal — a mounted
    // view rebinding to the new engine player — sees a fully built source.
    _sourceGeneration.value++;
    _eventManager.emit(FastPixPlayerReadyEvent(timestamp: DateTime.now()));
  }

  /// Release the engine player this controller holds, if any.
  ///
  /// `forceDispose` is required, not defensive: a player adopted from
  /// [FastPixPreloadManager] was built with `autoDispose: false`, so an
  /// ordinary `dispose()` on it returns immediately and releases nothing —
  /// leaking its decoder, and its MediaDrm session for protected content.
  void _releaseEngine() {
    final player = _betterPlayerController;
    if (player == null) return;
    // The listeners have to come off before the player goes away, or they keep
    // delivering events into a disposed engine controller.
    player.removeEventsListener(_onPlayerEvent);
    // The overlay is registered against the player, not against this
    // controller, so it has to be released with it.
    fastPixFullscreenOverlays[player] = null;
    player.dispose(forceDispose: true);
    _betterPlayerController = null;
  }

  /// Everything that describes the source being replaced, cleared in one place.
  ///
  /// Shared by first initialization and every later source change, because the
  /// list is exactly what is easy to get wrong: a second code path would have
  /// to re-derive all of it, and the analytics entry below fails silently.
  void _resetForNewSource() {
    // A new source is a new attempt: nothing from the previous one may leak
    // into it, or a retry with corrected credentials keeps reporting the old
    // failure.
    _lastError = null;
    _lastDrmError = null;
    _errorModel = null;
    _isEndedCalled = false;
    _lastEndedAt = null;
    _lastSeekAt = null;
    // A different video has different intrinsic dimensions.
    _lastVideoSourceWidth = 0;
    _lastVideoSourceHeight = 0;

    // The analytics fix, and the reason this list is shared.
    //
    // `validTransitions` terminates the sequence at `ended` and at `error`. A
    // source change that does not reopen it leaves every later event refused
    // by [_tryDispatch]: the video plays perfectly and reports nothing, with no
    // exception and no log. One line, and it looks like bookkeeping.
    _lastDispatchedEvent = null;

    // Segments belong to the source that declared them, so the previous
    // source's are dropped and any control on screen is hidden before the new
    // source's are installed.
    _skipManager.resetForNewSource();

    // Custom-UI state is per-source: a new source starts at normal speed, with
    // no scrub in flight and its track-ready signals not yet fired.
    _rateManager.resetForNewSource();
    _scrubController.resetForNewSource();
    _qualityManager.resetForNewSource();
    _pipManager.resetForNewSource();
    _lastPipVideoSize = null;
    _lifecycleManager.resetForNewSource();
    // A new source cannot be mid-churn, and must not inherit a settle timer
    // that would dispatch the previous source's transport state.
    _transportSettleTimer?.cancel();
    _transportSettleTimer = null;
    _lastTransportAt = null;
    _lastTransportKind = null;
    _transportFlipStreak = 0;
    _qualityTracksReady = false;
    _audioTracksReady = false;
    _subtitleTracksReady = false;
  }

  /// Close the previous source's metrics session and open one for [dataSource].
  ///
  /// Each source is an independent playback session, so measurements for one
  /// are never attributed to another. A teardown failure is swallowed: a beacon
  /// flush that throws on its way out must not stop the next source loading.
  Future<void> _recycleMetricsSession(
    FastPixPlayerDataSource dataSource,
    FastPixPlayerConfiguration? configuration,
  ) async {
    final previous = _fastPixMetrics;
    _fastPixMetrics = null;
    if (previous != null) {
      try {
        await previous.dispose(true);
      } catch (_) {}
    }

    final workspaceId = configuration?.workSpaceId;
    final beaconUrl = configuration?.beaconUrl;
    final viewerId = configuration?.viewerId;
    final video = dataSource.videoData;
    final customData = dataSource.customData;

    _dataSource = dataSource;
    _configuration =
        configuration ??
        FastPixPlayerConfiguration(
          workspaceId ?? '',
          viewerId ?? '',
          beaconUrl ?? '',
        );

    _fastPixMetrics =
        FastPixMetricsBuilder()
            .setPlayerObserver(this)
            .setMetricsConfiguration(
              MetricsConfiguration(
                workspaceId: workspaceId,
                beaconUrl: beaconUrl,
                viewerId: viewerId,
                videoData: VideoData(
                  video?.title ?? na,
                  video?.videoId ?? na,
                  dataSource.url,
                  video?.thumbnailUrl ?? na,
                ),
                // Kept in step with `version:` in pubspec.yaml by hand — the two are
                // reported separately and drift silently.
                playerData: PlayerData("fastpix-player", "1.1.0"),
                customData:
                    customData
                        ?.map((element) => CustomData(value: element))
                        .toList(),
              ),
            )
            .build();
  }

  /// Wall clock from [initialize] to the first frame actually rendered.
  ///
  /// Started at `initialize()` rather than at widget mount, because mount
  /// happens after the work being measured and would flatter every number.
  Stopwatch? _playStartClock;

  /// Whether the player in use came from [FastPixPreloadManager].
  ///
  /// Reported alongside the timing, because a warm start and a cold start are
  /// not comparable numbers and averaging them together hides the entire
  /// effect being measured.
  bool _startedFromWarmPlayer = false;

  bool _firstFrameReported = false;

  /// Log the tap-to-first-frame time, once per source.
  ///
  /// Fired from the progress tick because that is the first signal that media
  /// is genuinely advancing — `initialized` only says the player accepted the
  /// source, which on an adopted player already happened during the warm.
  void _reportFirstFrameOnce() {
    if (_firstFrameReported) return;
    final clock = _playStartClock;
    if (clock == null) return;

    final position =
        _betterPlayerController?.videoPlayerController?.value.position;
    // A progress tick at position zero is the player reporting for duty, not a
    // rendered frame.
    if (position == null || position <= Duration.zero) return;

    _firstFrameReported = true;
    clock.stop();

    final drm = _dataSource?.drmEnabled ?? false;
    FastPixWarmLog.preload(
      'FIRST FRAME in ${clock.elapsedMilliseconds}ms  '
      'drm=$drm  start=${_startedFromWarmPlayer ? "WARM (adopted)" : "COLD"}',
      playbackId: _dataSource?.playbackId,
    );
  }

  /// Whether this controller turned FLAG_SECURE on.
  ///
  /// Tracked so [dispose] only clears a flag this controller set. Clearing it
  /// unconditionally would re-enable screenshots for a host app that had set
  /// the flag itself for its own reasons.
  bool _secureScreenApplied = false;

  /// Block screenshots and screen recording for DRM playback.
  ///
  /// Android only. The flag belongs to the Activity window, so it covers the
  /// whole app while playback lasts — see
  /// [FastPixPlayerDrmConfiguration.secureScreen], which turns this off.
  ///
  /// Best effort: a window flag that cannot be set is not a reason to fail
  /// playback that is otherwise ready, so failures are reported as an event
  /// rather than thrown.
  Future<void> _applySecureScreen(FastPixPlayerDataSource dataSource) async {
    if (!Platform.isAndroid) return;

    // A source that does not want the flag *clears* it, rather than returning
    // and leaving whatever the previous source set.
    //
    // This runs on every source change, and one controller now plays many
    // sources in place — a playlist advance, or the demo's up-next rail. So
    // DRM followed by clear content used to leave the window flagged for the
    // rest of the session: screenshots stayed blocked across the whole app,
    // for videos that never needed it, with only disposal to undo it. Nothing
    // errors, nothing logs, and the flag is invisible until someone tries to
    // take a screenshot.
    final wantsSecureScreen = dataSource.drmEnabled &&
        dataSource.drmConfiguration?.secureScreen == true;
    if (!wantsSecureScreen) {
      await _clearSecureScreen();
      return;
    }

    // Already on, from the previous source. Setting it twice is harmless, but
    // the flag is the Activity's and a redundant platform call on every
    // playlist advance is not.
    if (_secureScreenApplied) return;

    try {
      await FlutterWindowManagerPlus.addFlags(
        FlutterWindowManagerPlus.FLAG_SECURE,
      );
      _secureScreenApplied = true;
    } catch (error) {
      _eventManager.emit(
        FastPixPlayerErrorEvent(
          timestamp: DateTime.now(),
          message: 'Could not block screen capture for this DRM stream: $error',
        ),
      );
    }
  }

  /// Release FLAG_SECURE if this controller set it.
  Future<void> _clearSecureScreen() async {
    if (!_secureScreenApplied) return;
    _secureScreenApplied = false;
    try {
      await FlutterWindowManagerPlus.clearFlags(
        FlutterWindowManagerPlus.FLAG_SECURE,
      );
    } catch (_) {
      // Leaving the flag set is safer than throwing while tearing down: the
      // host app can still clear it, and playback is already finished.
    }
  }

  /// Bring an adopted player up to playback settings.
  ///
  /// Only these two can be applied after the fact. Everything else —
  /// controls, `fit`, aspect ratio, screen sleep — was already applied at warm
  /// time through [buildBetterPlayerConfiguration], because
  /// [BetterPlayerController.betterPlayerConfiguration] is a final field and
  /// cannot be replaced now. That is what the fingerprint check in
  /// [FastPixPreloadManager.consume] exists to guarantee.
  void _adoptPreloadedController(
    BetterPlayerController controller,
    BetterPlayerConfiguration configuration,
  ) {
    unawaited(controller.setLooping(_dataSource?.loop ?? false));
    if (configuration.autoPlay) unawaited(controller.play());
  }

  /// Wraps the player on the way into the fullscreen route.
  ///
  /// Fullscreen is a separate route that better_player builds itself, holding
  /// nothing but the player: anything stacked over the player by the host —
  /// the cast button, for one — lives in the page tree left behind, so it
  /// cannot follow. This hook is the way back in. Set by [FastPixPlayer] while
  /// it is mounted and cleared when it goes.
  ///
  /// Stored against the underlying player rather than in a plain field,
  /// because the route builder baked into the configuration is a top-level
  /// function — see [fastPixFullscreenOverlays]. That indirection is what lets
  /// an adopted, preloaded player still show the overlay: its configuration
  /// was fixed at warm time, long before this controller existed.
  Widget Function(Widget player)? get fullscreenOverlayBuilder =>
      _fullscreenOverlayBuilder;

  set fullscreenOverlayBuilder(Widget Function(Widget player)? builder) {
    _fullscreenOverlayBuilder = builder;
    final player = _betterPlayerController;
    if (player != null) fastPixFullscreenOverlays[player] = builder;
  }

  Widget Function(Widget player)? _fullscreenOverlayBuilder;

  /// Re-point the overlay at whichever player this controller now owns.
  ///
  /// Needed because adoption swaps the underlying player after the host has
  /// already handed over its builder: without this the overlay would stay
  /// registered against a player that has been discarded, and fullscreen on a
  /// warm start would come up bare.
  void _rebindFullscreenOverlay() {
    final player = _betterPlayerController;
    final builder = _fullscreenOverlayBuilder;
    if (player != null && builder != null) {
      fastPixFullscreenOverlays[player] = builder;
    }
  }

  /// Create BetterPlayerConfiguration from FastPix configuration
  ///
  /// Delegates to [buildBetterPlayerConfiguration]. The builder lives in
  /// `utils/fastpix_better_player_configuration.dart` so that the preload path
  /// can construct a *warmed* controller with exactly these settings:
  /// [BetterPlayerController.betterPlayerConfiguration] is a final field, so a
  /// player warmed with different settings keeps them for its entire life and
  /// nothing at adoption time can correct it. One builder, both paths.
  BetterPlayerConfiguration _createBetterPlayerConfiguration() =>
      buildBetterPlayerConfiguration(
        configuration: _configuration,
        dataSource: _dataSource,
      );

  /// Setup event listeners
  ///
  /// One handler for every platform. There used to be two — `_onPlayerEvent`
  /// and an `_oniOSPlayerEvent` that differed by eight lines of seek debounce
  /// inside eighty-five otherwise identical ones. Two copies of a `switch` is
  /// two places to change, and the platforms drift the first time only one of
  /// them is edited; the debounce is now a guard inside the single `seekTo`
  /// case instead.
  void _setupEventListeners() {
    _betterPlayerController?.addEventsListener(_onPlayerEvent);
  }

  // Player dimensions
  double _playerWidth = 0.0;
  double _playerHeight = 0.0;

  /// Last non-zero intrinsic size reported by the platform player.
  ///
  /// The metrics SDK divides the player size by the video size to work out
  /// view scaling, with no guard against a zero denominator: a zero here
  /// produces Infinity or NaN and its `toInt()` throws on every pulse event.
  ///
  /// The platform player reports a zero size whenever its render surface is
  /// gone — which is exactly what happens while casting, since the local
  /// player is removed from the widget tree. The intrinsic size of the video
  /// has not actually changed at that point, so the last known value is the
  /// truthful answer and zero is the lie.
  int _lastVideoSourceWidth = 0;
  int _lastVideoSourceHeight = 0;

  PlayerEvent? _lastDispatchedEvent;
  bool _isEndedCalled = false;
  DateTime? _lastEndedAt;

  /// Set by [dispose] so an event still in flight cannot reach the platform
  /// player after it has been torn down.
  bool _disposed = false;

  void _tryDispatch(
    PlayerEvent next,
    Function eventBuilder, {
    BetterPlayerEvent? event,
    ErrorModel? errorModel,
  }) {
    final allowed = validTransitions[_lastDispatchedEvent] ?? {};
    // Errors must never be swallowed by the transition table: a failure can
    // arrive in any state (a DRM license rejection typically lands right after
    // `play` or `buffered`, neither of which lists `error` as a transition).
    final isAllowed =
        allowed.contains(next) ||
        (next == PlayerEvent.error &&
            _lastDispatchedEvent != PlayerEvent.error);
    // Invalid transitions are ignored.
    if (!isAllowed) return;

    if (_lastDispatchedEvent == PlayerEvent.ended && next == PlayerEvent.play) {
      return;
    }
    if (next == PlayerEvent.variantChanged) {
      _handleChangedTrackEvent(event!);
      return;
    }
    if (next == PlayerEvent.error) {
      // Metrics read the error through getPlayerError() while dispatching,
      // so it has to be set before dispatchEvent below.
      _errorModel =
          errorModel ??
          ErrorModel(
            event?.parameters?['exception'] ?? _unknownErrorMessage,
            event?.parameters?['source'] ?? '503',
          );
    }
    _emitDispatched(next, eventBuilder);
  }

  /// Send something to metrics, swallowing both a synchronous throw and a
  /// rejected future. Measurement is never a reason to fail playback.
  void _beacon(Future<void>? Function() send) {
    try {
      final pending = send();
      if (pending != null) unawaited(pending.catchError((_) {}));
    } catch (_) {}
  }

  /// Beacon the transition to metrics, then emit the built event to listeners.
  void _emitDispatched(PlayerEvent next, Function eventBuilder) {
    // A failing metrics beacon must never suppress the player's own events,
    // least of all the error ones. The beacon is asynchronous, so a synchronous
    // catch is not enough: an unreachable endpoint rejects its future long
    // after this returns, and an unhandled rejection is an app-level crash in
    // release mode for something the viewer cannot see.
    _beacon(() => _fastPixMetrics?.dispatchEvent(next));
    _lastDispatchedEvent = next;
    final emitted = eventBuilder();
    if (emitted is FastPixPlayerErrorEvent) {
      // Retained so a widget mounted after the failure can still render it.
      _lastError = emitted;
      _currentState = FastPixPlayerState.error;
    }
    _eventManager.emit(emitted);
    if (next == PlayerEvent.playing) {
      _isEndedCalled = false;
    }
  }

  /// Record a DRM failure and emit it to `error` listeners
  void _handleDrmException(FastPixDrmException exception) {
    _lastDrmError = exception;
    _errorModel = ErrorModel(exception.message, exception.code);
    _currentState = FastPixPlayerState.error;
    final event = FastPixPlayerDrmErrorEvent.fromException(
      exception,
      timestamp: DateTime.now(),
    );
    _lastError = event;
    _eventManager.emit(event);
  }

  /// Handle a playback exception from the platform player.
  ///
  /// On a DRM protected source the raw platform error is classified into a
  /// [FastPixDrmException] so listeners get an actionable cause instead of an
  /// opaque `CoreMediaErrorDomain` / `DrmSession` string.
  void _handlePlaybackException(BetterPlayerEvent event) {
    final rawError = event.parameters?['exception']?.toString();
    final drmEnabled = _dataSource?.drmEnabled ?? false;

    if (FastPixDrmErrorClassifier.isDrmError(
      rawError,
      drmEnabled: drmEnabled,
    )) {
      // A DRM failure on a source with no DRM configuration means the media is
      // protected and playback was never set up for it.
      final exception =
          drmEnabled
              ? FastPixDrmErrorClassifier.toException(
                rawError,
                playbackId: _dataSource?.playbackId,
              )
              : FastPixDrmException(
                FastPixDrmErrorCode.configurationMissing,
                FastPixDrmErrorClassifier.describe(
                  FastPixDrmErrorCode.configurationMissing,
                ),
                playbackId: _dataSource?.playbackId,
                underlyingError: rawError,
              );
      _lastDrmError = exception;
      _currentState = FastPixPlayerState.error;
      _tryDispatch(
        PlayerEvent.error,
        event: event,
        errorModel: ErrorModel(exception.message, exception.code),
        () => FastPixPlayerDrmErrorEvent.fromException(
          exception,
          timestamp: DateTime.now(),
        ),
      );
      return;
    }

    _tryDispatch(
      PlayerEvent.error,
      event: event,
      () => FastPixPlayerErrorEvent(
        timestamp: DateTime.now(),
        message: rawError ?? _unknownErrorMessage,
        // `better_player_plus` only ever sends an `exception` parameter, so
        // there is no platform code to report here. The player's own error
        // text is opaque by design: ExoPlayer collapses a missing playback ID,
        // an expired token and a rejected DRM license into the same
        // `Source error`. Call [diagnosePlayback] to recover the real cause.
        code: null,
      ),
    );
  }

  /// Explain a playback failure by probing the FastPix endpoints directly.
  ///
  /// The platform players report every load failure as the same opaque error,
  /// so this re-requests the manifest and, for DRM sources, the license and
  /// certificate endpoints, and reports the HTTP status each returns. That
  /// separates a bad playback ID (manifest 404) from an expired playback token
  /// (manifest 403) from a rejected DRM token (license 401/403).
  ///
  /// Returns `null` when no data source has been set.
  Future<FastPixPlaybackDiagnosis?> diagnosePlayback() async {
    final dataSource = _dataSource;
    if (dataSource == null) return null;

    final drm = dataSource.drmConfiguration;
    final String manifestUrl;
    try {
      manifestUrl = dataSource.url;
    } on FastPixDrmException {
      // The configuration is invalid, which is already the diagnosis.
      return null;
    }

    return FastPixPlaybackDiagnostics.diagnose(
      manifestUrl: manifestUrl,
      licenseUrl: drm?.licenseUrl(dataSource.playbackId),
      certificateUrl: drm?.certificateUrl(dataSource.playbackId),
      headers: dataSource.headers,
      drmConfigured: dataSource.drmEnabled,
    );
  }

  DateTime? _lastSeekAt;

  /// How close together two `seekTo` events must be to count as one drag.
  ///
  /// Named because the value used to disagree with the comment beside it: the
  /// comment said 200ms while the code compared against 500.
  static const Duration _seekBurstWindow = Duration(milliseconds: 500);

  /// Advance the state machine on a progress tick.
  ///
  /// Each check is evaluated against the event dispatched by the preceding
  /// one, so the order of these blocks is significant.
  void _handleProgressTick() {
    _reportFirstFrameOnce();
    updatePlayerDimensions();
    _reportVideoShapeToPip();
    if (_lastDispatchedEvent == PlayerEvent.buffering) {
      _tryDispatch(
        PlayerEvent.buffered,
        () => FastPixPlayerBufferedEvent(timestamp: DateTime.now()),
      );
    }
    if (_lastDispatchedEvent == PlayerEvent.seeking) {
      _tryDispatch(
        PlayerEvent.seeked,
        () => FastPixPlayerSeekedEvent(timestamp: DateTime.now()),
      );
    }
    if (_lastDispatchedEvent == PlayerEvent.seeked) {
      _tryDispatch(
        PlayerEvent.play,
        () => FastPixPlayerPlayEvent(timestamp: DateTime.now()),
      );
    }
    if (_lastDispatchedEvent == PlayerEvent.play) {
      _tryDispatch(
        PlayerEvent.playing,
        () => FastPixPlayerPlayingEvent(timestamp: DateTime.now()),
      );
    }

    // Custom-UI additions. Side-effect free with respect to the state machine
    // above: they only publish a snapshot and emit one-shot track-ready events.
    _detectTrackReadiness();
    // Skip detection rides this tick rather than a timer of its own: the tick
    // already fires during playback and already carries a position, and its
    // cadence is the resolution at which a skip control needs to appear. It is
    // also where deferred validation lands — the fourth one-shot latch of the
    // same shape as [_detectTrackReadiness].
    _skipManager.evaluate(
      position: getCurrentPosition() ?? Duration.zero,
      duration: getTotalDuration(),
    );
    _emitPlaybackState();
  }

  /// How close together an alternating play/pause pair has to arrive to count
  /// towards the churn streak.
  static const Duration _transportChurnWindow = Duration(milliseconds: 400);

  /// How many back-to-back flips it takes before they are read as engine churn
  /// rather than as a viewer working the button. Three inside
  /// [_transportChurnWindow] is already past what a finger can do, and the
  /// stall loop does thousands, so the first flips of a real interaction are
  /// never delayed.
  static const int _transportChurnStreak = 3;

  DateTime? _lastTransportAt;
  PlayerEvent? _lastTransportKind;
  int _transportFlipStreak = 0;
  Timer? _transportSettleTimer;

  /// Handle the engine's own `play`/`pause` events.
  ///
  /// Two things happen here that the bare `_tryDispatch` calls this replaced
  /// did not do, both additive to the analytics dispatch itself:
  ///
  /// 1. The custom-UI snapshot is published. Progress ticks stop when playback
  ///    does, and they were [playbackStateStream]'s only feed, so a pause left
  ///    the last `isPlaying: true` snapshot standing and a bound play/pause
  ///    button kept its pause icon until playback resumed.
  /// 2. A sustained run of alternating events is held back. iOS posts
  ///    play/pause from its `rate` KVO (`BetterPlayer.swift:271`) and can trade
  ///    thousands of them when the OS suspends a backgrounded player and the
  ///    engine's stall handler restarts it (`:286`) — enough to saturate the
  ///    analytics dispatcher (the "Using OverFlow queue" flood) and wedge the
  ///    UI. Suppression needs [_transportChurnStreak] flips to engage, so a
  ///    viewer's taps are reported immediately, and the settle timer reports
  ///    whichever state the churn ended on, so no transition is lost.
  void _handleTransportEvent(PlayerEvent kind) {
    final now = DateTime.now();
    final last = _lastTransportAt;
    final flipped =
        last != null &&
        _lastTransportKind != kind &&
        now.difference(last) < _transportChurnWindow;
    _transportFlipStreak = flipped ? _transportFlipStreak + 1 : 0;
    _lastTransportAt = now;
    _lastTransportKind = kind;

    if (_transportFlipStreak >= _transportChurnStreak) {
      // Report only where the churn settles, once it stops.
      _transportSettleTimer?.cancel();
      _transportSettleTimer = Timer(_transportChurnWindow, () {
        _transportSettleTimer = null;
        _transportFlipStreak = 0;
        if (_disposed) return;
        _dispatchTransportEvent(_lastTransportKind ?? kind);
      });
      return;
    }

    _transportSettleTimer?.cancel();
    _transportSettleTimer = null;
    _dispatchTransportEvent(kind);
  }

  void _dispatchTransportEvent(PlayerEvent kind) {
    if (kind == PlayerEvent.play) {
      _tryDispatch(
        PlayerEvent.play,
        () => FastPixPlayerPlayEvent(timestamp: DateTime.now()),
      );
    } else {
      _tryDispatch(
        PlayerEvent.pause,
        () => FastPixPlayerPauseEvent(timestamp: DateTime.now()),
      );
    }
    _emitPlaybackState();
  }

  /// Emit the end-of-playback pair, ignoring the duplicate `finished` events
  /// the platform players deliver within two seconds of each other.
  void _handleFinished() {
    final now = DateTime.now();
    if (_lastEndedAt != null && now.difference(_lastEndedAt!).inSeconds < 2) {
      return;
    }
    _lastEndedAt = now;
    if (!_isEndedCalled) {
      _isEndedCalled = true;
      _lastEndedAt = now;
      _tryDispatch(
        PlayerEvent.pause,
        () => FastPixPlayerPauseEvent(timestamp: DateTime.now()),
      );
      _tryDispatch(
        PlayerEvent.ended,
        () => FastPixPlayerFinishedEvent(timestamp: DateTime.now()),
      );
      // Inside the de-duplication, so the platform reporting completion twice
      // for the same item — which both platforms do — advances the playlist
      // exactly once.
      _handlePlaylistCompletion();
      // Playback has stopped, so progress ticks have too: publish the final
      // snapshot here or a bound control keeps its "playing" icon at the end
      // of the media.
      _emitPlaybackState();
    }
  }

  /// Close out whatever was in flight before the seek, then report the seek.
  void _handleSeekTo() {
    if (_lastDispatchedEvent == PlayerEvent.seeking) {
      _tryDispatch(
        PlayerEvent.seeked,
        () => FastPixPlayerSeekedEvent(timestamp: DateTime.now()),
      );
    }
    if (_lastDispatchedEvent == PlayerEvent.buffering) {
      _tryDispatch(
        PlayerEvent.buffered,
        () => FastPixPlayerBufferedEvent(timestamp: DateTime.now()),
      );
    }
    _tryDispatch(
      PlayerEvent.pause,
      () => FastPixPlayerPauseEvent(timestamp: DateTime.now()),
    );
    _tryDispatch(
      PlayerEvent.seeking,
      () => FastPixPlayerSeekingEvent(timestamp: DateTime.now()),
    );
    // A seek made while paused produces no progress tick, so a bound seekbar
    // would sit at the old position until playback resumed.
    _emitPlaybackState();
  }

  void _onPlayerEvent(BetterPlayerEvent event) {
    if (_disposed) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.play:
        _handleTransportEvent(PlayerEvent.play);
        break;

      case BetterPlayerEventType.progress:
        _handleProgressTick();
        break;

      case BetterPlayerEventType.finished:
        _handleFinished();
        break;

      case BetterPlayerEventType.changedTrack:
        _tryDispatch(
          PlayerEvent.variantChanged,
          event: event,
          () => FastPixPlayerFinishedEvent(timestamp: DateTime.now()),
        );
        break;

      case BetterPlayerEventType.bufferingStart:
        _tryDispatch(
          PlayerEvent.buffering,
          () => FastPixPlayerBufferingEvent(timestamp: DateTime.now()),
        );
        break;

      case BetterPlayerEventType.bufferingEnd:
        _tryDispatch(
          PlayerEvent.buffered,
          () => FastPixPlayerBufferedEvent(timestamp: DateTime.now()),
        );
        break;

      case BetterPlayerEventType.pause:
        _handleTransportEvent(PlayerEvent.pause);
        break;

      case BetterPlayerEventType.seekTo:
        // One viewer seek arrives as a burst of `seekTo` events, so a single
        // drag would otherwise dispatch a stream of seeking/seeked pairs into
        // analytics. Collapsed to the first of each burst.
        //
        // Both platforms, not just iOS. The engine's own progress bar seeks on
        // every `onHorizontalDragUpdate`, so Android produces the same burst —
        // measured at dozens of pause/seeking/seeked/play cycles for one drag,
        // every one of them a metrics beacon describing a seek the viewer did
        // not make.
        final now = DateTime.now();
        if (_lastSeekAt != null &&
            now.difference(_lastSeekAt!) < _seekBurstWindow) {
          return;
        }
        _lastSeekAt = now;
        _handleSeekTo();
        break;

      case BetterPlayerEventType.exception:
        _handlePlaybackException(event);
        break;

      // Picture-in-Picture is no longer sourced from the engine. Its
      // `pipStart`/`pipStop` only ever fire from its own PiP paths, and this
      // SDK does not use them — PiP state arrives on the SDK's own channel
      // instead, so a window the system opened or the viewer dismissed is
      // reported just as reliably as one the app asked for.

      // See the matching cases in the other event handler: bridge the engine's
      // own fullscreen transitions (including the back button) so a custom
      // control's fullscreen button stays in sync. Additive; deduped.
      case BetterPlayerEventType.openFullscreen:
        _emitFullscreen(true);
        break;

      case BetterPlayerEventType.hideFullscreen:
        _emitFullscreen(false);
        break;

      default:
        break;
    }
  }

  /// Play the video
  Future<void> play() async {
    await _betterPlayerController?.play();
  }

  /// Pause the video
  Future<void> pause() async {
    await _betterPlayerController?.pause();
  }

  /// Seek to a specific position
  Future<void> seekTo(Duration position) async {
    await _betterPlayerController?.seekTo(position);
  }

  /// Set volume (0.0 to 1.0)
  Future<void> setVolume(double volume) async {
    await _betterPlayerController?.setVolume(volume);

    // Emit volume changed event
    _eventManager.emit(
      FastPixPlayerVolumeChangedEvent(
        timestamp: DateTime.now(),
        volume: volume,
      ),
    );
  }

  /// Get current position
  Duration? getCurrentPosition() {
    return _betterPlayerController?.videoPlayerController?.value.position;
  }

  /// Get total duration
  Duration? getTotalDuration() {
    return _betterPlayerController?.videoPlayerController?.value.duration;
  }

  /// Emit position changed event (can be called periodically or on significant position changes)
  void emitPositionChangedEvent() {
    final position = getCurrentPosition();
    final duration = getTotalDuration();

    if (position != null && duration != null) {
      _eventManager.emit(
        FastPixPlayerPositionChangedEvent(
          timestamp: DateTime.now(),
          position: position.inMilliseconds,
          duration: duration.inMilliseconds,
        ),
      );
    }
  }

  /// Emit duration changed event
  void emitDurationChangedEvent() {
    final duration = getTotalDuration();

    if (duration != null) {
      _eventManager.emit(
        FastPixPlayerDurationChangedEvent(
          timestamp: DateTime.now(),
          duration: duration.inMilliseconds,
        ),
      );
    }
  }

  /// Check if video is playing
  bool get isPlaying {
    return _betterPlayerController?.isPlaying() ?? false;
  }

  /// Check if video is paused
  bool get isPaused {
    return _currentState == FastPixPlayerState.paused;
  }

  /// Check if video is finished
  bool get isFinished {
    return _currentState == FastPixPlayerState.finished;
  }

  /// Update player dimensions (called by the widget)
  /// If width or height is null, calculates default dimensions based on screen size and orientation
  /// In portrait: 90% of screen width with 16:9 aspect ratio, capped at 80% of screen height
  /// In landscape: 90% of screen height with 16:9 aspect ratio, capped at 80% of screen width
  void updatePlayerDimensions({double? width, double? height}) {
    // Get screen dimensions
    final screenSize = _getScreenSize();
    final screenWidth = screenSize.width;
    final screenHeight = screenSize.height;

    // Determine if we're in landscape mode
    final isLandscape = screenWidth > screenHeight;

    // Calculate default dimensions based on screen size, orientation, and aspect ratio
    if (width == null || height == null) {
      if (isLandscape) {
        // In landscape mode, use height as the primary dimension
        final defaultHeight = screenHeight * 0.9; // 90% of screen height
        final defaultWidth = defaultHeight * (16 / 9); // 16:9 aspect ratio

        // Ensure width doesn't exceed 80% of screen width
        final maxWidth = screenWidth * 0.8;
        final finalWidth = defaultWidth > maxWidth ? maxWidth : defaultWidth;
        final finalHeight = finalWidth * (9 / 16);

        _playerWidth = finalWidth;
        _playerHeight = finalHeight;
      } else {
        // In portrait mode, use width as the primary dimension
        final defaultWidth = screenWidth * 0.9; // 90% of screen width
        final defaultHeight = defaultWidth * (9 / 16); // 16:9 aspect ratio

        // Ensure height doesn't exceed 80% of screen height
        final maxHeight = screenHeight * 0.8;
        final finalHeight =
            defaultHeight > maxHeight ? maxHeight : defaultHeight;
        final finalWidth = finalHeight * (16 / 9);

        _playerWidth = finalWidth;
        _playerHeight = finalHeight;
      }
    } else {
      _playerWidth = width;
      _playerHeight = height;
    }
  }

  /// The video shape last handed to the PiP owner, so a per-tick call does not
  /// become a per-tick channel message.
  Size? _lastPipVideoSize;

  /// Tell the PiP owner the video's real shape, so a portrait video gets a
  /// portrait window.
  ///
  /// Read from the engine's reported size rather than the layout box: the
  /// window's shape must follow the *video*, not whatever rectangle the host
  /// happened to lay the player out in. Reported from the progress tick
  /// because that is the first place the size is reliably known and the place
  /// it would change if the stream switched to a differently-shaped rendition.
  void _reportVideoShapeToPip() {
    final size = _betterPlayerController?.videoPlayerController?.value.size;
    if (size == null || size.width <= 0 || size.height <= 0) return;
    if (size == _lastPipVideoSize) return;
    _lastPipVideoSize = size;
    _pipManager.setVideoSize(size.width, size.height);
  }

  /// Get screen size safely
  Size _getScreenSize() {
    try {
      return MediaQueryData.fromView(
        WidgetsBinding.instance.platformDispatcher.views.first,
      ).size;
    } catch (e) {
      // Fallback to default screen size if MediaQuery is not available
      return const Size(375, 812); // iPhone X dimensions as fallback
    }
  }

  /// Dispose the controller
  Future<void> dispose() async {
    _disposed = true;
    _lifecycleManager.detach();
    // Take this controller off the PiP channel before anything else: a
    // platform PiP transition arriving after disposal must not reach a
    // disposed event bus.
    _pipManager.dispose();
    _transportSettleTimer?.cancel();
    _transportSettleTimer = null;
    // Releasing takes the listeners off first: removing them after the field
    // is nulled is a no-op, so they stayed attached and kept delivering events
    // into a disposed BetterPlayerController — which surfaces as "A
    // VideoPlayerController was used after being disposed". It also forces the
    // release, which a player adopted from the preload manager needs; see
    // [_releaseEngine].
    _releaseEngine();

    // Screenshots have to work again once DRM playback is over: the flag is
    // window wide, so leaving it set would silently disable them for the rest
    // of the host app's life.
    await _clearSecureScreen();

    // The playlist goes with playback: no navigation, no automatic advance and
    // no warm declaration may follow disposal. The two platform event handlers
    // already return early on `_disposed`, which is what stops a completion
    // arriving afterwards from advancing anything.
    _playlist.clear();
    _skipManager.resetForNewSource();

    // Custom-UI stream. The attached cast controller is deliberately NOT
    // disposed here — the app owns it, and a session may outlive this screen.
    if (!_playbackStateController.isClosed) {
      await _playbackStateController.close();
    }
    if (!_playlistStateController.isClosed) {
      await _playlistStateController.close();
    }

    final previousState = _currentState;
    _currentState = FastPixPlayerState.initialized;

    // Emit state changed event
    _eventManager.emit(
      FastPixPlayerStateChangedEvent(
        timestamp: DateTime.now(),
        previousState: previousState.name,
        newState: _currentState.name,
      ),
    );

    // Tearing down metrics must not be able to fail the teardown itself. A
    // controller whose `initialize` was rejected — an invalid DRM setup, say —
    // has no metrics session at all, and a beacon flush can throw on its way
    // out. Either one escaping here aborts the caller mid-teardown, which
    // strands the next playback attempt: the caller never gets to build its
    // replacement controller.
    final metrics = _fastPixMetrics;
    _fastPixMetrics = null;
    try {
      await metrics?.dispose(true);
    } catch (_) {}
  }

  /// Reset the controller state for reinitialization
  void reset() {
    _currentState = FastPixPlayerState.initialized;
    _lastDispatchedEvent = null;
    _errorModel = null;
    _lastDrmError = null;
    _lastError = null;

    // Emit reset event
    _eventManager.emit(
      FastPixPlayerStateChangedEvent(
        timestamp: DateTime.now(),
        previousState: 'disposed',
        newState: _currentState.name,
      ),
    );
  }

  @override
  ErrorModel? getPlayerError() {
    return _errorModel;
  }

  @override
  bool isPlayerAutoPlayOn() {
    return betterPlayerController?.betterPlayerConfiguration.autoPlay ?? false;
  }

  @override
  bool isPlayerFullScreen() {
    return betterPlayerController?.isFullScreen ?? false;
  }

  @override
  bool isPlayerPaused() {
    return betterPlayerController?.isPlaying() == false;
  }

  @override
  bool isVideoSourceLive() {
    return betterPlayerController?.isLiveStream() ?? false;
  }

  @override
  double playerHeight() {
    return _playerHeight;
  }

  @override
  String playerLanguageCode() {
    return 'en';
  }

  @override
  Future<int> playerPlayHeadTime() async {
    try {
      final position =
          await betterPlayerController?.videoPlayerController?.position;
      return position?.inMilliseconds ?? 0;
    } catch (e) {
      return 0;
    }
  }

  @override
  bool playerPreLoadOn() {
    // BetterPlayer doesn't expose preCache directly, so we'll return false as default
    // This is a limitation of the current BetterPlayer API
    return false;
  }

  @override
  double playerWidth() {
    return _playerWidth;
  }

  @override
  int videoSourceDuration() {
    try {
      return betterPlayerController
              ?.videoPlayerController
              ?.value
              .duration
              ?.inMilliseconds ??
          0;
    } catch (e) {
      return 0;
    }
  }

  @override
  int videoSourceHeight() {
    final height =
        betterPlayerController?.videoPlayerController?.value.size?.height
            .toInt() ??
        0;
    if (height > 0) _lastVideoSourceHeight = height;
    return _lastVideoSourceHeight;
  }

  String _inferMimeTypeFromUrl(String url) {
    if (url.endsWith(".mp4")) return "video/mp4";
    if (url.endsWith(".m3u8")) return "application/x-mpegURL";
    if (url.endsWith(".webm")) return "video/webm";
    if (url.endsWith(".mov")) return "video/quicktime";
    return "application/octet-stream"; // fallback
  }

  @override
  String videoSourceMimeType() {
    final videoURL = dataSource?.url ?? '';
    return _inferMimeTypeFromUrl(videoURL);
  }

  @override
  String videoSourceUrl() {
    return dataSource?.url ?? 'NA';
  }

  @override
  int videoSourceWidth() {
    final width =
        betterPlayerController?.videoPlayerController?.value.size?.width
            .toInt() ??
        0;
    if (width > 0) _lastVideoSourceWidth = width;
    return _lastVideoSourceWidth;
  }

  @override
  String videoThumbnailUrl() {
    return dataSource?.thumbnailUrl ?? 'NA';
  }

  void _handleChangedTrackEvent(BetterPlayerEvent event) {
    final paramWidth = event.parameters?['width'];
    final paramHeight = event.parameters?['height'];
    final bitRate = event.parameters?['bitrate'];
    final frameRate = event.parameters?['frameRate'];
    final codec = event.parameters?['codecs'];
    final mimeType = event.parameters?['mimeType'];
    final Map<String, String> attributes = {};
    attributes['width'] =
        (paramWidth ??
                _betterPlayerController
                    ?.videoPlayerController
                    ?.value
                    .size
                    ?.width
                    .toInt())
            .toString();
    attributes['height'] =
        (paramHeight ??
                _betterPlayerController
                    ?.videoPlayerController
                    ?.value
                    .size
                    ?.height
                    .toInt())
            .toString();
    attributes['bitrate'] = bitRate.toString();
    attributes['frameRate'] = frameRate.toString();
    attributes['codecs'] = codec.toString();
    attributes['mimeType'] = mimeType.toString();

    _beacon(
      () => _fastPixMetrics?.dispatchEvent(
        PlayerEvent.variantChanged,
        attributes: attributes,
      ),
    );

    // Emit quality changed event
    _eventManager.emit(
      FastPixPlayerQualityChangedEvent(
        timestamp: DateTime.now(),
        qualityAttributes: attributes,
      ),
    );

    // Custom-UI mirror of the same change, carrying the FastPix-owned model.
    // Only reported while quality is automatic — a player-driven switch — so a
    // custom "Auto" menu can show what the ladder actually settled on. A user
    // selection already emitted its own event from the quality manager.
    if (_qualityManager.isAuto) {
      final width = int.tryParse(attributes['width'] ?? '') ?? 0;
      final height = int.tryParse(attributes['height'] ?? '') ?? 0;
      final bitrate = int.tryParse(attributes['bitrate'] ?? '') ?? 0;
      _qualityManager.reportAutomaticChange(
        FastPixQualityLevel(
          id: '${width}x$height@$bitrate',
          label: height > 0 ? '${height}p' : 'Auto',
          width: width,
          height: height,
          bitrate: bitrate,
        ),
      );
    }
  }
}
