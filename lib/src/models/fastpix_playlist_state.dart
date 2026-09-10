import 'package:fastpix_video_player/fastpix_video_player.dart';

/// A snapshot of where the playlist is, for hosts that render state rather
/// than react to transitions.
///
/// Every value here derives from the active index, which is the single
/// authority for what is playing: no two fields can disagree about it.
class FastPixPlaylistState {
  /// Zero-based position of the active item, or `-1` when the playlist holds
  /// no active position — after a source outside the playlist was loaded, or
  /// when there is no playlist at all.
  final int index;

  /// The active item, or null when there is no active position.
  final FastPixPlayerDataSource? item;

  /// How many items the playlist holds.
  final int count;

  /// Whether a later item exists to move to.
  final bool canGoNext;

  /// Whether an earlier item exists to move to.
  final bool canGoPrevious;

  const FastPixPlaylistState({
    required this.index,
    required this.item,
    required this.count,
    required this.canGoNext,
    required this.canGoPrevious,
  });

  /// No playlist set.
  static const FastPixPlaylistState empty = FastPixPlaylistState(
    index: -1,
    item: null,
    count: 0,
    canGoNext: false,
    canGoPrevious: false,
  );

  /// Whether a playlist is present at all.
  bool get hasPlaylist => count > 0;

  /// Position for display, e.g. "3 of 12"; empty when unpositioned.
  String get position => index < 0 ? '' : '${index + 1} of $count';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FastPixPlaylistState &&
          other.index == index &&
          other.item == item &&
          other.count == count &&
          other.canGoNext == canGoNext &&
          other.canGoPrevious == canGoPrevious;

  @override
  int get hashCode => Object.hash(index, item, count, canGoNext, canGoPrevious);

  @override
  String toString() =>
      'FastPixPlaylistState(index: $index, count: $count, '
      'canGoNext: $canGoNext, canGoPrevious: $canGoPrevious)';
}
