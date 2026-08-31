import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// Locks the play-start buffering settings.
///
/// Two failure modes are covered, and both are silent — the player keeps
/// working, just slower or with a preload that never gets adopted, and nothing
/// logs a complaint:
///
/// * the values stop reaching the engine, so playback quietly reverts to
///   waiting 3 s for a first frame;
/// * they reach the engine but are left out of the preload fingerprint, so a
///   warmed player built with different buffering is adopted anyway and
///   changes buffering behaviour for the rest of the session.
void main() {
  FastPixPlayerDataSource source({
    BetterPlayerBufferingConfiguration? buffering,
  }) => FastPixPlayerDataSource(
    playbackId: 'abc123',
    format: FastPixStreamingFormat.hls,
    bufferingConfiguration: buffering ?? fastPixPlayStartBuffering,
  );

  group('the values themselves', () {
    test('starts on far less media than the engine would wait for', () {
      // The whole point: this is the floor on time-to-first-frame once the
      // manifest and licence have been warmed away.
      expect(fastPixPlayStartBuffering.bufferForPlaybackMs, 500);
      expect(
        fastPixPlayStartBuffering.bufferForPlaybackMs,
        lessThan(BetterPlayerBufferingConfiguration.defaultBufferForPlaybackMs),
      );
    });

    test('resumes after a rebuffer more conservatively than it starts', () {
      // A rebuffer means the network already failed to keep up. Resuming on
      // the same 500 ms stalls again within seconds, and repeated stutter is
      // worse for a viewer than one longer pause.
      expect(
        fastPixPlayStartBuffering.bufferForPlaybackAfterRebufferMs,
        greaterThan(fastPixPlayStartBuffering.bufferForPlaybackMs),
      );
    });

    test('holds a bounded cushion rather than buffering indefinitely ahead', () {
      expect(fastPixPlayStartBuffering.minBufferMs, 15000);
      expect(fastPixPlayStartBuffering.maxBufferMs, 50000);
      expect(
        fastPixPlayStartBuffering.minBufferMs,
        lessThan(fastPixPlayStartBuffering.maxBufferMs),
      );
      // The engine's ceiling is ~6553 s, which on mobile spends the viewer's
      // data on media they may never reach.
      expect(
        fastPixPlayStartBuffering.maxBufferMs,
        lessThan(BetterPlayerBufferingConfiguration.defaultMaxBufferMs),
      );
    });
  });

  group('reaching the engine', () {
    test('is NOT applied unless the caller asks for it', () {
      // The tuning is opt-in. Preloading and precaching must not quietly
      // change how existing playback starts — a source that says nothing
      // about buffering has to behave exactly as it did before this existed.
      final built = const FastPixPlayerDataSource(
        playbackId: 'abc123',
        format: FastPixStreamingFormat.hls,
      ).toBetterPlayerDataSource();

      expect(
        built.bufferingConfiguration.bufferForPlaybackMs,
        BetterPlayerBufferingConfiguration.defaultBufferForPlaybackMs,
      );
      expect(
        built.bufferingConfiguration.minBufferMs,
        BetterPlayerBufferingConfiguration.defaultMinBufferMs,
      );
      expect(
        built.bufferingConfiguration.maxBufferMs,
        BetterPlayerBufferingConfiguration.defaultMaxBufferMs,
      );
    });

    test('is applied when the caller opts in', () {
      final built = source().toBetterPlayerDataSource();
      expect(built.bufferingConfiguration.bufferForPlaybackMs, 500);
      expect(built.bufferingConfiguration.minBufferMs, 15000);
      expect(built.bufferingConfiguration.maxBufferMs, 50000);
      expect(built.bufferingConfiguration.bufferForPlaybackAfterRebufferMs,
          2000);
    });

    test('a host that measured differently can override it', () {
      final built = source(
        buffering: const BetterPlayerBufferingConfiguration(
          bufferForPlaybackMs: 2500,
        ),
      ).toBetterPlayerDataSource();
      expect(built.bufferingConfiguration.bufferForPlaybackMs, 2500);
    });

    test('survives copyWith', () {
      // A dropped field here would revert the copy to the engine defaults and
      // — because buffering is fingerprinted — also stop every adoption.
      final copied = source(
        buffering: const BetterPlayerBufferingConfiguration(
          bufferForPlaybackMs: 750,
        ),
      ).copyWith(title: 'renamed');
      expect(
        copied.toBetterPlayerDataSource().bufferingConfiguration
            .bufferForPlaybackMs,
        750,
      );
    });

    test('the hls factory also leaves playback alone by default', () {
      final built = FastPixPlayerDataSource.hls(
        playbackId: 'abc123',
      ).toBetterPlayerDataSource();
      expect(
        built.bufferingConfiguration.bufferForPlaybackMs,
        BetterPlayerBufferingConfiguration.defaultBufferForPlaybackMs,
      );
    });

    test('the hls factory passes an opt-in through', () {
      final built = FastPixPlayerDataSource.hls(
        playbackId: 'abc123',
        bufferingConfiguration: fastPixPlayStartBuffering,
      ).toBetterPlayerDataSource();
      expect(built.bufferingConfiguration.bufferForPlaybackMs, 500);
    });
  });

  group('gating adoption', () {
    test('differing buffering produces a differing fingerprint', () {
      // A warmed player's load control is final. Adopting one built for
      // different buffering has to be refused, and the fingerprint is the only
      // thing that can refuse it.
      final warm = betterPlayerConfigurationFingerprint(dataSource: source());
      final playback = betterPlayerConfigurationFingerprint(
        dataSource: source(
          buffering: const BetterPlayerBufferingConfiguration(
            bufferForPlaybackMs: 3000,
          ),
        ),
      );
      expect(warm, isNot(playback));
    });

    test('matching buffering still matches', () {
      expect(
        betterPlayerConfigurationFingerprint(dataSource: source()),
        betterPlayerConfigurationFingerprint(dataSource: source()),
      );
    });
  });
}
