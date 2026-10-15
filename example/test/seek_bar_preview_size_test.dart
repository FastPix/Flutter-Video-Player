import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fastpix_player_example/src/custom_ui/fastpix_seek_bar.dart';

/// A controller holding a spritesheet with [tileWidth] x [tileHeight] tiles.
class _SheetController extends FastPixPlayerController {
  _SheetController(int tileWidth, int tileHeight)
      : _sheet = FastPixSpritesheet(
          type: FastPixSpritesheetType.normal,
          imageUrl: Uri.parse('https://images.fastpix.com/a/spritesheet.jpg'),
          tileWidth: tileWidth,
          tileHeight: tileHeight,
          duration: const Duration(seconds: 10),
          tiles: const <FastPixSpritesheetTile>[],
        );

  final FastPixSpritesheet _sheet;

  @override
  FastPixSpritesheet? get spritesheet => _sheet;
}

/// The seek preview used to be a fixed 160 wide whatever the layout. With the
/// real tile sizes the images service returns — 256x160 for a landscape video,
/// 160x256 for a vertical reel — that covered most of a portrait inline
/// player, and a reel's preview was taller than the player itself.
void main() {
  double widthFor(
    FastPixPlayerController controller, {
    required double barWidth,
    double? maxHeight,
  }) =>
      FastPixSeekBar(controller: controller, previewMaxHeight: maxHeight)
          .previewWidthFor(barWidth);

  test('a wide bar keeps the full 160', () {
    expect(widthFor(_SheetController(256, 160), barWidth: 700), 160);
  });

  test('a portrait bar shrinks it to 55% of the bar', () {
    expect(widthFor(_SheetController(256, 160), barWidth: 280), 154);
  });

  test('a vertical reel is held to the height limit', () {
    // A 16:9 inline player ~225 tall allows 90 of preview; a 160x256 tile
    // that tall is 56.25 wide.
    final width = widthFor(
      _SheetController(160, 256),
      barWidth: 280,
      maxHeight: 90,
    );
    expect(width, closeTo(56.25, 0.001));
    expect(width * 256 / 160, closeTo(90, 0.001));
  });

  test('a landscape tile already under the limit is left alone', () {
    expect(
      widthFor(_SheetController(256, 160), barWidth: 280, maxHeight: 100),
      154,
    );
  });

  test('with no spritesheet only the bar limits it', () {
    expect(
      widthFor(FastPixPlayerController(), barWidth: 280, maxHeight: 10),
      154,
    );
  });
}
