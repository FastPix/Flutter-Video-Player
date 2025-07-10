import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'models/fastpix_player_data_source.dart';
import 'fastpix_player_configuration.dart';
import 'enums/fastpix_player_enums.dart';

/// Controller for FastPix Player
class FastPixPlayerController {
  BetterPlayerController? _betterPlayerController;
  FastPixPlayerDataSource? _dataSource;
  FastPixPlayerConfiguration? _configuration;
  FastPixPlayerState _currentState = FastPixPlayerState.initialized;

  /// Get the current player state
  FastPixPlayerState get currentState => _currentState;

  /// Get the underlying BetterPlayerController
  BetterPlayerController? get betterPlayerController => _betterPlayerController;

  /// Get the current data source
  FastPixPlayerDataSource? get dataSource => _dataSource;

  /// Initialize the controller with data source and configuration
  Future<void> initialize({
    required FastPixPlayerDataSource dataSource,
    FastPixPlayerConfiguration? configuration,
  }) async {
    _dataSource = dataSource;
    _configuration = configuration ?? const FastPixPlayerConfiguration();

    final betterPlayerDataSource = dataSource.toBetterPlayerDataSource();
    final betterPlayerConfiguration = _createBetterPlayerConfiguration();

    _betterPlayerController = BetterPlayerController(betterPlayerConfiguration);

    await _betterPlayerController?.setupDataSource(betterPlayerDataSource);

    _setupEventListeners();
    _currentState = FastPixPlayerState.ready;
  }

  /// Create BetterPlayerConfiguration from FastPix configuration
  BetterPlayerConfiguration _createBetterPlayerConfiguration() {
    final baseConfig = BetterPlayerConfiguration(
      autoPlay:
          _configuration?.autoPlayConfiguration.autoPlay ==
          FastPixAutoPlay.enabled,
      looping: _dataSource?.loop ?? false,
      aspectRatio: 16 / 9,
      fit: BoxFit.contain,
      controlsConfiguration: BetterPlayerControlsConfiguration(
        controlBarColor:
            _configuration?.controlsConfiguration.controlsBackgroundColor ??
            Colors.black38,
        enableRetry: true,
      ),
      // iOS-specific configurations for better HLS support
      allowedScreenSleep: false,
      handleLifecycle: true,
    );

    return baseConfig;
  }

  /// Setup event listeners
  void _setupEventListeners() {
    _betterPlayerController?.addEventsListener(_onPlayerEvent);
  }

  /// Handle player events
  void _onPlayerEvent(BetterPlayerEvent event) {
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.initialized:
        _currentState = FastPixPlayerState.ready;
        break;
      case BetterPlayerEventType.play:
        _currentState = FastPixPlayerState.playing;
        break;
      case BetterPlayerEventType.pause:
        _currentState = FastPixPlayerState.paused;
        break;
      case BetterPlayerEventType.finished:
        _currentState = FastPixPlayerState.finished;
        break;
      case BetterPlayerEventType.exception:
        _currentState = FastPixPlayerState.error;
        break;
      case BetterPlayerEventType.bufferingUpdate:
        _currentState = FastPixPlayerState.buffering;
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
  }

  /// Get current position
  Duration? getCurrentPosition() {
    return _betterPlayerController?.videoPlayerController?.value.position;
  }

  /// Get total duration
  Duration? getTotalDuration() {
    return _betterPlayerController?.videoPlayerController?.value.duration;
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

  /// Update data source without reinitializing the entire controller
  Future<void> updateDataSource(FastPixPlayerDataSource dataSource) async {
    if (_betterPlayerController == null) {
      // If no controller exists, initialize normally
      await initialize(dataSource: dataSource);
      return;
    }

    _dataSource = dataSource;
    final betterPlayerDataSource = dataSource.toBetterPlayerDataSource();

    // Simply update the existing controller's data source
    await _betterPlayerController?.setupDataSource(betterPlayerDataSource);
    _betterPlayerController?.setSpeed(1.0);
    _currentState = FastPixPlayerState.ready;
  }

  /// Update configuration dynamically
  Future<void> updateConfiguration(
    FastPixPlayerConfiguration configuration,
  ) async {
    _configuration = configuration;

    if (_betterPlayerController != null && _dataSource != null) {
      // Recreate the controller with new configuration
      final oldController = _betterPlayerController;
      final betterPlayerConfiguration = _createBetterPlayerConfiguration();
      _betterPlayerController = BetterPlayerController(
        betterPlayerConfiguration,
      );

      // Setup the data source with the new configuration
      final betterPlayerDataSource = _dataSource!.toBetterPlayerDataSource();
      await _betterPlayerController?.setupDataSource(betterPlayerDataSource);

      // Dispose the old controller
      oldController?.dispose();

      _setupEventListeners();
    }
  }

  /// Update both data source and configuration
  Future<void> updateDataSourceAndConfiguration({
    required FastPixPlayerDataSource dataSource,
    FastPixPlayerConfiguration? configuration,
  }) async {
    if (configuration != null) {
      _configuration = configuration;
    }

    await updateDataSource(dataSource);
  }

  /// Switch to a new video (simple method for developers)
  Future<void> switchVideo(FastPixPlayerDataSource newDataSource) async {
    await updateDataSource(newDataSource);
  }

  /// Dispose the controller
  void dispose() {
    _betterPlayerController?.dispose();
    _betterPlayerController = null;
    _currentState = FastPixPlayerState.initialized;
  }
}
