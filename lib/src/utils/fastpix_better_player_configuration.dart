import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';

import '../enums/fastpix_controls_visibility.dart';
import '../fastpix_player_configuration.dart';
import '../models/fastpix_player_controls_configuration.dart';
import '../models/fastpix_player_data_source.dart';

/// Accent used for the played portion of the seek bar.
///
/// The FastPix brand red, which also matches what viewers expect from a
/// video scrubber after YouTube.
const Color kFastPixAccentColor = Color(0xFFFF2D55);

/// Per-player wrapper applied to the fullscreen route, keyed by the player it
/// belongs to.
///
/// Fullscreen is a route better_player builds itself, containing nothing but
/// the player. Anything the host stacked *over* the player — the cast button —
/// lives in the page tree left behind and cannot follow, so it has to be put
/// back inside the route. That is what this holds.
///
/// A registry rather than a field on the controller because the route builder
/// below has to be a plain function: it is baked into
/// [BetterPlayerConfiguration], which is a **final field** on a player that may
/// have been built by the preload manager long before any widget existed to
/// supply an overlay. Looking the overlay up at fullscreen time — rather than
/// capturing it at build time — is what lets a warmed player still show the
/// cast button once it is adopted.
///
/// An [Expando] so entries disappear with the players they describe.
final Expando<Widget Function(Widget player)> fastPixFullscreenOverlays =
    Expando<Widget Function(Widget player)>('fastPixFullscreenOverlays');

/// The fullscreen route, reproducing better_player's own default except that
/// the player is first passed through whatever [fastPixFullscreenOverlays]
/// holds for it.
///
/// Falls back to the bare player when nothing is registered, which is the
/// normal case for a host that never asked for an overlay.
Widget fastPixFullscreenRoute(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  BetterPlayerControllerProvider controllerProvider,
) {
  final wrap = fastPixFullscreenOverlays[controllerProvider.controller];
  final Widget player =
      wrap == null ? controllerProvider : wrap(controllerProvider);

  return Scaffold(
    resizeToAvoidBottomInset: false,
    body: Container(
      alignment: Alignment.center,
      color: Colors.black,
      child: player,
    ),
  );
}

/// Builds the [BetterPlayerConfiguration] used for playback.
///
/// Extracted from `FastPixPlayerController` so that a *warmed* controller can
/// be built with exactly the same settings.
///
/// This matters because [BetterPlayerController.betterPlayerConfiguration] is
/// a **final field**: a controller keeps whatever configuration it was born
/// with for its entire life, and nothing at adoption time can correct it. A
/// player warmed with default settings would render with default controls, no
/// `fit` and no aspect ratio, forever — a visible regression on exactly the
/// playbacks preloading is supposed to improve.
///
/// So anything that is going to be adopted has to be born with the playback
/// configuration already applied, which means one builder, shared by both
/// paths. Warming overrides only `autoPlay`, `autoDispose` and
/// `handleLifecycle`; everything else comes from here.
///
/// See also [betterPlayerConfigurationFingerprint], which gates adoption on
/// these same inputs.
BetterPlayerConfiguration buildBetterPlayerConfiguration({
  FastPixPlayerConfiguration? configuration,
  FastPixPlayerDataSource? dataSource,
}) {
  final controlConfiguration = configuration?.controlsConfiguration;
  final baseConfig = BetterPlayerConfiguration(
    autoPlay: controlConfiguration?.autoPlay ?? false,
    looping: dataSource?.loop ?? false,
    aspectRatio: 16 / 9,
    fit: BoxFit.contain,
    controlsConfiguration: buildControlsConfiguration(controlConfiguration),
    // Set on both the warm and the playing path, and identically: this lands
    // in a final field, so a player warmed without it could never show a
    // fullscreen overlay once adopted. Harmless when no overlay is registered.
    routePageBuilder: fastPixFullscreenRoute,
    // iOS-specific configurations for better HLS support
    allowedScreenSleep: false,
    // Additional configurations for better replay support
    autoDetectFullscreenDeviceOrientation: true,
    autoDetectFullscreenAspectRatio: true,
  );

  return baseConfig;
}

