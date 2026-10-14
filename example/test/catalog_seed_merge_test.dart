import 'dart:convert';

import 'package:fastpix_player_example/src/catalog.dart';
import 'package:fastpix_player_example/src/models/demo_stream.dart';
import 'package:flutter_test/flutter_test.dart';

const _fromFile = 'from-file';
const _coHost = 'stream.fastpix.co';
const _comHost = 'stream.fastpix.com';

/// What launch-time seeding does to a stored catalog.
///
/// Local overrides used to replace the stored catalog on every launch, so a
/// stream added in the app was gone after a restart and a deleted seeded
/// stream came back. These pin the merge that replaced it.
void main() {
  DemoStream stream(String id, {String? title, String? token}) =>
      DemoStream(playbackId: id, title: title ?? id, token: token);

  List<String> ids(List<DemoStream>? streams) =>
      streams!.map((stream) => stream.playbackId).toList();

  group('an empty catalog', () {
    test('takes the whole seed', () {
      final merged = Catalog.mergeSeed(
        stored: const [],
        seeded: [stream('a'), stream('b')],
        removed: const {},
        overridden: false,
      );
      expect(ids(merged), ['a', 'b']);
    });

    test('less anything the viewer deleted', () {
      final merged = Catalog.mergeSeed(
        stored: const [],
        seeded: [stream('a'), stream('b')],
        removed: const {'a'},
        overridden: true,
      );
      expect(ids(merged), ['b']);
    });
  });

  test('a stored catalog without overrides is left alone', () {
    final merged = Catalog.mergeSeed(
      stored: [stream('mine')],
      seeded: [stream('a')],
      removed: const {},
      overridden: false,
    );
    expect(merged, isNull);
  });

  group('with overrides', () {
    test('keeps a stream added in the app', () {
      final merged = Catalog.mergeSeed(
        stored: [stream('a'), stream('mine')],
        seeded: [stream('a')],
        removed: const {},
        overridden: true,
      );
      expect(ids(merged), ['a', 'mine']);
    });

    test('does not bring back a deleted seeded stream', () {
      final merged = Catalog.mergeSeed(
        stored: [stream('b')],
        seeded: [stream('a'), stream('b')],
        removed: const {'a'},
        overridden: true,
      );
      expect(ids(merged), ['b']);
    });

    test('appends a seeded stream never stored before', () {
      final merged = Catalog.mergeSeed(
        stored: [stream('mine')],
        seeded: [stream('new')],
        removed: const {},
        overridden: true,
      );
      expect(ids(merged), ['mine', 'new']);
    });

    test("refreshes the seed's token but keeps the viewer's title", () {
      final merged = Catalog.mergeSeed(
        stored: [stream('a', title: 'Renamed', token: 'yesterday')],
        seeded: [stream('a', title: 'Seed title', token: 'today')],
        removed: const {},
        overridden: true,
      );
      expect(merged!.single.token, 'today');
      expect(merged.single.title, 'Renamed');
    });

    test('a blank seed token does not clear a stored one', () {
      final merged = Catalog.mergeSeed(
        stored: [stream('a', token: 'kept')],
        seeded: [stream('a')],
        removed: const {},
        overridden: true,
      );
      expect(merged!.single.token, 'kept');
    });
  });

  // Seeding runs on every launch. It used to copy the seed's credentials over
  // the stored ones each time, so a token edited in the app was the seed's
  // again the next time the app opened.
  group('with a record of what the seed last applied', () {
    DemoStream drm(String id, {String? token, String? host}) => DemoStream(
      playbackId: id,
      title: id,
      token: token,
      drmToken: token,
      drmEnabled: token != null,
      streamHost: host,
      drmHost: host,
    );

    List<DemoStream>? relaunch(
      DemoStream stored,
      DemoStream seeded,
      SeedCredentials applied,
    ) => Catalog.mergeSeed(
      stored: [stored],
      seeded: [seeded],
      removed: const {},
      overridden: true,
      applied: {stored.playbackId: applied},
    );

    test('a token edited in the app survives an unchanged seed', () {
      final seed = drm('a', token: _fromFile, host: _coHost);
      final merged = relaunch(
        drm('a', token: 'edited', host: _coHost),
        seed,
        SeedCredentials.of(seed),
      );
      expect(merged!.single.token, 'edited');
      expect(merged.single.drmToken, 'edited');
    });

    test('a host edited in the app survives an unchanged seed', () {
      final seed = drm('a', token: 't', host: _coHost);
      final merged = relaunch(
        drm('a', token: 't', host: _comHost),
        seed,
        SeedCredentials.of(seed),
      );
      expect(merged!.single.streamHost, _comHost);
      expect(merged.single.drmHost, _comHost);
    });

    test('a refreshed seed still replaces the stored token', () {
      final merged = relaunch(
        drm('a', token: 'edited'),
        drm('a', token: 'fresh'),
        const SeedCredentials(token: 'yesterday', drmToken: 'yesterday'),
      );
      expect(merged!.single.token, 'fresh');
      expect(merged.single.drmToken, 'fresh');
    });

    test('only the fields the seed changed are applied', () {
      final merged = relaunch(
        drm('a', token: 'edited', host: 'my.host'),
        drm('a', token: 'fresh', host: _coHost),
        const SeedCredentials(
          token: 'yesterday',
          drmToken: 'yesterday',
          streamHost: _coHost,
          drmHost: _coHost,
        ),
      );
      expect(merged!.single.token, 'fresh');
      expect(merged.single.streamHost, 'my.host');
    });

    test('DRM switched off in the app stays off while the seed is unchanged',
        () {
      final seed = drm('a', token: 't');
      final merged = relaunch(
        seed.copyWith(drmEnabled: false),
        seed,
        SeedCredentials.of(seed),
      );
      expect(merged!.single.drmEnabled, isFalse);
    });

    test('a stream with no record takes the seed, as before', () {
      final merged = Catalog.mergeSeed(
        stored: [drm('a', token: 'edited')],
        seeded: [drm('a', token: _fromFile)],
        removed: const {},
        overridden: true,
        applied: const {},
      );
      expect(merged!.single.token, _fromFile);
    });

    test('the record survives being saved and read back', () {
      const credentials = SeedCredentials(
        token: 't',
        drmToken: 'd',
        streamHost: _coHost,
        drmHost: 'api.fastpix.co',
      );
      final decoded = SeedCredentials.decodeAll(
        jsonDecode(jsonEncode({'a': credentials.toJson(), 'bad': 3})),
      );
      expect(decoded.keys, ['a']);
      expect(decoded['a']!.token, 't');
      expect(decoded['a']!.drmToken, 'd');
      expect(decoded['a']!.streamHost, _coHost);
      expect(decoded['a']!.drmHost, 'api.fastpix.co');
    });
  });
}
