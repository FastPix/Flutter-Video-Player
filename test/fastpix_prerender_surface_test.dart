import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_prerender_platform.dart';
import 'support/player_test_harness.dart';

/// Playlist IDs from [PlayerTestHarness.playlist].
const _item1 = 'item-1';

/// Tasks 7.1 - 7.5: the hidden slot in both surfaces.
void main() {
  PlayerTestHarness.install();
  PrerenderTestHarness.install();

  Future<void> pumpFor(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<FastPixPlayerController> controllerWithPlaylist(
    WidgetTester tester,
  ) async {
    final controller = FastPixPlayerController()..preloadRadius = 0;
    await tester.runAsync(() async {
      await controller.setPlaylist(
        PlayerTestHarness.playlist(3),
        configuration: PlayerTestHarness.configuration(),
      );
      await PlayerTestHarness.reportReady();
    });
    return controller;
  }

  Future<void> mount(WidgetTester tester, Widget surface) async {
    await tester.pumpWidget(MaterialApp(home: Center(child: surface)));
    await pumpFor(tester);
  }

  Future<BetterPlayerController> prerenderNext(
    WidgetTester tester,
    FastPixPlayerController controller,
  ) async {
    await tester.runAsync(
      () => PrerenderTestHarness.ready(controller, _item1),
    );
    await pumpFor(tester);
    return controller.prerenderEngine.value!;
  }

  Finder playerOf(BetterPlayerController engine) => find.byWidgetPredicate(
        (w) => w is BetterPlayer && identical(w.controller, engine),
      );

  /// The `Stack` that holds both slots, and its two keyed children in paint
  /// order.
  List<KeyedSubtree> slotsIn(WidgetTester tester) {
    final stack = tester.widget<Stack>(
      find.byWidgetPredicate(
        (w) => w is Stack && w.children.whereType<KeyedSubtree>().length == 2,
      ),
    );
    return stack.children.whereType<KeyedSubtree>().toList();
  }

  void expectHiddenBelowAndCovered(
    WidgetTester tester,
    BetterPlayerController hidden,
  ) {
    final slots = slotsIn(tester);
    final below = slots.first.child as IgnorePointer;
    expect(below.ignoring, isTrue, reason: 'below and untouchable');
    expect((below.child! as ExcludeSemantics).excluding, isTrue);
    expect((slots.last.child as IgnorePointer).ignoring, isFalse);

    expect(playerOf(hidden), findsOneWidget);
    expect(
      find.descendant(
        of: find.byWidget(slots.first),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Positioned &&
              w.child is ColoredBox &&
              (w.child as ColoredBox).color == Colors.black,
        ),
      ),
      findsOneWidget,
      reason: 'an opaque cover over the hidden player',
    );
    // Inside the slot: nothing that would stop the platform drawing a frame.
    for (final type in const <Type>[Opacity, Offstage, Visibility]) {
      expect(
        find.ancestor(
          of: playerOf(hidden),
          matching: find.descendant(
            of: find.byWidget(slots.first),
            matching: find.byType(type),
          ),
        ),
        findsNothing,
      );
    }
  }

  group('FastPixVideoSurface (7.1, 7.2)', () {
    testWidgets('the hidden slot is below, covered and inert', (tester) async {
      final controller = await controllerWithPlaylist(tester);
      await mount(tester, FastPixVideoSurface(controller: controller));
      expect(find.byType(BetterPlayer), findsOneWidget, reason: 'none live');

      final hidden = await prerenderNext(tester, controller);
      expect(find.byType(BetterPlayer), findsNWidgets(2));
      expectHiddenBelowAndCovered(tester, hidden);

      await tester.runAsync(() async => controller.cancelPrerender(_item1));
      await pumpFor(tester);
      expect(find.byType(BetterPlayer), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.dispose);
    });

    testWidgets('PiP shows only the active player', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final controller = await controllerWithPlaylist(tester);
      await mount(tester, FastPixVideoSurface(controller: controller));
      await prerenderNext(tester, controller);
      final active = controller.betterPlayerController!;

      controller.pip.notifyActive(true);
      await pumpFor(tester);
      expect(find.byType(BetterPlayer), findsOneWidget);
      expect(playerOf(active), findsOneWidget);

      controller.pip.notifyActive(false);
      await pumpFor(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.dispose);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('FastPixPlayer (7.3)', () {
    testWidgets('the hidden slot is below, covered and inert', (tester) async {
      final controller = await controllerWithPlaylist(tester);
      await mount(tester, FastPixPlayer(controller: controller));
      expect(find.byType(BetterPlayer), findsOneWidget);

      final hidden = await prerenderNext(tester, controller);
      expect(find.byType(BetterPlayer), findsNWidgets(2));
      expectHiddenBelowAndCovered(tester, hidden);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.dispose);
    });
  });

  group('surface availability (7.4)', () {
    testWidgets('unmounting while preparing fails with surfaceUnavailable',
        (tester) async {
      final controller = await controllerWithPlaylist(tester);
      await mount(tester, FastPixVideoSurface(controller: controller));
      final engines = PlayerTestHarness.platform;

      await tester.runAsync(() async {
        final before = engines.created.length;
        controller.prerender(PlayerTestHarness.source(_item1));
        await PrerenderTestHarness.waitForBuild(before);
        await engines.emitInitialized(engines.created.last);
        await PlayerTestHarness.settle();
      });
      expect(
        controller.prerenderStatusOf(_item1),
        FastPixPrerenderStatus.preparing,
      );

      await tester.pumpWidget(const SizedBox());
      expect(
        controller.prerenderStatusOf(_item1),
        FastPixPrerenderStatus.failed,
      );
      await tester.runAsync(controller.dispose);
    });

    test('a headless controller is skipped with noSurface', () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(3),
      );
      final result = await controller.prerender(
        PlayerTestHarness.source(_item1),
      );
      expect(result.errorCode, FastPixPrerenderErrorCode.noSurface);
      await controller.dispose();
    });
  });

  group('slot identity (7.5)', () {
    testWidgets('the promoted player keeps the State it had while hidden',
        (tester) async {
      final controller = await controllerWithPlaylist(tester);
      await mount(tester, FastPixVideoSurface(controller: controller));
      final hidden = await prerenderNext(tester, controller);
      final state = tester.state(playerOf(hidden));

      await tester.runAsync(() async {
        await controller.next();
        await PlayerTestHarness.settle();
      });
      await pumpFor(tester);

      expect(controller.betterPlayerController, same(hidden));
      expect(find.byType(BetterPlayer), findsOneWidget);
      expect(tester.state(playerOf(hidden)), same(state));

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.dispose);
    });
  });
}
