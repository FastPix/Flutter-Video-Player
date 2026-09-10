import 'dart:async';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// A cast controller with a receiver already found, so the cast glyph draws and
/// the top-right row has to hold two buttons instead of one.
class _FakeCastController extends FastPixCastController {
  final StreamController<FastPixCastState> _states =
      StreamController<FastPixCastState>.broadcast();

  @override
  FastPixCastState get state => FastPixCastState.devicesFound;

  @override
  Stream<FastPixCastState> get stateStream => _states.stream;
}

/// The playlist queue: the panel that makes a playlist navigable rather than
/// merely sequential.
///
/// Previous/next walk one step at a time; these tests are about the other
/// half — every item listed, the active one marked, and a tap on any of them
/// jumping straight to it.
///
/// Every controller call goes through [WidgetTester.runAsync]: the controller
/// waits on real timers, which a widget test's fake clock never advances.
void main() {
  PlayerTestHarness.install();

  final Finder queueButton = find.byIcon(Icons.playlist_play_rounded);
  final Finder panel = find.byType(FastPixPlaylistPanel);

  Future<void> pumpFor(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> mount(
    WidgetTester tester,
    FastPixPlayerController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FastPixPlayer(controller: controller)),
      ),
    );
    await pumpFor(tester);
  }

  Future<void> unmount(
    WidgetTester tester,
    FastPixPlayerController controller,
  ) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.dispose);
  }

  /// A controller carrying named items, so the panel's rows can be identified
  /// by the titles the host actually supplied.
  Future<FastPixPlayerController> withTitles(
    WidgetTester tester,
    List<String> titles, {
    int startIndex = 0,
  }) async {
    late FastPixPlayerController controller;
    await tester.runAsync(() async {
      controller = FastPixPlayerController();
      await controller.setPlaylist(
        <FastPixPlayerDataSource>[
          for (final title in titles)
            FastPixPlayerDataSource.hls(
              playbackId: title.toLowerCase(),
              title: title,
            ),
        ],
        startIndex: startIndex,
        configuration: PlayerTestHarness.configuration(),
      );
      await PlayerTestHarness.reportReady();
    });
    return controller;
  }

  /// Open the queue by pressing its button, the way a viewer does.
  Future<void> openQueue(WidgetTester tester) async {
    expect(queueButton, findsOneWidget);
    await tester.tap(queueButton);
    await pumpFor(tester);
  }

  group('reaching the queue', () {
    testWidgets('no button without a playlist', (tester) async {
      final controller = FastPixPlayerController();
      await tester.runAsync(
        () => PlayerTestHarness.load(controller, PlayerTestHarness.source('a')),
      );
      await mount(tester, controller);

      expect(queueButton, findsNothing);
      await unmount(tester, controller);
    });

    testWidgets('a playlist offers the button, and it opens the panel',
        (tester) async {
      final controller = await withTitles(tester, ['One', 'Two', 'Three']);
      await mount(tester, controller);

      expect(panel, findsNothing);
      await openQueue(tester);

      expect(panel, findsOneWidget);
      await unmount(tester, controller);
    });
  });

  group('what the queue shows', () {
    testWidgets('every item, in order, by the title the host supplied',
        (tester) async {
      final controller = await withTitles(tester, ['One', 'Two', 'Three']);
      await mount(tester, controller);
      await openQueue(tester);

      for (final title in ['One', 'Two', 'Three']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      // The panel's own position readout comes from the playlist state, so it
      // cannot disagree with any other readout in the app.
      expect(find.text('1 of 3'), findsOneWidget);
      await unmount(tester, controller);
    });

    testWidgets('the playing item is marked, and only it', (tester) async {
      final controller =
          await withTitles(tester, ['One', 'Two', 'Three'], startIndex: 1);
      await mount(tester, controller);
      await openQueue(tester);

      expect(find.byIcon(Icons.equalizer_rounded), findsOneWidget);
      final marked = tester.widget<ListTile>(
        find.ancestor(
          of: find.byIcon(Icons.equalizer_rounded),
          matching: find.byType(ListTile),
        ),
      );
      expect(marked.selected, isTrue);
      expect(find.text('2 of 3'), findsOneWidget);
      await unmount(tester, controller);
    });
  });

  group('jumping from the queue', () {
    testWidgets('tapping an item plays it, skipping everything between',
        (tester) async {
      final controller =
          await withTitles(tester, ['One', 'Two', 'Three', 'Four']);
      await mount(tester, controller);
      await openQueue(tester);

      // The whole point of the panel: the fourth item without playing the two
      // before it.
      final created = PlayerTestHarness.platform.created.length;
      await tester.runAsync(() async {
        controller.jumpTo(3);
        for (var i = 0;
            i < 40 && PlayerTestHarness.platform.created.length == created;
            i++) {
          await PlayerTestHarness.settle(1);
        }
        await PlayerTestHarness.reportReady();
      });
      await pumpFor(tester);

      expect(controller.currentPlaylistIndex, 3);
      expect(controller.dataSource?.playbackId, 'four');
      await unmount(tester, controller);
    });

    testWidgets('choosing an item closes the panel', (tester) async {
      final controller = await withTitles(tester, ['One', 'Two', 'Three']);
      await mount(tester, controller);
      await openQueue(tester);

      // Tapping the item already playing is not a jump — it just closes,
      // which is what makes this safe to drive without a load.
      await tester.tap(find.text('One'));
      await pumpFor(tester);

      expect(panel, findsNothing);
      expect(controller.currentPlaylistIndex, 0);
      await unmount(tester, controller);
    });

    testWidgets('the close button dismisses it', (tester) async {
      final controller = await withTitles(tester, ['One', 'Two']);
      await mount(tester, controller);
      await openQueue(tester);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await pumpFor(tester);

      expect(panel, findsNothing);
      await unmount(tester, controller);
    });
  });

  group('sharing the top-right corner with cast', () {
    testWidgets('both glyphs are drawn, and the queue sits left of cast',
        (tester) async {
      final controller = await withTitles(tester, ['One', 'Two']);
      final cast = _FakeCastController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FastPixPlayer(controller: controller, castController: cast),
          ),
        ),
      );
      await pumpFor(tester);

      expect(queueButton, findsOneWidget);
      final castGlyph = find.byType(FastPixCastButton);
      expect(castGlyph, findsOneWidget);

      // Left of cast, so the cast glyph stays where viewers have always found
      // it. Overlapping would put one on top of the other with no error.
      final queueX = tester.getCenter(queueButton).dx;
      final castX = tester.getCenter(castGlyph).dx;
      expect(queueX, lessThan(castX));
      await unmount(tester, controller);
    });

    testWidgets('the cast glyph does not move when the queue button appears',
        (tester) async {
      // The row is right-aligned and sized to its contents, so a button added
      // on its left extends the row leftwards into empty space rather than
      // pushing the cast glyph along. Measured, not assumed: getting this
      // wrong would silently shift a control viewers already know the position
      // of.
      Future<double> castCentreWith(List<String> titles) async {
        final controller = await withTitles(tester, titles);
        final cast = _FakeCastController();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FastPixPlayer(controller: controller, castController: cast),
            ),
          ),
        );
        await pumpFor(tester);
        final centre = tester.getCenter(find.byType(FastPixCastButton)).dx;
        await unmount(tester, controller);
        return centre;
      }

      // One item draws no queue button; two draws one.
      final withoutQueue = await castCentreWith(['Only']);
      final withQueue = await castCentreWith(['One', 'Two']);

      expect(withQueue, withoutQueue);
    });

    testWidgets('the queue button still draws with no cast controller at all',
        (tester) async {
      final controller = await withTitles(tester, ['One', 'Two']);
      await mount(tester, controller);

      expect(queueButton, findsOneWidget);
      expect(find.byType(FastPixCastButton), findsNothing);
      await unmount(tester, controller);
    });
  });

  group('the host can turn it off', () {
    testWidgets('showPlaylistPanel: false leaves the arrows and drops the queue',
        (tester) async {
      final controller = FastPixPlayerController();
      await tester.runAsync(() async {
        await controller.setPlaylist(
          PlayerTestHarness.playlist(3),
          configuration: FastPixPlayerConfiguration(
            'workspace',
            'viewer',
            'beacon.example.com',
            controlsConfiguration: const FastPixPlayerControlsConfiguration(
              showPlaylistPanel: false,
            ),
          ),
        );
        await PlayerTestHarness.reportReady();
      });
      await mount(tester, controller);

      expect(queueButton, findsNothing);
      // The arrows are a separate switch and are untouched.
      expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
      await unmount(tester, controller);
    });
  });
}
