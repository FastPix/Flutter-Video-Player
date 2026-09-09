import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit coverage for the Custom UI mechanism's pure logic — the parts testable
/// without a live platform player: the FastPix-owned model mappings, the scrub
/// controller's seek-once-on-release contract, and playback-rate clamping.
void main() {
  group('FastPixPlaybackState', () {
    test('initial is all-zero, not playing, normal rate', () {
      const s = FastPixPlaybackState.initial;
      expect(s.position, Duration.zero);
      expect(s.duration, Duration.zero);
      expect(s.bufferedPosition, Duration.zero);
      expect(s.isPlaying, false);
      expect(s.isBuffering, false);
      expect(s.playbackRate, 1.0);
    });

    test('value equality and copyWith', () {
      const a = FastPixPlaybackState(
        position: Duration(seconds: 5),
        duration: Duration(seconds: 60),
        isPlaying: true,
      );
      final b = const FastPixPlaybackState(
        duration: Duration(seconds: 60),
      ).copyWith(position: const Duration(seconds: 5), isPlaying: true);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });

  group('FastPixQualityLevel.fromAsmsTrack', () {
    test('the engine default/empty track maps to automatic', () {
      final level =
          FastPixQualityLevel.fromAsmsTrack(BetterPlayerAsmsTrack.defaultTrack());
      expect(level.isAuto, true);
      expect(level, FastPixQualityLevel.automatic);
    });

    test('a real rendition gets a resolution label and its fields', () {
      const track = BetterPlayerAsmsTrack(
        'track-1',
        1920,
        1080,
        5000000,
        30,
        'avc1',
        'video/mp4',
      );
      final level = FastPixQualityLevel.fromAsmsTrack(track);
      expect(level.isAuto, false);
      expect(level.label, '1080p');
      expect(level.width, 1920);
      expect(level.height, 1080);
      expect(level.bitrate, 5000000);
      expect(level.id, 'track-1');
    });
  });

  group('FastPixAudioTrack.fromAsmsAudioTrack', () {
    test('carries label and language, id falls back to index', () {
      final track = BetterPlayerAsmsAudioTrack(
        label: 'English',
        language: 'en',
      );
      final model = FastPixAudioTrack.fromAsmsAudioTrack(track, 2);
      expect(model.label, 'English');
      expect(model.language, 'en');
      expect(model.id, '2'); // no engine id -> index
    });
  });

  group('FastPixSubtitleTrack.fromSource', () {
    test('external file is not embedded; name becomes id and label', () {
      final source = BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.network,
        name: 'English',
        urls: const ['https://example.com/en.vtt'],
      );
      final model = FastPixSubtitleTrack.fromSource(source, 0);
      expect(model.isEmbedded, false);
      expect(model.id, 'English');
      expect(model.label, 'English');
    });

    test('in-manifest (segmented) source is flagged embedded', () {
      final source = BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.network,
        name: 'Auto',
        asmsIsSegmented: true,
      );
      final model = FastPixSubtitleTrack.fromSource(source, 1);
      expect(model.isEmbedded, true);
    });
  });

  group('FastPixScrubController', () {
    test('updateScrub never seeks; endScrub seeks exactly once', () async {
      final seeks = <Duration>[];
      final events = FastPixPlayerEventManager();
      final scrub =
          FastPixScrubController((pos) async => seeks.add(pos), events);

      scrub.beginScrub(const Duration(seconds: 3));
      expect(scrub.isScrubbing, true);
      scrub.updateScrub(const Duration(seconds: 10));
      scrub.updateScrub(const Duration(seconds: 20));
      expect(seeks, isEmpty); // dragging must not seek
      expect(scrub.scrubPosition, const Duration(seconds: 20));

      await scrub.endScrub(const Duration(seconds: 25));
      expect(scrub.isScrubbing, false);
      expect(seeks, [const Duration(seconds: 25)]); // one seek, on release
    });

    test('emits scrub started and ended events', () async {
      final types = <String>[];
      final events = FastPixPlayerEventManager()
        ..addGlobalListener((e) => types.add(e.type));
      final scrub = FastPixScrubController((_) async {}, events);

      scrub.beginScrub(Duration.zero);
      await scrub.endScrub(const Duration(seconds: 5));

      expect(types, contains(FastPixPlayerEventTypes.scrubStarted));
      expect(types, contains(FastPixPlayerEventTypes.scrubEnded));
    });

    test('a negative release position is clamped to zero', () async {
      final seeks = <Duration>[];
      final scrub = FastPixScrubController(
        (pos) async => seeks.add(pos),
        FastPixPlayerEventManager(),
      );
      await scrub.endScrub(const Duration(seconds: -5));
      expect(seeks.single, Duration.zero);
    });
  });

  group('FastPixPlaybackRateManager', () {
    test('supported rates are within the engine range', () {
      for (final r in FastPixPlaybackRateManager.supportedRates) {
        expect(r, greaterThan(0));
        expect(r, lessThanOrEqualTo(2.0));
      }
    });

    test('clamps out-of-range requests rather than throwing', () async {
      final events = FastPixPlayerEventManager();
      // Null engine accessor: no live player, but clamping/reporting still work.
      final manager = FastPixPlaybackRateManager(() => null, events);

      expect(await manager.setRate(5.0), 2.0); // above ceiling -> clamp
      expect(manager.rate, 2.0);
      expect(await manager.setRate(0.0), 0.25); // zero rejected -> floor
      expect(manager.rate, 0.25);
      expect(await manager.setRate(1.5), 1.5); // in range -> unchanged
      expect(manager.rate, 1.5);
    });

    test('emits a rate-changed event when the rate changes', () async {
      final rates = <double>[];
      final events = FastPixPlayerEventManager()
        ..addEventListener(
          FastPixPlayerEventTypes.playbackRateChanged,
          (e) => rates.add((e as FastPixPlaybackRateChangedEvent).rate),
        );
      final manager = FastPixPlaybackRateManager(() => null, events);
      await manager.setRate(1.5);
      expect(rates, [1.5]);
    });
  });

  group('track managers tolerate no live engine', () {
    test('quality: empty list, auto by default, no throw on switch', () async {
      final q = FastPixQualityManager(() => null, FastPixPlayerEventManager());
      expect(q.getLevels(), isEmpty);
      expect(q.isAuto, true);
      expect(q.hasTracks, false);
      await q.setAuto(); // must not throw
    });

    test('audio: empty list, null current, no throw on switch', () async {
      final a =
          FastPixAudioTrackManager(() => null, FastPixPlayerEventManager());
      expect(a.getTracks(), isEmpty);
      expect(a.current, isNull);
      await a.setTrack(const FastPixAudioTrack(id: '0')); // must not throw
    });

    test('subtitle: empty list, null current, disable is a no-op', () async {
      final s =
          FastPixSubtitleTrackManager(() => null, FastPixPlayerEventManager());
      expect(s.getTracks(), isEmpty);
      expect(s.current, isNull);
      await s.disable(); // must not throw
    });
  });

  group('FastPixPipManager', () {
    test('unavailable and inert with no live engine', () async {
      final events = FastPixPlayerEventManager();
      // No prepared source: the readiness predicate is what tells "you asked
      // too early" apart from "this device cannot do PiP".
      final pip = FastPixPipManager(events, hasPreparedSource: () => false);

      expect(await pip.isPipAvailable(), false);
      expect(pip.isPipActive, false);
      await pip.enterPip(); // must not throw
      await pip.togglePip(); // must not throw
      pip.setPipAudioBehavior(mixWithOthers: true); // must not throw
      expect(pip.isPipActive, false);
    });

    test('disabled switch makes it unavailable', () async {
      final pip = FastPixPipManager(FastPixPlayerEventManager())
        ..enabled = false;
      expect(await pip.isPipAvailable(), false);
    });

    test('notifyActive flips state and emits a pip-changed event', () {
      final states = <bool>[];
      final events = FastPixPlayerEventManager()
        ..addEventListener(
          FastPixPlayerEventTypes.pipChanged,
          (e) => states.add((e as FastPixPipChangedEvent).isActive),
        );
      final pip = FastPixPipManager(events);

      pip.notifyActive(true);
      expect(pip.isPipActive, true);
      pip.notifyActive(true); // deduped — no second event
      pip.notifyActive(false);
      expect(pip.isPipActive, false);

      expect(states, [true, false]);
    });

    test('entering with no engine surfaces a playerNotReady error', () async {
      final codes = <String?>[];
      final events = FastPixPlayerEventManager()
        ..addEventListener(
          FastPixPlayerEventTypes.error,
          (e) => codes.add((e as FastPixPlayerErrorEvent).code),
        );
      final pip = FastPixPipManager(events, hasPreparedSource: () => false);
      await pip.enterPip();
      expect(codes, [FastPixCustomUIErrorCode.playerNotReady.value]);
    });
  });

  group('FastPixCustomUIErrorCode', () {
    test('every code has a stable string value', () {
      expect(FastPixCustomUIErrorCode.castUnavailable.value, 'cast_unavailable');
      expect(FastPixCustomUIErrorCode.playerNotReady.value, 'player_not_ready');
      expect(
        FastPixCustomUIErrorCode.values.map((c) => c.value).toSet().length,
        FastPixCustomUIErrorCode.values.length,
      );
    });
  });
}
