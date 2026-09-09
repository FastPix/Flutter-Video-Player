import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// A mounted view must follow the controller when it replaces its source —
/// without being rebuilt by the host, and without ever rendering a player that
/// has been released.
void main() {
  PlayerTestHarness.install();
  final platform = PlayerTestHarness.platform;

  /// The engine player a widget is currently rendering, or null when it is
  /// showing its placeholder.
  BetterPlayerController? renderedPlayer(WidgetTester tester) {
    final players = tester.widgetList<BetterPlayer>(find.byType(BetterPlayer));
    return players.isEmpty ? null : players.first.controller;
  }

  Future<void> pumpFor(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  group('FastPixPlayer', () {
    testWidgets('renders the new source after a switch, never a released one',
        (tester) async {
      final controller = FastPixPlayerController();
      await tester.runAsync(
          () => PlayerTestHarness.load(controller, PlayerTestHarness.source('a')));

      await tester.pumpWidget(
        MaterialApp(home: FastPixPlayer(controller: controller)),
      );
      await pumpFor(tester);

      final first = renderedPlayer(tester);
      expect(first, isNotNull);
      expect(first, same(controller.betterPlayerController));

      await tester.runAsync(
          () => PlayerTestHarness.load(controller, PlayerTestHarness.source('b')));
      await pumpFor(tester);

      final second = renderedPlayer(tester);
      expect(second, isNotNull);
      expect(second, isNot(same(first)),
          reason: 'the widget latched the released player');
      expect(second, same(controller.betterPlayerController));

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.dispose);
    });

    testWidgets('clears the previous source failure on a switch',
        (tester) async {
      final controller = FastPixPlayerController();
      await tester.runAsync(
          () => PlayerTestHarness.load(controller, PlayerTestHarness.source('a')));
      await tester.pumpWidget(
        MaterialApp(
          home: FastPixPlayer(controller: controller, diagnoseErrors: false),
        ),
      );
      await pumpFor(tester);

      await tester.runAsync(() async {
        await platform.emitError(platform.created.last, 'Source error');
        await PlayerTestHarness.settle();
      });
      await pumpFor(tester);
      expect(find.text('Playback failed'), findsOneWidget);

      await tester.runAsync(
          () => PlayerTestHarness.load(controller, PlayerTestHarness.source('b')));
      await pumpFor(tester);
      expect(find.text('Playback failed'), findsNothing);
      expect(renderedPlayer(tester), same(controller.betterPlayerController));

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.dispose);
    });
  });

  group('FastPixVideoSurface', () {
    testWidgets('rebinds when the source changes while mounted',
        (tester) async {
      final controller = FastPixPlayerController();
      await tester.runAsync(
          () => PlayerTestHarness.load(controller, PlayerTestHarness.source('a')));

      await tester.pumpWidget(
        MaterialApp(home: FastPixVideoSurface(controller: controller)),
      );
      await pumpFor(tester);
      final first = renderedPlayer(tester);
      expect(first, same(controller.betterPlayerController));

      await tester.runAsync(
          () => PlayerTestHarness.load(controller, PlayerTestHarness.source('b')));
      await pumpFor(tester);
      expect(renderedPlayer(tester), same(controller.betterPlayerController));
      expect(renderedPlayer(tester), isNot(same(first)));

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.dispose);
    });

    testWidgets('mounting after a switch renders the current source',
        (tester) async {
      final controller = FastPixPlayerController();
      await tester.runAsync(
          () => PlayerTestHarness.load(controller, PlayerTestHarness.source('a')));
      await tester.runAsync(
          () => PlayerTestHarness.load(controller, PlayerTestHarness.source('b')));

      await tester.pumpWidget(
        MaterialApp(home: FastPixVideoSurface(controller: controller)),
      );
      await pumpFor(tester);

      expect(renderedPlayer(tester), same(controller.betterPlayerController));
      expect(controller.dataSource?.playbackId, 'b');

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.dispose);
    });

    testWidgets('keeps its PiP key registration across a switch',
        (tester) async {
      final controller = FastPixPlayerController();
      await tester.runAsync(
          () => PlayerTestHarness.load(controller, PlayerTestHarness.source('a')));

      await tester.pumpWidget(
        MaterialApp(home: FastPixVideoSurface(controller: controller)),
      );
      await pumpFor(tester);
      final key = tester
          .widget<AspectRatio>(find.byType(AspectRatio).first)
          .key;
      expect(key, isNotNull);

      await tester.runAsync(
          () => PlayerTestHarness.load(controller, PlayerTestHarness.source('b')));
      await pumpFor(tester);
      expect(
        tester.widget<AspectRatio>(find.byType(AspectRatio).first).key,
        same(key),
        reason: 'the surface must keep anchoring PiP to the same box',
      );

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.dispose);
    });
  });
}
