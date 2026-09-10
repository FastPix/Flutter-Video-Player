import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// Playlist previous/next in the **default** skin.
///
/// The buttons are an overlay over better_player's controls rather than part of
/// them — the same arrangement the cast button uses, and for the same reason:
/// the skin belongs to the engine. What these tests hold to is the behaviour
/// that arrangement has to produce — the buttons appear only for a playlist,
/// they move it, they dim at the ends, and the host can turn them off.
///
/// Every controller call goes through [WidgetTester.runAsync]: the controller
/// waits on real timers and platform round trips, which a widget test's fake
/// clock never advances.
void main() {
  PlayerTestHarness.install();

  final Finder previous = find.byIcon(Icons.skip_previous_rounded);
  final Finder next = find.byIcon(Icons.skip_next_rounded);

  /// Let the overlay's stream subscription and the engine's listeners land.
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

  /// Tear the tree down before disposing, as the other widget suites do: a
  /// disposed controller under a mounted player is not a state the app can
  /// reach.
  Future<void> unmount(
    WidgetTester tester,
    FastPixPlayerController controller,
  ) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.dispose);
  }

  /// The [IconButton] wrapping [icon], so its `onPressed` can be read — null is
  /// how this overlay says "this end of the playlist".
  IconButton buttonFor(WidgetTester tester, Finder icon) => tester.widget(
        find.ancestor(of: icon, matching: find.byType(IconButton)),
      );

  /// Press a button and let the load it starts actually finish.
  ///
  /// The callback is invoked rather than tapped because the work it starts runs
  /// on real timers: dispatched through [WidgetTester.tap] it would continue on
  /// the fake clock and leave timers pending past the end of the test. This
  /// still goes through the widget's own `onPressed`, so the wiring under test
  /// is the same one a tap would reach.
  Future<void> press(WidgetTester tester, Finder icon) async {
    final onPressed = buttonFor(tester, icon).onPressed;
    expect(onPressed, isNotNull, reason: 'button is disabled');
    final before = PlayerTestHarness.platform.created.length;
    await tester.runAsync(() async {
      onPressed!();
      // `onPressed` returns nothing, so the load it started is waited for by
      // watching the platform instead: `reportReady` addresses the newest
      // engine player, and reporting into the outgoing one — which is already
      // initialized — throws "Future already completed".
      for (var i = 0;
          i < 40 && PlayerTestHarness.platform.created.length == before;
          i++) {
        await PlayerTestHarness.settle(1);
      }
      expect(
        PlayerTestHarness.platform.created.length,
        greaterThan(before),
        reason: 'the button did not start a load',
      );
      await PlayerTestHarness.reportReady();
    });
    await pumpFor(tester);
  }

  group('the buttons appear only when there is a playlist to move through', () {
    testWidgets('a single source draws neither button', (tester) async {
      final controller = FastPixPlayerController();
      await tester.runAsync(
        () => PlayerTestHarness.load(controller, PlayerTestHarness.source('a')),
      );
      await mount(tester, controller);

      expect(previous, findsNothing);
      expect(next, findsNothing);
      await unmount(tester, controller);
    });

    testWidgets('a playlist draws both', (tester) async {
      late FastPixPlayerController controller;
      await tester.runAsync(() async {
        controller = await PlayerTestHarness.withPlaylist(
          PlayerTestHarness.playlist(3),
          startIndex: 1,
        );
      });
      await mount(tester, controller);

      expect(previous, findsOneWidget);
      expect(next, findsOneWidget);
      await unmount(tester, controller);
    });

    testWidgets('clearing the playlist takes them away again', (tester) async {
      late FastPixPlayerController controller;
      await tester.runAsync(() async {
        controller = await PlayerTestHarness.withPlaylist(
          PlayerTestHarness.playlist(3),
        );
      });
      await mount(tester, controller);
      expect(next, findsOneWidget);

      controller.clearPlaylist();
      await pumpFor(tester);

      expect(previous, findsNothing);
      expect(next, findsNothing);
      await unmount(tester, controller);
    });
  });

  group('the buttons move the playlist', () {
    testWidgets('next advances the active item', (tester) async {
      late FastPixPlayerController controller;
      await tester.runAsync(() async {
        controller = await PlayerTestHarness.withPlaylist(
          PlayerTestHarness.playlist(3),
        );
      });
      await mount(tester, controller);

      await press(tester, next);

      expect(controller.currentPlaylistIndex, 1);
      expect(controller.dataSource?.playbackId, 'item-1');
      await unmount(tester, controller);
    });

    testWidgets('previous steps back', (tester) async {
      late FastPixPlayerController controller;
      await tester.runAsync(() async {
        controller = await PlayerTestHarness.withPlaylist(
          PlayerTestHarness.playlist(3),
          startIndex: 2,
        );
      });
      await mount(tester, controller);

      await press(tester, previous);

      expect(controller.currentPlaylistIndex, 1);
      await unmount(tester, controller);
    });
  });

  group('the ends of the playlist', () {
    testWidgets('the first item cannot go back, and the glyph says so',
        (tester) async {
      late FastPixPlayerController controller;
      await tester.runAsync(() async {
        controller = await PlayerTestHarness.withPlaylist(
          PlayerTestHarness.playlist(2),
        );
      });
      await mount(tester, controller);

      // Still drawn — the row keeps its shape at the ends rather than
      // reflowing under the viewer's finger.
      expect(previous, findsOneWidget);
      expect(buttonFor(tester, previous).onPressed, isNull);

      await tester.tap(previous);
      await pumpFor(tester);
      expect(controller.currentPlaylistIndex, 0);
      await unmount(tester, controller);
    });

    testWidgets('the last item cannot go on', (tester) async {
      late FastPixPlayerController controller;
      await tester.runAsync(() async {
        controller = await PlayerTestHarness.withPlaylist(
          PlayerTestHarness.playlist(2),
          startIndex: 1,
        );
      });
      await mount(tester, controller);

      expect(buttonFor(tester, next).onPressed, isNull);
      await unmount(tester, controller);
    });

    testWidgets('reaching the end re-enables the other side', (tester) async {
      late FastPixPlayerController controller;
      await tester.runAsync(() async {
        controller = await PlayerTestHarness.withPlaylist(
          PlayerTestHarness.playlist(2),
        );
      });
      await mount(tester, controller);

      await press(tester, next);

      expect(buttonFor(tester, previous).onPressed, isNotNull);
      await unmount(tester, controller);
    });
  });

  group('the host can turn them off', () {
    testWidgets('showPlaylistControls: false draws nothing, playlist or not',
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
              showPlaylistControls: false,
            ),
          ),
        );
        await PlayerTestHarness.reportReady();
      });
      await mount(tester, controller);

      expect(previous, findsNothing);
      expect(next, findsNothing);
      // The playlist itself is untouched — only its chrome is gone.
      expect(controller.playlistCount, 3);
      expect(controller.canGoNext, isTrue);
      await unmount(tester, controller);
    });
  });
}
