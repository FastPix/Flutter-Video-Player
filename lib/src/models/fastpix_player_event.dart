import 'package:flutter/foundation.dart';

/// Base class for all FastPix player events
abstract class FastPixPlayerEvent {
  /// Event type identifier
  final String type;

  /// Timestamp when the event occurred
  final DateTime timestamp;

  /// Additional event data
  final Map<String, dynamic>? data;

  const FastPixPlayerEvent({
    required this.type,
    required this.timestamp,
    this.data,
  });

  @override
  String toString() =>
      'FastPixPlayerEvent(type: $type, timestamp: $timestamp, data: $data)';
}

/// Play event - fired when video starts playing
class FastPixPlayerPlayEvent extends FastPixPlayerEvent {
  const FastPixPlayerPlayEvent({required super.timestamp, super.data})
    : super(type: 'play');
}

/// Pause event - fired when video is paused
class FastPixPlayerPauseEvent extends FastPixPlayerEvent {
  const FastPixPlayerPauseEvent({required super.timestamp, super.data})
    : super(type: 'pause');
}

/// Playing event - fired during video playback
class FastPixPlayerPlayingEvent extends FastPixPlayerEvent {
  const FastPixPlayerPlayingEvent({required super.timestamp, super.data})
    : super(type: 'playing');
}

/// Buffering event - fired when video is buffering
class FastPixPlayerBufferingEvent extends FastPixPlayerEvent {
  const FastPixPlayerBufferingEvent({required super.timestamp, super.data})
    : super(type: 'buffering');
}

/// Buffered event - fired when buffering is complete
class FastPixPlayerBufferedEvent extends FastPixPlayerEvent {
  const FastPixPlayerBufferedEvent({required super.timestamp, super.data})
    : super(type: 'buffered');
}

/// Seeking event - fired when seeking starts
class FastPixPlayerSeekingEvent extends FastPixPlayerEvent {
  const FastPixPlayerSeekingEvent({required super.timestamp, super.data})
    : super(type: 'seeking');
}

/// Seeked event - fired when seeking is complete
class FastPixPlayerSeekedEvent extends FastPixPlayerEvent {
  const FastPixPlayerSeekedEvent({required super.timestamp, super.data})
    : super(type: 'seeked');
}

/// Finished event - fired when video playback is complete
class FastPixPlayerFinishedEvent extends FastPixPlayerEvent {
  const FastPixPlayerFinishedEvent({required super.timestamp, super.data})
    : super(type: 'finished');
}

/// Error event - fired when an error occurs
class FastPixPlayerErrorEvent extends FastPixPlayerEvent {
  /// Error message
  final String message;

  /// Error code
  final String? code;

  const FastPixPlayerErrorEvent({
    required super.timestamp,
    required this.message,
    this.code,
    super.data,
  }) : super(type: 'error');
}

/// Quality changed event - fired when video quality changes
class FastPixPlayerQualityChangedEvent extends FastPixPlayerEvent {
  /// New quality attributes
  final Map<String, String> qualityAttributes;

  const FastPixPlayerQualityChangedEvent({
    required super.timestamp,
    required this.qualityAttributes,
    super.data,
  }) : super(type: 'qualityChanged');
}

/// Duration changed event - fired when video duration is available
class FastPixPlayerDurationChangedEvent extends FastPixPlayerEvent {
  /// Video duration in milliseconds
  final int duration;

  const FastPixPlayerDurationChangedEvent({
    required super.timestamp,
    required this.duration,
    super.data,
  }) : super(type: 'durationChanged');
}

/// Position changed event - fired when playback position changes
class FastPixPlayerPositionChangedEvent extends FastPixPlayerEvent {
  /// Current position in milliseconds
  final int position;

  /// Total duration in milliseconds
  final int duration;

  const FastPixPlayerPositionChangedEvent({
    required super.timestamp,
    required this.position,
    required this.duration,
    super.data,
  }) : super(type: 'positionChanged');
}

