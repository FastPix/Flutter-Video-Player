import 'dart:async';
import 'dart:io';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_flutter_core_data/fastpix_flutter_core_data.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_windowmanager_plus/flutter_windowmanager_plus.dart';
import 'models/valid_events.dart';
import 'utils/fastpix_fairplay_bridge.dart';

/// Controller for FastPix Player
class FastPixPlayerController implements PlayerObserver {
  /// Fallback message used when the platform player reports a failure without
  /// an exception string.
  static const String _unknownErrorMessage = 'Unknown error';

  BetterPlayerController? _betterPlayerController;
  FastPixPlayerDataSource? _dataSource;
  FastPixPlayerConfiguration? _configuration;
  FastPixPlayerState _currentState = FastPixPlayerState.initialized;

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
    // Started before any work so the measurement covers the whole of
    // initialize(), including the DRM validation and the adoption attempt.
    _playStartClock = Stopwatch()..start();
    _firstFrameReported = false;

    // A new source is a new attempt: nothing from the previous one may leak
    // into it, or a retry with corrected credentials keeps reporting the old
    // failure.
    _lastError = null;
    _lastDrmError = null;
    _errorModel = null;
    _lastDispatchedEvent = null;
    _isEndedCalled = false;
    _lastEndedAt = null;
    // A different video has different intrinsic dimensions.
    _lastVideoSourceWidth = 0;
    _lastVideoSourceHeight = 0;

    // Fail fast on an unusable DRM setup: the exception carries an actionable
    // message and is also emitted as an error event so listeners see it.
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

