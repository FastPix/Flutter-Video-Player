import 'package:fastpix_video_player/fastpix_video_player.dart';

/// The playlist cursor: what the items are, and which one is active.
///
/// Engine-free and synchronous by design. The whole cursor contract — bounds,
/// derivation, warm ordering — is testable with no platform binding, which is
/// how the same logic was already tested while it lived in the example app.
///
/// [currentIndex] is the only stored representation of "what is playing".
/// Everything else derives from it, so there is no second field that can
/// disagree with it about the active item.
class FastPixPlaylistManager {
  List<FastPixPlayerDataSource> _items = const <FastPixPlayerDataSource>[];
  int _currentIndex = -1;

  /// The items, in play order.
  List<FastPixPlayerDataSource> get items =>
      List<FastPixPlayerDataSource>.unmodifiable(_items);

  /// How many items the playlist holds.
  int get count => _items.length;

  /// Whether a playlist is present.
  bool get isEmpty => _items.isEmpty;

  /// Position of the active item, or `-1` when the playlist holds no active
  /// position — which is what loading a source that is not in the playlist
  /// leaves behind.
  int get currentIndex => _currentIndex;

  /// The active item, or null when there is no active position.
  FastPixPlayerDataSource? get currentItem => itemAt(_currentIndex);

  /// The item at [index], or null when [index] is outside the playlist.
  FastPixPlayerDataSource? itemAt(int index) =>
      index >= 0 && index < _items.length ? _items[index] : null;

  /// Whether a later item exists.
  bool get canGoNext => _currentIndex >= 0 && _currentIndex + 1 < _items.length;

  /// Whether an earlier item exists.
  bool get canGoPrevious => _currentIndex > 0;

  /// Adopt [items], positioned at [startIndex].
  ///
  /// The caller validates first: this is the cursor, not the gate.
  void setItems(List<FastPixPlayerDataSource> items, {int startIndex = 0}) {
    _items = List<FastPixPlayerDataSource>.unmodifiable(items);
    _currentIndex = _items.isEmpty ? -1 : startIndex;
  }

  /// Drop the playlist, leaving the controller usable for single-source
  /// playback.
  void clear() {
    _items = const <FastPixPlayerDataSource>[];
    _currentIndex = -1;
  }

  /// Move the cursor to [index], reporting whether it actually moved.
  ///
  /// Out of range, or already there, both report no movement rather than
  /// throwing: navigation that cannot be performed is a normal answer to a
  /// button press, not an error.
  bool moveTo(int index) {
    if (index < 0 || index >= _items.length) return false;
    if (index == _currentIndex) return false;
    _currentIndex = index;
    return true;
  }

  /// Move to the next item, reporting whether it moved.
  bool nextItem() => canGoNext && moveTo(_currentIndex + 1);

  /// Move to the previous item, reporting whether it moved.
  bool previousItem() => canGoPrevious && moveTo(_currentIndex - 1);

  /// Position of the first item whose playback ID is [playbackId], or `-1`.
  int indexOfPlaybackId(String playbackId) =>
      _items.indexWhere((item) => item.playbackId == playbackId);

  /// Point the cursor at [index] without treating it as navigation.
  ///
  /// Used when a playlist is replaced under a playing item, or when a source
  /// loaded directly turns out to be one of the items. `-1` means the playlist
  /// holds no active position.
  void repointTo(int index) {
    _currentIndex = index >= 0 && index < _items.length ? index : -1;
  }

  /// A snapshot of the cursor for hosts that render state.
  FastPixPlaylistState get state => FastPixPlaylistState(
        index: _currentIndex,
        item: currentItem,
        count: _items.length,
        canGoNext: canGoNext,
        canGoPrevious: canGoPrevious,
      );

  /// What to hand [FastPixPreloadManager.preload], most likely first.
  ///
  /// Warms in **both** directions. Preloading only forward leaves the previous
  /// button as a guaranteed cold start — and the viewer who taps it is doing
  /// so deliberately, usually to rewatch something they just saw, so it is a
  /// worse experience than the forward case rather than a rarer one.
  ///
  /// Results interleave outward from the active item — next, previous, next+1,
  /// previous-1 — rather than listing all of one direction first. That matters
  /// because the warming subsystem truncates to its window: a
  /// forward-then-backward ordering with a window of two would warm two items
  /// ahead and nothing behind, which is the bug this ordering exists to fix.
  ///
  /// Forward still wins each tie, since autoplay advances that way on its own
  /// while backward needs a tap.
  ///
  /// Both rules were learned by measurement on device. They are the reason
  /// this lives in the SDK rather than being left to each integrator to
  /// rediscover.
  List<FastPixPlayerDataSource> warmWindow({int radius = 2}) {
    if (_currentIndex < 0) return const <FastPixPlayerDataSource>[];
    final result = <FastPixPlayerDataSource>[];
    for (var offset = 1; offset <= radius; offset++) {
      final ahead = _currentIndex + offset;
      if (ahead < _items.length) result.add(_items[ahead]);

      final behind = _currentIndex - offset;
      if (behind >= 0) result.add(_items[behind]);
    }
    return result;
  }
}
