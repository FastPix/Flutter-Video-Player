import '../enums/fastpix_prerender_error_code.dart';
import 'fastpix_player_event.dart';
import 'fastpix_player_event_types.dart';

/// Common shape for every prerender event.
///
/// A prerender describes a source that is *not* the one playing, so each
/// event sets its own `playbackId` and `playlistIndex` in [data]. Keys an
/// event already carries win over the emitter's attribution, which would
/// otherwise name the active item.
abstract class FastPixPrerenderEvent extends FastPixPlayerEvent {
  FastPixPrerenderEvent({
    required super.type,
    required super.timestamp,
    required this.playbackId,
    this.playlistIndex,
  }) : super(
          data: <String, dynamic>{
            'playbackId': playbackId,
            // Null rather than absent while a playlist is set but the source
            // is not in it, so the active item's index is not attached.
            'playlistIndex': playlistIndex,
          },
        );

  /// The source this event describes.
  final String playbackId;

  /// That source's playlist position, or null when it is not in a playlist.
  final int? playlistIndex;
}

/// Fired when a prerender is admitted and starts preparing.
class FastPixPrerenderRequestedEvent extends FastPixPrerenderEvent {
  /// Whether the playlist trigger asked for it, rather than the application.
  final bool automatic;

  FastPixPrerenderRequestedEvent({
    required super.timestamp,
    required super.playbackId,
    super.playlistIndex,
    required this.automatic,
  }) : super(type: FastPixPlayerEventTypes.prerenderRequested);

  @override
  String toString() =>
      'FastPixPrerenderRequestedEvent($playbackId, automatic: $automatic)';
}

/// Fired when the platform confirms the prerendered source is ready for
/// presentation on the hidden surface.
class FastPixPrerenderReadyEvent extends FastPixPrerenderEvent {
  final Duration timeToFirstFrame;

  FastPixPrerenderReadyEvent({
    required super.timestamp,
    required super.playbackId,
    super.playlistIndex,
    required this.timeToFirstFrame,
  }) : super(type: FastPixPlayerEventTypes.prerenderReady);

  @override
  String toString() =>
      'FastPixPrerenderReadyEvent($playbackId, ttff: $timeToFirstFrame)';
}

/// Fired when a prerender was skipped by policy or could not reach
/// frame-ready; [code] says why, and the prerender's status tells a skip from
/// a failure. Informational only: playback is never affected.
class FastPixPrerenderFailedEvent extends FastPixPrerenderEvent {
  final FastPixPrerenderErrorCode code;
  final String message;

  FastPixPrerenderFailedEvent({
    required super.timestamp,
    required super.playbackId,
    super.playlistIndex,
    required this.code,
    required this.message,
  }) : super(type: FastPixPlayerEventTypes.prerenderFailed);

  @override
  String toString() =>
      'FastPixPrerenderFailedEvent($playbackId, ${code.value}: $message)';
}
