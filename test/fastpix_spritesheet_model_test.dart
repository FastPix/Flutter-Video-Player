import 'dart:convert';
import 'dart:io';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_routed_http.dart';
import 'support/spritesheet_fixtures.dart';

final Uri imageUrl = Uri.parse(
  'https://images.fastpix.com/abc/spritesheet.jpg',
);

/// A non-production stream host, for the derivation tests.
const String altStreamHost = 'stream.fastpix.co';

/// The images origin [altStreamHost] must derive.
const String altImagesOrigin = 'https://images.fastpix.co';

FastPixSpritesheet parse(
  String body, {
  FastPixSpritesheetType type = FastPixSpritesheetType.normal,
}) => FastPixSpritesheet.parse(body, type: type, imageUrl: imageUrl);

void main() {
  spritesheetConfigurationTests();
  imagesHostTests();
  parseTests();
  tileAtTests();
  fakeRoutedHttpTests();
}

void spritesheetConfigurationTests() {
  group('FastPixPlayerSpritesheetConfiguration', () {
    test('defaults load the normal spritesheet from the default host', () {
      const config = FastPixPlayerSpritesheetConfiguration();
      expect(config.enableSpritesheet, isTrue);
      expect(config.enableAdvancedSpritesheet, isFalse);
      expect(config.advancedSpritesheetInterval, 10);
    });

    test('an interval outside 1 to 10 resolves to 10', () {
      int resolved(int interval) =>
          FastPixPlayerSpritesheetConfiguration(
            advancedSpritesheetInterval: interval,
          ).resolvedInterval;
      expect(resolved(0), 10);
      expect(resolved(1), 1);
      expect(resolved(10), 10);
      expect(resolved(11), 10);
    });

    test('copyWith replaces only what it is given', () {
      const base = FastPixPlayerSpritesheetConfiguration();
      final copy = base.copyWith(
        enableAdvancedSpritesheet: true,
        advancedSpritesheetInterval: 2,
      );
      expect(copy.enableSpritesheet, isTrue);
      expect(copy.enableAdvancedSpritesheet, isTrue);
      expect(copy.advancedSpritesheetInterval, 2);
    });

    test('is carried by FastPixPlayerConfiguration and its copyWith', () {
      final config = FastPixPlayerConfiguration(
        'ws',
        'viewer',
        'beacon',
        spritesheetConfiguration: const FastPixPlayerSpritesheetConfiguration(
          enableAdvancedSpritesheet: true,
        ),
      );
      expect(
        config.copyWith().spritesheetConfiguration.enableAdvancedSpritesheet,
        isTrue,
      );
      expect(
        FastPixPlayerConfiguration(
          'ws',
          'viewer',
          'beacon',
        ).spritesheetConfiguration.enableSpritesheet,
        isTrue,
      );
    });

    test('does not change the preload fingerprint', () {
      const source = FastPixPlayerDataSource(
        playbackId: 'abc',
        format: FastPixStreamingFormat.hls,
      );
      String fingerprint(FastPixPlayerSpritesheetConfiguration settings) =>
          betterPlayerConfigurationFingerprint(
            configuration: FastPixPlayerConfiguration(
              'ws',
              'viewer',
              'beacon',
              spritesheetConfiguration: settings,
            ),
            dataSource: source,
          );
      expect(
        fingerprint(const FastPixPlayerSpritesheetConfiguration()),
        fingerprint(
          const FastPixPlayerSpritesheetConfiguration(
            enableSpritesheet: false,
            enableAdvancedSpritesheet: true,
            advancedSpritesheetInterval: 2,
          ),
        ),
      );
    });
  });
}

