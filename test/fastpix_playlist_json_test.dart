import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// The JSON contract, which is the surface a playlist producer writes against:
/// `playbackId` required, everything else optional, unknown keys ignored.
/// The title carried through the JSON cases.
const String episodeTitle = 'Episode 1';

void main() {
  group('FastPixSkipSegment', () {
    test('carries its range and type, and compares by value', () {
      const a = FastPixSkipSegment(
        start: Duration(seconds: 5),
        end: Duration(seconds: 35),
        type: FastPixSkipType.intro,
      );
      const b = FastPixSkipSegment(
        start: Duration(seconds: 5),
        end: Duration(seconds: 35),
        type: FastPixSkipType.intro,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.length, const Duration(seconds: 30));
    });

    test('differs when any of range or type differs', () {
      const base = FastPixSkipSegment(
        start: Duration(seconds: 5),
        end: Duration(seconds: 35),
        type: FastPixSkipType.intro,
      );
      expect(
        base,
        isNot(const FastPixSkipSegment(
          start: Duration(seconds: 5),
          end: Duration(seconds: 35),
          type: FastPixSkipType.credits,
        )),
      );
      expect(
        base,
        isNot(const FastPixSkipSegment(
          start: Duration(seconds: 6),
          end: Duration(seconds: 35),
          type: FastPixSkipType.intro,
        )),
      );
    });

    test('is active from its start up to, but not including, its end', () {
      const segment = FastPixSkipSegment(
        start: Duration(seconds: 10),
        end: Duration(seconds: 20),
        type: FastPixSkipType.recap,
      );
      expect(segment.contains(const Duration(seconds: 9)), isFalse);
      expect(segment.contains(const Duration(seconds: 10)), isTrue);
      expect(segment.contains(const Duration(seconds: 19)), isTrue);
      // Excluding the end is what stops a skip landing back inside it.
      expect(segment.contains(const Duration(seconds: 20)), isFalse);
    });
  });

  group('skipSegments on a source', () {
    test('survive copyWith and the hls factory', () {
      const segments = <FastPixSkipSegment>[
        FastPixSkipSegment(
          start: Duration.zero,
          end: Duration(seconds: 30),
          type: FastPixSkipType.intro,
        ),
      ];
      final source =
          FastPixPlayerDataSource.hls(playbackId: 'abc', skipSegments: segments);
      expect(source.skipSegments, segments);

      final renamed = source.copyWith(title: episodeTitle);
      expect(renamed.skipSegments, segments,
          reason: 'copyWith must carry them across');
      expect(renamed.title, episodeTitle);
    });

    test('are absent by default, and change nothing when absent', () {
      final source = FastPixPlayerDataSource.hls(playbackId: 'abc');
      expect(source.skipSegments, isNull);
      expect(source.url, 'https://stream.fastpix.com/abc.m3u8');
    });
  });

  group('FastPixPlayerDataSource.fromJson', () {
    test('a minimal entry needs only a playback ID', () {
      final source = FastPixPlayerDataSource.fromJson(
        <String, dynamic>{'playbackId': 'abc123'},
      );
      expect(source.playbackId, 'abc123');
      expect(source.format, FastPixStreamingFormat.hls);
      expect(source.title, isNull);
      expect(source.token, isNull);
      expect(source.drmConfiguration, isNull);
      expect(source.skipSegments, isNull);
      expect(source.streamType, StreamType.onDemand);
    });

    test('a fully populated entry maps every field', () {
      final source = FastPixPlayerDataSource.fromJson(<String, dynamic>{
        'playbackId': 'abc123',
        'title': episodeTitle,
        'description': 'The first one',
        'token': 'playback-token',
        'drmToken': 'drm-token',
        'customDomain': 'stream.example.com',
        'thumbnailUrl': 'https://example.com/thumb.jpg',
        'duration': 1425.5,
        'streamType': 'live',
        'skipSegments': <Map<String, dynamic>>[
          <String, dynamic>{'start': 0, 'end': 30, 'type': 'intro'},
          <String, dynamic>{'start': 1400, 'end': 1425, 'type': 'credits'},
        ],
      });

      expect(source.title, episodeTitle);
      expect(source.description, 'The first one');
      expect(source.token, 'playback-token');
      expect(source.drmConfiguration?.drmToken, 'drm-token');
      expect(source.drmEnabled, isTrue);
      expect(source.customDomain, 'stream.example.com');
      expect(source.thumbnailUrl, 'https://example.com/thumb.jpg');
      expect(source.duration, const Duration(milliseconds: 1425500));
      expect(source.streamType, StreamType.live);
      expect(source.skipSegments, hasLength(2));
      expect(source.skipSegments!.first.type, FastPixSkipType.intro);
      expect(source.skipSegments!.first.end, const Duration(seconds: 30));
      expect(source.skipSegments!.last.type, FastPixSkipType.credits);
    });

    test('unknown keys are ignored rather than rejected', () {
      final source = FastPixPlayerDataSource.fromJson(<String, dynamic>{
        'playbackId': 'abc123',
        'somethingTheSdkHasNeverHeardOf': <String, dynamic>{'nested': true},
        'anotherOne': 42,
      });
      expect(source.playbackId, 'abc123');
    });

    test('an entry produces the same source as constructing it directly', () {
      final parsed = FastPixPlayerDataSource.fromJson(
        <String, dynamic>{'playbackId': 'abc123', 'token': 'tok'},
      );
      final constructed =
          FastPixPlayerDataSource.hls(playbackId: 'abc123', token: 'tok');
      expect(parsed.url, constructed.url);
    });

    group('rejects', () {
      Matcher rejectedWith(FastPixPlaylistErrorCode code) => throwsA(
            isA<FastPixPlaylistException>()
                .having((e) => e.code, 'code', code),
          );

      test('a missing playback ID', () {
        expect(
          () => FastPixPlayerDataSource.fromJson(<String, dynamic>{}),
          rejectedWith(FastPixPlaylistErrorCode.missingPlaybackId),
        );
      });

      test('an empty playback ID', () {
        expect(
          () => FastPixPlayerDataSource.fromJson(
            <String, dynamic>{'playbackId': ''},
          ),
          rejectedWith(FastPixPlaylistErrorCode.missingPlaybackId),
        );
      });

      test('a playback ID that is not a string', () {
        expect(
          () => FastPixPlayerDataSource.fromJson(
            <String, dynamic>{'playbackId': 7},
          ),
          rejectedWith(FastPixPlaylistErrorCode.missingPlaybackId),
        );
      });

      test('a field of the wrong type', () {
        expect(
          () => FastPixPlayerDataSource.fromJson(
            <String, dynamic>{'playbackId': 'abc', 'title': 12},
          ),
          rejectedWith(FastPixPlaylistErrorCode.malformedEntry),
        );
        expect(
          () => FastPixPlayerDataSource.fromJson(
            <String, dynamic>{'playbackId': 'abc', 'duration': 'long'},
          ),
          rejectedWith(FastPixPlaylistErrorCode.malformedEntry),
        );
      });

      test('an unrecognised stream type', () {
        expect(
          () => FastPixPlayerDataSource.fromJson(
            <String, dynamic>{'playbackId': 'abc', 'streamType': 'broadcast'},
          ),
          rejectedWith(FastPixPlaylistErrorCode.malformedEntry),
        );
      });

      test('skip segments that are not an array', () {
        expect(
          () => FastPixPlayerDataSource.fromJson(
            <String, dynamic>{'playbackId': 'abc', 'skipSegments': 'intro'},
          ),
          rejectedWith(FastPixPlaylistErrorCode.malformedEntry),
        );
      });

      test('a skip segment with an unknown type', () {
        expect(
          () => FastPixPlayerDataSource.fromJson(<String, dynamic>{
            'playbackId': 'abc',
            'skipSegments': <Map<String, dynamic>>[
              <String, dynamic>{'start': 0, 'end': 30, 'type': 'advert'},
            ],
          }),
          rejectedWith(FastPixPlaylistErrorCode.malformedEntry),
        );
      });

      test('a skip segment missing a bound', () {
        expect(
          () => FastPixPlayerDataSource.fromJson(<String, dynamic>{
            'playbackId': 'abc',
            'skipSegments': <Map<String, dynamic>>[
              <String, dynamic>{'start': 0, 'type': 'intro'},
            ],
          }),
          rejectedWith(FastPixPlaylistErrorCode.malformedEntry),
        );
      });

      test('the offending position is named when one is supplied', () {
        expect(
          () => FastPixPlayerDataSource.fromJson(
            <String, dynamic>{},
            itemIndex: 3,
          ),
          throwsA(
            isA<FastPixPlaylistException>()
                .having((e) => e.itemIndex, 'itemIndex', 3),
          ),
        );
      });
    });
  });
}
