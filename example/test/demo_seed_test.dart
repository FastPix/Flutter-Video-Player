import 'package:fastpix_player_example/src/demo_seed.dart';
import 'package:flutter_test/flutter_test.dart';

// The seed exists so nobody types playback IDs into the app one at a time.
//
// That only holds if every line in `.env` becomes a stream. A dropped entry is
// silent — the app just shows fewer titles than the file lists, which reads as
// "the app is fine" rather than "the parser ate one".

/// IDs used by the format tests. Only their shape matters, not their value.
const String idA = 'abc-123';
const String idB = 'def-456';

void main() {
  group('the shipped catalog', () {
    // These IDs are committed rather than read from `.env`, so a fresh clone
    // and a CI machine behave identically to a developer's laptop. A gitignored
    // file cannot be a build input: Flutter fails outright on a declared asset
    // that is missing.
    test('ships enough streams to exercise the preload window', () {
      expect(DemoSeed.defaultPlaybackIds.length, greaterThanOrEqualTo(4));
    });

    test('every shipped ID parses into a stream', () {
      final streams = DemoSeed.parse(DemoSeed.defaultPlaybackIds.join('\n'));
      expect(streams, hasLength(DemoSeed.defaultPlaybackIds.length));
    });

    test('no duplicates in the shipped list', () {
      expect(
        DemoSeed.defaultPlaybackIds.toSet(),
        hasLength(DemoSeed.defaultPlaybackIds.length),
      );
    });

    test('the shipped list carries no tokens', () {
      // A committed ID is harmless; a committed token is a credential leak.
      // Anything with a comma has extra fields, and the third is the token.
      for (final id in DemoSeed.defaultPlaybackIds) {
        expect(id.contains(','), isFalse, reason: '$id carries extra fields');
      }
    });
  });

  group('the format', () {
    test('blank lines and comments are skipped', () {
      final streams = DemoSeed.parse('# a comment\n$idA\n\n\n$idB\n');
      expect(streams.map((s) => s.playbackId), <String>[idA, idB]);
    });

    test('a repeated ID is added once', () {
      // Two entries for one asset make the preload window confusing to read,
      // since the same key appears twice in the logs.
      expect(DemoSeed.parse('$idA\n$idA\n'), hasLength(1));
    });

    test('an optional title is used, and the ID is the fallback', () {
      final streams = DemoSeed.parse('$idA, My Title\n$idB\n');
      expect(streams.first.title, 'My Title');
      expect(streams.last.title, idB);
    });

    test('a third field is taken as the playback token', () {
      final streams = DemoSeed.parse('$idA, Title, tok-789\n');
      expect(streams.single.token, 'tok-789');
    });

    test('a last line with no trailing newline is still read', () {
      // The real .env ends this way, so this is not hypothetical.
      expect(DemoSeed.parse('$idA\n$idB'), hasLength(2));
    });

    test('carriage returns do not corrupt the ID', () {
      // A file saved on Windows would otherwise yield ids ending in \r, which
      // produce a URL that 404s in a way that looks like a bad playback ID.
      final streams = DemoSeed.parse('$idA\r\n$idB\r\n');
      expect(streams.map((s) => s.playbackId), <String>[idA, idB]);
    });
  });
}
