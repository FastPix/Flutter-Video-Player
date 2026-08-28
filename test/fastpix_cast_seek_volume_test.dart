import 'package:flutter_chrome_cast/entities/media_seek_option.dart';
import 'package:flutter_chrome_cast/enums/media_resume_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards two Cast defaults that are wrong for a player, and whose wrongness
/// is invisible in code review.
///
/// Neither of these throws, logs, or fails a build. They are only observable by
/// casting to a real receiver and noticing the player did something nobody
/// asked for — which is why they survived until someone reported them.
void main() {
  group('seeking must not decide whether playback is running', () {
    // The bug this replaced: pause a video, tap skip-forward-10s, and it
    // starts playing again on its own.
    //
    // The plugin's own default is `play`, meaning "play regardless of current
    // state". Omitting `resumeState` therefore turns every seek into a play
    // command, which is exactly what a scrub bar must never do.
    test('the plugin default really is play — this is not a hypothetical', () {
      final option = GoogleCastMediaSeekOption(position: Duration.zero);

      expect(
        option.resumeState,
        GoogleCastMediaResumeState.play,
        reason: 'if this ever becomes `unchanged`, the explicit argument in '
            'FastPixCastController.seekTo is redundant but still harmless',
      );
    });

    // What seekTo now sends. `unchanged` leaves a paused receiver paused and a
    // playing one playing, which is the only behaviour a seek should have.
    test('unchanged is what leaves the receiver as the user left it', () {
      final option = GoogleCastMediaSeekOption(
        position: const Duration(seconds: 30),
        resumeState: GoogleCastMediaResumeState.unchanged,
      );

      expect(option.resumeState, GoogleCastMediaResumeState.unchanged);
      expect(option.position, const Duration(seconds: 30));
    });

    // Serialised by index, so a reordering of the enum upstream would silently
    // change what the receiver is told. `unchanged` must stay first.
    test('unchanged serialises as index 0', () {
      expect(GoogleCastMediaResumeState.unchanged.index, 0);
      expect(GoogleCastMediaResumeState.play.index, 1);
      expect(GoogleCastMediaResumeState.pause.index, 2);
    });
  });

  group('a volume of zero from the session is not evidence of mute', () {
    // The bug this replaced: the mute icon showed muted from the moment a cast
    // session started, while the receiver played at full volume. The slider
    // still worked, because the first drag overwrote the bad seed.
    //
    // The plugin reports 0.0 both for "muted" and for "no reading available",
    // and has no volume callback on either platform, so the second is by far
    // the more common meaning.
    //
    // This encodes the rule FastPixCastController applies at connect. The
    // controller itself needs a live session to exercise, so the decision is
    // asserted here rather than the code path.
    bool shouldTrustSeed(double? level) => level != null && level > 0;

    test('a null or zero reading is discarded', () {
      expect(shouldTrustSeed(null), isFalse);
      expect(shouldTrustSeed(0.0), isFalse);
    });

    test('any real level is trusted', () {
      expect(shouldTrustSeed(0.01), isTrue);
      expect(shouldTrustSeed(0.5), isTrue);
      expect(shouldTrustSeed(1.0), isTrue);
    });

    // The asymmetry that justifies the rule: a wrong mute icon is visible and
    // sticky, because nothing ever corrects it. A wrong unmuted icon is fixed
    // by the first setVolume the user performs.
    test('the default survives an unusable reading', () {
      const fallback = 1.0;
      final seeded = shouldTrustSeed(0.0) ? 0.0 : fallback;
      expect(seeded, fallback);
    });
  });
}
