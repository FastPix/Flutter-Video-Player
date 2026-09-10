import 'package:better_player_plus/better_player_plus.dart';

/// A single selectable video quality, in FastPix-owned terms.
///
/// Wraps the engine's `BetterPlayerAsmsTrack` so a custom quality menu never
/// references an engine type (Principle 4). The [automatic] sentinel represents
/// "let the player choose", which is the entry a menu shows at the top and the
/// state after [FastPixPlayerController.setQualityAuto].
class FastPixQualityLevel {
  /// Stable identifier for this rendition. Empty for [automatic]. Derived from
  /// the engine track's id, falling back to `WxH` when the engine gives none.
  final String id;

  /// Human-readable label suitable for a menu, e.g. `1080p` or `Auto`.
  final String label;

  /// Rendition width in pixels, or 0 when unknown / [isAuto].
  final int width;

  /// Rendition height in pixels, or 0 when unknown / [isAuto].
  final int height;

  /// Rendition bitrate in bits per second, or 0 when unknown / [isAuto].
  final int bitrate;

  /// Whether this entry means "automatic" rather than a fixed rendition.
  final bool isAuto;

  const FastPixQualityLevel({
    required this.id,
    required this.label,
    this.width = 0,
    this.height = 0,
    this.bitrate = 0,
    this.isAuto = false,
  });

  /// The "let the player decide" entry.
  static const FastPixQualityLevel automatic = FastPixQualityLevel(
    id: '',
    label: 'Auto',
    isAuto: true,
  );

  /// Build from an engine track.
  ///
  /// An empty engine id (`BetterPlayerAsmsTrack.defaultTrack()`) is the engine's
  /// own way of spelling "automatic", so that maps to [automatic] rather than to
  /// a zero-sized rendition that a menu would render as a blank row.
  factory FastPixQualityLevel.fromAsmsTrack(BetterPlayerAsmsTrack track) {
    final width = track.width ?? 0;
    final height = track.height ?? 0;
    final bitrate = track.bitrate ?? 0;
    final rawId = track.id ?? '';

    final isAuto = rawId.isEmpty && width == 0 && height == 0 && bitrate == 0;
    if (isAuto) return automatic;

    // A rendition is named by its height where it has one; failing that by the
    // engine's own id, and failing that by its bitrate — so a menu row is never
    // blank.
    final String label;
    if (height > 0) {
      label = '${height}p';
    } else if (rawId.isNotEmpty) {
      label = rawId;
    } else {
      label = '${bitrate ~/ 1000} kbps';
    }

    final id = rawId.isNotEmpty ? rawId : '${width}x$height@$bitrate';

    return FastPixQualityLevel(
      id: id,
      label: label,
      width: width,
      height: height,
      bitrate: bitrate,
      isAuto: false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FastPixQualityLevel &&
      other.id == id &&
      other.width == width &&
      other.height == height &&
      other.bitrate == bitrate &&
      other.isAuto == isAuto;

  @override
  int get hashCode => Object.hash(id, width, height, bitrate, isAuto);

  @override
  String toString() =>
      'FastPixQualityLevel(label: $label, ${width}x$height, '
      'bitrate: $bitrate, isAuto: $isAuto)';
}
