import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// The skip manager on its own: entry, exit, seeking across a boundary, and
/// the deferred validation that keeps an unknown duration from being mistaken
/// for an invalid segment. No platform binding — it is handed a position and a
/// duration and answers with events.
void main() {
  late FastPixPlayerEventManager events;
  late List<FastPixPlayerEvent> emitted;
  late FastPixSkipManager manager;

  setUp(() {
    events = FastPixPlayerEventManager();
    emitted = <FastPixPlayerEvent>[];
    events.addGlobalListener(emitted.add);
    manager = FastPixSkipManager(events);
  });

  const intro = FastPixSkipSegment(
    start: Duration(seconds: 10),
    end: Duration(seconds: 40),
    type: FastPixSkipType.intro,
  );
  const credits = FastPixSkipSegment(
    start: Duration(seconds: 100),
    end: Duration(seconds: 120),
    type: FastPixSkipType.credits,
  );
  const duration = Duration(seconds: 130);

  void tick(int seconds, {Duration? mediaDuration = duration}) =>
      manager.evaluate(
        position: Duration(seconds: seconds),
        duration: mediaDuration,
      );

  List<String> types() =>
      emitted.map((event) => event.type).toList();

  group('reporting an active segment', () {
    setUp(() => manager.setSegments(const <FastPixSkipSegment>[intro, credits]));

    test('entering a segment reports it once', () {
      tick(5);
      expect(manager.activeSegment, isNull);
      expect(types(), isEmpty);

      tick(10);
      expect(manager.activeSegment, intro);
      expect(types(), <String>[FastPixPlayerEventTypes.skipAvailable]);
      expect(
        (emitted.single as FastPixSkipAvailableEvent).segment,
        intro,
      );
    });

    test('staying inside emits nothing further', () {
      tick(12);
      tick(20);
      tick(39);
      expect(types(), <String>[FastPixPlayerEventTypes.skipAvailable]);
      expect(manager.activeSegment, intro);
    });

    test('leaving reports the hide, and nothing is active', () {
      tick(12);
      tick(40);
      expect(types(), <String>[
        FastPixPlayerEventTypes.skipAvailable,
        FastPixPlayerEventTypes.skipHidden,
      ]);
      expect(manager.activeSegment, isNull);
    });

    test('seeking straight into a segment reports it', () {
      tick(0);
      tick(110);
      expect(manager.activeSegment, credits);
      expect(types(), <String>[FastPixPlayerEventTypes.skipAvailable]);
    });

    test('seeking out of an active segment hides it', () {
      tick(110);
      tick(5);
      expect(manager.activeSegment, isNull);
      expect(types().last, FastPixPlayerEventTypes.skipHidden);
    });

    test('a source with no segments reports nothing at all', () {
      manager.setSegments(null);
      for (var second = 0; second < 130; second += 10) {
        tick(second);
      }
      expect(emitted, isEmpty);
      expect(manager.activeSegment, isNull);
    });
  });

  group('deferred validation', () {
    setUp(() => manager.setSegments(const <FastPixSkipSegment>[intro]));

    test('an unknown duration means not yet validated, never invalid', () {
      tick(15, mediaDuration: null);
      expect(manager.isValidated, isFalse);
      expect(manager.activeSegment, isNull,
          reason: 'nothing may activate before validation');
      expect(emitted, isEmpty, reason: 'and nothing may be rejected');
    });

    test('validation runs once, when the duration arrives', () {
      tick(15, mediaDuration: null);
      tick(15);
      expect(manager.isValidated, isTrue);
      expect(manager.activeSegment, intro);
      expect(types(), <String>[FastPixPlayerEventTypes.skipAvailable]);

      // A second tick re-validates nothing and re-emits nothing.
      tick(16);
      expect(types(), <String>[FastPixPlayerEventTypes.skipAvailable]);
    });

    test('a duration that never arrives leaves the segments pending', () {
      for (var second = 0; second < 200; second += 5) {
        tick(second, mediaDuration: null);
      }
      expect(manager.isValidated, isFalse);
      expect(manager.activeSegment, isNull);
      expect(emitted, isEmpty,
          reason: 'a live stream offers no control and reports no failure');
    });

    test('a zero duration is treated as unknown, as a live stream reports it',
        () {
      tick(15, mediaDuration: Duration.zero);
      expect(manager.isValidated, isFalse);
      expect(emitted, isEmpty);
    });
  });

  group('validation', () {
    FastPixSkipFailedEvent? failureFor(FastPixSkipSegment segment) {
      manager.setSegments(<FastPixSkipSegment>[segment]);
      tick(0);
      final failures = emitted.whereType<FastPixSkipFailedEvent>();
      return failures.isEmpty ? null : failures.first;
    }

    test('a zero-length segment is rejected', () {
      final failure = failureFor(const FastPixSkipSegment(
        start: Duration(seconds: 20),
        end: Duration(seconds: 20),
        type: FastPixSkipType.recap,
      ));
      expect(failure?.reason, FastPixSkipFailureReason.zeroLength);
    });

    test('an inverted range is rejected', () {
      final failure = failureFor(const FastPixSkipSegment(
        start: Duration(seconds: 30),
        end: Duration(seconds: 10),
        type: FastPixSkipType.song,
      ));
      expect(failure?.reason, FastPixSkipFailureReason.invertedRange);
    });

    test('a segment starting at or past the duration is rejected', () {
      final failure = failureFor(const FastPixSkipSegment(
        start: duration,
        end: Duration(seconds: 140),
        type: FastPixSkipType.credits,
      ));
      expect(failure?.reason, FastPixSkipFailureReason.startBeyondDuration);
    });

    test('a segment ending past the duration is rejected', () {
      final failure = failureFor(const FastPixSkipSegment(
        start: Duration(seconds: 120),
        end: Duration(seconds: 140),
        type: FastPixSkipType.credits,
      ));
      expect(failure?.reason, FastPixSkipFailureReason.endBeyondDuration);
    });

    test('a valid segment survives an invalid sibling', () {
      manager.setSegments(const <FastPixSkipSegment>[
        FastPixSkipSegment(
          start: Duration(seconds: 200),
          end: Duration(seconds: 210),
          type: FastPixSkipType.credits,
        ),
        intro,
      ]);
      tick(15);

      expect(
        emitted.whereType<FastPixSkipFailedEvent>().single.reason,
        FastPixSkipFailureReason.startBeyondDuration,
      );
      expect(manager.activeSegment, intro);
      expect(manager.segments, <FastPixSkipSegment>[intro]);
    });

    test('the duration-relative rules are never applied before duration', () {
      manager.setSegments(const <FastPixSkipSegment>[
        FastPixSkipSegment(
          start: Duration(seconds: 500),
          end: Duration(seconds: 520),
          type: FastPixSkipType.credits,
        ),
      ]);
      tick(10, mediaDuration: null);
      expect(emitted, isEmpty,
          reason: 'that segment is only out of range once a duration exists');

      tick(10);
      expect(
        emitted.whereType<FastPixSkipFailedEvent>().single.reason,
        FastPixSkipFailureReason.startBeyondDuration,
      );
    });

    test('a rejection is reported once, not on every tick', () {
      manager.setSegments(const <FastPixSkipSegment>[
        FastPixSkipSegment(
          start: Duration(seconds: 20),
          end: Duration(seconds: 20),
          type: FastPixSkipType.intro,
        ),
      ]);
      tick(1);
      tick(2);
      tick(3);
      expect(emitted.whereType<FastPixSkipFailedEvent>(), hasLength(1));
    });
  });

  group('per source', () {
    test('resetting hides an active segment and drops the segments', () {
      manager.setSegments(const <FastPixSkipSegment>[intro]);
      tick(15);
      expect(manager.activeSegment, intro);

      manager.resetForNewSource();

      expect(manager.activeSegment, isNull);
      expect(manager.hasSegments, isFalse);
      expect(manager.isValidated, isFalse);
      expect(types().last, FastPixPlayerEventTypes.skipHidden);
    });

    test('a skip clears the active segment and reports completion', () {
      manager.setSegments(const <FastPixSkipSegment>[intro]);
      tick(15);
      manager.notifySkipped(intro);

      expect(manager.activeSegment, isNull);
      expect(types().last, FastPixPlayerEventTypes.skipCompleted);
      expect(
        (emitted.last as FastPixSkipCompletedEvent).segment,
        intro,
      );

      // The tick after the skip lands past the end and reports nothing new.
      tick(40);
      expect(types().last, FastPixPlayerEventTypes.skipCompleted);
    });
  });
}
