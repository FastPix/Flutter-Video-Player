import 'package:flutter/material.dart';
import 'package:better_player_plus/better_player_plus.dart';
import 'fastpix_cast_button.dart';
import 'fastpix_cast_controller.dart';
import 'fastpix_player_controller.dart';
import 'models/fastpix_player_drm_error.dart';
import 'models/fastpix_player_event.dart';
import 'models/fastpix_player_event_types.dart';
import 'utils/fastpix_playback_diagnostics.dart';

/// Main FastPix Player widget
class FastPixPlayer extends StatefulWidget {
  /// Player controller (required)
  final FastPixPlayerController controller;

  /// Widget width
  final double? width;

  /// Widget height
  final double? height;

  /// Whether to show loading indicator
  final bool showLoadingIndicator;

  /// Loading indicator color
  final Color? loadingIndicatorColor;

  final VoidCallback? onReplay;

  /// Placeholder widget builder
  final Widget Function()? placeholderWidgetBuilder;

  /// Builder for the DRM failure state.
  ///
  /// Called when the stream is DRM protected and playback failed for a DRM
  /// reason, for example an expired DRM token or an unsupported device. Takes
  /// precedence over [errorWidgetBuilder] for DRM failures. When both are
  /// omitted, a default message built from the failure is shown.
  final Widget Function(FastPixDrmException error)? drmErrorWidgetBuilder;

  /// Builder for the generic failure state.
  ///
  /// Called for any playback error — network, manifest, or a DRM failure when
  /// [drmErrorWidgetBuilder] is not supplied.
  final Widget Function(FastPixPlayerErrorEvent error)? errorWidgetBuilder;

  /// Whether to probe the FastPix endpoints after a failure to work out its
  /// real cause, since the platform players report every load failure with the
  /// same opaque message. The result is appended to the default error UI.
  final bool diagnoseErrors;

  /// Cast controller backing the cast button drawn on the video.
  ///
  /// When supplied, the button appears in the player's own control bar — the
  /// place viewers expect it after YouTube — and fades in and out with the rest
  /// of the controls. It shows itself only once a receiver has been discovered.
  /// Leave null to draw no cast button at all.
  final FastPixCastController? castController;

  /// Called when the cast button is tapped, with the picker and the
  /// stop-casting flow left to the app so they can match the rest of it.
  ///
  /// Without it the button is inert, so supply one whenever
  /// [castController] is set.
  final VoidCallback? onCastPressed;

  /// Extra content drawn over the video, in both inline and fullscreen.
  ///
  /// Exists because better_player moves the player into a **new route** when it
  /// goes fullscreen. Anything an app stacks around [FastPixPlayer] stays
  /// behind on the old route, which is why a cast scrubber built in the host's
  /// page vanishes the moment the viewer goes fullscreen — the video fills the
  /// screen with no way to seek it.
  ///
  /// Content built here follows the player into that route, so remote
  /// transport controls stay reachable in both layouts. It is drawn above the
  /// video and below nothing else, so it must manage its own hit-testing:
  /// wrap non-interactive parts in [IgnorePointer] or they will swallow taps
  /// meant for the player's own controls.
  ///
  /// Only meaningful while casting — during local playback the player draws
  /// its own controls, and a second set stacked over them competes for the
  /// same gestures.
  final WidgetBuilder? castOverlayBuilder;

  const FastPixPlayer({
    super.key,
    required this.controller,
    this.width,
    this.onReplay,
    this.height,
    this.showLoadingIndicator = true,
    this.loadingIndicatorColor,
    this.placeholderWidgetBuilder,
    this.drmErrorWidgetBuilder,
    this.errorWidgetBuilder,
    this.diagnoseErrors = true,
    this.castController,
    this.onCastPressed,
    this.castOverlayBuilder,
  });

  @override
  State<FastPixPlayer> createState() => _FastPixPlayerState();
}

class _FastPixPlayerState extends State<FastPixPlayer> {
  BetterPlayerController? _betterPlayerController;
  bool _isInitialized = false;
  FastPixPlayerErrorEvent? _error;
  FastPixPlaybackDiagnosis? _diagnosis;
  bool _diagnosing = false;

