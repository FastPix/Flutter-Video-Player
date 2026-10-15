import 'package:better_player_plus/better_player_plus.dart';
// ignore: implementation_imports
import 'package:better_player_plus/src/enum/aspect_enum.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/utils/fastpix_aspect_ratio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// Players of any shape: a 9:16 reel, a 2:3 card, or the video's own shape,
/// with the video either letterboxed or cropped to fill on both platforms.
void main() {
  PlayerTestHarness.install();
  final platform = PlayerTestHarness.platform;

  FastPixPlayerConfiguration config([
    FastPixVideoFit videoFit = FastPixVideoFit.contain,
  ]) => FastPixPlayerConfiguration(
    'workspace',
    'viewer',
    'beacon.example.com',
    videoFit: videoFit,
  );

  group('fastPixResolveAspectRatio', () {
    test('defaults to 16:9', () {
      expect(fastPixResolveAspectRatio(), 16 / 9);
    });

    test('uses the pinned shape', () {
      expect(fastPixResolveAspectRatio(aspectRatio: 9 / 16), 9 / 16);
      expect(fastPixResolveAspectRatio(aspectRatio: 2 / 3), 2 / 3);
    });

    test('a pinned shape wins over the video unless matching it', () {
      expect(
        fastPixResolveAspectRatio(
          aspectRatio: 1,
          videoSize: const Size(1080, 1920),
        ),
        1,
      );
    });

    test("matching the video uses the video's shape once known", () {
      expect(
        fastPixResolveAspectRatio(
          matchVideo: true,
          videoSize: const Size(1080, 1920),
        ),
        1080 / 1920,
      );
    });

    test('matching the video falls back until the video reports a size', () {
      expect(fastPixResolveAspectRatio(matchVideo: true), 16 / 9);
      expect(
        fastPixResolveAspectRatio(aspectRatio: 9 / 16, matchVideo: true),
        9 / 16,
      );
    });

    test('an unusable shape falls back rather than breaking layout', () {
      expect(fastPixResolveAspectRatio(aspectRatio: 0), 16 / 9);
      expect(fastPixResolveAspectRatio(aspectRatio: double.nan), 16 / 9);
      expect(
        fastPixResolveAspectRatio(matchVideo: true, videoSize: Size.zero),
        16 / 9,
      );
    });
  });

  group('fastPixVideoAreaWithin', () {
    test('a vertical video in a 16:9 box fills the middle, full height', () {
      expect(
        fastPixVideoAreaWithin(const Size(320, 180), const Size(1080, 1920)),
        const Size(180 * 1080 / 1920, 180),
      );
    });

    test('a landscape video in a portrait box fills the width', () {
      expect(
        fastPixVideoAreaWithin(const Size(180, 320), const Size(1920, 1080)),
        const Size(180, 180 * 1080 / 1920),
      );
    });

    test('a matching video fills the whole box', () {
      expect(
        fastPixVideoAreaWithin(const Size(320, 180), const Size(1920, 1080)),
        const Size(320, 180),
      );
    });

    test('unknown sizes leave the box as it is', () {
      expect(fastPixVideoAreaWithin(null, const Size(1, 1)), isNull);
      expect(
        fastPixVideoAreaWithin(const Size(320, 180), null),
        const Size(320, 180),
      );
      expect(
        fastPixVideoAreaWithin(const Size(320, 180), Size.zero),
        const Size(320, 180),
      );
    });
  });

  group('videoFit', () {
    test('defaults to contain on both platforms', () {
      final built = buildBetterPlayerConfiguration(configuration: config());
      expect(built.fit, BoxFit.contain);
      // Not the engine's own default, which is `fill` — resizeAspectFill —
      // and made iOS crop what Android letterboxed.
      expect(built.aspectRatioIOS, AspectRatioTypeIOS.aspect);
      expect(
        buildBetterPlayerConfiguration().aspectRatioIOS,
        AspectRatioTypeIOS.aspect,
      );
    });

    test('cover fills on both platforms', () {
      final built = buildBetterPlayerConfiguration(
        configuration: config(FastPixVideoFit.cover),
      );
      expect(built.fit, BoxFit.cover);
      expect(built.aspectRatioIOS, AspectRatioTypeIOS.fill);
    });

    test('is part of the adoption fingerprint', () {
      // Baked into the final configuration, so a player warmed at one fit
      // must never be adopted for a playback that asked for the other.
      expect(
        betterPlayerConfigurationFingerprint(configuration: config()),
        isNot(
          betterPlayerConfigurationFingerprint(
            configuration: config(FastPixVideoFit.cover),
          ),
        ),
      );
    });

    test('an absent configuration fingerprints like a default one', () {
      final absent = betterPlayerConfigurationFingerprint().split('|');
      final defaulted = betterPlayerConfigurationFingerprint(
        configuration: config(),
      ).split('|');
      expect(absent[2], defaulted[2]);
    });

    test('copyWith carries and replaces it', () {
      final covered = config(FastPixVideoFit.cover);
      expect(covered.copyWith().videoFit, FastPixVideoFit.cover);
      expect(
        covered.copyWith(videoFit: FastPixVideoFit.contain).videoFit,
        FastPixVideoFit.contain,
      );
    });
  });

  group('player box', () {
    Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(width: 270, child: child))),
    );

    Future<FastPixPlayerController> loaded(
      WidgetTester tester, {
      Size videoSize = const Size(1920, 1080),
    }) async {
      final controller = FastPixPlayerController();
      await tester.runAsync(() async {
        await controller.initialize(
          dataSource: PlayerTestHarness.source('abc'),
          configuration: PlayerTestHarness.configuration(),
        );
        await platform.emitInitialized(
          platform.created.last,
          width: videoSize.width,
          height: videoSize.height,
        );
        await PlayerTestHarness.settle();
      });
      return controller;
    }

    Future<void> unmount(
      WidgetTester tester,
      FastPixPlayerController controller,
    ) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 60));
      await tester.runAsync(controller.dispose);
    }

    double shapeOf(WidgetTester tester, Finder finder) {
      final size = tester.getSize(finder);
      return size.width / size.height;
    }

    testWidgets('FastPixPlayer is 16:9 by default', (tester) async {
      final controller = await loaded(tester);
      await tester.pumpWidget(host(FastPixPlayer(controller: controller)));
      await tester.pump();

      expect(shapeOf(tester, find.byType(BetterPlayer)), closeTo(16 / 9, 1e-6));
      expect(controller.betterPlayerController!.getAspectRatio(), 16 / 9);
      await unmount(tester, controller);
    });

    testWidgets('FastPixPlayer takes a portrait shape, engine box included',
        (tester) async {
      final controller = await loaded(tester);
      await tester.pumpWidget(
        host(FastPixPlayer(controller: controller, aspectRatio: 9 / 16)),
      );
      await tester.pump();

      expect(shapeOf(tester, find.byType(BetterPlayer)), closeTo(9 / 16, 1e-6));
      // Without this the engine lays a 16:9 video area out inside the 9:16
      // box and fits the video into that instead.
      expect(controller.betterPlayerController!.getAspectRatio(), 9 / 16);
      await unmount(tester, controller);
    });

    testWidgets("FastPixPlayer can follow the video's own shape",
        (tester) async {
      final controller = await loaded(tester, videoSize: const Size(720, 1080));
      await tester.pumpWidget(
        host(
          FastPixPlayer(controller: controller, matchVideoAspectRatio: true),
        ),
      );
      await tester.pump();

      expect(shapeOf(tester, find.byType(BetterPlayer)), closeTo(2 / 3, 1e-6));
      expect(
        controller.betterPlayerController!.getAspectRatio(),
        closeTo(2 / 3, 1e-6),
      );
      await unmount(tester, controller);
    });

    testWidgets('FastPixVideoSurface passes its shape to the engine',
        (tester) async {
      final controller = await loaded(tester);
      await tester.pumpWidget(
        host(FastPixVideoSurface(controller: controller, aspectRatio: 2 / 3)),
      );
      await tester.pump();

      expect(shapeOf(tester, find.byType(BetterPlayer)), closeTo(2 / 3, 1e-6));
      expect(controller.betterPlayerController!.getAspectRatio(), 2 / 3);
      await unmount(tester, controller);
    });

    testWidgets('default sizing follows the box shape', (tester) async {
      final controller = FastPixPlayerController();
      controller.updatePlayerDimensions(aspectRatio: 9 / 16);
      expect(
        controller.playerWidth() / controller.playerHeight(),
        closeTo(9 / 16, 1e-6),
      );
      // A later call without a shape keeps the one the widget reported.
      controller.updatePlayerDimensions();
      expect(
        controller.playerWidth() / controller.playerHeight(),
        closeTo(9 / 16, 1e-6),
      );
      await tester.runAsync(controller.dispose);
    });
  });
}
