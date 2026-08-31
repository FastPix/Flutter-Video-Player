import 'fastpix_cast_device.dart';
import 'fastpix_cast_error.dart';
import 'fastpix_player_event.dart';
import 'fastpix_player_event_types.dart';

/// Fired the first time a receiver becomes reachable.
///
/// This is the signal to reveal a cast button — not app start, since a button
/// that opens an empty device list reads as broken.
class FastPixCastAvailableEvent extends FastPixPlayerEvent {
  /// Number of receivers currently discovered.
  final int deviceCount;

  const FastPixCastAvailableEvent({
    required super.timestamp,
    required this.deviceCount,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.castAvailable);
}

/// Fired when a session becomes live and the receiver takes over playback.
class FastPixCastStartedEvent extends FastPixPlayerEvent {
  /// The receiver now playing, when the session reported one.
  final FastPixCastDevice? device;

  const FastPixCastStartedEvent({
    required super.timestamp,
    required this.device,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.castStarted);
}

/// Fired when a session ends, whichever side ended it.
///
/// A session can close from this app, the Google Home app, the TV powering
/// off, or the network dropping, so this is the single place to resume local
/// playback from.
class FastPixCastEndedEvent extends FastPixPlayerEvent {
  /// The receiver that was playing, when it is still known.
  final FastPixCastDevice? device;

  /// Last position observed on the receiver, for resuming locally.
  final Duration position;

  const FastPixCastEndedEvent({
    required super.timestamp,
    required this.device,
    required this.position,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.castEnded);
}

/// Fired when discovery, a session, or a remote load fails.
///
/// Unlike [FastPixPlayerDrmErrorEvent] this does not extend
/// [FastPixPlayerErrorEvent], because a cast failure is not a local playback
/// failure: the phone may still be playing perfectly. Listeners that care
/// subscribe to `castError` explicitly.
class FastPixCastErrorEvent extends FastPixPlayerEvent {
  /// Human readable description of what failed.
  final String message;

  /// Normalised cause, for branching on what to show the user.
  final FastPixCastErrorCode errorCode;

  /// The platform's own error text, when the failure came from the Cast SDK.
  ///
  /// Kept as its own field rather than folded into [message]: a caller that
  /// wants to log or report the original should not have to parse it back out
  /// of an English sentence.
  final String? underlyingError;

  const FastPixCastErrorEvent({
    required super.timestamp,
    required this.message,
    required this.errorCode,
    this.underlyingError,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.castError);

  /// Stable string code for this failure, e.g. `FP_CAST_CONNECT_TIMEOUT`.
  String get code => errorCode.code;

  /// Whether casting is unusable until the user changes something.
  bool get isFatal => errorCode.isFatal;

  /// Whether the user can fix this from the system settings app.
  bool get isPermissionRelated => errorCode.isPermissionRelated;

  /// Whether this content can never play on a receiver.
  bool get isContentUnsupported => errorCode.isContentUnsupported;

  /// Whether the same action may succeed if simply tried again.
  bool get isRetryable => errorCode.isRetryable;

  @override
  String toString() =>
      'FastPixCastErrorEvent($code): $message'
      '${underlyingError != null ? '\nUnderlying error: $underlyingError' : ''}';
}
