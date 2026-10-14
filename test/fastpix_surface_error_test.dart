import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

const String _sourceError = 'Source error';
const String _playbackFailed = 'Playback failed';

/// Failures inside the **custom-UI** surface.
///
/// The surface draws no failure panel of its own: it reports the failure —
/// the `error` event and `lastError` — and keeps drawing what it was drawing.
/// What the viewer sees about the failure is the host's, through
/// [FastPixVideoSurface.errorBuilder] or its own widgets over the surface.
void main() {
  PlayerTestHarness.install();
  final platform = PlayerTestHarness.platform;

  Future<void> pumpFor(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// `diagnoseErrors: false` by default: the probe is a real network call, and
  /// what it returns is [FastPixPlaybackDiagnostics]' own test's subject. These
  /// tests are about what the panel does with an answer, not about getting one.
  Future<void> mount(
    WidgetTester tester,
    FastPixPlayerController controller, {
    Widget Function(BuildContext, FastPixPlayerErrorEvent)? errorBuilder,
    bool diagnoseErrors = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FastPixVideoSurface(
            controller: controller,
            errorBuilder: errorBuilder,
            diagnoseErrors: diagnoseErrors,
          ),
        ),
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

  testWidgets('a playback failure draws no panel; it is reported instead',
      (tester) async {
    late FastPixPlayerController controller;
    await tester.runAsync(() async {
      controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    });
    final reported = <FastPixPlayerEvent>[];
    controller.addEventListener(FastPixPlayerEventTypes.error, reported.add);
    await mount(tester, controller);

    await tester.runAsync(() async {
      await platform.emitError(platform.created.last, _sourceError);
      await PlayerTestHarness.settle();
    });
    await pumpFor(tester);

    // Nothing drawn over or instead of the surface…
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.text(_playbackFailed), findsNothing);
    expect(find.text(_sourceError), findsNothing);
    // …which keeps the player it was showing…
    expect(find.byType(BetterPlayer), findsOneWidget);
    // …and the failure is reported for the host to draw.
    expect(reported, isNotEmpty);
    expect(controller.lastError, isNotNull);

    await unmount(tester, controller);
  });

  testWidgets('no endpoint diagnosis is drawn, whatever diagnoseErrors says',
      (tester) async {
    late FastPixPlayerController controller;
    await tester.runAsync(() async {
      controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    });
    await mount(tester, controller, diagnoseErrors: true);

    await tester.runAsync(() async {
      await platform.emitError(platform.created.last, _sourceError);
      await PlayerTestHarness.settle();
    });
    await pumpFor(tester);

    expect(find.text('Working out why…'), findsNothing);
    expect(find.text(_playbackFailed), findsNothing);

    await unmount(tester, controller);
  });

  testWidgets('errorBuilder replaces the default panel', (tester) async {
    late FastPixPlayerController controller;
    await tester.runAsync(() async {
      controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    });
    await mount(
      tester,
      controller,
      errorBuilder: (context, error) => Text('mine: ${error.message}'),
    );

    await tester.runAsync(() async {
      await platform.emitError(platform.created.last, _sourceError);
      await PlayerTestHarness.settle();
    });
    await pumpFor(tester);

    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.textContaining('mine:'), findsOneWidget);

    await unmount(tester, controller);
  });

  testWidgets('a failure that did not stop playback leaves the video alone',
      (tester) async {
    late FastPixPlayerController controller;
    await tester.runAsync(() async {
      controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    });
    await mount(tester, controller);

    // A cast route that could not be offered reports on the same `error`
    // channel, but playback never stopped. Covering the video for it would be
    // a black rectangle caused by a button.
    await tester.runAsync(() async {
      await controller.toggleCast();
      await PlayerTestHarness.settle();
    });
    await pumpFor(tester);

    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(controller.lastError, isNull);

    await unmount(tester, controller);
  });

  testWidgets('a new source clears the host failure UI', (tester) async {
    late FastPixPlayerController controller;
    await tester.runAsync(() async {
      controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await platform.emitError(platform.created.last, _sourceError);
      await PlayerTestHarness.settle();
    });
    await mount(
      tester,
      controller,
      errorBuilder: (context, error) => const Text('mine'),
    );
    expect(find.text('mine'), findsOneWidget,
        reason: 'a failure from before the mount still reaches errorBuilder');

    await tester.runAsync(() async {
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('b'));
    });
    await pumpFor(tester);

    expect(find.text('mine'), findsNothing);

    await unmount(tester, controller);
  });
}
