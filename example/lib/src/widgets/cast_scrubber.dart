import 'package:flutter/material.dart';

import '../theme.dart';

/// A drag-to-seek bar whose touch target is the bar and nothing else.
///
/// Written rather than assembled from Material's [Slider] on purpose. A
/// `Slider` sizes its track to whatever box it is given and reacts to a tap
/// anywhere inside it, so one placed in an `Expanded` on the video surface
/// swallows touches meant for the transport buttons and turns them into
/// absolute seeks. better_player's own progress bar is worse: its gesture child
/// is `MediaQuery.size.height / 2` tall, half the screen.
///
/// Here the gesture detector is exactly [touchHeight] tall and no taller, so
/// the bar behaves the way a viewer expects after YouTube — dragging seeks only
/// when the drag starts on the bar, and everything else on the surface keeps
/// working normally.
///
/// Stateless by design: the drag position lives with the caller, so there is
/// one source of truth for what the bar shows and the time readout beside it
/// can follow the thumb.
class CastScrubber extends StatelessWidget {
  const CastScrubber({
    super.key,
    required this.position,
    required this.duration,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onCancel,
    this.touchHeight = 28,
    this.trackHeight = 3,
    this.thumbSize = 12,
  });

  /// Where to draw the playhead — the caller's drag value while a drag is in
  /// progress, the receiver's reported position otherwise.
  final Duration position;

  /// Length of the media. Must be greater than zero; callers show a `LIVE`
  /// label instead when the receiver reports no length.
  final Duration duration;

  /// Called continuously while dragging, so the caller can hold the value and
  /// keep the elapsed-time label with the thumb.
  ///
  /// Deliberately *not* wired straight to a seek: each one is a network round
  /// trip, and one per frame floods the session and makes the thumb fight the
  /// positions coming back.
  final ValueChanged<Duration> onChanged;

  /// Called once, on release or on a completed tap: seek to the last value
  /// [onChanged] reported.
  ///
  /// Takes no position on purpose. Reading it back from [position] would be a
  /// frame behind — pointer events are dispatched in batches, so a drag-end or
  /// a fast tap-up can arrive before the rebuild carrying the value that the
  /// matching [onChanged] just sent. The caller already holds that value
  /// synchronously; it is the only copy guaranteed to be current.
  final VoidCallback onChangeEnd;

  /// Called when the gesture is taken away — a competing recognizer in an
  /// ancestor claiming the pointer, say. The caller should drop its drag value
  /// and go back to following the receiver, without seeking anywhere.
  final VoidCallback onCancel;

  /// Height of the touch target. The band the finger has to land in for a drag
  /// to count — comfortably tappable, and small enough to sit clear of the
  /// controls above it.
  final double touchHeight;

  /// Thickness of the drawn track.
  final double trackHeight;

  /// Diameter of the thumb.
  final double thumbSize;

  Duration _positionAt(double dx, double width) {
    if (width <= 0) return Duration.zero;
    final fraction = (dx / width).clamp(0.0, 1.0);
    return Duration(
      milliseconds: (duration.inMilliseconds * fraction).round(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final played =
            duration > Duration.zero
                ? (position.inMilliseconds / duration.inMilliseconds).clamp(
                  0.0,
                  1.0,
                )
                : 0.0;

        return GestureDetector(
          // Opaque so the band itself is the target: taps inside it belong to
          // the bar, and taps outside it are not the bar's business at all.
          behavior: HitTestBehavior.opaque,
          // Horizontal only. A vertical swipe that starts here still reaches
          // the scroll view behind, so the bar does not become a dead strip
          // the page cannot be scrolled from.
          onHorizontalDragStart:
              (details) =>
                  onChanged(_positionAt(details.localPosition.dx, width)),
          onHorizontalDragUpdate:
              (details) =>
                  onChanged(_positionAt(details.localPosition.dx, width)),
          onHorizontalDragEnd: (_) => onChangeEnd(),
          onHorizontalDragCancel: onCancel,
          // A tap on the bar seeks there, as it does on any scrubber. Safe to
          // offer here precisely because the target is the bar and not the
          // whole surface.
          onTapDown:
              (details) =>
                  onChanged(_positionAt(details.localPosition.dx, width)),
          onTapUp: (_) => onChangeEnd(),
          onTapCancel: onCancel,
          child: SizedBox(
            height: touchHeight,
            width: width,
            child: Center(
              child: SizedBox(
                height: thumbSize,
                width: width,
                child: Stack(
                  children: [
                    _track(
                      left: 0,
                      width: width,
                      color: Colors.white24,
                    ),
                    _track(
                      left: 0,
                      width: width * played,
                      color: AppColors.accent,
                    ),
                    Positioned(
                      // Kept inside the bar at both ends, so the thumb never
                      // hangs past the track it is supposed to sit on.
                      left: (width * played - thumbSize / 2).clamp(
                        0.0,
                        (width - thumbSize).clamp(0.0, double.infinity),
                      ),
                      top: 0,
                      width: thumbSize,
                      height: thumbSize,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _track({
    required double left,
    required double width,
    required Color color,
  }) {
    return Positioned(
      left: left,
      width: width,
      top: (thumbSize - trackHeight) / 2,
      height: trackHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(trackHeight),
        ),
      ),
    );
  }
}
