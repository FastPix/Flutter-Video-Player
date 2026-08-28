import 'package:better_player_plus/better_player_plus.dart';
// The configuration helpers now come through the package's public barrel, so
// the direct src/ import they used to need is redundant.
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A colour the assertions can recognise on sight, in the hex form the public
/// API takes.
const String redHex = '#FF0000';

/// Locks the configuration builder that both playback and preloading use.
///
/// [FastPixPlayerController] delegates to it, and the preload manager will
/// build its warmed controllers from it. Because
/// [BetterPlayerController.betterPlayerConfiguration] is a final field, a
/// warmed player keeps whatever this produced for its entire life — so a field
/// silently dropped here renders permanently wrong on every adopted playback,
/// with no error anywhere.
void main() {
  FastPixPlayerDataSource source({
    bool loop = false,
    Duration? startAt,
    FastPixPlayerVideoQuality? maxResolution,
  }) => FastPixPlayerDataSource(
    playbackId: 'abc123',
    format: FastPixStreamingFormat.hls,
    loop: loop,
    startAt: startAt,
    maxResolution: maxResolution,
  );

  FastPixPlayerConfiguration config([
    FastPixPlayerControlsConfiguration? controls,
  ]) => FastPixPlayerConfiguration(
    'ws',
    'viewer',
    'https://beacon.example',
    controlsConfiguration:
        controls ?? const FastPixPlayerControlsConfiguration(),
  );

  group('the settings a warmed player can never change', () {
    // These five are hardcoded, not configurable. If a refactor ever routes
    // them through the public config, a warmed player built before that change
    // renders with the wrong aspect ratio or lets the screen sleep mid-video.
    test('fixed presentation settings survive every input shape', () {
      for (final built in <BetterPlayerConfiguration>[
        buildBetterPlayerConfiguration(),
        buildBetterPlayerConfiguration(configuration: config()),
        buildBetterPlayerConfiguration(dataSource: source()),
        buildBetterPlayerConfiguration(
          configuration: config(),
          dataSource: source(),
        ),
      ]) {
        expect(built.aspectRatio, 16 / 9);
        expect(built.fit, BoxFit.contain);
        expect(built.allowedScreenSleep, isFalse);
        expect(built.autoDetectFullscreenDeviceOrientation, isTrue);
        expect(built.autoDetectFullscreenAspectRatio, isTrue);
      }
    });

    test('null configuration and null data source fall back, never throw', () {
      final built = buildBetterPlayerConfiguration();
      expect(built.autoPlay, isFalse);
      expect(built.looping, isFalse);
    });

    test('autoPlay comes from controls, looping from the data source', () {
      final built = buildBetterPlayerConfiguration(
        configuration: config(
          const FastPixPlayerControlsConfiguration(autoPlay: true),
        ),
        dataSource: source(loop: true),
      );
      expect(built.autoPlay, isTrue);
      expect(built.looping, isTrue);
    });
  });

  group('controls mapping', () {
    test('defaults reproduce what the player already did', () {
      final controls = buildControlsConfiguration(
        const FastPixPlayerControlsConfiguration(),
      );

      expect(controls.controlBarColor, Colors.transparent);
      expect(controls.textColor, Colors.white);
      expect(controls.iconsColor, Colors.white);
      expect(controls.loadingColor, kFastPixAccentColor);
      expect(controls.progressBarPlayedColor, kFastPixAccentColor);
      expect(controls.progressBarHandleColor, kFastPixAccentColor);
      expect(controls.progressBarBufferedColor, Colors.white38);
      expect(controls.progressBarBackgroundColor, Colors.white24);

      expect(controls.showControls, isTrue);
      expect(controls.showControlsOnInitialize, isTrue);
      expect(controls.enablePlayPause, isTrue);
      expect(controls.enableProgressBar, isTrue);
      expect(controls.enableProgressBarDrag, isTrue);
      expect(controls.enableProgressText, isTrue);
      expect(controls.enableFullscreen, isTrue);
      expect(controls.enableMute, isTrue);
      expect(controls.enableSubtitles, isTrue);
      expect(controls.enableQualities, isTrue);
      expect(controls.enableRetry, isFalse);
      expect(controls.enableSkips, isFalse);

      expect(controls.overflowModalColor, const Color(0xFF1C1C1E));
      expect(controls.overflowModalTextColor, Colors.white);
      expect(controls.overflowMenuIconsColor, Colors.white);
    });

    test('a null controls config is identical to a default one', () {
      final fromNull = buildControlsConfiguration(null);
      final fromDefault = buildControlsConfiguration(
        const FastPixPlayerControlsConfiguration(),
      );
      expect(fromNull.showControls, fromDefault.showControls);
      expect(fromNull.textColor, fromDefault.textColor);
      expect(
        fromNull.progressBarPlayedColor,
        fromDefault.progressBarPlayedColor,
      );
      expect(fromNull.enableRetry, fromDefault.enableRetry);
    });

    // A progress bar is what makes the seek bar. Treating them separately
    // would let one be shown without the other, which renders a drag handle
    // with no track under it.
    test('either of showProgressBar or showSeekBar off disables both', () {
      for (final controls in <FastPixPlayerControlsConfiguration>[
        const FastPixPlayerControlsConfiguration(showProgressBar: false),
        const FastPixPlayerControlsConfiguration(showSeekBar: false),
      ]) {
        final built = buildControlsConfiguration(controls);
        expect(built.enableProgressBar, isFalse);
        expect(built.enableProgressBarDrag, isFalse);
      }
    });

    test('controlsVisibility.never suppresses controls on initialize', () {
      expect(
        buildControlsConfiguration(
          const FastPixPlayerControlsConfiguration(
            controlsVisibility: FastPixControlsVisibility.never,
          ),
        ).showControlsOnInitialize,
        isFalse,
      );
      expect(
        buildControlsConfiguration(
          const FastPixPlayerControlsConfiguration(
            controlsVisibility: FastPixControlsVisibility.always,
          ),
        ).showControlsOnInitialize,
        isTrue,
      );
    });

    test('every visibility toggle reaches better_player', () {
      final built = buildControlsConfiguration(
        const FastPixPlayerControlsConfiguration(
          showControls: false,
          showPlayPauseButton: false,
          showTimeIndicator: false,
          showFullscreenButton: false,
          showVolumeSlider: false,
          showSubtitleSelector: false,
          showQualitySelector: false,
          enableRetry: true,
          enableSkips: true,
        ),
      );
      expect(built.showControls, isFalse);
      expect(built.enablePlayPause, isFalse);
      expect(built.enableProgressText, isFalse);
      expect(built.enableFullscreen, isFalse);
      expect(built.enableMute, isFalse);
      expect(built.enableSubtitles, isFalse);
      expect(built.enableQualities, isFalse);
      expect(built.enableRetry, isTrue);
      expect(built.enableSkips, isTrue);
    });

    test('custom colours override the palette', () {
      final built = buildControlsConfiguration(
        const FastPixPlayerControlsConfiguration(
          controlsBackgroundColor: Color(0xFF102030),
          controlsForegroundColor: '#00FF00',
          progressBarPlayedColor: redHex,
          progressBarBufferedColor: '#0000FF',
          progressBarColor: '#808080',
        ),
      );
      expect(built.controlBarColor, const Color(0xFF102030));
      expect(built.textColor, const Color(0xFF00FF00));
      expect(built.iconsColor, const Color(0xFF00FF00));
      expect(built.progressBarPlayedColor, const Color(0xFFFF0000));
      expect(built.progressBarHandleColor, const Color(0xFFFF0000));
      expect(built.progressBarBufferedColor, const Color(0xFF0000FF));
      expect(built.progressBarBackgroundColor, const Color(0xFF808080));
    });
  });

  group('colour parsing', () {
    test('accepts #RRGGBB and #AARRGGBB, with or without the hash', () {
      expect(parseFastPixColor(redHex), const Color(0xFFFF0000));
      expect(parseFastPixColor('FF0000'), const Color(0xFFFF0000));
      expect(parseFastPixColor('#80FF0000'), const Color(0x80FF0000));
    });

    // The colour fields are strings on the public API, so an unparseable value
    // has to fall back to the default rather than throw mid-build.
    test('rejects anything else without throwing', () {
      for (final bad in <String?>[null, '', 'red', '#FFF', '#GGGGGG', '#1234567']) {
        expect(parseFastPixColor(bad), isNull, reason: 'input: $bad');
      }
    });
  });

  group('adoption fingerprint', () {
    // A warmed player may only be adopted when the fingerprint matches,
    // because the configuration is final on the controller. Two calls with
    // equal inputs must agree, or every adoption is refused and the whole
    // feature silently does nothing.
    test('equal inputs produce equal fingerprints across rebuilds', () {
      expect(
        betterPlayerConfigurationFingerprint(
          configuration: config(),
          dataSource: source(),
        ),
        betterPlayerConfigurationFingerprint(
          configuration: config(),
          dataSource: source(),
        ),
      );
    });

    test('null inputs are stable and do not throw', () {
      expect(
        betterPlayerConfigurationFingerprint(),
        betterPlayerConfigurationFingerprint(),
      );
    });

    // Each of these changes what the warmed player renders or where it starts,
    // and none of them can be corrected after construction.
    test('every adoption-relevant field changes the fingerprint', () {
      final base = betterPlayerConfigurationFingerprint(
        configuration: config(),
        dataSource: source(),
      );

      final variants = <String, String>{
        'autoPlay': betterPlayerConfigurationFingerprint(
          configuration: config(
            const FastPixPlayerControlsConfiguration(autoPlay: true),
          ),
          dataSource: source(),
        ),
        'showControls': betterPlayerConfigurationFingerprint(
          configuration: config(
            const FastPixPlayerControlsConfiguration(showControls: false),
          ),
          dataSource: source(),
        ),
        'controlsVisibility': betterPlayerConfigurationFingerprint(
          configuration: config(
            const FastPixPlayerControlsConfiguration(
              controlsVisibility: FastPixControlsVisibility.never,
            ),
          ),
          dataSource: source(),
        ),
        'controlsBackgroundColor': betterPlayerConfigurationFingerprint(
          configuration: config(
            const FastPixPlayerControlsConfiguration(
              controlsBackgroundColor: Color(0xFF102030),
            ),
          ),
          dataSource: source(),
        ),
        'progressBarPlayedColor': betterPlayerConfigurationFingerprint(
          configuration: config(
            const FastPixPlayerControlsConfiguration(
              progressBarPlayedColor: redHex,
            ),
          ),
          dataSource: source(),
        ),
        'enableRetry': betterPlayerConfigurationFingerprint(
          configuration: config(
            const FastPixPlayerControlsConfiguration(enableRetry: true),
          ),
          dataSource: source(),
        ),
        'enableSkips': betterPlayerConfigurationFingerprint(
          configuration: config(
            const FastPixPlayerControlsConfiguration(enableSkips: true),
          ),
          dataSource: source(),
        ),
        'loop': betterPlayerConfigurationFingerprint(
          configuration: config(),
          dataSource: source(loop: true),
        ),
        // A warmed player is already positioned; adopting one warmed at 0 for
        // a playback asking for 30s starts in the wrong place.
        'startAt': betterPlayerConfigurationFingerprint(
          configuration: config(),
          dataSource: source(startAt: const Duration(seconds: 30)),
        ),
        // On this SDK the resolution caps are URL query parameters, so a warm
        // at one cap is holding a genuinely different manifest.
        'maxResolution': betterPlayerConfigurationFingerprint(
          configuration: config(),
          dataSource: source(
            maxResolution: FastPixPlayerVideoQuality.p720,
          ),
        ),
      };

      variants.forEach((field, fingerprint) {
        expect(
          fingerprint,
          isNot(base),
          reason:
              '$field must change the fingerprint, or a player warmed with a '
              'different $field is adopted and renders wrong forever',
        );
      });
    });

    // Metrics identity is applied after adoption and does not affect what the
    // player renders. Including it would refuse adoptions for no reason.
    test('metrics identity does not affect the fingerprint', () {
      expect(
        betterPlayerConfigurationFingerprint(
          configuration: FastPixPlayerConfiguration('ws-a', 'viewer-a', 'url-a'),
          dataSource: source(),
        ),
        betterPlayerConfigurationFingerprint(
          configuration: FastPixPlayerConfiguration('ws-b', 'viewer-b', 'url-b'),
          dataSource: source(),
        ),
      );
    });
  });
}