void imagesHostTests() {
  group('FastPixPlayerDataSource.imagesHost', () {
    // FastPix serves images from the stream host with `stream` swapped for
    // `images` in the first label. These are the hosts the Android and iOS
    // SDKs hard-code between them; neither table holds all of these, which is
    // why the rule reads the host instead of memorising it.
    test('derives the images host for every known FastPix environment', () {
      const cases = <String, String>{
        'stream.fastpix.com': 'https://images.fastpix.com',
        altStreamHost: altImagesOrigin,
        'stream.fastpix.io': 'https://images.fastpix.io',
        'stream.fastpix.app': 'https://images.fastpix.app',
        'venus-stream.fastpix.dev': 'https://venus-images.fastpix.dev',
      };
      cases.forEach((domain, expected) {
        expect(
          FastPixPlayerDataSource.hls(
            playbackId: 'abc',
            customDomain: domain,
          ).imagesHost,
          expected,
          reason: domain,
        );
      });
    });

    test('no custom domain means the default images host', () {
      expect(
        FastPixPlayerDataSource.hls(playbackId: 'abc').imagesHost,
        FastPixPlayerDataSource.defaultImagesHost,
      );
      expect(
        FastPixPlayerDataSource.hls(
          playbackId: 'abc',
          customDomain: '',
        ).imagesHost,
        FastPixPlayerDataSource.defaultImagesHost,
      );
    });

    test('a scheme or a trailing slash on the domain is tolerated', () {
      // The two shapes that come from pasting a browser URL or a config file.
      for (final domain in <String>[
        'https://stream.fastpix.co',
        'stream.fastpix.co/',
        'https://stream.fastpix.co/',
      ]) {
        expect(
          FastPixPlayerDataSource.hls(
            playbackId: 'abc',
            customDomain: domain,
          ).imagesHost,
          altImagesOrigin,
          reason: domain,
        );
      }
    });

    test('the label match ignores case, as host names do', () {
      // A host name is case-insensitive, so `Stream.fastpix.co` plays exactly
      // like `stream.fastpix.co`. It must not be the one spelling that
      // silently drops seek previews.
      for (final domain in <String>[
        'Stream.fastpix.co',
        'STREAM.FASTPIX.CO',
        'Venus-Stream.fastpix.dev',
      ]) {
        expect(
          FastPixPlayerDataSource.hls(
            playbackId: 'abc',
            customDomain: domain,
          ).imagesHost,
          isNotNull,
          reason: domain,
        );
      }
      expect(
        FastPixPlayerDataSource.hls(
          playbackId: 'abc',
          customDomain: 'STREAM.FASTPIX.CO',
        ).imagesHost,
        altImagesOrigin,
      );
    });

    // The reason the rule is a guarded swap rather than a blind one: an apex
    // domain has no `stream` label to replace, and swapping its first label
    // would send the seek path — carrying the playback token — to a domain
    // someone else owns.
    test('a domain with no stream label derives nothing, never images.com', () {
      for (final domain in <String>[
        'xyz.com',
        'cdn.acme.io',
        'streaming.fastpix.com',
        'localhost',
      ]) {
        expect(
          FastPixPlayerDataSource.hls(
            playbackId: 'abc',
            customDomain: domain,
          ).imagesHost,
          isNull,
          reason: domain,
        );
      }
    });

    test('is carried through copyWith, which replaces the stream domain', () {
      final source = FastPixPlayerDataSource.hls(
        playbackId: 'abc',
        customDomain: altStreamHost,
      );
      expect(source.imagesHost, altImagesOrigin);
      expect(source.copyWith(title: 't').imagesHost, altImagesOrigin);
      expect(
        source.copyWith(customDomain: 'stream.fastpix.io').imagesHost,
        'https://images.fastpix.io',
      );
    });
  });
}

