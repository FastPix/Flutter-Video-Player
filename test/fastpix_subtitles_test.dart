import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reused so the same track URL is not repeated across cases.
const String enVttUrl = 'https://example.com/en.vtt';
const String esVttUrl = 'https://example.com/es.vtt';

void main() {
  _secureScreenTests();

  group('local subtitle plumbing', () {
    test('external tracks reach the underlying player', () {
      final source = FastPixPlayerDataSource.hls(
        playbackId: 'abc',
        subtitles: const <FastPixPlayerSubtitle>[
          FastPixPlayerSubtitle(
            url: enVttUrl,
            name: 'English',
            languageCode: 'en',
          ),
          FastPixPlayerSubtitle(
            url: esVttUrl,
            name: 'Spanish',
            languageCode: 'es',
          ),
        ],
      );

      final subtitles = source.toBetterPlayerDataSource().subtitles;
      expect(subtitles, hasLength(2));
      expect(subtitles!.first.name, 'English');
      expect(subtitles.first.urls, <String>[enVttUrl]);
    });

    test('a source with no external tracks declares none', () {
      final source = FastPixPlayerDataSource.hls(playbackId: 'abc');
      expect(source.toBetterPlayerDataSource().subtitles, isNull);
    });

    test('manifest captions are offered unless explicitly turned off', () {
      // FastPix carries captions in the manifest, so the default has to leave
      // them on or the subtitle menu is empty for every ordinary stream.
      final on = FastPixPlayerDataSource.hls(playbackId: 'abc');
      expect(on.toBetterPlayerDataSource().useAsmsSubtitles, isTrue);

      final off = FastPixPlayerDataSource.hls(
        playbackId: 'abc',
        useHlsSubtitles: false,
      );
      expect(off.toBetterPlayerDataSource().useAsmsSubtitles, isFalse);
    });

    test('no track is pre-selected unless showSubtitles asked for one', () {
      final source = FastPixPlayerDataSource.hls(
        playbackId: 'abc',
        subtitles: const <FastPixPlayerSubtitle>[
          FastPixPlayerSubtitle(
            url: enVttUrl,
            name: 'English',
            isDefault: true,
          ),
        ],
      );

      expect(
        source.toBetterPlayerDataSource().subtitles!.single.selectedByDefault,
        isFalse,
      );
    });

    test('showSubtitles selects the default track, not merely the first', () {
      final source = FastPixPlayerDataSource.hls(
        playbackId: 'abc',
        showSubtitles: true,
        subtitles: const <FastPixPlayerSubtitle>[
          FastPixPlayerSubtitle(url: enVttUrl, name: 'English'),
          FastPixPlayerSubtitle(
            url: esVttUrl,
            name: 'Spanish',
            isDefault: true,
          ),
        ],
      );

      final subtitles = source.toBetterPlayerDataSource().subtitles!;
      expect(subtitles[0].selectedByDefault, isFalse);
      expect(subtitles[1].selectedByDefault, isTrue);
    });

    test('showSubtitles falls back to the first track when none is default', () {
      final source = FastPixPlayerDataSource.hls(
        playbackId: 'abc',
        showSubtitles: true,
        subtitles: const <FastPixPlayerSubtitle>[
          FastPixPlayerSubtitle(url: enVttUrl, name: 'English'),
          FastPixPlayerSubtitle(url: esVttUrl, name: 'Spanish'),
        ],
      );

      final subtitles = source.toBetterPlayerDataSource().subtitles!;
      expect(subtitles[0].selectedByDefault, isTrue);
      expect(subtitles[1].selectedByDefault, isFalse);
    });
  });

  group('FastPixCastTextTrack', () {
    GoogleCastMediaTrack track({
      int id = 1,
      String? name,
      Rfc5646Language? language,
      TextTrackType? subtype,
    }) {
      return GoogleCastMediaTrack(
        trackId: id,
        type: TrackType.text,
        trackContentType: 'text/vtt',
        name: name,
        language: language,
        subtype: subtype,
      );
    }

    test('carries the receiver track ID, which is what selects it', () {
      final mapped = FastPixCastTextTrack.fromPlugin(track(id: 7));
      expect(mapped.id, 7);
    });

    test('labels a track by name', () {
      final mapped = FastPixCastTextTrack.fromPlugin(
        track(name: 'English (CC)', language: Rfc5646Language.english),
      );
      expect(mapped.label, 'English (CC)');
      expect(mapped.languageCode, 'en');
    });

    test('falls back to the language when the receiver reports no name', () {
      // Receivers commonly report manifest tracks with a language and no name.
      final mapped = FastPixCastTextTrack.fromPlugin(
        track(language: Rfc5646Language.spanish),
      );
      expect(mapped.label, 'es');
    });

    test('falls back to the track ID when neither is reported', () {
      final mapped = FastPixCastTextTrack.fromPlugin(track(id: 3));
      expect(mapped.label, 'Track 3');
      expect(mapped.languageCode, isNull);
    });

    test('distinguishes closed captions from plain subtitles', () {
      expect(
        FastPixCastTextTrack.fromPlugin(
          track(subtype: TextTrackType.captions),
        ).isClosedCaption,
        isTrue,
      );
      expect(
        FastPixCastTextTrack.fromPlugin(
          track(subtype: TextTrackType.subtitles),
        ).isClosedCaption,
        isFalse,
      );
    });

    test('identity is the track ID, so a relabelled track is the same track', () {
      expect(
        FastPixCastTextTrack.fromPlugin(track(id: 2, name: 'English')),
        FastPixCastTextTrack.fromPlugin(track(id: 2, name: 'Anglais')),
      );
    });
  });

  group('active track selection', () {
    // The real layout a FastPix stream reports: video 1, two audio tracks,
    // one subtitle track — with audio and subtitles active together.
    const List<int> activeIds = <int>[2, 4];
    const List<FastPixCastTextTrack> textTracks = <FastPixCastTextTrack>[
      FastPixCastTextTrack(id: 4, label: 'English', languageCode: 'en-IN'),
    ];

    int? activeTextTrackId(List<int> active, List<FastPixCastTextTrack> texts) {
      for (final int id in active) {
        for (final FastPixCastTextTrack track in texts) {
          if (track.id == id) return id;
        }
      }
      return null;
    }

    test('the subtitle track is found past the audio track ahead of it', () {
      // Taking the first ID would answer 2 — the audio track — and no subtitle
      // menu entry would match it, making every selection look ignored.
      expect(activeTextTrackId(activeIds, textTracks), 4);
    });

    test('audio-only active tracks mean subtitles are off', () {
      expect(activeTextTrackId(<int>[2], textTracks), isNull);
    });

    test('nothing active means subtitles are off', () {
      expect(activeTextTrackId(const <int>[], textTracks), isNull);
    });

    List<int> nextActiveIds(
      List<int> active,
      List<FastPixCastTextTrack> texts,
      FastPixCastTextTrack? selected,
    ) {
      final textIds = texts.map((t) => t.id).toSet();
      return <int>[
        ...active.where((id) => !textIds.contains(id)),
        if (selected != null) selected.id,
      ];
    }

    test('selecting a subtitle keeps the audio track active', () {
      // Cast replaces the whole active set, so sending [4] alone would switch
      // the audio track off.
      expect(
        nextActiveIds(activeIds, textTracks, textTracks.first),
        <int>[2, 4],
      );
    });

    test('turning subtitles off keeps the audio track active', () {
      expect(nextActiveIds(activeIds, textTracks, null), <int>[2]);
    });
  });
}

