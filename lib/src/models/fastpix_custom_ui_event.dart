import 'fastpix_audio_track.dart';
import 'fastpix_player_event.dart';
import 'fastpix_quality_level.dart';
import 'fastpix_subtitle_track.dart';

/// Events emitted by the custom-UI functionality API.
///
/// Every class here extends [FastPixPlayerEvent] and is dispatched through the
/// same [FastPixPlayerEventManager] as playback and cast events, so a custom UI
/// binds to one event system. These are additive: the existing events
/// (including [FastPixPlayerFullscreenChangedEvent] for fullscreen and
/// [FastPixPlayerQualityChangedEvent] for the raw engine attributes) are left
/// untouched, and the new quality event below is a distinct type carrying the
/// FastPix-owned model.

/// Emitted when the playback speed changes.
class FastPixPlaybackRateChangedEvent extends FastPixPlayerEvent {
  final double rate;

  FastPixPlaybackRateChangedEvent({
    required super.timestamp,
    required this.rate,
    super.data,
  }) : super(type: 'playbackRateChanged');
}

/// Emitted when a scrub interaction starts.
class FastPixScrubStartedEvent extends FastPixPlayerEvent {
  final Duration position;

  FastPixScrubStartedEvent({
    required super.timestamp,
    required this.position,
    super.data,
  }) : super(type: 'scrubStarted');
}

/// Emitted when a scrub interaction ends and a seek is issued.
class FastPixScrubEndedEvent extends FastPixPlayerEvent {
  final Duration position;

  FastPixScrubEndedEvent({
    required super.timestamp,
    required this.position,
    super.data,
  }) : super(type: 'scrubEnded');
}

/// Emitted when quality levels first become available for the loaded media.
class FastPixQualityLevelsReadyEvent extends FastPixPlayerEvent {
  final List<FastPixQualityLevel> levels;

  FastPixQualityLevelsReadyEvent({
    required super.timestamp,
    required this.levels,
    super.data,
  }) : super(type: 'qualityLevelsReady');
}

/// Emitted when the active quality changes, including automatic switches made
/// by the player itself ([isAutomatic] is true for those).
class FastPixQualityLevelChangedEvent extends FastPixPlayerEvent {
  final FastPixQualityLevel? level;
  final bool isAutomatic;

  FastPixQualityLevelChangedEvent({
    required super.timestamp,
    required this.level,
    required this.isAutomatic,
    super.data,
  }) : super(type: 'qualityLevelChanged');
}

/// Emitted when audio tracks first become available.
class FastPixAudioTracksReadyEvent extends FastPixPlayerEvent {
  final List<FastPixAudioTrack> tracks;

  FastPixAudioTracksReadyEvent({
    required super.timestamp,
    required this.tracks,
    super.data,
  }) : super(type: 'audioTracksReady');
}

/// Emitted when the active audio track changes.
class FastPixAudioTrackChangedEvent extends FastPixPlayerEvent {
  final FastPixAudioTrack track;

  FastPixAudioTrackChangedEvent({
    required super.timestamp,
    required this.track,
    super.data,
  }) : super(type: 'audioTrackChanged');
}

/// Emitted when subtitle tracks first become available.
class FastPixSubtitleTracksReadyEvent extends FastPixPlayerEvent {
  final List<FastPixSubtitleTrack> tracks;

  FastPixSubtitleTracksReadyEvent({
    required super.timestamp,
    required this.tracks,
    super.data,
  }) : super(type: 'subtitleTracksReady');
}

/// Emitted when the active subtitle track changes or is disabled ([track] is
/// null when subtitles were turned off).
class FastPixSubtitleChangedEvent extends FastPixPlayerEvent {
  final FastPixSubtitleTrack? track;

  FastPixSubtitleChangedEvent({
    required super.timestamp,
    required this.track,
    super.data,
  }) : super(type: 'subtitleChanged');
}

/// Emitted when Picture-in-Picture starts or stops (including PiP the system
/// started or dismissed on its own). Mirrors the iOS SDK's
/// `onPiPStateChanged(isActive:)`.
class FastPixPipChangedEvent extends FastPixPlayerEvent {
  final bool isActive;

  FastPixPipChangedEvent({
    required super.timestamp,
    required this.isActive,
    super.data,
  }) : super(type: 'pipChanged');
}
