import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/foundation.dart';

/// The one configuration both preloading and playback use.
///
/// **It must be identical on both sides.** A warmed player's
/// `BetterPlayerConfiguration` is a final field, so adoption is gated on a
/// fingerprint taken over these values. If `preload()` and `initialize()`
/// disagree by even one field, the warmed player is refused and playback
/// falls back to a cold start — correctly, but *silently*, which looks exactly
/// like preloading not being wired up at all.
///
/// Sharing one builder is how that whole class of bug is avoided, and it is
/// the same reason the SDK itself has a single
/// `buildBetterPlayerConfiguration`.
///
/// Seek previews follow [demoSpritesheetSettings], which the player's preview
/// menu changes at run time. Spritesheet settings never reach the engine, so
/// they are safe to vary without breaking preload adoption.
FastPixPlayerConfiguration demoPlayerConfiguration() =>
    FastPixPlayerConfiguration(
      'demo-workspace',
      'demo-viewer',
      'metrix.ws.fastpix.io',
      // No lock-screen / Control Center media panel in the demo.
      enableNowPlaying: false,
      spritesheetConfiguration: demoSpritesheetSettings.value,
      prerenderConfiguration: FastPixPlayerPrerenderConfiguration(
        enablePrerender: demoPrerenderEnabled,
        prerenderOnCellular: demoPrerenderOnCellular.value,
      ),
      controlsConfiguration: const FastPixPlayerControlsConfiguration(
        // Headless: the app draws its own transport over a bare
        // [FastPixVideoSurface] (see [FastPixCustomControls]). The default skin
        // is not used anywhere, which is what removes better_player's
        // pause-on-drag and its engine PiP button — the two Android bugs.
        showControls: false,
        autoPlay: true,
        enableRetry: true,
        enableSkips: true,
      ),
    );

/// Whether the next playlist item is prerendered beneath the current one.
/// On by default, as in the SDK; a build-time switch to measure the gap
/// between items without it: `--dart-define=FASTPIX_PRERENDER=false`.
const bool demoPrerenderEnabled = bool.fromEnvironment(
  'FASTPIX_PRERENDER',
  defaultValue: true,
);

/// Whether prerendering may run on cellular, shared by every screen.
///
/// Toggled from the switch in the prerender panel, which also hands the change
/// to the controller on screen through `updatePrerenderConfiguration`, so it
/// applies at once. Starts at the SDK's own default. Prerender
/// settings never reach the engine, so they are safe to vary without breaking
/// preload adoption.
final ValueNotifier<bool> demoPrerenderOnCellular = ValueNotifier<bool>(
  const FastPixPlayerPrerenderConfiguration().prerenderOnCellular,
);

/// Whether the demo uses the advanced spritesheet. A build-time switch:
/// `--dart-define=FASTPIX_ADVANCED_SPRITESHEET=true`.
const bool demoAdvancedSpritesheet = bool.fromEnvironment(
  'FASTPIX_ADVANCED_SPRITESHEET',
);

/// Seconds between advanced thumbnails:
/// `--dart-define=FASTPIX_SPRITESHEET_INTERVAL=2`.
const int demoSpritesheetInterval = int.fromEnvironment(
  'FASTPIX_SPRITESHEET_INTERVAL',
  defaultValue: FastPixPlayerSpritesheetConfiguration.defaultInterval,
);

/// The seek-preview settings the app starts with: the build-time switches
/// above, so a build made with them still opens in that mode.
const FastPixPlayerSpritesheetConfiguration demoSpritesheetConfiguration =
    FastPixPlayerSpritesheetConfiguration(
      enableAdvancedSpritesheet: demoAdvancedSpritesheet,
      advancedSpritesheetInterval: demoSpritesheetInterval,
    );

/// The seek-preview settings in use now, shared by every screen.
///
/// Starts at [demoSpritesheetConfiguration] and is changed from the player's
/// preview menu, so normal and advanced can be compared on one build without
/// re-running with different defines. A player already on screen is switched
/// through `setSpritesheetConfiguration`; every player created afterwards
/// reads this through [demoPlayerConfiguration]. Not persisted: a restart
/// returns to the build's defaults.
final ValueNotifier<FastPixPlayerSpritesheetConfiguration>
demoSpritesheetSettings = ValueNotifier<FastPixPlayerSpritesheetConfiguration>(
  demoSpritesheetConfiguration,
);

/// Whether the demo offers Picture-in-Picture at all — the PiP button and the
/// window that opens on leaving the app — shared by every screen.
///
/// Toggled from the "Picture-in-Picture" switch under the player, which also
/// switches the player already on screen. On by default, as the demo has
/// always been. Off means leaving the app goes straight to the background
/// rule.
final ValueNotifier<bool> demoPip = ValueNotifier<bool>(true);

/// Apply [demoPip] to [controller]: both PiP itself and automatic PiP.
void applyDemoPip(FastPixPlayerController controller) {
  final enabled = demoPip.value;
  controller.pip.enabled = enabled;
  controller.pip.autoEnterOnBackground = enabled;
}