// ---------------------------------------------------------------------------

void _secureScreenTests() {
  group('DRM secure screen', () {
    test('is on by default, since DRM implies capture protection', () {
      const drm = FastPixPlayerDrmConfiguration(drmToken: 'token');
      expect(drm.secureScreen, isTrue);
    });

    test('can be turned off for hosts that need screenshots to keep working',
        () {
      const drm = FastPixPlayerDrmConfiguration(
        drmToken: 'token',
        secureScreen: false,
      );
      expect(drm.secureScreen, isFalse);
    });

    test('survives copyWith, and is overridable through it', () {
      const drm = FastPixPlayerDrmConfiguration(
        drmToken: 'token',
        secureScreen: false,
      );
      expect(drm.copyWith().secureScreen, isFalse);
      expect(drm.copyWith(secureScreen: true).secureScreen, isTrue);
    });

    test('the Widevine copy the cast path makes keeps the setting', () {
      // startCastingFrom rewrites the DRM type for the receiver; that must not
      // quietly re-enable a protection the caller switched off.
      const drm = FastPixPlayerDrmConfiguration(
        drmToken: 'token',
        secureScreen: false,
      );
      expect(
        drm.copyWith(drmType: FastPixDrmType.widevine).secureScreen,
        isFalse,
      );
    });
  });
}
