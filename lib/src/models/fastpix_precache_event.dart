import '../enums/fastpix_precache_status.dart';
import 'fastpix_player_event.dart';
import 'fastpix_player_event_types.dart';

/// Common shape for every precache lifecycle event.
///
/// Keyed on [playbackId], never the URL: a FastPix playback URL carries a
/// signed `token` that rotates independently of the media, so URL-keyed
/// bookkeeping stops matching after a refresh — silently, because a miss looks
/// exactly like never having cached.
abstract class FastPixPrecacheEvent extends FastPixPlayerEvent {
  FastPixPrecacheEvent({
    required super.type,
    required super.timestamp,
    required this.playbackId,
    super.data,
  });

  final String playbackId;
}

/// Fired when a manifest download begins.
class FastPixPrecacheStartedEvent extends FastPixPrecacheEvent {
  FastPixPrecacheStartedEvent({
    required super.timestamp,
    required super.playbackId,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.precacheStarted);
}

/// Fired when bytes have actually been committed to the player's cache.
///
/// This *is* a completion signal — the native write is synchronous and returns
/// [bytesWritten], and a write of zero is reported as a failure instead. That
/// distinction matters: the engine's own `preCache` reports success whether or
/// not anything was stored, which is how a cache that never works can look
/// healthy indefinitely.
class FastPixPrecacheCachedEvent extends FastPixPrecacheEvent {
  FastPixPrecacheCachedEvent({
    required super.timestamp,
    required super.playbackId,
    required this.bytesWritten,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.precacheCached);

  /// Bytes committed. A master playlist is typically 2–8 KB.
  final int bytesWritten;
}

/// Fired when a manifest download fails, or the source cannot be cached.
///
/// **Never a playback failure.** The manifest is simply fetched from the
/// network as it always has been.
class FastPixPrecacheFailedEvent extends FastPixPrecacheEvent {
  FastPixPrecacheFailedEvent({
    required super.timestamp,
    required super.playbackId,
    required this.status,
    required this.reason,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.precacheFailed);

  /// [FastPixPrecacheStatus.failed] for a download error, or
  /// [FastPixPrecacheStatus.unsupported] when the source or platform was never
  /// eligible. The distinction matters: unsupported is a design decision, not
  /// a fault, and should not be retried or alerted on.
  final FastPixPrecacheStatus status;

  /// Human-readable explanation, safe to log.
  final String reason;
}
