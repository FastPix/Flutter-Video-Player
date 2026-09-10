import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

/// A playlist previous/next glyph for a custom UI, built on the public
/// controller API only — the same API the default skin's own overlay uses.
///
/// The position is read from [FastPixPlayerController.playlistStateStream] and
/// nowhere else: the app keeps no index of its own, so the button cannot drift
/// out of step with what is actually playing. `initialData` is seeded from
/// [FastPixPlayerController.playlistState] so it is correct on its first frame
/// rather than blank until the first item change.
///
/// With fewer than two items there is nothing to navigate, so the button
/// collapses rather than sitting there permanently dead. At either end of a
/// playlist the glyph on that side dims and stops taking taps but keeps its
/// space, so the transport does not reflow under the viewer's finger.
class FastPixPlaylistNavButton extends StatelessWidget {
  const FastPixPlaylistNavButton.previous({
    super.key,
    required this.controller,
    this.iconSize = 32,
    this.color = Colors.white,
  }) : _isPrevious = true;

  const FastPixPlaylistNavButton.next({
    super.key,
    required this.controller,
    this.iconSize = 32,
    this.color = Colors.white,
  }) : _isPrevious = false;

  final FastPixPlayerController controller;
  final double iconSize;
  final Color color;
  final bool _isPrevious;

  /// Everything that differs between the two directions, read once each,
  /// so the button itself is written a single time.
  IconData get _icon =>
      _isPrevious ? Icons.skip_previous_rounded : Icons.skip_next_rounded;

  String get _tooltip => _isPrevious ? 'Previous video' : 'Next video';

  bool _canMove(FastPixPlaylistState state) =>
      _isPrevious ? state.canGoPrevious : state.canGoNext;

  // `previous()`/`next()` report whether they moved; the state stream that
  // follows is what redraws this button, so the result is not needed here.
  void _move() {
    if (_isPrevious) {
      controller.previous();
    } else {
      controller.next();
    }
  }

  Widget _buildButton(FastPixPlaylistState state) {
    if (state.count < 2) return const SizedBox.shrink();

    final canMove = _canMove(state);
    return Opacity(
      opacity: canMove ? 1 : 0.3,
      child: IconButton(
        iconSize: iconSize,
        color: color,
        icon: Icon(_icon),
        tooltip: _tooltip,
        onPressed: canMove ? _move : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<FastPixPlaylistState>(
      stream: controller.playlistStateStream,
      initialData: controller.playlistState,
      builder: (context, snapshot) =>
          _buildButton(snapshot.data ?? controller.playlistState),
    );
  }
}
