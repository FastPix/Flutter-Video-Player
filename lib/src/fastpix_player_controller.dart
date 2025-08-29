import 'dart:io';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_flutter_core_data/fastpix_flutter_core_data.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'models/valid_events.dart';

/// Controller for FastPix Player
class FastPixPlayerController implements PlayerObserver {
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

  late FastPixMetrics _fastPixMetrics;
  ErrorModel? _errorModel;

  /// Initialize the controller with data source and configuration
  Future<void> initialize({
    required FastPixPlayerDataSource dataSource,
    FastPixPlayerConfiguration? configuration,
  }) async {
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
                playerData: PlayerData("fastpix-player", "1.0.0"),
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

    final betterPlayerDataSource = dataSource.toBetterPlayerDataSource();
    final betterPlayerConfiguration = _createBetterPlayerConfiguration();
    _betterPlayerController = BetterPlayerController(
      betterPlayerConfiguration,
      betterPlayerDataSource: betterPlayerDataSource,
    );
    _setupEventListeners();
    _currentState = FastPixPlayerState.ready;
    _eventManager.emit(FastPixPlayerReadyEvent(timestamp: DateTime.now()));
  }

  /// Create BetterPlayerConfiguration from FastPix configuration
  BetterPlayerConfiguration _createBetterPlayerConfiguration() {
    final controlConfiguration = _configuration?.controlsConfiguration;
    final baseConfig = BetterPlayerConfiguration(
      autoPlay: controlConfiguration?.autoPlay ?? false,
      looping: _dataSource?.loop ?? false,
      aspectRatio: 16 / 9,
      fit: BoxFit.contain,
      controlsConfiguration: BetterPlayerControlsConfiguration(
        controlBarColor:
            controlConfiguration?.controlsBackgroundColor ?? Colors.black38,
        enableRetry: controlConfiguration?.enableRetry ?? false,
        enableSkips: controlConfiguration?.enableSkips ?? false,
      ),
      // iOS-specific configurations for better HLS support
      allowedScreenSleep: false,
      // Additional configurations for better replay support
      autoDetectFullscreenDeviceOrientation: true,
      autoDetectFullscreenAspectRatio: true,
    );

    return baseConfig;
  }

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

  PlayerEvent? _lastDispatchedEvent;
  bool _isEndedCalled = false;
  DateTime? _lastEndedAt;

  void _tryDispatch(
    PlayerEvent next,
    Function eventBuilder, {
    BetterPlayerEvent? event,
  }) {
    final allowed = validTransitions[_lastDispatchedEvent] ?? {};
    if (allowed.contains(next)) {
      if (_lastDispatchedEvent == PlayerEvent.ended &&
          next == PlayerEvent.play) {
        return;
      }
      if (next == PlayerEvent.variantChanged) {
        _handleChangedTrackEvent(event!);
        return;
      }
      if (next == PlayerEvent.error) {
        _errorModel = ErrorModel(
          event?.parameters?['exception'] ?? 'Unknown error',
          event?.parameters?['source'] ?? '503',
        );
      }
      _fastPixMetrics.dispatchEvent(next);
      _lastDispatchedEvent = next;
      _eventManager.emit(eventBuilder());
      if (next == PlayerEvent.playing) {
        _isEndedCalled = false;
      }
    } else {
      // ignore invalid transitions
    }
  }

  DateTime? _lastSeekAt;

  void _oniOSPlayerEvent(BetterPlayerEvent event) {
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.play:
        _tryDispatch(
          PlayerEvent.play,
          () => FastPixPlayerPlayEvent(timestamp: DateTime.now()),
        );
        break;

      case BetterPlayerEventType.progress:
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
        break;

      case BetterPlayerEventType.finished:
        final now = DateTime.now();
        if (_lastEndedAt != null &&
            now.difference(_lastEndedAt!).inSeconds < 2) {
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
        break;

      case BetterPlayerEventType.exception:
        _tryDispatch(
          PlayerEvent.error,
          event: event,
          () => FastPixPlayerErrorEvent(
            timestamp: DateTime.now(),
            message: event.parameters?['exception'] ?? 'Unknown error',
            code: event.parameters?['source'] ?? '503',
          ),
        );
        break;

      default:
        break;
    }
  }

  void _onPlayerEvent(BetterPlayerEvent event) {
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.play:
        _tryDispatch(
          PlayerEvent.play,
          () => FastPixPlayerPlayEvent(timestamp: DateTime.now()),
        );
        break;

      case BetterPlayerEventType.progress:
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
        break;

      case BetterPlayerEventType.finished:
        final now = DateTime.now();
        if (_lastEndedAt != null &&
            now.difference(_lastEndedAt!).inSeconds < 2) {
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
        break;

      case BetterPlayerEventType.exception:
        _tryDispatch(
          PlayerEvent.error,
          event: event,
          () => FastPixPlayerErrorEvent(
            timestamp: DateTime.now(),
            message: event.parameters?['exception'] ?? 'Unknown error',
            code: event.parameters?['source'] ?? '503',
          ),
        );
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
    _betterPlayerController?.dispose();
    _betterPlayerController = null;
    _betterPlayerController?.removeEventsListener(_onPlayerEvent);
    _betterPlayerController?.removeEventsListener(_oniOSPlayerEvent);

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

    await _fastPixMetrics.dispose(true);
  }

  /// Reset the controller state for reinitialization
  void reset() {
    _currentState = FastPixPlayerState.initialized;
    _lastDispatchedEvent = null;
    _errorModel = null;

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
    return betterPlayerController?.videoPlayerController?.value.size?.height
            .toInt() ??
        0;
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
    return betterPlayerController?.videoPlayerController?.value.size?.width
            .toInt() ??
        0;
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

    _fastPixMetrics.dispatchEvent(
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