/// Volume changed event - fired when volume changes
class FastPixPlayerVolumeChangedEvent extends FastPixPlayerEvent {
  /// New volume level (0.0 to 1.0)
  final double volume;

  const FastPixPlayerVolumeChangedEvent({
    required super.timestamp,
    required this.volume,
    super.data,
  }) : super(type: 'volumeChanged');
}

/// Fullscreen changed event - fired when fullscreen state changes
class FastPixPlayerFullscreenChangedEvent extends FastPixPlayerEvent {
  /// Whether fullscreen is enabled
  final bool isFullscreen;

  const FastPixPlayerFullscreenChangedEvent({
    required super.timestamp,
    required this.isFullscreen,
    super.data,
  }) : super(type: 'fullscreenChanged');
}

/// Ready event - fired when player is ready to play
class FastPixPlayerReadyEvent extends FastPixPlayerEvent {
  const FastPixPlayerReadyEvent({required super.timestamp, super.data})
    : super(type: 'ready');
}

/// State changed event - fired when player state changes
class FastPixPlayerStateChangedEvent extends FastPixPlayerEvent {
  /// Previous state
  final String previousState;

  /// New state
  final String newState;

  const FastPixPlayerStateChangedEvent({
    required super.timestamp,
    required this.previousState,
    required this.newState,
    super.data,
  }) : super(type: 'stateChanged');
}

/// Event listener interface
typedef FastPixPlayerEventListener = void Function(FastPixPlayerEvent event);

/// Event listener manager
class FastPixPlayerEventManager {
  final Map<String, List<FastPixPlayerEventListener>> _listeners = {};
  final List<FastPixPlayerEventListener> _globalListeners = [];

  /// Add a listener for a specific event type
  void addEventListener(String eventType, FastPixPlayerEventListener listener) {
    _listeners.putIfAbsent(eventType, () => []).add(listener);
  }

  /// Add a listener for all events
  void addGlobalListener(FastPixPlayerEventListener listener) {
    _globalListeners.add(listener);
  }

  /// Remove a listener for a specific event type
  void removeEventListener(
    String eventType,
    FastPixPlayerEventListener listener,
  ) {
    _listeners[eventType]?.remove(listener);
  }

  /// Remove a global listener
  void removeGlobalListener(FastPixPlayerEventListener listener) {
    _globalListeners.remove(listener);
  }

  /// Remove all listeners for a specific event type
  void removeAllEventListeners(String eventType) {
    _listeners.remove(eventType);
  }

  /// Remove all listeners
  void removeAllListeners() {
    _listeners.clear();
    _globalListeners.clear();
  }

  /// Emit an event to all registered listeners
  void emit(FastPixPlayerEvent event) {
    // Emit to specific event listeners
    final eventListeners = _listeners[event.type];
    if (eventListeners != null) {
      for (final listener in eventListeners) {
        try {
          listener(event);
        } catch (e, stackTrace) {
          debugPrint(
            'Error in event listener for ${event.type}: $e\n$stackTrace',
          );
        }
      }
    }

    // Emit to global listeners
    for (final listener in _globalListeners) {
      try {
        listener(event);
      } catch (e, stackTrace) {
        debugPrint('Error in global event listener: $e\n$stackTrace');
      }
    }
  }

  /// Get the number of listeners for a specific event type
  int getListenerCount(String eventType) {
    return _listeners[eventType]?.length ?? 0;
  }

  /// Get the total number of global listeners
  int getGlobalListenerCount() {
    return _globalListeners.length;
  }

  /// Check if there are any listeners for a specific event type
  bool hasListeners(String eventType) {
    return _listeners.containsKey(eventType) &&
        _listeners[eventType]!.isNotEmpty;
  }

  /// Check if there are any global listeners
  bool hasGlobalListeners() {
    return _globalListeners.isNotEmpty;
  }
}
