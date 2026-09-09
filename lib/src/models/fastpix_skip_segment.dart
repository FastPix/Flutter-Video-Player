import 'package:fastpix_video_player/fastpix_video_player.dart';

/// A stretch of a video the viewer may want to jump over — an intro, a recap,
/// a song, the closing credits.
///
/// A segment is *active* when the playhead is at or after [start] and strictly
/// before [end], which is when a host shows its skip control. Declared on the
/// source, so a playlist carries per-item segments and nothing has to be set
/// again as items change.
///
/// Deliberately not named after
/// [FastPixPlayerControlsConfiguration.enableSkips], which means the engine's
/// ±10 second buttons and is a different feature.
class FastPixSkipSegment {
  /// Where the segment begins, from the start of the media.
  final Duration start;

  /// Where the segment ends. Skipping seeks here.
  final Duration end;

  /// What the segment covers.
  final FastPixSkipType type;

  const FastPixSkipSegment({
    required this.start,
    required this.end,
    required this.type,
  });

  /// Whether [position] falls inside the segment.
  ///
  /// Half-open — the end is excluded — so a skip that seeks to [end] leaves
  /// the segment rather than immediately re-entering it.
  bool contains(Duration position) => position >= start && position < end;

  /// How long the segment lasts.
  Duration get length => end - start;

  /// Parse one entry of a `skipSegments` array.
  ///
  /// Throws [FastPixPlaylistException] on anything unreadable, so a malformed
  /// segment is reported where it was supplied rather than silently dropped.
  factory FastPixSkipSegment.fromJson(
    Map<String, dynamic> json, {
    int? itemIndex,
  }) {
    Duration read(String key) {
      final value = json[key];
      if (value is! num) {
        throw FastPixPlaylistException(
          FastPixPlaylistErrorCode.malformedEntry,
          'Skip segment "$key" must be a number of seconds.',
          itemIndex: itemIndex,
        );
      }
      return Duration(milliseconds: (value * 1000).round());
    }

    final type = FastPixSkipType.fromValue(json['type'] as String?);
    if (type == null) {
      throw FastPixPlaylistException(
        FastPixPlaylistErrorCode.malformedEntry,
        'Skip segment "type" must be one of '
        '${FastPixSkipType.values.map((value) => value.value).join(', ')}.',
        itemIndex: itemIndex,
      );
    }

    return FastPixSkipSegment(
      start: read('start'),
      end: read('end'),
      type: type,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FastPixSkipSegment &&
          other.start == start &&
          other.end == end &&
          other.type == type;

  @override
  int get hashCode => Object.hash(start, end, type);

  @override
  String toString() =>
      'FastPixSkipSegment(${type.value}, $start → $end)';
}
