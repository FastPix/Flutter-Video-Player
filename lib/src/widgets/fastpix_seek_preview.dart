import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../fastpix_player_controller.dart';
import '../managers/fastpix_spritesheet_manager.dart';
import '../models/fastpix_spritesheet.dart';

/// A seek-preview thumbnail: the spritesheet tile for [position], from the
/// controller's active source.
///
/// Built for a custom seek bar — place it above the thumb while the viewer
/// scrubs, passing the scrub position. Where it sits is the application's to
/// decide.
///
/// When no image is drawable — spritesheets disabled, a live source, the image
/// still loading or generating, or a failure — it shows only the time, never a
/// loading indicator or an error. It follows the controller on its own: an
/// image that arrives while it is on screen replaces the time-only view, and a
/// source change clears it.
class FastPixSeekPreview extends StatefulWidget {
  const FastPixSeekPreview({
    super.key,
    required this.controller,
    required this.position,
    this.width = 160,
    this.showTime = true,
  });

  /// The controller whose spritesheet is drawn.
  final FastPixPlayerController controller;

  /// The media position to preview.
  final Duration position;

  /// Width of the thumbnail. Its height follows the tile's aspect ratio.
  final double width;

  /// Whether the time is shown beneath the thumbnail. The time is always shown
  /// when there is no thumbnail to draw.
  final bool showTime;

  @override
  State<FastPixSeekPreview> createState() => _FastPixSeekPreviewState();
}

class _FastPixSeekPreviewState extends State<FastPixSeekPreview> {
  StreamSubscription<FastPixSpritesheet?>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(FastPixSeekPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _subscription?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.controller.spritesheetStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  static String _format(Duration position) {
    final total = position.isNegative ? 0 : position.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final time = Text(
      _format(widget.position),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontFeatures: <ui.FontFeature>[ui.FontFeature.tabularFigures()],
      ),
    );

    final manager = fastPixSpritesheetManagers[widget.controller];
    final sheet = manager?.spritesheet;
    final image = manager?.image;
    final tile = sheet?.tileAt(widget.position);

    if (manager == null || sheet == null || image == null || tile == null) {
      return DecoratedBox(
        key: const ValueKey<String>('fastpix-seek-preview-time'),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: time,
        ),
      );
    }

    final height = widget.width * sheet.tileHeight / sheet.tileWidth;
    return Column(
      key: const ValueKey<String>('fastpix-seek-preview-tile'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: CustomPaint(
            size: Size(widget.width, height),
            painter: FastPixSeekPreviewPainter(
              image: image,
              tile: tile,
              decodeScale: manager.decodeScale,
            ),
          ),
        ),
        if (widget.showTime)
          Padding(padding: const EdgeInsets.only(top: 4), child: time),
      ],
    );
  }
}

/// Paints one spritesheet tile scaled to fill its canvas.
///
/// Repaints only when the tile or the image changes, so a scrub that stays
/// within one tile costs no painting.
class FastPixSeekPreviewPainter extends CustomPainter {
  FastPixSeekPreviewPainter({
    required this.image,
    required this.tile,
    required this.decodeScale,
  });

  final ui.Image image;
  final FastPixSpritesheetTile tile;
  final double decodeScale;

  @override
  void paint(Canvas canvas, Size size) {
    final region = tile.region;
    // The tile region is in full-size pixels; the image may be decoded smaller.
    final source = Rect.fromLTWH(
      region.left * decodeScale,
      region.top * decodeScale,
      region.width * decodeScale,
      region.height * decodeScale,
    );
    canvas.drawImageRect(
      image,
      source,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(FastPixSeekPreviewPainter oldDelegate) =>
      oldDelegate.tile.index != tile.index ||
      !identical(oldDelegate.image, image) ||
      oldDelegate.decodeScale != decodeScale;
}
