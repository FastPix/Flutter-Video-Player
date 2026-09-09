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

/// The licence token used across the seed-format cases.
const String licenceToken = 'tok-789';

void main() {
  // load() reads an asset, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the shipped catalog', () {
    // These IDs are committed rather than read from `.env`, so a fresh clone
    // and a CI machine behave identically to a developer's laptop. A gitignored
    // file cannot be a build input: Flutter fails outright on a declared asset
    // that is missing.
    test('ships enough streams to exercise the preload window', () {
      expect(DemoSeed.defaultCatalog.length, greaterThanOrEqualTo(4));
    });

    test('every shipped line parses into a stream', () {
      final streams = DemoSeed.parse(DemoSeed.defaultCatalog.join('\n'));
      expect(streams, hasLength(DemoSeed.defaultCatalog.length));
    });

    test('no duplicates in the shipped list', () {
      final ids = DemoSeed.defaultCatalog
          .map((line) => line.split(',').first.trim())
          .toSet();
      expect(ids, hasLength(DemoSeed.defaultCatalog.length));
    });

    test('the shipped list carries no tokens', () {
      // A committed ID is harmless; a committed token is a credential leak.
      // Titles are fine — the token is the *third* field, so what is forbidden
      // is a line with more than two fields, not a line with a comma in it.
      for (final line in DemoSeed.defaultCatalog) {
        expect(
          line.split(',').length,
          lessThanOrEqualTo(2),
          reason: '$line carries a third field, which would be a token',
        );
      }
    });

    test('every shipped stream is named, so nothing shows a bare UUID', () {
      // The playlist queue, the catalog rows and the up-next rail all render
      // DemoStream.title, which parse() falls back to the playback ID for.
      for (final stream in DemoSeed.parse(DemoSeed.defaultCatalog.join('\n'))) {
        expect(
          stream.title,
          isNot(stream.playbackId),
          reason: '${stream.playbackId} has no title',
        );
        expect(stream.title.trim(), isNotEmpty);
      }
    });

    test('titles are unique, so two queue rows never read the same', () {
      final titles = DemoSeed.parse(DemoSeed.defaultCatalog.join('\n'))
          .map((stream) => stream.title)
          .toSet();
      expect(titles, hasLength(DemoSeed.defaultCatalog.length));
    });
  });

  group('the merged seed', () {
    // `_extra` is compile-time, so what a run without the define produces is
    // all a unit test can observe directly. The merge rule it relies on —
    // first line for an ID wins — is what the tokened `.env` entry needs in
    // order to replace the tokenless committed one, so lock that down here.
    test('an extra line ahead of a shipped one replaces it', () {
      final shipped = DemoSeed.defaultCatalog.first;
      final id = shipped.split(',').first.trim();
      final streams = DemoSeed.parse('$id, DRM, tok-789, licence-abc\n$shipped');

      expect(streams, hasLength(1));
      expect(streams.single.drmToken, 'licence-abc');
      expect(streams.single.token, licenceToken);
      expect(streams.single.title, 'DRM');
    });

    test('load() falls back to the shipped catalog with no overrides', () async {
      // The fresh-clone path: no local file, no define, and the app still has
      // a full catalog. On a machine that *does* have the file, the assertion
      // is the other half of the contract — overrides only ever add.
      final streams = await DemoSeed.load();
      if (DemoSeed.hasLocalOverrides) {
        expect(streams.length, greaterThanOrEqualTo(
          DemoSeed.defaultCatalog.length,
        ));
        return;
      }
      expect(streams, hasLength(DemoSeed.defaultCatalog.length));
    });

    test('every tokened entry that arrives is a usable DRM source', () async {
      // Only meaningful on a machine carrying `assets/local/streams.txt`;
      // without it there is nothing to assert and this passes trivially. Its
      // job is to prove the whole path — bundle read, merge, DRM flag, URLs —
      // on the machine where DRM is actually being tested.
      final drm = (await DemoSeed.load()).where((s) => s.drmEnabled).toList();
      if (drm.isEmpty) {
        expect(DemoSeed.hasLocalOverrides, isFalse,
            reason: 'local overrides were read but produced no DRM stream');
        return;
      }
      for (final stream in drm) {
        expect(stream.drmToken, isNotNull);
        final source = stream.toDataSource();
        expect(source.drmEnabled, isTrue);
        // A DRM entry with no playback token is legal but never what is meant
        // here: FastPix DRM media is always private.
        expect(stream.token, isNotNull, reason: '${stream.title} has no token');
        // The manifest and the licence must agree on an environment.
        final manifestIsStaging = source.url.contains('fastpix.co/');
        final licenceIsStaging = source.drmConfiguration!
            .resolvedBaseUrl
            .contains('fastpix.co/');
        expect(manifestIsStaging, licenceIsStaging,
            reason: '${stream.title} mixes environments');
      }
    });

    test('comments and blank lines in the local file are ignored', () {
      // The file is meant to be annotated — which entry expires when, which
      // one is a known-bad asset — and a comment must not become a stream.
      final streams = DemoSeed.parse(
        '# a note\n\n$idA, Real, tok, lic, stream.fastpix.co, api.fastpix.co\n'
        '# 72dd0ebb-…, disabled for now\n',
      );
      expect(streams, hasLength(1));
      expect(streams.single.playbackId, idA);
    });
  });

  group('the format', () {
    test('quotes around a field are stripped', () {
      // Seed lines are usually pasted from somewhere they were quoted — a Dart
      // list, a shell command — and a title complete with apostrophes is not
      // what anyone meant.
      final streams = DemoSeed.parse("'$idA', 'Nature'\n");
      expect(streams.single.playbackId, idA);
      expect(streams.single.title, 'Nature');
    });

    test('an apostrophe inside a title survives', () {
      final streams = DemoSeed.parse("$idA, Nature's best\n");
      expect(streams.single.title, "Nature's best");
    });

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

    test('a fourth field is the licence token, and it turns DRM on', () {
      final stream = DemoSeed.parse('$idA, DRM prod, tok-789, licence-abc\n').single;
      expect(stream.drmToken, 'licence-abc');
      expect(stream.drmEnabled, isTrue);
      // Both tokens survive: the playback token signs the URL, the licence
      // token authorises decryption. They are different credentials.
      expect(stream.token, licenceToken);
      expect(stream.toDataSource().drmEnabled, isTrue);
    });

    test('the fifth and sixth fields are the stream and DRM hosts', () {
      // A staging asset 404s on the production host, and its licence request
      // fails on the production DRM host — two different origins, both wrong,
      // so both are seedable.
      final stream = DemoSeed.parse(
        '$idA, DRM staging, tok, lic, stream.fastpix.co, api.fastpix.co\n',
      ).single;

      expect(stream.streamHost, 'stream.fastpix.co');
      expect(stream.drmHost, 'api.fastpix.co');

      final source = stream.toDataSource();
      expect(source.url, startsWith('https://stream.fastpix.co/'));
      expect(
        source.drmConfiguration!.licenseUrl(idA),
        startsWith('https://api.fastpix.co/'),
      );
    });

    test('omitted hosts leave the package defaults in place', () {
      // Which is what every production entry relies on.
      final stream = DemoSeed.parse('$idA, Prod, tok, lic\n').single;
      expect(stream.streamHost, isNull);
      expect(stream.drmHost, isNull);
      expect(stream.toDataSource().url, startsWith('https://stream.fastpix.com/'));
      expect(
        stream.toDataSource().drmConfiguration!.licenseUrl(idA),
        startsWith('https://api.fastpix.com/'),
      );
    });

    test('a stream host with no DRM host is left alone, not guessed', () {
      final stream = DemoSeed.parse('$idA, Clear, , , video.example.com\n').single;
      expect(stream.streamHost, 'video.example.com');
      expect(stream.drmHost, isNull);
      expect(stream.drmEnabled, isFalse);
    });

    test('a playback token alone does not imply DRM', () {
      // Plenty of signed streams are unprotected, and guessing wrong here
      // produces a failure that reads like a DRM bug.
      final stream = DemoSeed.parse('$idA, Signed, tok-789\n').single;
      expect(stream.drmEnabled, isFalse);
      expect(stream.drmToken, isNull);
      expect(stream.toDataSource().drmEnabled, isFalse);
    });

    test('a DRM stream can be seeded without a playback token', () {
      final stream = DemoSeed.parse('$idA, DRM, , licence-abc\n').single;
      expect(stream.drmEnabled, isTrue);
      expect(stream.token, isNull);
    });

    test('a third field is taken as the playback token', () {
      final streams = DemoSeed.parse('$idA, Title, tok-789\n');
      expect(streams.single.token, licenceToken);
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
