import 'package:better_player_plus/better_player_plus.dart';

/// A single selectable subtitle/caption track, in FastPix-owned terms.
///
/// Wraps the engine's `BetterPlayerSubtitlesSource` so a custom subtitle menu
/// never references an engine type (Principle 4). The engine treats "off" as a
/// source of type `none`; that source is not modelled here — turning subtitles
/// off is [FastPixPlayerController.disableSubtitles], and the active track being
/// null means off.
class FastPixSubtitleTrack {
  /// Stable identifier used to select this track. Derived from the source name,
  /// falling back to the list index, since engine subtitle sources have no id.
  final String id;

  /// Human-readable label suitable for a menu. Null when the source declared no
  /// name.
  final String? label;

  /// Language code when known. The engine's subtitle source does not always
  /// carry one, so this is frequently null even for a named track.
  final String? language;

  /// Whether the track lives inside the HLS manifest (as opposed to an external
  /// file supplied through [FastPixPlayerDataSource.subtitles]). In-manifest
  /// tracks are discovered by the engine at load time.
  final bool isEmbedded;

  const FastPixSubtitleTrack({
    required this.id,
    this.label,
    this.language,
    this.isEmbedded = false,
  });

  /// Build from an engine subtitle source. [index] disambiguates two sources
  /// that happen to share a name.
  factory FastPixSubtitleTrack.fromSource(
    BetterPlayerSubtitlesSource source,
    int index,
  ) {
    final name = source.name;
    // ASMS (in-manifest) sources are flagged segmented by the engine; external
    // files supplied by the app are not.
    final isEmbedded = source.asmsIsSegmented == true;
    return FastPixSubtitleTrack(
      id: (name != null && name.isNotEmpty) ? name : 'subtitle-$index',
      label: name,
      isEmbedded: isEmbedded,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FastPixSubtitleTrack &&
      other.id == id &&
      other.label == label &&
      other.language == language &&
      other.isEmbedded == isEmbedded;

  @override
  int get hashCode => Object.hash(id, label, language, isEmbedded);

  @override
  String toString() =>
      'FastPixSubtitleTrack(id: $id, label: $label, '
      'language: $language, isEmbedded: $isEmbedded)';
}
