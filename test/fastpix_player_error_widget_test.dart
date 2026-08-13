import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _drmTokenRejected = 'DRM token rejected';

Future<void> _pumpPlayer(WidgetTester tester, FastPixPlayerController c) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: FastPixPlayer(controller: c, height: 200))),
  );
}

/// Let the widget's controller wait loop time out so no timers outlive the test
Future<void> _drainInitWait(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
}

void main() {
  testWidgets('renders a generic playback error', (tester) async {
    final controller = FastPixPlayerController();
    await _pumpPlayer(tester, controller);

    controller.eventManager.emit(
      FastPixPlayerErrorEvent(
        timestamp: DateTime(2026),
        message: 'Source error: connection lost',
        code: '503',
      ),
    );
    await tester.pump();

    expect(find.text('Source error: connection lost'), findsOneWidget);
    expect(find.text('503'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);

    await _drainInitWait(tester);
  });

  testWidgets('renders a DRM error with its code', (tester) async {
    final controller = FastPixPlayerController();
    await _pumpPlayer(tester, controller);

    controller.eventManager.emit(
      FastPixPlayerDrmErrorEvent.fromException(
        FastPixDrmErrorClassifier.toException(
          'MediaDrmCallbackException: Response code: 403',
          playbackId: 'abc',
        ),
        timestamp: DateTime(2026),
      ),
    );
    await tester.pump();

    expect(find.text(FastPixDrmErrorCode.licenseUnauthorized.code), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);

    await _drainInitWait(tester);
  });

  testWidgets('opaque platform text is not shown as the headline', (
    tester,
  ) async {
    final controller = FastPixPlayerController();
    await _pumpPlayer(tester, controller);

    controller.eventManager.emit(
      FastPixPlayerErrorEvent(
        timestamp: DateTime(2026),
        message: 'Video player had error ExoPlaybackException: Source error',
      ),
    );
    await tester.pump();

    // The viewer gets a stable headline; the raw text is demoted to detail.
    expect(find.text('Playback failed'), findsOneWidget);
    expect(
      find.text('Video player had error ExoPlaybackException: Source error'),
      findsOneWidget,
    );

    await _drainInitWait(tester);
  });

  testWidgets('an identified DRM cause is the headline immediately', (
    tester,
  ) async {
    final controller = FastPixPlayerController();
    await _pumpPlayer(tester, controller);

    controller.eventManager.emit(
      FastPixPlayerDrmErrorEvent.fromException(
        const FastPixDrmException(
          FastPixDrmErrorCode.licenseUnauthorized,
          _drmTokenRejected,
        ),
        timestamp: DateTime(2026),
      ),
    );
    await tester.pump();

    // Already the most specific thing known, so it is never replaced.
    expect(find.text(_drmTokenRejected), findsOneWidget);
    expect(find.text('Playback failed'), findsNothing);

    await _drainInitWait(tester);
  });

  testWidgets('a new controller clears the previous error', (tester) async {
    // Reproduces retrying with a corrected DRM token: the stream URL is
    // unchanged, so only the swapped controller signals a new attempt.
    final failed = FastPixPlayerController();
    await _pumpPlayer(tester, failed);

    failed.eventManager.emit(
      FastPixPlayerDrmErrorEvent.fromException(
        const FastPixDrmException(
          FastPixDrmErrorCode.licenseUnauthorized,
          _drmTokenRejected,
        ),
        timestamp: DateTime(2026),
      ),
    );
    await tester.pump();
    expect(find.text(_drmTokenRejected), findsOneWidget);

    // Retry with a fresh controller, as an app does on "try again".
    final retried = FastPixPlayerController();
    await _pumpPlayer(tester, retried);
    await tester.pump();

    expect(find.text(_drmTokenRejected), findsNothing);

    // The old controller is detached; only the new one drives the UI.
    failed.eventManager.emit(
      FastPixPlayerErrorEvent(
        timestamp: DateTime(2026),
        message: 'stale error from the old attempt',
      ),
    );
    await tester.pump();
    expect(find.text('stale error from the old attempt'), findsNothing);

    retried.eventManager.emit(
      FastPixPlayerErrorEvent(
        timestamp: DateTime(2026),
        message: 'fresh error from the new attempt',
      ),
    );
    await tester.pump();
    expect(find.text('fresh error from the new attempt'), findsOneWidget);

    await _drainInitWait(tester);
  });

  testWidgets('drmErrorWidgetBuilder overrides the DRM error UI', (
    tester,
  ) async {
    final controller = FastPixPlayerController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FastPixPlayer(
            controller: controller,
            height: 200,
            drmErrorWidgetBuilder:
                (error) => Text('custom: ${error.errorCode.name}'),
          ),
        ),
      ),
    );

    controller.eventManager.emit(
      FastPixPlayerDrmErrorEvent.fromException(
        const FastPixDrmException(
          FastPixDrmErrorCode.deviceNotSupported,
          'no secure decoder',
        ),
        timestamp: DateTime(2026),
      ),
    );
    await tester.pump();

    expect(find.text('custom: deviceNotSupported'), findsOneWidget);

    await _drainInitWait(tester);
  });
}
