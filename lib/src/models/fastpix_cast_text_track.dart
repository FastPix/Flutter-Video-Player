import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

/// A subtitle or caption track the receiver is offering.
///
/// Wraps the plugin's `GoogleCastMediaTrack` for the same reason
/// [FastPixCastDevice] wraps `GoogleCastDevice`: keeping third-party types out
/// of a published public API.
///
/// Tracks come from two places and this model does not distinguish them,
/// because a viewer should not have to care: those declared in
/// [FastPixPlayerDataSource.subtitles] are sent to the receiver on load, and
/// those inside the HLS manifest are found by the receiver itself and reported
/// back in its media status.
class FastPixCastTextTrack {
  /// Receiver-assigned track ID, used to select it.
  final int id;

  /// Label to show, for example "English (CC)".
  ///
  /// Falls back to the language code, then to the track ID, since a receiver
  /// may report a track with no name at all.
  final String label;

  /// RFC 5646 language code, when the receiver reported one.
  final String? languageCode;

  /// Whether the track is closed captions rather than plain subtitles.
  final bool isClosedCaption;

  const FastPixCastTextTrack({
    required this.id,
    required this.label,
    this.languageCode,
    this.isClosedCaption = false,
  });

  /// Map a text track reported by the Cast plugin onto the FastPix model.
  factory FastPixCastTextTrack.fromPlugin(GoogleCastMediaTrack track) {
    final language = track.language?.value;
    final name = track.name;
    return FastPixCastTextTrack(
      id: track.trackId,
      label:
          (name != null && name.isNotEmpty)
              ? name
              : (language ?? 'Track ${track.trackId}'),
      languageCode: language,
      isClosedCaption: track.subtype == TextTrackType.captions,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FastPixCastTextTrack && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'FastPixCastTextTrack(id: $id, label: $label)';
}
