import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/managers/fastpix_spritesheet_manager.dart';
import 'package:fastpix_video_player/src/utils/fastpix_spritesheet_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_routed_http.dart';
import 'support/player_test_harness.dart';
import 'support/spritesheet_fixtures.dart';

/// The seek preview: a tile when the image is drawable, the time alone
/// otherwise — never a spinner, never an error.
///
/// Controller work goes through [WidgetTester.runAsync], since it waits on
/// real timers and real HTTP that a widget test's fake clock never advances.
void main() {
  PlayerTestHarness.install();

  late FakeRoutedHttpOverrides fake;
  HttpOverrides? previous;
  late Future<void> Function(Duration) retryDelay;
  // Three 256x160 tiles in one row, ten seconds apart: a 768x160 sheet.
  final threeTiles = spritesheetJson(count: 3, columns: 3, step: 10);
  Uint8List? png;

  final Finder timeOnly =
      find.byKey(const ValueKey<String>('fastpix-seek-preview-time'));
  final Finder tile =
      find.byKey(const ValueKey<String>('fastpix-seek-preview-tile'));

  setUp(() {
    previous = HttpOverrides.current;
    fake = FakeRoutedHttpOverrides((_) => null);
    HttpOverrides.global = fake;
    retryDelay = (_) async {};
    FastPixSpritesheetManager.debugClientFactory =
        () => FastPixSpritesheetClient(delay: (d) => retryDelay(d));
  });

  tearDown(() {
    FastPixSpritesheetManager.debugClientFactory = null;
    HttpOverrides.global = previous;
  });

  Future<Uint8List> sheetPng(WidgetTester tester) async =>
      png ??= (await tester.runAsync(() => pngBytes(768, 160)))!;

  Future<FastPixPlayerController> load(
    WidgetTester tester, {
    FastPixPlayerSpritesheetConfiguration settings =
        const FastPixPlayerSpritesheetConfiguration(),
  }) async {
    final controller = FastPixPlayerController();
    await tester.runAsync(() async {
      await controller.initialize(
        dataSource: PlayerTestHarness.source('a'),
        configuration: FastPixPlayerConfiguration(
          'workspace',
          'viewer',
          'beacon.example.com',
          spritesheetConfiguration: settings,
        ),
      );
      await PlayerTestHarness.reportReady();
      await PlayerTestHarness.settle(8);
    });
    return controller;
  }

  Future<void> show(
    WidgetTester tester,
    FastPixPlayerController controller, {
    Duration position = const Duration(seconds: 15),
    bool showTime = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: FastPixSeekPreview(
            controller: controller,
            position: position,
            showTime: showTime,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> release(WidgetTester tester, FastPixPlayerController controller) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.dispose);
  }

  void expectTimeOnly(WidgetTester tester, String time) {
    expect(timeOnly, findsOneWidget);
    expect(tile, findsNothing);
    expect(find.text(time), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  }

  group('time only when no image is drawable', () {
    testWidgets('spritesheets disabled', (tester) async {
      final controller = await load(
        tester,
        settings: const FastPixPlayerSpritesheetConfiguration(
          enableSpritesheet: false,
        ),
      );
      await show(tester, controller);
      expectTimeOnly(tester, '0:15');
      expect(fake.requestsFor('spritesheet'), isEmpty);
      await release(tester, controller);
    });

    testWidgets('metadata still loading', (tester) async {
      fake.route = spritesheetRoute(metadata: Completer<FakeReply?>().future);
      final controller = await load(tester);
      await show(tester, controller);
      expectTimeOnly(tester, '0:15');
      await release(tester, controller);
    });

    testWidgets('image still being generated', (tester) async {
      retryDelay = (_) => Completer<void>().future; // mid-schedule, forever
      fake.route = spritesheetRoute(
        metadata: FakeReply.text(200, threeTiles),
        image: FakeReply.text(202, '{}'),
      );
      final controller = await load(tester);
      await show(tester, controller);
      expect(controller.spritesheetStatus, FastPixSpritesheetStatus.ready);
      expectTimeOnly(tester, '0:15');
      await release(tester, controller);
    });

    testWidgets('spritesheet failed', (tester) async {
      fake.route = spritesheetRoute(
        metadata: FakeReply.text(404, '{}'),
        image: FakeReply.text(404, '{}'),
      );
      final controller = await load(tester);
      await show(tester, controller, position: const Duration(minutes: 61, seconds: 5));
      expect(controller.spritesheetStatus, FastPixSpritesheetStatus.failed);
      expectTimeOnly(tester, '1:01:05');
      await release(tester, controller);
    });
  });

  group('tile', () {
    testWidgets('draws the tile for the position, sized from the tile aspect',
        (tester) async {
      final bytes = await sheetPng(tester);
      fake.route = spritesheetRoute(
        metadata: FakeReply.text(200, threeTiles),
        image: FakeReply(200, bytes),
      );
      final controller = await load(tester);
      await show(tester, controller);

      expect(tile, findsOneWidget);
      expect(find.text('0:15'), findsOneWidget);
      final paint = tester.widget<CustomPaint>(
        find.descendant(of: tile, matching: find.byType(CustomPaint)),
      );
      final painter = paint.painter! as FastPixSeekPreviewPainter;
      expect(painter.tile.index, 1);
      expect(painter.decodeScale, 1);
      expect(paint.size, const Size(160, 100));
      await release(tester, controller);
    });

    testWidgets('switches from time only to the tile when the image arrives',
        (tester) async {
      final bytes = await sheetPng(tester);
      final image = Completer<FakeReply?>();
      fake.route = spritesheetRoute(
        metadata: FakeReply.text(200, threeTiles),
        image: image.future,
      );
      final controller = await load(tester);
      await show(tester, controller);
      expectTimeOnly(tester, '0:15');

      await tester.runAsync(() async {
        image.complete(FakeReply(200, bytes));
        await PlayerTestHarness.settle(10);
      });
      await tester.pump();

      expect(tile, findsOneWidget);
      await release(tester, controller);
    });

    testWidgets('repaints only when the tile or image changes', (tester) async {
      final bytes = await sheetPng(tester);
      fake.route = spritesheetRoute(
        metadata: FakeReply.text(200, threeTiles),
        image: FakeReply(200, bytes),
      );
      final controller = await load(tester);
      final manager = fastPixSpritesheetManagers[controller]!;
      final sheet = controller.spritesheet!;

      FastPixSeekPreviewPainter painterAt(int seconds) => FastPixSeekPreviewPainter(
            image: manager.image!,
            tile: sheet.tileAt(Duration(seconds: seconds))!,
            decodeScale: manager.decodeScale,
          );

      expect(painterAt(11).shouldRepaint(painterAt(19)), isFalse);
      expect(painterAt(11).shouldRepaint(painterAt(21)), isTrue);
      await release(tester, controller);
    });

    testWidgets('showTime false hides the label beside a tile', (tester) async {
      final bytes = await sheetPng(tester);
      fake.route = spritesheetRoute(
        metadata: FakeReply.text(200, threeTiles),
        image: FakeReply(200, bytes),
      );
      final controller = await load(tester);
      await show(tester, controller, showTime: false);
      expect(tile, findsOneWidget);
      expect(find.text('0:15'), findsNothing);
      await release(tester, controller);
    });
  });
}
