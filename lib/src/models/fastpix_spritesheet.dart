import 'dart:convert';
import 'dart:ui' show Rect;

import '../enums/fastpix_spritesheet_type.dart';

/// One thumbnail in a spritesheet.
class FastPixSpritesheetTile {
  /// Position in the sheet's tile list, from 0.
  final int index;

  /// Media time at which this tile becomes active.
  final Duration start;

  /// Media time at which the next tile takes over, or the media duration for
  /// the last tile. The tile is active from [start] up to, but not including,
  /// [end].
  final Duration end;

  /// Where the tile sits in the full-size spritesheet image, in its pixels.
  final Rect region;

  const FastPixSpritesheetTile({
    required this.index,
    required this.start,
    required this.end,
    required this.region,
  });

  @override
  String toString() =>
      'FastPixSpritesheetTile($index, ${start.inMilliseconds}ms-'
      '${end.inMilliseconds}ms, $region)';
}

/// The spritesheet loaded for a source: its tiles, and the image they are cut
/// from.
class FastPixSpritesheet {
  /// Which spritesheet this is.
  final FastPixSpritesheetType type;

  /// The image the tiles are cut from.
  ///
  /// Built by the player from the host, playback ID and token; the `url` in the
  /// metadata is deliberately not used, since the service has been seen to
  /// return it with doubled slashes and mis-cased file names.
  final Uri imageUrl;

  /// Width of every tile, in image pixels.
  final int tileWidth;

  /// Height of every tile, in image pixels.
  final int tileHeight;

  /// Media duration the sheet covers, as reported by the metadata.
  final Duration duration;

  /// Seconds between tiles for an advanced spritesheet; null for normal.
  final int? interval;

  /// The tiles, in the order the metadata lists them.
  final List<FastPixSpritesheetTile> tiles;

  const FastPixSpritesheet({
    required this.type,
    required this.imageUrl,
    required this.tileWidth,
    required this.tileHeight,
    required this.duration,
    required this.tiles,
    this.interval,
  });

  /// Parse the FastPix spritesheet metadata in [body].
  ///
  /// Tiles come only from `tiles[]`. Their count is never derived from duration
  /// and interval: the service returns one fewer than `ceil(duration /
  /// interval)`, with the last tile running to the end.
  ///
  /// Throws a [FormatException] for anything unusable — invalid JSON, no tiles,
  /// or a non-positive tile size or duration.
  factory FastPixSpritesheet.parse(
    String body, {
    required FastPixSpritesheetType type,
    required Uri imageUrl,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const FormatException('Spritesheet metadata is not valid JSON.');
    }
    if (decoded is! Map) {
      throw const FormatException('Spritesheet metadata is not an object.');
    }

    final width = _positiveInt(
      decoded['tile_width'],
      'Spritesheet tile size must be positive.',
    );
    final height = _positiveInt(
      decoded['tile_height'],
      'Spritesheet tile size must be positive.',
    );
    final durationSeconds = decoded['duration'];
    if (durationSeconds is! num || durationSeconds <= 0) {
      throw const FormatException('Spritesheet duration must be positive.');
    }
    final rawTiles = decoded['tiles'];
    if (rawTiles is! List || rawTiles.isEmpty) {
      throw const FormatException('Spritesheet metadata lists no tiles.');
    }

    final duration = _seconds(durationSeconds);
    final tiles = _parseTiles(
      rawTiles,
      width: width,
      height: height,
      duration: duration,
    );

    final interval = decoded['interval'];
    return FastPixSpritesheet(
      type: type,
      imageUrl: imageUrl,
      tileWidth: width,
      tileHeight: height,
      duration: duration,
      interval: interval is num ? interval.toInt() : null,
      tiles: List<FastPixSpritesheetTile>.unmodifiable(tiles),
    );
  }

  /// The tile covering [position].
  ///
  /// Found by the tiles' start times: never by dividing the position by an
  /// interval, which drifts onto the previous tile because the tile count is
  /// one short of `duration / interval`. A negative position resolves to the
  /// first tile, and anything at or past the last tile's start to the last.
  FastPixSpritesheetTile? tileAt(Duration position) {
    if (tiles.isEmpty) return null;
    // Last tile whose start is at or before the position.
    var low = 0;
    var high = tiles.length - 1;
    var found = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (tiles[mid].start <= position) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return tiles[found];
  }

  /// A positive `tile_width` or `tile_height`, or a [FormatException].
  static int _positiveInt(Object? value, String message) {
    if (value is! num || value <= 0) {
      throw FormatException(message);
    }
    return value.toInt();
  }

  /// The `tiles[]` entries, in order, each running to the next tile's start and
  /// the last to [duration].
  static List<FastPixSpritesheetTile> _parseTiles(
    List<Object?> rawTiles, {
    required int width,
    required int height,
    required Duration duration,
  }) {
    final starts = <Duration>[];
    final regions = <Rect>[];
    for (final raw in rawTiles) {
      if (raw is! Map) {
        throw const FormatException('Every spritesheet tile must be an object.');
      }
      final start = raw['start'];
      final x = raw['x'];
      final y = raw['y'];
      if (start is! num || x is! num || y is! num) {
        throw const FormatException(
          'Every spritesheet tile needs a numeric start, x and y.',
        );
      }
      starts.add(_seconds(start));
      regions.add(
        Rect.fromLTWH(
          x.toDouble(),
          y.toDouble(),
          width.toDouble(),
          height.toDouble(),
        ),
      );
    }

    return <FastPixSpritesheetTile>[
      for (var i = 0; i < starts.length; i++)
        FastPixSpritesheetTile(
          index: i,
          start: starts[i],
          end: i + 1 < starts.length ? starts[i + 1] : duration,
          region: regions[i],
        ),
    ];
  }

  static Duration _seconds(num seconds) =>
      Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());

  @override
  String toString() =>
      'FastPixSpritesheet(${type.name}, ${tiles.length} tiles, '
      'interval: $interval)';
}