/// Map the FastPix controls configuration onto better_player's.
///
/// Every default below reproduces what the player already did; only the
/// palette and icons differ. [FastPixPlayerControlsConfiguration] declared
/// most of these fields without ever passing them on, so setting one now
/// takes effect where it was previously ignored.
///
/// [FastPixPlayerControlsConfiguration.controlsAutoHideDuration] is
/// deliberately not mapped: better_player hardcodes its 3s auto-hide delay,
/// and its `controlsHideTime` is the fade animation length, so routing the
/// delay there would produce a three-second fade instead.
BetterPlayerControlsConfiguration buildControlsConfiguration(
  FastPixPlayerControlsConfiguration? config,
) {
  final Color foreground =
      parseFastPixColor(config?.controlsForegroundColor) ?? Colors.white;
  final Color played =
      parseFastPixColor(config?.progressBarPlayedColor) ?? kFastPixAccentColor;
  final Color buffered =
      parseFastPixColor(config?.progressBarBufferedColor) ?? Colors.white38;
  final Color background =
      parseFastPixColor(config?.progressBarColor) ?? Colors.white24;

  final visibility = config?.controlsVisibility ?? FastPixControlsVisibility.onTap;
  // A progress bar is what makes the seek bar; treating them separately
  // would let one be shown without the other.
  final bool showBar = (config?.showProgressBar ?? true) &&
      (config?.showSeekBar ?? true);

  return BetterPlayerControlsConfiguration(
    // Pinned rather than left to better_player's platform default, which is
    // `material` on Android and `cupertino` everywhere else
    // (`better_player_with_controls.dart:148`). The two are separate widgets
    // with different layouts, and the Cupertino one breaks this package in two
    // ways:
    //
    // * Its top bar is `[fullscreen][pip] ←spacer→ [mute][overflow]`, so the
    //   cast glyph — pinned top-right by `_CastControlBarButton`, which
    //   reserves width for Material's `[pip][overflow]` — lands on top of the
    //   mute button. Android never collides because there the reservation
    //   describes the real layout.
    // * It moves fullscreen to the top-left, while Material keeps it
    //   bottom-right beside mute. Same player, two different places to look.
    //
    // Pinning to material gives one layout on both platforms, which is what
    // the cast overlay's width reservation already assumes. Note this is a
    // constant rather than something read from `config`, so it is deliberately
    // absent from `betterPlayerConfigurationFingerprint` — it cannot differ
    // between a warmed player and the playback that adopts it.
    playerTheme: BetterPlayerTheme.material,

    // Transparent, so the scrim comes from the gradient better_player draws
    // behind the bar rather than from a flat slab over the video.
    controlBarColor: config?.controlsBackgroundColor ?? Colors.transparent,
    textColor: foreground,
    iconsColor: foreground,
    loadingColor: kFastPixAccentColor,

    // Filled glyphs read better over video than the outlined defaults.
    playIcon: Icons.play_arrow_rounded,
    pauseIcon: Icons.pause_rounded,
    skipBackIcon: Icons.replay_10_rounded,
    skipForwardIcon: Icons.forward_10_rounded,
    fullscreenEnableIcon: Icons.fullscreen_rounded,
    fullscreenDisableIcon: Icons.fullscreen_exit_rounded,
    muteIcon: Icons.volume_up_rounded,
    unMuteIcon: Icons.volume_off_rounded,
    overflowMenuIcon: Icons.more_vert_rounded,
    subtitlesIcon: Icons.closed_caption_rounded,
    qualitiesIcon: Icons.high_quality_rounded,
    playbackSpeedIcon: Icons.speed_rounded,
    audioTracksIcon: Icons.multitrack_audio_rounded,

    progressBarPlayedColor: played,
    progressBarHandleColor: played,
    progressBarBufferedColor: buffered,
    progressBarBackgroundColor: background,

    showControls: config?.showControls ?? true,
    showControlsOnInitialize: visibility != FastPixControlsVisibility.never,
    enablePlayPause: config?.showPlayPauseButton ?? true,
    enableProgressBar: showBar,
    enableProgressBarDrag: showBar,
    enableProgressText: config?.showTimeIndicator ?? true,
    enableFullscreen: config?.showFullscreenButton ?? true,
    enableMute: config?.showVolumeSlider ?? true,
    enableSubtitles: config?.showSubtitleSelector ?? true,
    enableQualities: config?.showQualitySelector ?? true,
    enableRetry: config?.enableRetry ?? false,
    enableSkips: config?.enableSkips ?? false,

    // Dark sheet for the overflow menu, matching the player rather than
    // better_player's white-on-black default.
    overflowModalColor: const Color(0xFF1C1C1E),
    overflowModalTextColor: Colors.white,
    overflowMenuIconsColor: Colors.white,
  );
}

