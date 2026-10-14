// Imports only the package entry point, deliberately: everything a host needs
// for seek previews must be reachable without importing anything under `src/`.
import 'dart:ui' show Rect;

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the whole seek preview surface is exported from the package', () {
    // Configuration.
    expect(
      FastPixPlayerConfiguration(
        'ws',
        'viewer',
        'beacon',
        spritesheetConfiguration: const FastPixPlayerSpritesheetConfiguration(
          enableAdvancedSpritesheet: true,
          advancedSpritesheetInterval: 2,
        ),
      ).spritesheetConfiguration.resolvedInterval,
      2,
    );
    expect(
      FastPixPlayerDataSource.hls(
        playbackId: 'a',
        customDomain: 'stream.fastpix.co',
      ).imagesHost,
      'https://images.fastpix.co',
    );

    // Models and enums.
    const tile = FastPixSpritesheetTile(
      index: 0,
      start: Duration.zero,
      end: Duration(seconds: 10),
      region: Rect.fromLTWH(0, 0, 256, 160),
    );
    final sheet = FastPixSpritesheet(
      type: FastPixSpritesheetType.normal,
      imageUrl: Uri.parse('https://images.fastpix.com/a/spritesheet.jpg'),
      tileWidth: 256,
      tileHeight: 160,
      duration: const Duration(seconds: 10),
      tiles: const <FastPixSpritesheetTile>[tile],
    );
    expect(sheet.tileAt(const Duration(seconds: 3)), same(tile));
    expect(FastPixSpritesheetType.advanced, isA<FastPixSpritesheetType>());
    expect(FastPixSpritesheetStatus.ready, isA<FastPixSpritesheetStatus>());
    expect(FastPixSpritesheetErrorCode.decodeFailed.value, 'decodeFailed');

    // Events.
    final now = DateTime.now();
    expect(
      FastPixSpritesheetLoadStartedEvent(
        timestamp: now,
        spritesheetType: FastPixSpritesheetType.normal,
      ).type,
      FastPixPlayerEventTypes.spritesheetLoadStarted,
    );
    expect(
      FastPixSpritesheetLoadedEvent(
        timestamp: now,
        spritesheetType: FastPixSpritesheetType.advanced,
        interval: 2,
        tileCount: 1,
      ).type,
      FastPixPlayerEventTypes.spritesheetLoaded,
    );
    expect(
      FastPixSpritesheetImageReadyEvent(
        timestamp: now,
        spritesheetType: FastPixSpritesheetType.normal,
        decodeScale: 1,
      ).type,
      FastPixPlayerEventTypes.spritesheetImageReady,
    );
    expect(
      FastPixSpritesheetFailedEvent(
        timestamp: now,
        spritesheetType: FastPixSpritesheetType.normal,
        code: FastPixSpritesheetErrorCode.mediaNotFound,
        message: 'm',
      ),
      isNot(isA<FastPixPlayerErrorEvent>()),
    );
    expect(FastPixPlayerEventTypes.spritesheet, hasLength(4));
    expect(
      FastPixPlayerEventTypes.all,
      containsAll(FastPixPlayerEventTypes.spritesheet),
    );

    // Controller surface and widget.
    final controller = FastPixPlayerController();
    expect(controller.spritesheet, isNull);
    expect(controller.spritesheetStatus, FastPixSpritesheetStatus.idle);
    expect(controller.spritesheetTileAt(Duration.zero), isNull);
    expect(controller.spritesheetStream, isA<Stream<FastPixSpritesheet?>>());
    expect(
      FastPixSeekPreview(controller: controller, position: Duration.zero),
      isA<FastPixSeekPreview>(),
    );
  });
}
