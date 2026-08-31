import 'package:fastpix_video_player/fastpix_video_player.dart';

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
FastPixPlayerConfiguration demoPlayerConfiguration() =>
    FastPixPlayerConfiguration(
      'demo-workspace',
      'demo-viewer',
      'metrix.ws.fastpix.io',
      controlsConfiguration: const FastPixPlayerControlsConfiguration(
        autoPlay: true,
        enableRetry: true,
        enableSkips: true,
      ),
    );
