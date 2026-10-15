import '../enums/fastpix_spritesheet_error_code.dart';
import '../enums/fastpix_spritesheet_type.dart';
import 'fastpix_player_event.dart';
import 'fastpix_player_event_types.dart';

// Spritesheet events carry no playback ID of their own: the event manager
// attaches `playbackId`, and `playlistIndex` while a playlist is set, to the
// `data` of every event it emits.

/// Fired when a spritesheet request begins for the active source.
class FastPixSpritesheetLoadStartedEvent extends FastPixPlayerEvent {
  /// Which spritesheet is being requested.
  final FastPixSpritesheetType spritesheetType;

  FastPixSpritesheetLoadStartedEvent({
    required super.timestamp,
    required this.spritesheetType,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.spritesheetLoadStarted);

  @override
  String toString() =>
      'FastPixSpritesheetLoadStartedEvent(${spritesheetType.name})';
}

/// Fired when spritesheet metadata is loaded and positions resolve to tiles.
///
/// The image may still be on its way; see [FastPixSpritesheetImageReadyEvent].
class FastPixSpritesheetLoadedEvent extends FastPixPlayerEvent {
  /// Which spritesheet loaded.
  final FastPixSpritesheetType spritesheetType;

  /// Seconds between tiles for an advanced spritesheet; null for normal.
  final int? interval;

  /// How many tiles the metadata lists.
  final int tileCount;

  FastPixSpritesheetLoadedEvent({
    required super.timestamp,
    required this.spritesheetType,
    required this.tileCount,
    this.interval,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.spritesheetLoaded);

  @override
  String toString() =>
      'FastPixSpritesheetLoadedEvent(${spritesheetType.name}, '
      'tiles: $tileCount, interval: $interval)';
}

/// Fired when the spritesheet image is decoded and previews can draw tiles.
class FastPixSpritesheetImageReadyEvent extends FastPixPlayerEvent {
  /// Which spritesheet's image is ready.
  final FastPixSpritesheetType spritesheetType;

  /// Decoded size relative to the full image: 1 when decoded at full size,
  /// below 1 when the image was too large for the device.
  final double decodeScale;

  FastPixSpritesheetImageReadyEvent({
    required super.timestamp,
    required this.spritesheetType,
    required this.decodeScale,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.spritesheetImageReady);

  @override
  String toString() =>
      'FastPixSpritesheetImageReadyEvent(${spritesheetType.name}, '
      'scale: $decodeScale)';
}

/// Fired when a spritesheet, or its image, could not be used.
///
/// Informational only. Playback is never affected, and this is deliberately not
/// a `FastPixPlayerErrorEvent`: `FastPixPlayer` replaces the whole player with
/// its error screen on one of those, which a missing thumbnail must never do.
class FastPixSpritesheetFailedEvent extends FastPixPlayerEvent {
  /// Which spritesheet failed.
  final FastPixSpritesheetType spritesheetType;

  /// Why.
  final FastPixSpritesheetErrorCode code;

  /// What happened, in a sentence.
  final String message;

  FastPixSpritesheetFailedEvent({
    required super.timestamp,
    required this.spritesheetType,
    required this.code,
    required this.message,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.spritesheetFailed);

  @override
  String toString() =>
      'FastPixSpritesheetFailedEvent(${spritesheetType.name}, '
      '${code.value}: $message)';
}
