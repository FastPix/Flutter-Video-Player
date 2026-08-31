import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifies the platform messages a call site cannot tell apart', () {
    test('Play Services is separated from a generic init failure', () {
      // Both surface from initialize(), which only knows "init failed".
      expect(
        FastPixCastErrorClassifier.classifyOr(
          'PlatformException: SERVICE_VERSION_UPDATE_REQUIRED',
          FastPixCastErrorCode.initFailed,
        ),
        FastPixCastErrorCode.playServicesUnavailable,
      );
      expect(
        FastPixCastErrorClassifier.classifyOr(
          'PlatformException: something else entirely',
          FastPixCastErrorCode.initFailed,
        ),
        FastPixCastErrorCode.initFailed,
      );
    });

    test('a receiver in use by another sender is not a plain connect failure', () {
      expect(
        FastPixCastErrorClassifier.classifyOr(
          'Failed to start session: device already in use',
          FastPixCastErrorCode.connectFailed,
        ),
        FastPixCastErrorCode.sessionTaken,
      );
    });

    test('a refused container is separated from a failed load', () {
      expect(
        FastPixCastErrorClassifier.classifyOr(
          'Receiver reported unsupported codec avc1.640033',
          FastPixCastErrorCode.loadFailed,
        ),
        FastPixCastErrorCode.mediaUnsupported,
      );
    });

    test('an unrecognisable error keeps the call site\'s own code', () {
      expect(
        FastPixCastErrorClassifier.classifyOr(
          'error 42',
          FastPixCastErrorCode.commandFailed,
        ),
        FastPixCastErrorCode.commandFailed,
      );
    });

    test('no cause at all keeps the call site\'s own code', () {
      expect(FastPixCastErrorClassifier.classify(null), isNull);
      expect(
        FastPixCastErrorClassifier.classifyOr(
          null,
          FastPixCastErrorCode.drmUnsupported,
        ),
        FastPixCastErrorCode.drmUnsupported,
      );
    });
  });

  group('codes carry the handling a UI needs', () {
    test('permission failures point at Settings, not at a retry', () {
      const code = FastPixCastErrorCode.nearbyPermissionDenied;
      expect(code.isPermissionRelated, isTrue);
      expect(code.isFatal, isTrue);
      expect(code.isRetryable, isFalse);
    });

    test('content that can never cast is not offered a retry', () {
      for (final code in [
        FastPixCastErrorCode.drmUnsupported,
        FastPixCastErrorCode.mediaUnsupported,
      ]) {
        expect(code.isContentUnsupported, isTrue, reason: code.name);
        expect(code.isRetryable, isFalse, reason: code.name);
      }
    });

    test('a timed-out connection is worth trying again', () {
      expect(FastPixCastErrorCode.connectTimeout.isRetryable, isTrue);
      expect(FastPixCastErrorCode.connectTimeout.isFatal, isFalse);
    });

    test('every code has a unique, stable FP_CAST_ string', () {
      final codes = FastPixCastErrorCode.values.map((c) => c.code).toList();
      expect(codes.toSet(), hasLength(codes.length));
      expect(codes.every((c) => c.startsWith('FP_CAST_')), isTrue);
    });
  });

  group('the event exposes the raw platform text separately', () {
    test('underlyingError is not buried in the message', () {
      final event = FastPixCastErrorEvent(
        timestamp: DateTime.now(),
        message: 'Could not load the stream on Living Room TV',
        errorCode: FastPixCastErrorCode.mediaUnsupported,
        underlyingError: 'PlatformException(LOAD_FAILED, unsupported codec)',
      );

      expect(event.code, 'FP_CAST_MEDIA_UNSUPPORTED');
      expect(event.underlyingError, contains('unsupported codec'));
      expect(event.message, isNot(contains('PlatformException')));
      expect(event.isContentUnsupported, isTrue);
      expect(event.type, FastPixPlayerEventTypes.castError);
    });
  });
}