/// Parse `#RRGGBB` or `#AARRGGBB`, returning null for anything else.
///
/// The colour fields are strings on the public API, so an unparseable value
/// has to fall back to the default rather than throw mid-build.
Color? parseFastPixColor(String? value) {
  if (value == null) return null;
  final hex = value.replaceFirst('#', '').trim();
  if (hex.length != 6 && hex.length != 8) return null;
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) return null;
  return Color(hex.length == 6 ? 0xFF000000 | parsed : parsed);
}

/// The subset of settings a warmed controller cannot change after birth.
///
/// A warmed player may only be adopted for a playback whose fingerprint
/// matches, because [BetterPlayerConfiguration] is final on the controller —
/// adopting a player built for different settings renders permanently wrong,
/// which is worse than the cold start it would have saved. A refused adoption
/// is correct behaviour, not a failure.
///
/// Comparing whole configuration objects instead would be useless here: most
/// apps rebuild them every frame, so identity never matches and value equality
/// is not implemented.
///
/// **Maintenance rule.** This must cover *every input*
/// [buildBetterPlayerConfiguration] reads, plus the data-source fields that
/// are baked in at warm time. Add a field there and you must add it here.
/// Nothing in the compiler enforces the pairing, and a drift produces
/// permanently wrong-looking video with no error anywhere.
///
/// Deliberately excluded: `workSpaceId`, `viewerId` and `beaconUrl`. Those
/// drive metrics, are applied after adoption, and including them would cause
/// spurious refusals.
String betterPlayerConfigurationFingerprint({
  FastPixPlayerConfiguration? configuration,
  FastPixPlayerDataSource? dataSource,
}) {
  final controls = configuration?.controlsConfiguration;
  final parts = <Object?>[
    // --- read by buildBetterPlayerConfiguration ---
    controls?.autoPlay,
    dataSource?.loop,

    // --- read by buildControlsConfiguration ---
    controls?.controlsForegroundColor,
    controls?.progressBarPlayedColor,
    controls?.progressBarBufferedColor,
    controls?.progressBarColor,
    controls?.controlsBackgroundColor?.toARGB32(),
    controls?.controlsVisibility.name,
    controls?.showProgressBar,
    controls?.showSeekBar,
    controls?.showControls,
    controls?.showPlayPauseButton,
    controls?.showTimeIndicator,
    controls?.showFullscreenButton,
    controls?.showVolumeSlider,
    controls?.showSubtitleSelector,
    controls?.showQualitySelector,
    controls?.enableRetry,
    controls?.enableSkips,

    // --- baked into the warmed player by setupDataSource ---
    // A warmed player is already positioned, so a different startAt would
    // begin playback in the wrong place.
    dataSource?.startAt?.inMilliseconds,
    // On this SDK the resolution caps are URL query parameters, so a warm at
    // one cap is holding a genuinely different manifest.
    dataSource?.minResolution?.name,
    dataSource?.maxResolution?.name,
    dataSource?.resolution?.name,
    dataSource?.renditionOrder?.name,
    // Baked into the warmed player's load control, which cannot be replaced
    // afterwards. `BetterPlayerBufferingConfiguration` implements no equality,
    // so the values are listed rather than the object.
    dataSource?.bufferingConfiguration.minBufferMs,
    dataSource?.bufferingConfiguration.maxBufferMs,
    dataSource?.bufferingConfiguration.bufferForPlaybackMs,
    dataSource?.bufferingConfiguration.bufferForPlaybackAfterRebufferMs,
  ];
  return parts.map((part) => part ?? '~').join('|');
}
