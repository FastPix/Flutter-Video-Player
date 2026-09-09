import 'package:better_player_plus/better_player_plus.dart';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

/// Rebuilds a view when the engine reports a new video size.
///
/// Nothing here decides layout — the player box stays the shape its widget
/// asks for. This exists for a rendering detail on Android: the engine draws
/// the video as a `FittedBox` over a `SizedBox` sized from
/// `videoPlayerController.value.size`
/// (`better_player_with_controls.dart:270-283`), and the state that owns it
/// calls `setState` only when `initialized` flips or on its own
/// play/setupDataSource events. A size that lands outside those moments — a
/// playlist advance into a differently shaped video is the common one — is
/// never picked up, so the new source is drawn fitted to the *previous* one's
/// dimensions and appears squeezed until something else forces a rebuild.
///
/// A host rebuild does force it, so views watch the size and rebuild on a
/// change. iOS is unaffected either way: it takes the `SizedBox.expand` branch
/// two lines above, with no `FittedBox` to hold a stale shape.
///
/// [onSizeChanged] fires only when the size actually moves, never on the
/// ordinary position ticks that also notify the same notifier.
class FastPixVideoSizeWatcher {
  FastPixVideoSizeWatcher(this.onSizeChanged);

  /// Called when the reported video size changes.
  final VoidCallback onSizeChanged;

  /// Held as the notifier supertype: `VideoPlayerController` is internal to
  /// better_player and not exported, but it *is* a
  /// `ValueNotifier<VideoPlayerValue>`.
  ValueNotifier<VideoPlayerValue>? _video;

  Size? _size;

  /// The engine's reported video size, or null before it has one.
  Size? get size => _size;

  /// Point at [controller]'s current engine player. Safe to call on every
  /// rebind; re-pointing at the same player is a no-op beyond a re-read.
  void watch(BetterPlayerController? controller) =>
      watchValue(controller?.videoPlayerController);

  /// The same, given the engine player directly. Separate because
  /// `BetterPlayerController` cannot be constructed without a platform, while
  /// this half is testable on its own.
  void watchValue(ValueNotifier<VideoPlayerValue>? video) {
    if (identical(video, _video)) {
      _read();
      return;
    }
    _video?.removeListener(_read);
    _video = video;
    // A different player has not reported anything yet; keeping the previous
    // source's size is what leaves the stale shape on screen.
    _size = null;
    _video?.addListener(_read);
    _read();
  }

  void dispose() {
    _video?.removeListener(_read);
    _video = null;
  }

  void _read() {
    final next = _video?.value.size;
    if (next == null || next.width <= 0 || next.height <= 0) return;
    if (_size == next) return;
    _size = next;
    onSizeChanged();
  }
}
