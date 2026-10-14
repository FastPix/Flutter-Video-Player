// Imports only the package entry point, deliberately: everything a host needs
// for prerendering must be reachable without importing anything under `src/`.
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tasks 2.1 - 2.6: the public prerender types.
void main() {
  group('enums', () {
    test('statuses have their wire strings', () {
      expect(FastPixPrerenderStatus.values.map((s) => s.value), [
        'idle',
        'preparing',
        'frameReady',
        'skipped',
        'failed',
        'released',
      ]);
    });

    test('error codes have their wire strings', () {
      expect(FastPixPrerenderErrorCode.values.map((c) => c.value), [
        'loadFailed',
        'timedOut',
        'seekFailed',
        'surfaceUnavailable',
        'disabled',
        'networkPolicy',
        'decoderBudget',
        'drm',
        'live',
        'pip',
        'externalPlayback',
        'background',
        'navigationPolicy',
        'noSurface',
        'featureDisabled',
      ]);
    });
  });

  group('FastPixPlayerPrerenderConfiguration', () {
    test('defaults: on, cellular allowed', () {
      const config = FastPixPlayerPrerenderConfiguration();
      expect(config.enablePrerender, isTrue);
      expect(config.prerenderOnCellular, isTrue);
    });

    test('copyWith replaces only what it is given', () {
      const base = FastPixPlayerPrerenderConfiguration();
      final copy = base.copyWith(enablePrerender: false);
      expect(copy.enablePrerender, isFalse);
      expect(copy.prerenderOnCellular, base.prerenderOnCellular);
    });
  });

  group('FastPixPlayerConfiguration.prerenderConfiguration', () {
    test('defaults, and survives copyWith of an unrelated field', () {
      final config = FastPixPlayerConfiguration('ws', 'viewer', 'beacon');
      expect(config.prerenderConfiguration.enablePrerender, isTrue);

      final off = config.copyWith(
        prerenderConfiguration: const FastPixPlayerPrerenderConfiguration(
          enablePrerender: false,
        ),
      );
      expect(off.prerenderConfiguration.enablePrerender, isFalse);
      expect(
        off.copyWith(enableNowPlaying: false).prerenderConfiguration
            .enablePrerender,
        isFalse,
      );
    });

    test('is not part of the engine fingerprint', () {
      final source = FastPixPlayerDataSource.hls(playbackId: 'abc');
      final on = FastPixPlayerConfiguration('ws', 'viewer', 'beacon');
      final off = on.copyWith(
        prerenderConfiguration: const FastPixPlayerPrerenderConfiguration(
          enablePrerender: false,
          prerenderOnCellular: false,
        ),
      );
      expect(
        betterPlayerConfigurationFingerprint(
          configuration: off,
          dataSource: source,
        ),
        betterPlayerConfigurationFingerprint(
          configuration: on,
          dataSource: source,
        ),
      );
    });
  });

  group('events', () {
    final now = DateTime(2026, 10, 6);

    final events = <FastPixPlayerEvent, String>{
      FastPixPrerenderRequestedEvent(
        timestamp: now,
        playbackId: 'next',
        playlistIndex: 2,
        automatic: true,
      ): FastPixPlayerEventTypes.prerenderRequested,
      FastPixPrerenderReadyEvent(
        timestamp: now,
        playbackId: 'next',
        playlistIndex: 2,
        timeToFirstFrame: const Duration(milliseconds: 400),
      ): FastPixPlayerEventTypes.prerenderReady,
      FastPixPrerenderFailedEvent(
        timestamp: now,
        playbackId: 'next',
        playlistIndex: 2,
        code: FastPixPrerenderErrorCode.timedOut,
        message: 'no frame',
      ): FastPixPlayerEventTypes.prerenderFailed,
    };

    test('each has its type and describes its own item', () {
      for (final entry in events.entries) {
        expect(entry.key.type, entry.value);
        expect(entry.key.data?['playbackId'], 'next');
        expect(entry.key.data?['playlistIndex'], 2);
      }
    });

    test('the active item attribution never overwrites the described item', () {
      final event = FastPixPrerenderFailedEvent(
        timestamp: now,
        playbackId: 'next',
        code: FastPixPrerenderErrorCode.timedOut,
        message: 'no frame',
      )..attachAttribution({'playbackId': 'active', 'playlistIndex': 0});
      expect(event.data?['playbackId'], 'next');
      expect(event.data?['playlistIndex'], isNull);
    });

    test('every type is registered', () {
      for (final type in events.values) {
        expect(FastPixPlayerEventTypes.all, contains(type));
        expect(FastPixPlayerEventTypes.prerender, contains(type));
      }
    });
  });
}
