import 'package:fastpix_player_example/src/catalog.dart';
import 'package:fastpix_player_example/src/models/demo_stream.dart';
import 'package:flutter_test/flutter_test.dart';

/// The hero banner's rules: what it features, and when it offers to resume.
///
/// These live in the catalogue rather than in the widget because they are the
/// decisions — "which stream is the top of the screen about" and "is this
/// position worth going back to" — and both were previously answered wrongly:
/// the banner showed `_streams.first` forever, whatever you watched.
void main() {
  final catalog = Catalog.instance;

  DemoStream stream(String id) => DemoStream(playbackId: id, title: id);

  setUp(() {
    for (final existing in catalog.streams) {
      catalog.remove(existing);
    }
    catalog
      ..save(stream('first'))
      ..save(stream('second'))
      ..save(stream('third'));
  });

  tearDown(() {
    for (final existing in catalog.streams) {
      catalog.remove(existing);
    }
  });

  group('what the hero features', () {
    test('the first entry until something has been watched', () {
      expect(catalog.featured?.playbackId, 'first');
    });

    test('whatever was watched most recently', () {
      catalog.markWatchedId('third');
      expect(catalog.featured?.playbackId, 'third');

      catalog.markWatchedId('second');
      expect(catalog.featured?.playbackId, 'second',
          reason: 'the banner follows the viewer, not the insertion order');
    });

    test('falls back when the most recent stream is deleted', () {
      catalog.markWatchedId('third');
      catalog.remove(stream('third'));
      expect(catalog.featured?.playbackId, 'first');
    });
  });

  group('recording progress', () {
    test('is readable back, with its fraction and remaining time', () {
      catalog.recordProgress(
        'second',
        const Duration(minutes: 3),
        const Duration(minutes: 12),
      );

      final progress = catalog.progressOf('second');
      expect(progress?.position, const Duration(minutes: 3));
      expect(progress?.duration, const Duration(minutes: 12));
      expect(progress?.fraction, closeTo(0.25, 0.001));
      expect(progress?.remaining, const Duration(minutes: 9));
    });

    test('a zero duration is not recorded — there is nothing to be part of',
        () {
      catalog.recordProgress('second', const Duration(seconds: 30), Duration.zero);
      expect(catalog.progressOf('second'), isNull);
    });

    test('deleting a stream forgets where it had reached', () {
      catalog.recordProgress(
        'second',
        const Duration(minutes: 3),
        const Duration(minutes: 12),
      );
      catalog.remove(stream('second'));
      expect(catalog.progressOf('second'), isNull);
    });

    test('finishing clears it, so the next open starts fresh', () {
      catalog.recordProgress(
        'second',
        const Duration(minutes: 3),
        const Duration(minutes: 12),
      );
      catalog.clearProgress('second');
      expect(catalog.resumePositionOf('second'), isNull);
    });
  });

  group('when a position is worth resuming', () {
    Duration? resumeAt(Duration position, Duration duration) {
      catalog.recordProgress('second', position, duration);
      return catalog.resumePositionOf('second');
    }

    test('a real position part-way through resumes there', () {
      expect(
        resumeAt(const Duration(minutes: 3), const Duration(minutes: 12)),
        const Duration(minutes: 3),
      );
    });

    test('the first few seconds do not count as started', () {
      expect(
        resumeAt(const Duration(seconds: 4), const Duration(minutes: 12)),
        isNull,
        reason: 'offering to resume four seconds in is noise',
      );
    });

    test('a position at the credits starts over instead', () {
      expect(
        resumeAt(const Duration(seconds: 115), const Duration(seconds: 120)),
        isNull,
        reason: 'a video that ran to the end should offer a fresh play',
      );
    });
  });

  group('StreamProgress persistence', () {
    test('round-trips through JSON', () {
      const progress = StreamProgress(
        position: Duration(minutes: 2),
        duration: Duration(minutes: 10),
      );
      final decoded = StreamProgress.decodeAll(<String, dynamic>{
        'abc': progress.toJson(),
      });
      expect(decoded['abc']?.position, const Duration(minutes: 2));
      expect(decoded['abc']?.duration, const Duration(minutes: 10));
    });

    test('unreadable entries are skipped, not fatal', () {
      final decoded = StreamProgress.decodeAll(<String, dynamic>{
        'good': <String, dynamic>{'position': 1000, 'duration': 5000},
        'bad': <String, dynamic>{'position': 'halfway'},
        'worse': 'not even a map',
      });
      expect(decoded.keys, <String>['good']);
    });

    test('a missing or malformed store decodes to nothing', () {
      expect(StreamProgress.decodeAll(null), isEmpty);
      expect(StreamProgress.decodeAll('nonsense'), isEmpty);
    });
  });
}
