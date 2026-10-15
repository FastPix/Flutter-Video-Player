import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

/// Reference seekbar with buffered progress, correct scrub handling and a
/// thumbnail preview.
///
/// Reference component (Feature 6), built only on the public API. It shows the
/// behaviours the design calls for:
///
/// * The handle follows the **user's** drag, not the player's reported
///   position, because `playbackStateStream` reports the scrub target while
///   `controller.isScrubbing` (the SDK does that when `beginScrub`/`updateScrub`
///   are used).
/// * The player is sought **once**, on release (`endScrub`), never during the
///   drag (`updateScrub` does not seek).
/// * While dragging, a [FastPixSeekPreview] for the dragged-to position sits
///   above the thumb, kept within the bar, and disappears on release. The SDK
///   draws the spritesheet tile, or only the time when there is none.
/// * Pause-on-scrub is left to the app — this widget does not touch play/pause.
///
/// Edge cases handled: an unknown duration (live / not yet reported) disables
/// dragging rather than dividing by zero, every value is clamped to the
/// current duration so a release outside range is safe, and a bar removed
/// mid-drag — fullscreen or PiP rebuilding the controls — commits the drag as
/// if released there (see [_FastPixSeekBarState.dispose]).
class FastPixSeekBar extends StatefulWidget {
  const FastPixSeekBar({
    super.key,
    required this.controller,
    this.playedColor = const Color(0xFFFF2D55),
    this.bufferedColor = Colors.white38,
    this.trackColor = Colors.white24,
    this.showLabels = true,
    this.showPreview = true,
    this.previewWidth = 160,
    this.previewMaxHeight,
  });

  final FastPixPlayerController controller;
  final Color playedColor;
  final Color bufferedColor;
  final Color trackColor;
  final bool showLabels;

  /// Whether a thumbnail preview is shown above the thumb while dragging.
  final bool showPreview;

  /// Largest width of the preview thumbnail. It is drawn smaller when the bar
  /// is narrow or the tile would be taller than [previewMaxHeight] — see
  /// [previewWidthFor].
  final double previewWidth;

  /// Tallest the preview thumbnail may be, or null for no limit. The seek bar
  /// cannot see the player around it, so whoever lays it out passes this.
  final double? previewMaxHeight;

  /// Share of the bar's width the preview may take. A fixed 160 took about
  /// half of a portrait phone's bar; 0.4 then left it about 70x44 there,
  /// too small to read. A wide bar still stops at [previewWidth].
  static const double _maxBarFraction = 0.55;

  /// The width to draw the preview at, for a bar [barWidth] wide.
  ///
  /// The height follows the tile's shape, which varies: a landscape video's
  /// tiles are 256x160, a vertical reel's 160x256. At a fixed 160 wide the
  /// reel's preview was 256 tall — taller than the inline player it sat on —
  /// and even a landscape one covered about two thirds of a portrait inline
  /// player. So the width is capped by the bar, then reduced further if the
  /// tile would be taller than [previewMaxHeight].
  @visibleForTesting
  double previewWidthFor(double barWidth) {
    var width = previewWidth;
    final byBar = barWidth * _maxBarFraction;
    if (byBar > 0 && byBar < width) width = byBar;

    final maxHeight = previewMaxHeight;
    final sheet = controller.spritesheet;
    if (maxHeight != null &&
        maxHeight > 0 &&
        sheet != null &&
        sheet.tileWidth > 0 &&
        sheet.tileHeight > 0) {
      final height = width * sheet.tileHeight / sheet.tileWidth;
      if (height > maxHeight) {
        width = maxHeight * sheet.tileWidth / sheet.tileHeight;
      }
    }
    return width;
  }

  @override
  State<FastPixSeekBar> createState() => _FastPixSeekBarState();
}

class _FastPixSeekBarState extends State<FastPixSeekBar> {
  /// Whether this bar started the scrub in progress and has not ended it.
  ///
  /// Held here, not read from `controller.isScrubbing`, because when the
  /// controls are rebuilt the new bar is built before the old one is disposed
  /// and both see the same controller: only the bar that began the scrub may
  /// end it.
  bool _dragging = false;

  /// Where the finger last was, in milliseconds, for a drag that never gets
  /// its release.
  double _dragValue = 0;

  FastPixPlayerController get controller => widget.controller;

  /// Horizontal inset of the slider's track from its own edges: the larger of
  /// the thumb and overlay radii configured below.
  static const double _trackInset = 14;

  /// Gap between the top of the slider and the bottom of the preview.
  static const double _previewGap = 4;

