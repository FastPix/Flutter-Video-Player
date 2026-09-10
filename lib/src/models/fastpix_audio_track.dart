import 'package:better_player_plus/better_player_plus.dart';

/// A single selectable audio track, in FastPix-owned terms.
///
/// Wraps the engine's `BetterPlayerAsmsAudioTrack` so a custom audio menu never
/// touches an engine type (Principle 4).
class FastPixAudioTrack {
  /// Stable identifier used to select this track. The engine keys audio tracks
  /// by an integer index; it is stringified here so the public model carries no
  /// engine-specific numeric convention.
  final String id;

  /// Human-readable label, e.g. `English (Director's commentary)`. Null when
  /// the stream declared none.
  final String? label;

  /// BCP-47 / ISO language code, e.g. `en`. Null when the stream declared none.
  final String? language;

  const FastPixAudioTrack({required this.id, this.label, this.language});

  /// Build from an engine track. [index] is the position in the engine's audio
  /// track list, which is what selection is ultimately keyed on.
  factory FastPixAudioTrack.fromAsmsAudioTrack(
    BetterPlayerAsmsAudioTrack track,
    int index,
  ) {
    return FastPixAudioTrack(
      id: (track.id ?? index).toString(),
      label: track.label,
      language: track.language,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FastPixAudioTrack &&
      other.id == id &&
      other.label == label &&
      other.language == language;

  @override
  int get hashCode => Object.hash(id, label, language);

  @override
  String toString() =>
      'FastPixAudioTrack(id: $id, label: $label, language: $language)';
}