  @override
  void initState() {
    super.initState();
    // Playback can fail at any point (an expiring DRM license, a dropped
    // connection), so the error state is driven by the event stream rather
    // than only by the initial wait.
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.error,
      _onErrorEvent,
    );
    _initializeController();
  }

  @override
  void didUpdateWidget(FastPixPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;

    // A new controller means a new playback attempt. Without this the state
    // stays bound to the old controller and keeps showing its error — which is
    // what happens when only the DRM token changes, since the stream URL (and
    // so any key derived from it) is unchanged.
    oldWidget.controller.removeEventListener(
      FastPixPlayerEventTypes.error,
      _onErrorEvent,
    );
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.error,
      _onErrorEvent,
    );
    oldWidget.controller.fullscreenOverlayBuilder = null;
    setState(() {
      _error = null;
      _diagnosis = null;
      _diagnosing = false;
      _betterPlayerController = null;
      _isInitialized = false;
    });
    _initializeController();
  }

  @override
  void dispose() {
    widget.controller.removeEventListener(
      FastPixPlayerEventTypes.error,
      _onErrorEvent,
    );
    widget.controller.fullscreenOverlayBuilder = null;
    super.dispose();
  }

  void _onErrorEvent(FastPixPlayerEvent event) {
    if (event is! FastPixPlayerErrorEvent || !mounted) return;
    setState(() => _error = event);
    _diagnose();
  }

  /// The platform error text cannot distinguish a bad playback ID from an
  /// expired token or a rejected license, so ask the FastPix endpoints.
  Future<void> _diagnose() async {
    if (!widget.diagnoseErrors || _diagnosing) return;
    // Rebuild so the detail line can say the work is under way, rather than
    // leaving a gap that later fills with text out of nowhere.
    setState(() => _diagnosing = true);
    try {
      final diagnosis = await widget.controller.diagnosePlayback();
      if (!mounted) return;
      setState(() => _diagnosis = diagnosis);
    } finally {
      if (mounted) {
        setState(() => _diagnosing = false);
      } else {
        _diagnosing = false;
      }
    }
  }

  /// Initialize the controller
  Future<void> _initializeController() async {
    await _waitForControllerReady();
    // dispose() may have already run during the wait above, and it has already
    // cleared the hook — installing it now would leave the controller holding a
    // closure over a State that is gone.
    if (!mounted) return;

    _betterPlayerController = widget.controller.betterPlayerController;
    // Let the cast button follow the player into fullscreen, which is a route
    // of better_player's own making that this widget's tree never reaches.
    widget.controller.fullscreenOverlayBuilder = _wrapForFullscreen;
    setState(() {
      _isInitialized = true;
    });
  }

  /// Wait for the controller to be ready
  Future<void> _waitForControllerReady() async {
    // Wait until the controller has a BetterPlayerController
    // Use exponential backoff for better performance with timeout
    int delay = 50;
    int totalWaitTime = 0;
    const maxWaitTime = 5000; // 5 seconds timeout

    while (widget.controller.betterPlayerController == null) {
      // A failure before the player exists means it never will be created:
      // stop waiting and let build() surface the error.
      if (widget.controller.lastError != null) {
        return;
      }
      await Future.delayed(Duration(milliseconds: delay));
      totalWaitTime += delay;
      if (totalWaitTime >= maxWaitTime) {
        break;
      }

      delay = delay < 200 ? delay * 2 : 200; // Cap at 200ms
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error ?? widget.controller.lastError;
    if (error != null) {
      return _buildErrorWidget(error);
    }
    if (!_isInitialized) {
      return _buildPlaceholderWidget();
    }
    if (_betterPlayerController == null) {
      return _buildPlaceholderWidget();
    }
    return _buildPlayerWidget();
  }

  /// Opaque platform text that tells a viewer nothing and must not be shown as
  /// the headline. ExoPlayer reports every load failure this way.
  static final RegExp _opaquePlatformError = RegExp(
    r'source error|video player had error|unknown error',
    caseSensitive: false,
  );

  /// The line shown the instant the error arrives. Chosen once and never
  /// replaced, so the diagnosis can only add to what the viewer already read.
  String _headline(FastPixPlayerErrorEvent error) {
    if (error is FastPixPlayerDrmErrorEvent &&
        error.drmErrorCode != FastPixDrmErrorCode.unknown) {
      // An identified DRM cause is already the most specific thing we know.
      return error.message;
    }
    return _opaquePlatformError.hasMatch(error.message)
        ? 'Playback failed'
        : error.message;
  }

  /// The line below the headline: what we are still working out, then what we
  /// found. Null when there is nothing more to say than the headline.
  String? _detail(FastPixPlayerErrorEvent error) {
    if (_diagnosis != null) return _diagnosis!.summary;
    if (_diagnosing) return 'Working out why…';
    // No probe ran, so the raw platform text is all we have left to offer.
    final raw =
        error is FastPixPlayerDrmErrorEvent
            ? error.underlyingError
            : error.message;
    return raw != null && raw != _headline(error) ? raw : null;
  }

  /// Build the failure widget for [error], DRM or otherwise
  Widget _buildErrorWidget(FastPixPlayerErrorEvent error) {
    final isDrm = error is FastPixPlayerDrmErrorEvent;

    if (isDrm && widget.drmErrorWidgetBuilder != null) {
      return widget.drmErrorWidgetBuilder!(
        FastPixDrmException(
          error.drmErrorCode,
          error.message,
          playbackId: error.playbackId,
          underlyingError: error.underlyingError,
        ),
      );
    }
    if (widget.errorWidgetBuilder != null) {
      return widget.errorWidgetBuilder!(error);
    }

    widget.controller.updatePlayerDimensions(
      width: widget.width,
      height: widget.height,
    );

    return Container(
      width: widget.width ?? widget.controller.playerWidth(),
      height: widget.height ?? widget.controller.playerHeight(),
      color: Colors.black,
      padding: const EdgeInsets.all(16),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isDrm ? Icons.lock_outline : Icons.error_outline,
                color: Colors.white70,
                size: 32,
              ),
              const SizedBox(height: 8),
              // The headline is fixed the moment the error arrives and never
              // changes: a message that rewrites itself reads as the first one
              // having been wrong.
              Text(
                _headline(error),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              // The detail only ever fills in — from "working it out" to the
              // answer — so nothing already on screen is contradicted.
              if (_detail(error) case final detail?) ...[
                const SizedBox(height: 6),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
              if (error.code != null || _diagnosis != null) ...[
                const SizedBox(height: 6),
                Text(
                  [
                    if (error.code != null) error.code!,
                    if (_diagnosis != null) _diagnosis!.probes.join('  ·  '),
                  ].join('  ·  '),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Build the player widget
  Widget _buildPlayerWidget() {
    // The Stack is unconditional, even with no cast button to put in it.
    // Wrapping the player only when one exists changes the widget type in this
    // slot, and Flutter answers that by unmounting the old element — whose
    // dispose calls BetterPlayerController.dispose(), tearing down playback
    // mid-session. A constant shape costs nothing and cannot do that.
    final Widget videoSurface = Stack(
      fit: StackFit.expand,
      children: [
        BetterPlayer(controller: _betterPlayerController!),
        _buildCastOverlay(),
      ],
    );

    Widget playerWidget = AspectRatio(
      aspectRatio:
          16 / 9, // Default 16:9 aspect ratio - could be made configurable
      child: videoSurface,
    );

    // Always update controller with player dimensions (including defaults)
    widget.controller.updatePlayerDimensions(
      width: widget.width,
      height: widget.height,
    );

    // Use explicit dimensions if provided, otherwise let the controller calculate defaults
    final finalWidth = widget.width;
    final finalHeight = widget.height;

    if (finalWidth != null || finalHeight != null) {
      playerWidget = SizedBox(
        width: finalWidth,
        height: finalHeight,
        child: playerWidget,
      );
    }

    return playerWidget;
  }

  /// The cast button, sitting in the player's top control bar.
  ///
  /// Aligned to the top-right, so it reads as one row with better_player's own
  /// top-bar buttons rather than as something pasted on top.
  Widget _buildCastOverlay() {
    final castController = widget.castController;
    if (castController == null) return const SizedBox.shrink();

    return Align(
      alignment: Alignment.topRight,
      // No SafeArea: better_player's own top bar has none either, and adding
      // one here would push the cast glyph out of line with it.
      child: _CastControlBarButton(
        player: _betterPlayerController!,
        castController: castController,
        onPressed: widget.onCastPressed,
      ),
    );
  }

  /// Put the cast button back over the player once better_player has moved it
  /// into its own fullscreen route.
  ///
  /// `Positioned` rather than `Align`, so the [Stack] takes its size from the
  /// player and the button lands on the player's top-right corner instead of
  /// the screen's — they are not the same place once the video is letterboxed.
  Widget _wrapForFullscreen(Widget player) {
    final castController = widget.castController;
    final betterPlayer = _betterPlayerController;
    if (castController == null || betterPlayer == null) return player;

    final overlay = widget.castOverlayBuilder;

    return Stack(
      children: [
        player,
        // Positioned.fill so the host's overlay gets the player's box rather
        // than the screen's — the two differ once the video is letterboxed.
        if (overlay != null)
          Positioned.fill(child: Builder(builder: overlay)),
        Positioned(
          top: 0,
          right: 0,
          child: _CastControlBarButton(
            player: betterPlayer,
            castController: castController,
            onPressed: widget.onCastPressed,
          ),
        ),
      ],
    );
  }

  /// Build placeholder widget
  Widget _buildPlaceholderWidget() {
    if (widget.placeholderWidgetBuilder != null) {
      return widget.placeholderWidgetBuilder!();
    }

    // Update controller with dimensions first to get calculated defaults
    widget.controller.updatePlayerDimensions(
      width: widget.width,
      height: widget.height,
    );

    return Container(
      width: widget.width ?? widget.controller.playerWidth(),
      height: widget.height ?? widget.controller.playerHeight(),
      color: Colors.black,
      child: Center(
        child:
            widget.showLoadingIndicator
                ? CircularProgressIndicator(
                  color: widget.loadingIndicatorColor ?? Colors.white,
                )
                : const SizedBox.shrink(),
      ),
    );
  }
}

/// The cast glyph as it appears in the player's control bar: fading in and out
/// with the rest of the controls, and reserving room for the buttons
/// better_player draws in its own top bar so it lands to their left.
///
/// Owns its visibility rather than taking it from the player widget. Fullscreen
/// is a route better_player builds, outside [FastPixPlayer]'s element tree, so
/// a `setState` up there could never reach the copy of this button that goes
/// fullscreen. Listening to the player directly means both copies stay correct
/// — and it stops the whole player subtree rebuilding every time the controls
/// happen to fade.
class _CastControlBarButton extends StatefulWidget {
  const _CastControlBarButton({
    required this.player,
    required this.castController,
    required this.onPressed,
  });

  final BetterPlayerController player;
  final FastPixCastController castController;
  final VoidCallback? onPressed;

  @override
  State<_CastControlBarButton> createState() => _CastControlBarButtonState();
}

class _CastControlBarButtonState extends State<_CastControlBarButton> {
  /// Whether the player's controls are on screen.
  ///
  /// Starts true because the player shows its controls on initialize unless
  /// they are disabled entirely.
  bool _controlsVisible = true;

  @override
  void initState() {
    super.initState();
    widget.player.addEventsListener(_onPlayerEvent);
  }

  @override
  void didUpdateWidget(_CastControlBarButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.player, widget.player)) return;
    oldWidget.player.removeEventsListener(_onPlayerEvent);
    widget.player.addEventsListener(_onPlayerEvent);
  }

  @override
  void dispose() {
    widget.player.removeEventsListener(_onPlayerEvent);
    super.dispose();
  }

  /// Mirror the controls' own show/hide into [_controlsVisible].
  ///
  /// `controlsHiddenStart` rather than `controlsHiddenEnd`: the former fires as
  /// the fade begins, so the cast button fades alongside the controls instead
  /// of vanishing once they have already gone.
  void _onPlayerEvent(BetterPlayerEvent event) {
    final bool? visible = switch (event.betterPlayerEventType) {
      BetterPlayerEventType.controlsVisible => true,
      BetterPlayerEventType.controlsHiddenStart => false,
      _ => null,
    };
    if (visible == null || visible == _controlsVisible || !mounted) return;
    setState(() => _controlsVisible = visible);
  }

  @override
  Widget build(BuildContext context) {
    final controls = widget.player.betterPlayerConfiguration.controlsConfiguration;
    final controlsEnabled = widget.player.controlsEnabled;
    // With controls turned off there is nothing to fade with, so the button is
    // simply always there — otherwise it could never be reached.
    final visible = !controlsEnabled || _controlsVisible;

    return SizedBox(
      height: controls.controlBarHeight,
      child: IgnorePointer(
        // Taps must fall through to the video while the controls are gone,
        // otherwise this corner would stop being a place you can tap to bring
        // them back.
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1.0 : 0.0,
          duration: controls.controlsHideTime,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FastPixCastButton(
                controller: widget.castController,
                onPressed: widget.onPressed,
              ),
              if (controlsEnabled) _buildTopBarReservation(controls),
            ],
          ),
        ),
      ),
    );
  }

  /// Blank space matching the buttons better_player draws in its own top bar,
  /// so the cast glyph lands to their left instead of on top of them.
  ///
  /// The picture-in-picture check repeats better_player's: it draws that button
  /// only when the platform supports PiP and the player has a global key.
  Widget _buildTopBarReservation(BetterPlayerControlsConfiguration controls) {
    const double buttonWidth = 40; // 24px icon plus its 8px padding each side.
    if (!controls.enableOverflowMenu) return const SizedBox.shrink();

    if (!controls.enablePip || widget.player.betterPlayerGlobalKey == null) {
      return const SizedBox(width: buttonWidth);
    }

    return FutureBuilder<bool>(
      future: widget.player.isPictureInPictureSupported(),
      builder: (context, snapshot) {
        final hasPip = snapshot.data ?? false;
        return SizedBox(width: hasPip ? buttonWidth * 2 : buttonWidth);
      },
    );
  }
}
