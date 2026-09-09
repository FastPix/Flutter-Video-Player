import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

/// Reference seekbar with buffered progress and correct scrub handling.
///
/// Reference component (Feature 6), built only on the public API. It shows the
/// three behaviours the design calls for:
///
/// * The handle follows the **user's** drag, not the player's reported
///   position, because `playbackStateStream` reports the scrub target while
///   `controller.isScrubbing` (the SDK does that when `beginScrub`/`updateScrub`
///   are used).
/// * The player is sought **once**, on release (`endScrub`), never during the
///   drag (`updateScrub` does not seek).
/// * Pause-on-scrub is left to the app — this widget does not touch play/pause.
///
/// Edge cases handled: an unknown duration (live / not yet reported) disables
/// dragging rather than dividing by zero, and every value is clamped to the
/// current duration so a release outside range is safe.
class FastPixSeekBar extends StatelessWidget {
  const FastPixSeekBar({
    super.key,
    required this.controller,
    this.playedColor = const Color(0xFFFF2D55),
    this.bufferedColor = Colors.white38,
    this.trackColor = Colors.white24,
    this.showLabels = true,
  });

  final FastPixPlayerController controller;
  final Color playedColor;
  final Color bufferedColor;
  final Color trackColor;
  final bool showLabels;

  static String _fmt(Duration d) {
    final total = d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  static const TextStyle _labelStyle =
      TextStyle(color: Colors.white, fontSize: 12);

  /// A stream with no duration yet — a live edge, or a source still loading —
  /// gets an inert track rather than a scrubbable one, so the whole slider is
  /// built from this single flag.
  Widget _buildSlider(BuildContext context, FastPixPlaybackState state) {
    final durationMs = state.duration.inMilliseconds;
    final hasDuration = durationMs > 0;
    final upperBound = hasDuration ? durationMs : 0;
    final positionMs =
        state.position.inMilliseconds.clamp(0, upperBound).toDouble();
    final bufferedMs =
        state.bufferedPosition.inMilliseconds.clamp(0, upperBound).toDouble();

    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 3,
        activeTrackColor: playedColor,
        inactiveTrackColor: trackColor,
        secondaryActiveTrackColor: bufferedColor,
        thumbColor: playedColor,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      ),
      child: Slider(
        min: 0,
        max: hasDuration ? durationMs.toDouble() : 1,
        value: hasDuration ? positionMs : 0,
        // The buffered edge painted behind the played portion.
        secondaryTrackValue: hasDuration ? bufferedMs : null,
        onChangeStart: hasDuration ? _scrubHandler(controller.beginScrub) : null,
        onChanged: hasDuration ? _scrubHandler(controller.updateScrub) : null,
        onChangeEnd: hasDuration ? _scrubHandler(controller.endScrub) : null,
      ),
    );
  }

  /// The slider reports milliseconds as a double; every scrub callback wants
  /// the same [Duration], so the conversion is written once.
  static ValueChanged<double> _scrubHandler(void Function(Duration) scrub) =>
      (value) => scrub(Duration(milliseconds: value.round()));

  Widget _buildBar(BuildContext context, FastPixPlaybackState state) {
    final slider = _buildSlider(context, state);
    if (!showLabels) return slider;

    final hasDuration = state.duration.inMilliseconds > 0;
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(_fmt(state.position), style: _labelStyle),
        ),
        Expanded(child: slider),
        SizedBox(
          width: 52,
          child: Text(
            hasDuration ? _fmt(state.duration) : 'LIVE',
            textAlign: TextAlign.right,
            style: _labelStyle,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<FastPixPlaybackState>(
      stream: controller.playbackStateStream,
      initialData: controller.playbackState,
      builder: (context, snapshot) =>
          _buildBar(context, snapshot.data ?? FastPixPlaybackState.initial),
    );
  }
}
