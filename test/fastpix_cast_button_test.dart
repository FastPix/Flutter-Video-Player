import 'dart:async';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cast controller whose state is driven by the test rather than by a real
/// Cast session, so the button can be exercised without a platform channel.
class _FakeCastController extends FastPixCastController {
  _FakeCastController(this._state);

  final StreamController<FastPixCastState> _states =
      StreamController<FastPixCastState>.broadcast();
  FastPixCastState _state;

  @override
  FastPixCastState get state => _state;

  @override
  Stream<FastPixCastState> get stateStream => _states.stream;

  void emit(FastPixCastState state) {
    _state = state;
    _states.add(state);
  }
}

Future<void> _pump(WidgetTester tester, _FakeCastController cast,
    {VoidCallback? onPressed, bool showWhenNoDevices = true}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FastPixCastButton(
          controller: cast,
          onPressed: onPressed,
          showWhenNoDevices: showWhenNoDevices,
        ),
      ),
    ),
  );
}

/// The colour the glyph is drawn in, to tell the dimmed idle state from the
/// live one without depending on an exact opacity.
Color _glyphColour(WidgetTester tester, IconData icon) =>
    tester.widget<Icon>(find.byIcon(icon)).color!;

void main() {
  group('the glyph advertises the feature before a receiver exists', () {
    testWidgets('it is drawn, dimmed, while nothing has been found',
        (tester) async {
      // A viewer who has never cast has to learn the player can. YouTube and
      // every other large player keep the glyph present for exactly this
      // reason; dimming says "idle", not "broken".
      await _pump(tester, _FakeCastController(FastPixCastState.noDevices));

      expect(find.byIcon(Icons.cast), findsOneWidget);
      expect(_glyphColour(tester, Icons.cast).a, lessThan(1.0));
    });

    testWidgets('a receiver appearing brings it to full strength',
        (tester) async {
      final cast = _FakeCastController(FastPixCastState.noDevices);
      await _pump(tester, cast);
      final idle = _glyphColour(tester, Icons.cast).a;

      cast.emit(FastPixCastState.devicesFound);
      await tester.pump();

      expect(_glyphColour(tester, Icons.cast).a, greaterThan(idle));
      expect(_glyphColour(tester, Icons.cast).a, 1.0);
    });

    testWidgets('showWhenNoDevices: false restores the checklist behaviour',
        (tester) async {
      // The Google Cast Design Checklist wants nothing until a receiver
      // exists. Hosts certifying against it opt back in here.
      await _pump(
        tester,
        _FakeCastController(FastPixCastState.noDevices),
        showWhenNoDevices: false,
      );

      expect(find.byIcon(Icons.cast), findsNothing);
      expect(find.byIcon(Icons.cast_connected), findsNothing);
    });

    testWidgets('an unavailable subsystem draws nothing either', (
      tester,
    ) async {
      // Nothing to advertise where casting can never work: no Play Services,
      // a failed Cast context, or a denied local-network permission on iOS.
      await _pump(tester, _FakeCastController(FastPixCastState.unavailable));

      expect(find.byIcon(Icons.cast), findsNothing);
    });

    testWidgets('a discovered receiver brings the glyph in', (tester) async {
      final cast = _FakeCastController(FastPixCastState.noDevices);
      await _pump(tester, cast);

      cast.emit(FastPixCastState.devicesFound);
      await tester.pump();

      expect(find.byIcon(Icons.cast), findsOneWidget);
    });

    testWidgets('a live session shows the connected glyph', (tester) async {
      await _pump(tester, _FakeCastController(FastPixCastState.connected));

      expect(find.byIcon(Icons.cast_connected), findsOneWidget);
      expect(find.byIcon(Icons.cast), findsNothing);
    });
  });

  group('taps', () {
    testWidgets('a tap reaches the app', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        _FakeCastController(FastPixCastState.devicesFound),
        onPressed: () => taps++,
      );

      await tester.tap(find.byIcon(Icons.cast));
      expect(taps, 1);
    });

    testWidgets('mid-handshake the button spins and refuses taps', (
      tester,
    ) async {
      var taps = 0;
      await _pump(
        tester,
        _FakeCastController(FastPixCastState.connecting),
        onPressed: () => taps++,
      );

      // Visible, so the viewer can see something is happening — but inert, so
      // a second tap cannot race the connection.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byType(CircularProgressIndicator));
      expect(taps, 0);
    });
  });
}
