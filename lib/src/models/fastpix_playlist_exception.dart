/// What was wrong with a playlist.
enum FastPixPlaylistErrorCode {
  /// The list held no items.
  emptyPlaylist('emptyPlaylist'),

  /// An entry had no playback ID, or an empty one.
  missingPlaybackId('missingPlaybackId'),

  /// The JSON could not be decoded, or was not the shape the contract accepts.
  malformedJson('malformedJson'),

  /// An entry was readable JSON but not a usable item.
  malformedEntry('malformedEntry'),

  /// The requested start index was negative, or not less than the item count.
  startIndexOutOfRange('startIndexOutOfRange');

  const FastPixPlaylistErrorCode(this.value);

  /// Stable identifier, safe to log or switch on.
  final String value;
}

/// A playlist was rejected.
///
/// Rejection rather than silence is deliberate: an empty or malformed playlist
/// almost always means the caller's own fetch or filter returned nothing, and
/// the failure mode of silence is a blank player with no diagnostic. The
/// player's existing state is left untouched — nothing is adopted, no source
/// is switched, and any current playback continues.
class FastPixPlaylistException implements Exception {
  /// Which rule was broken.
  final FastPixPlaylistErrorCode code;

  /// What to fix, in a sentence.
  final String message;

  /// Position of the offending entry, when one entry is to blame.
  final int? itemIndex;

  const FastPixPlaylistException(this.code, this.message, {this.itemIndex});

  @override
  String toString() => itemIndex == null
      ? 'FastPixPlaylistException(${code.value}): $message'
      : 'FastPixPlaylistException(${code.value}) at item $itemIndex: $message';
}