void parseTests() {
  group('FastPixSpritesheet.parse', () {
    test('normal: 100 unevenly-rounded tiles from a 79-minute video', () {
      const step = 47.58503723144531;
      final sheet = parse(
        spritesheetJson(count: 100, step: step, duration: 4758.504),
      );
      expect(sheet.type, FastPixSpritesheetType.normal);
      expect(sheet.interval, isNull);
      expect(sheet.tiles, hasLength(100));
      expect(sheet.tileWidth, 256);
      expect(sheet.tileHeight, 160);
      expect(sheet.imageUrl, imageUrl);
      expect(sheet.tiles[1].region, const Rect.fromLTWH(256, 0, 256, 160));
      expect(sheet.tiles[5].region, const Rect.fromLTWH(0, 160, 256, 160));
      expect(sheet.tiles[0].end, sheet.tiles[1].start);
      expect(sheet.tiles.last.end, const Duration(microseconds: 4758504000));
    });

    test('advanced interval 2: 2379 tiles with a partial final row', () {
      final sheet = parse(
        spritesheetJson(
          count: 2379,
          columns: 24,
          interval: 2,
          duration: 4758.504,
        ),
        type: FastPixSpritesheetType.advanced,
      );
      expect(sheet.interval, 2);
      expect(sheet.tiles, hasLength(2379));
      // 24 x 100 grid, 21 empty cells at the end of row 100.
      expect(
        sheet.tiles.last.region,
        const Rect.fromLTWH(512, 15840, 256, 160),
      );
      expect(sheet.tiles.last.start, const Duration(seconds: 4756));
    });

    test('ignores the metadata url', () {
      final sheet = parse(spritesheetJson(count: 2));
      expect(sheet.imageUrl, imageUrl);
    });

    test('rejects unusable metadata with a FormatException', () {
      Map<String, Object?> valid() =>
          jsonDecode(spritesheetJson(count: 2)) as Map<String, Object?>;

      expect(() => parse('not json'), throwsFormatException);
      expect(() => parse('[]'), throwsFormatException);
      expect(
        () => parse(jsonEncode(valid()..remove('tiles'))),
        throwsFormatException,
      );
      expect(
        () => parse(jsonEncode(valid()..['tiles'] = <Object>[])),
        throwsFormatException,
      );
      expect(
        () => parse(jsonEncode(valid()..['tile_width'] = 0)),
        throwsFormatException,
      );
      expect(
        () => parse(jsonEncode(valid()..['tile_height'] = -1)),
        throwsFormatException,
      );
      expect(
        () => parse(jsonEncode(valid()..['duration'] = 0)),
        throwsFormatException,
      );
      expect(
        () => parse(jsonEncode(valid()..['tiles'] = <Object>['x'])),
        throwsFormatException,
      );
    });
  });
}

void tileAtTests() {
  group('FastPixSpritesheet.tileAt', () {
    final sheet = parse(spritesheetJson(count: 3, step: 10, duration: 30));

    test('inside a tile', () {
      expect(sheet.tileAt(const Duration(seconds: 15))!.index, 1);
    });

    test('exactly on a boundary belongs to the later tile', () {
      expect(sheet.tileAt(const Duration(seconds: 20))!.index, 2);
      expect(sheet.tileAt(Duration.zero)!.index, 0);
    });

    test('negative resolves to the first tile, beyond the end to the last', () {
      expect(sheet.tileAt(const Duration(seconds: -5))!.index, 0);
      expect(sheet.tileAt(const Duration(hours: 2))!.index, 2);
    });

    test('long advanced sheet: never drifts onto the previous tile', () {
      // The server returns 475 tiles for 4758.504 s at interval 10, one fewer
      // than duration / interval. Dividing by duration / count picks tile 399
      // for 4000 s; the tile starting at 4000 s is 400.
      final advanced = parse(
        spritesheetJson(count: 475, interval: 10, duration: 4758.504),
        type: FastPixSpritesheetType.advanced,
      );
      final tile = advanced.tileAt(const Duration(seconds: 4000))!;
      expect(tile.index, 400);
      expect(tile.start, const Duration(seconds: 4000));
      for (var second = 0; second < 4758; second += 7) {
        expect(
          advanced.tileAt(Duration(seconds: second))!.index,
          // The last tile, starting at 4740 s, runs to the end.
          (second ~/ 10).clamp(0, 474),
          reason: 'at $second s',
        );
      }
    });
  });
}

void fakeRoutedHttpTests() {
  group('FakeRoutedHttpOverrides', () {
    test(
      'answers by route, falls back to a playlist, records requests',
      () async {
        final fake = FakeRoutedHttpOverrides(
          (uri) => isMetadataRequest(uri) ? FakeReply.text(404, 'nope') : null,
        );
        await HttpOverrides.runWithHttpOverrides(() async {
          final client = HttpClient();
          final missing =
              await (await client.getUrl(
                Uri.parse('https://a.test/x.json'),
              )).close();
          expect(missing.statusCode, 404);
          final playlist =
              await (await client.getUrl(
                Uri.parse('https://a.test/x.m3u8'),
              )).close();
          expect(playlist.statusCode, 200);
          expect(
            await playlist.transform(const SystemEncoding().decoder).join(),
            startsWith('#EXTM3U'),
          );
        }, fake);
        expect(fake.requested.map((u) => u.path), <String>[
          '/x.json',
          '/x.m3u8',
        ]);
        expect(fake.requestsFor(metadataExtension), hasLength(1));
      },
    );
  });
}
