import 'package:fastpix_video_player/fastpix_video_player.dart';

/// Fired when a playlist is set, replaced or cleared.
///
/// Emitted through the ordinary event system rather than through the analytics
/// dispatch: `validTransitions` describes the beacon's playback state machine,
/// and a playlist notification is not part of it.
class FastPixPlaylistChangedEvent extends FastPixPlayerEvent {
  /// How many items the playlist now holds; zero when it was cleared.
  final int count;

  /// Where playback is positioned in the new playlist, or `-1` when nowhere.
  final int currentIndex;

  FastPixPlaylistChangedEvent({
    required super.timestamp,
    required this.count,
    required this.currentIndex,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.playlistChanged);

  /// Whether a playlist is present at all.
  bool get hasPlaylist => count > 0;

  @override
  String toString() =>
      'FastPixPlaylistChangedEvent(count: $count, currentIndex: $currentIndex)';
}

/// Fired when the active item changes — and only then.
///
/// Navigation that does not move, such as `next()` at the last item, emits
/// nothing.
class FastPixPlaylistItemChangedEvent extends FastPixPlayerEvent {
  /// Position of the item now playing.
  final int index;

  /// Position the playlist was on before, or `-1` when it was on none.
  final int previousIndex;

  /// Playback ID of the item now playing.
  final String playbackId;

  /// What moved the playlist: the initial load, host navigation, an automatic
  /// advance, or a repeat.
  final FastPixPlaylistItemChangeReason reason;

  FastPixPlaylistItemChangedEvent({
    required super.timestamp,
    required this.index,
    required this.previousIndex,
    required this.playbackId,
    required this.reason,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.playlistItemChanged);

  @override
  String toString() =>
      'FastPixPlaylistItemChangedEvent($previousIndex → $index, '
      '${reason.name}, playbackId: $playbackId)';
}

/// Fired when the final item finishes and no repeat applies.
class FastPixPlaylistEndedEvent extends FastPixPlayerEvent {
  /// How many items played through.
  final int count;

  FastPixPlaylistEndedEvent({
    required super.timestamp,
    required this.count,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.playlistEnded);

  @override
  String toString() => 'FastPixPlaylistEndedEvent(count: $count)';
}

/// Fired when playback enters a declared skip segment — the moment to show a
/// skip control.
class FastPixSkipAvailableEvent extends FastPixPlayerEvent {
  /// The segment now active.
  final FastPixSkipSegment segment;

  FastPixSkipAvailableEvent({
    required super.timestamp,
    required this.segment,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.skipAvailable);

  @override
  String toString() => 'FastPixSkipAvailableEvent($segment)';
}

/// Fired when no segment is active any longer — the moment to hide the control.
class FastPixSkipHiddenEvent extends FastPixPlayerEvent {
  /// The segment that was active, when there was one.
  final FastPixSkipSegment? segment;

  FastPixSkipHiddenEvent({
    required super.timestamp,
    this.segment,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.skipHidden);

  @override
  String toString() => 'FastPixSkipHiddenEvent($segment)';
}

/// Fired when a requested skip has been performed.
class FastPixSkipCompletedEvent extends FastPixPlayerEvent {
  /// The segment that was skipped.
  final FastPixSkipSegment segment;

  FastPixSkipCompletedEvent({
    required super.timestamp,
    required this.segment,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.skipCompleted);

  @override
  String toString() => 'FastPixSkipCompletedEvent($segment)';
}

/// Fired when a declared segment is rejected, or a requested skip cannot be
/// performed.
///
/// Never a playback failure: a segment that does not describe the media is a
/// configuration problem, and playback continues either way. It is reported on
/// its own channel rather than on `error` so a host that renders every error
/// as "playback failed" is not handed one.
class FastPixSkipFailedEvent extends FastPixPlayerEvent {
  /// Which rule was broken.
  final FastPixSkipFailureReason reason;

  /// What to fix, in a sentence.
  final String message;

  /// The segment concerned, when the failure is about one.
  final FastPixSkipSegment? segment;

  FastPixSkipFailedEvent({
    required super.timestamp,
    required this.reason,
    required this.message,
    this.segment,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.skipFailed);

  @override
  String toString() =>
      'FastPixSkipFailedEvent(${reason.value}: $message)';
}