  static String _fmt(Duration d) {
    final total = d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  static const TextStyle _labelStyle = TextStyle(
    color: Colors.white,
    fontSize: 12,
  );

  /// A slider removed while the finger is down — entering fullscreen or PiP
  /// mid-drag swaps the controls' tree — gets neither its drag-end nor its
  /// drag-cancel callback: disposing a drag that has already won the gesture
  /// arena drops the pointer silently. `endScrub` would never run, leaving the
  /// SDK reporting the drag target as the position, so the preview and the
  /// time label froze until the next drag. Ended where the finger was, as a
  /// release there would have: the viewer chose that position before the
  /// layout changed, and cancelling snapped playback back to where it was.
  @override
  void dispose() {
    if (_dragging) controller.endScrub(_toDuration(_dragValue));
    super.dispose();
  }

  void _onScrubStart(double value) {
    _dragging = true;
    _dragValue = value;
    controller.beginScrub(_toDuration(value));
  }

  void _onScrubUpdate(double value) {
    _dragValue = value;
    controller.updateScrub(_toDuration(value));
  }

  void _onScrubEnd(double value) {
    _dragging = false;
    controller.endScrub(_toDuration(value));
  }

  /// A bar that loses its duration mid-drag — the source changing under the
  /// finger — disables itself, and a disabled slider drops the release rather
  /// than reporting it: `onChangeEnd` is read when the finger lifts, and by
  /// then it is null. `endScrub` would never run, leaving the SDK scrubbing
  /// with the time and preview frozen and the ±10s buttons ignored.
  ///
  /// Abandoned rather than ended: the target was chosen on the old duration,
  /// and seeking the new source there would be a jump the viewer never asked
  /// for. After the frame, since it publishes to the stream being built.
  void _dropDragIfDisabled(bool hasDuration) {
    if (hasDuration || !_dragging) return;
    _dragging = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_dragging) controller.cancelScrub();
    });
  }

  /// A stream with no duration yet — a live edge, or a source still loading —
  /// gets an inert track rather than a scrubbable one, so the whole slider is
  /// built from this single flag.
  Widget _buildSlider(BuildContext context, FastPixPlaybackState state) {
    final durationMs = state.duration.inMilliseconds;
    final hasDuration = durationMs > 0;
    _dropDragIfDisabled(hasDuration);
    final upperBound = hasDuration ? durationMs : 0;
    final positionMs = state.position.inMilliseconds
        .clamp(0, upperBound)
        .toDouble();
    final bufferedMs = state.bufferedPosition.inMilliseconds
        .clamp(0, upperBound)
        .toDouble();

    // A fixed height: a Slider stretches to fill a tall box, which would move
    // its track away from where the preview is placed above it.
    return SizedBox(
      height: kMinInteractiveDimension,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          activeTrackColor: widget.playedColor,
          inactiveTrackColor: widget.trackColor,
          secondaryActiveTrackColor: widget.bufferedColor,
          thumbColor: widget.playedColor,
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        ),
        child: Slider(
          min: 0,
          max: hasDuration ? durationMs.toDouble() : 1,
          value: hasDuration ? positionMs : 0,
          // The buffered edge painted behind the played portion.
          secondaryTrackValue: hasDuration ? bufferedMs : null,
          onChangeStart: hasDuration ? _onScrubStart : null,
          onChanged: hasDuration ? _onScrubUpdate : null,
          onChangeEnd: hasDuration ? _onScrubEnd : null,
        ),
      ),
    );
  }

  /// The slider with the preview floating above its thumb while scrubbing.
  ///
  /// The preview overflows upwards out of the slider's box rather than taking
  /// layout space, so the bar keeps its height whether or not a drag is on.
  ///
  /// The tree is the same shape with or without the preview. Wrapping the
  /// slider only once a drag starts would rebuild it mid-gesture, and the
  /// release — and with it `endScrub` — would never arrive.
  Widget _buildSliderWithPreview(
    BuildContext context,
    FastPixPlaybackState state,
  ) {
    final slider = _buildSlider(context, state);
    final durationMs = state.duration.inMilliseconds;
    final previewing =
        widget.showPreview && controller.isScrubbing && durationMs > 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final previewWidth = widget.previewWidthFor(width);
        final fraction = previewing
            ? (state.position.inMilliseconds / durationMs).clamp(0.0, 1.0)
            : 0.0;
        final thumbX = _trackInset + fraction * (width - 2 * _trackInset);
        final left = (thumbX - previewWidth / 2).clamp(
          0.0,
          (width - previewWidth).clamp(0.0, double.infinity),
        );

        return Stack(
          clipBehavior: Clip.none,
          children: [
            slider,
            if (previewing)
              Positioned(
                left: left,
                bottom: kMinInteractiveDimension + _previewGap,
                width: previewWidth,
                child: Center(
                  child: FastPixSeekPreview(
                    controller: controller,
                    position: state.position,
                    width: previewWidth,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// The slider reports milliseconds as a double; every scrub callback wants
  /// the same [Duration], so the conversion is written once.
  static Duration _toDuration(double value) =>
      Duration(milliseconds: value.round());

  Widget _buildBar(BuildContext context, FastPixPlaybackState state) {
    final slider = _buildSliderWithPreview(context, state);
    if (!widget.showLabels) return slider;

    final hasDuration = state.duration.inMilliseconds > 0;
    // "LIVE" only for a live source. A missing duration is not one: every
    // on-demand video has none while it loads, and keeps none if it fails,
    // and labelling those LIVE told the viewer they were watching a stream.
    final source = controller.currentPlaylistItem ?? controller.dataSource;
    final isLive = source?.streamType == StreamType.live;
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
            hasDuration ? _fmt(state.duration) : (isLive ? 'LIVE' : '--:--'),
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