    final workspaceId = configuration?.workSpaceId;
    final beaconUrl = configuration?.beaconUrl;
    final viewerId = configuration?.viewerId;
    final video = dataSource.videoData;
    final customData = dataSource.customData;

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
                playerData: PlayerData("fastpix-player", "1.0.2"),
                customData:
                    customData
                        ?.map((element) => CustomData(value: element))
                        .toList(),
              ),
            )
            .build();
    _dataSource = dataSource;
    _configuration =
        configuration ??
        FastPixPlayerConfiguration(
          workspaceId ?? '',
          viewerId ?? '',
          beaconUrl ?? '',
        );

    // FairPlay only, iOS only, and always before the engine builds its player:
    // the engine installs its resource-loader delegate during that build, and
    // the patch substitutes ours at that moment or not at all.
    //
    // Best effort. A false answer changes nothing here — playback proceeds on
    // the engine's own path exactly as it does without the patch.
    await FastPixFairPlayBridge.configure(dataSource);

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
    final BetterPlayerController? preloaded = adoptPreloaded
        ? FastPixPreloadManager.instance.consume(
            dataSource.playbackId,
            fingerprint: betterPlayerConfigurationFingerprint(
              configuration: _configuration,
              dataSource: dataSource,
            ),
          )
        : null;

    _startedFromWarmPlayer = preloaded != null;
    if (preloaded != null) {
      _betterPlayerController = preloaded;
      _adoptPreloadedController(preloaded, betterPlayerConfiguration);
    } else {
      _betterPlayerController = BetterPlayerController(
        betterPlayerConfiguration,
        betterPlayerDataSource: betterPlayerDataSource,
      );
    }
    // A fresh player is live again, so events must be accepted once more.
    // An adopted player is just as fresh from this controller's point of view.
    _disposed = false;
    // Both branches above replaced the player, so any fullscreen overlay the
    // host registered is still pointing at the previous one.
    _rebindFullscreenOverlay();
    _setupEventListeners();
    await _applySecureScreen(dataSource);
    _currentState = FastPixPlayerState.ready;
    _eventManager.emit(FastPixPlayerReadyEvent(timestamp: DateTime.now()));
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

    final position = _betterPlayerController?.videoPlayerController?.value.position;
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
    if (!dataSource.drmEnabled) return;
    if (dataSource.drmConfiguration?.secureScreen != true) return;

    try {
      await FlutterWindowManagerPlus.addFlags(
        FlutterWindowManagerPlus.FLAG_SECURE,
      );
      _secureScreenApplied = true;
    } catch (error) {
      _eventManager.emit(
        FastPixPlayerErrorEvent(
          timestamp: DateTime.now(),
          message:
              'Could not block screen capture for this DRM stream: $error',
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
  void _setupEventListeners() {
    if (Platform.isIOS) {
      _betterPlayerController?.addEventsListener(_oniOSPlayerEvent);
    } else {
      _betterPlayerController?.addEventsListener(_onPlayerEvent);
    }
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

  /// Beacon the transition to metrics, then emit the built event to listeners.
  void _emitDispatched(PlayerEvent next, Function eventBuilder) {
    // A failing metrics beacon must never suppress the player's own events,
    // least of all the error ones.
    try {
      _fastPixMetrics?.dispatchEvent(next);
    } catch (_) {}
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

  /// Advance the state machine on a progress tick.
  ///
  /// Each check is evaluated against the event dispatched by the preceding
  /// one, so the order of these blocks is significant.
  void _handleProgressTick() {
    _reportFirstFrameOnce();
    updatePlayerDimensions();
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
  }

  void _oniOSPlayerEvent(BetterPlayerEvent event) {
    if (_disposed) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.play:
        _tryDispatch(
          PlayerEvent.play,
          () => FastPixPlayerPlayEvent(timestamp: DateTime.now()),
        );
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
        _tryDispatch(
          PlayerEvent.pause,
          () => FastPixPlayerPauseEvent(timestamp: DateTime.now()),
        );
        break;

      case BetterPlayerEventType.seekTo:
        final now = DateTime.now();

        // If the last seek was less than 200ms ago, ignore this event
        if (_lastSeekAt != null &&
            now.difference(_lastSeekAt!).inMilliseconds < 500) {
          return;
        }
        _lastSeekAt = now;
        _handleSeekTo();
        break;

      case BetterPlayerEventType.exception:
        _handlePlaybackException(event);
        break;

      default:
        break;
    }
  }

  void _onPlayerEvent(BetterPlayerEvent event) {
    if (_disposed) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.play:
        _tryDispatch(
          PlayerEvent.play,
          () => FastPixPlayerPlayEvent(timestamp: DateTime.now()),
        );
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
        _tryDispatch(
          PlayerEvent.pause,
          () => FastPixPlayerPauseEvent(timestamp: DateTime.now()),
        );
        break;

      case BetterPlayerEventType.seekTo:
        _handleSeekTo();
        break;

      case BetterPlayerEventType.exception:
        _handlePlaybackException(event);
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
    // The listeners have to come off before the player goes away. Removing
    // them after the field is nulled is a no-op, so they stayed attached and
    // kept delivering events into a disposed BetterPlayerController — which
    // surfaces as "A VideoPlayerController was used after being disposed".
    _disposed = true;
    _betterPlayerController?.removeEventsListener(_onPlayerEvent);
    _betterPlayerController?.removeEventsListener(_oniOSPlayerEvent);
    // `forceDispose` is required, not defensive.
    //
    // better_player's dispose() begins with:
    //     if (!betterPlayerConfiguration.autoDispose && !forceDispose) return;
    // A player adopted from [FastPixPreloadManager] was built with
    // `autoDispose: false` so the manager — not a widget — owns its lifetime,
    // which means a plain dispose() on it does nothing at all and leaks its
    // decoder, plus its MediaDrm session for protected content.
    //
    // For a normally constructed player this changes nothing:
    // BetterPlayerConfiguration defaults `autoDispose` to true, so the guard
    // above is already false and disposal proceeds either way.
    _betterPlayerController?.dispose(forceDispose: true);
    _betterPlayerController = null;

    // Screenshots have to work again once DRM playback is over: the flag is
    // window wide, so leaving it set would silently disable them for the rest
    // of the host app's life.
    await _clearSecureScreen();

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

    _fastPixMetrics?.dispatchEvent(
      PlayerEvent.variantChanged,
      attributes: attributes,
    );

    // Emit quality changed event
    _eventManager.emit(
      FastPixPlayerQualityChangedEvent(
        timestamp: DateTime.now(),
        qualityAttributes: attributes,
      ),
    );
  }
}
