import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'fastpix_cast_button.dart';
import 'fastpix_cast_controller.dart';
import 'fastpix_player_controller.dart';
import 'models/fastpix_player_drm_error.dart';
import 'models/fastpix_player_event.dart';
import 'models/fastpix_player_controls_configuration.dart';
import 'models/fastpix_player_event_types.dart';
import 'models/fastpix_playlist_state.dart';
import 'widgets/fastpix_pip_layout.dart';
import 'widgets/fastpix_playlist_panel.dart';
import 'utils/fastpix_video_size_watcher.dart';
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
    this.pipBuilder,
  });

  /// What the Picture-in-Picture window shows while one is open.
  ///
  /// Defaults to [fastPixDefaultPipLayout] — the bare video, with none of this
  /// widget's own chrome. Supply a builder to put something else there; the
  /// video widget it is handed must appear in the tree it returns, or the
  /// engine controller is disposed and the playback the window is showing
  /// ends.
  final FastPixPipBuilder? pipBuilder;

  @override
  State<FastPixPlayer> createState() => _FastPixPlayerState();
}

class _FastPixPlayerState extends State<FastPixPlayer> {
  BetterPlayerController? _betterPlayerController;

  /// Rebuilds this widget when the engine reports a new video size, so the
  /// engine's own `FittedBox` re-reads it. Without that, a source change on
  /// Android leaves the new video fitted to the previous one's dimensions.
  late final FastPixVideoSizeWatcher _videoSize;

  /// Whether a PiP window is showing this playback.
  ///
  /// While it is, this widget renders [FastPixPlayer.pipBuilder] instead of its
  /// page layout, so the window shows the video and not the whole app. That
  /// matters most on Android, where the system resizes the entire activity into
  /// the PiP rectangle.
  bool _pipActive = false;

  /// Keeps the player the *same element* across a Picture-in-Picture
  /// transition. Entering PiP replaces this widget's layout, and a re-parented
  /// subtree without a `GlobalKey` is unmounted and rebuilt — which for
  /// `BetterPlayer` means disposing the engine controller and ending the
  /// playback the window is showing.
  final GlobalKey _playerKey = GlobalKey();

  /// How large the player was drawn while it was still on the page, so a PiP
  /// window can render a scaled copy of it. See [fastPixPipVideoBox].
  final FastPixInlinePlayerSize _inlineSize = FastPixInlinePlayerSize();

  bool _isInitialized = false;
  FastPixPlayerErrorEvent? _error;
  FastPixPlaybackDiagnosis? _diagnosis;
  bool _diagnosing = false;

  @override
  void initState() {
    super.initState();
    _videoSize = FastPixVideoSizeWatcher(_onVideoSizeChanged);
    _pipActive = widget.controller.pip.isPipActiveOrPending;
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
    );
    // Playback can fail at any point (an expiring DRM license, a dropped
    // connection), so the error state is driven by the event stream rather
    // than only by the initial wait.
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.error,
      _onErrorEvent,
    );
    // The controller can replace the source it is playing without this widget
    // being rebuilt and without being handed a different controller — a
    // playlist advance does exactly that. Without this the widget keeps
    // rendering the engine player it latched at mount, which by then has been
    // released.
    widget.controller.sourceGeneration.addListener(_onSourceChanged);
    _initializeController();
  }

  /// Re-read the engine player after the controller changed source.
  void _onSourceChanged() {
    if (!mounted) return;
    setState(() {
      // A new source is a new attempt: the previous source's failure must not
      // keep the error state on screen over video that is playing.
      _error = null;
      _diagnosis = null;
      _diagnosing = false;
      _betterPlayerController = widget.controller.betterPlayerController;
      _isInitialized = _betterPlayerController != null;
    });
    _videoSize.watch(_betterPlayerController);
  }

  void _onVideoSizeChanged() {
    if (mounted) setState(() {});
  }

  void _onPipChanged(FastPixPlayerEvent _) {
    if (!mounted) return;
    setState(() => _pipActive = widget.controller.pip.isPipActiveOrPending);
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
    oldWidget.controller.removeEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
    );
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
    );
    oldWidget.controller.sourceGeneration.removeListener(_onSourceChanged);
    widget.controller.sourceGeneration.addListener(_onSourceChanged);
    oldWidget.controller.fullscreenOverlayBuilder = null;
    _videoSize.watch(null);
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
    widget.controller.removeEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
    );
    widget.controller.sourceGeneration.removeListener(_onSourceChanged);
    widget.controller.fullscreenOverlayBuilder = null;
    _videoSize.dispose();
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
    _videoSize.watch(_betterPlayerController);
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
    final Widget video =
        BetterPlayer(key: _playerKey, controller: _betterPlayerController!);

    // A PiP window shows the video alone. On Android the window IS this tree —
    // the system resizes the whole activity — so the page layout below
    // (overlays, playlist rail, top bar) would be drawn into a thumbnail
    // unless it is replaced. On iOS the window is a separate system surface
    // and this page carries on unchanged. See
    // [fastPixHostTreeBecomesPipWindow].
    //
    // An opaque cover used to be composited over the video here instead. That
    // existed only because the engine's iOS PiP added a *second* AVPlayerLayer
    // on the same player and handed that one to AVKit, leaving this one still
    // drawing the same video. The SDK owns PiP natively now and attaches it to
    // this layer, so there is no second one and nothing to hide.
    // Pending counts, not just confirmed. Android resizes the window — and so
    // rebuilds this tree — *before* the platform reports the window open, so a
    // build gated on the confirmed flag lays the full page out at ~192x108
    // first. That layout throws (`BoxConstraints forces an infinite height`, a
    // failed `Stack` assertion, an overflowing `RenderFlex`) and a tree that
    // throws during layout paints nothing: the black PiP window.
    if (_pipActive && fastPixHostTreeBecomesPipWindow) {
      final build = widget.pipBuilder ?? fastPixDefaultPipLayout;
      // Scaled here rather than inside the default layout so a host that
      // supplies its own `pipBuilder` gets the same captions too.
      return build(
        context,
        fastPixPipVideoBox(
          context,
          video,
          inlinePlayerSize: _inlineSize.value,
        ),
      );
    }

    // Records the size the player is drawn at here, for the PiP branch above to
    // scale down from. Sampled from the inline path because that is the only
    // place the inline layout exists.
    _inlineSize.sampleAfterFrame(_playerKey, () => !_pipActive);

    final Widget videoSurface = Stack(
      fit: StackFit.expand,
      children: [
        video,
        _buildPlaylistOverlay(),
        _buildTopBarOverlay(),
      ],
    );

    Widget playerWidget = AspectRatio(
      aspectRatio: 16 / 9,
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

  /// Whether the playlist controls could ever draw for this player.
  ///
  /// A cheap gate for the fullscreen wrap: it says the configuration allows
  /// them, not that a playlist is currently set — that second question is the
  /// overlay's own, and it answers it live from the playlist state stream.
  bool get _playlistControlsPossible {
    final controls = widget.controller.configuration?.controlsConfiguration;
    if (controls == null) return true;
    return controls.showPlaylistControls || controls.showPlaylistPanel;
  }

  /// Whether the queue is open over the video.
  ///
  /// Held here rather than inside the overlay because the button that opens it
  /// lives in the top bar and the panel it opens is drawn over the middle of
  /// the player — two different subtrees, and in fullscreen two different
  /// routes.
  bool _panelOpen = false;

  void _openPanel() {
    if (!mounted) return;
    setState(() => _panelOpen = true);
    // The controls' own hide timer keeps running behind the panel; nudging it
    // means they are still there when the queue closes.
    _betterPlayerController?.setControlsVisibility(true);
  }

  void _closePanel() {
    if (!mounted) return;
    setState(() => _panelOpen = false);
  }

  /// Playlist previous/next and the queue panel, over the middle of the player.
  ///
  /// Drawn for both the inline player and the engine's fullscreen route (see
  /// [_wrapForFullscreen]) so playlist navigation does not disappear the moment
  /// the viewer goes fullscreen.
  Widget _buildPlaylistOverlay() {
    final player = _betterPlayerController;
    if (player == null) return const SizedBox.shrink();
    return _PlaylistNavOverlay(
      player: player,
      controller: widget.controller,
      panelOpen: _panelOpen,
      onClosePanel: _closePanel,
    );
  }

  /// The player's top-right control row: the playlist queue button, then the
  /// cast glyph, then blank space matching better_player's own top-bar buttons.
  ///
  /// One row rather than several overlays, because they share a corner. The
  /// left-hand side of the player is not an option: in portrait that is where
  /// the host's back chevron sits.
  Widget _buildTopBarOverlay() {
    final player = _betterPlayerController;
    if (player == null) return const SizedBox.shrink();

    return Align(
      alignment: Alignment.topRight,
      // No SafeArea: better_player's own top bar has none either, and adding
      // one here would push these glyphs out of line with it.
      child: _TopBarControls(
        player: player,
        controller: widget.controller,
        castController: widget.castController,
        onCastPressed: widget.onCastPressed,
        onPlaylistPressed: _openPanel,
      ),
    );
  }

  /// Put the cast button and the playlist controls back over the player once
  /// better_player has moved it into its own fullscreen route.
  ///
  /// `Positioned` rather than `Align`, so the [Stack] takes its size from the
  /// player and the button lands on the player's top-right corner instead of
  /// the screen's — they are not the same place once the video is letterboxed.
  Widget _wrapForFullscreen(Widget player) {
    final castController = widget.castController;
    final betterPlayer = _betterPlayerController;
    // Cast is optional; the playlist controls are not tied to it, so the wrap
    // still happens for a playlist with no cast controller in play.
    if (betterPlayer == null) return player;

    final overlay = widget.castOverlayBuilder;
    if (castController == null && overlay == null && !_playlistControlsPossible) {
      return player;
    }

    return Stack(
      children: [
        player,
        // Positioned.fill so the host's overlay gets the player's box rather
        // than the screen's — the two differ once the video is letterboxed.
        if (overlay != null) Positioned.fill(child: Builder(builder: overlay)),
        Positioned.fill(
          child: _PlaylistNavOverlay(
            player: betterPlayer,
            controller: widget.controller,
            panelOpen: _panelOpen,
            onClosePanel: _closePanel,
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: _TopBarControls(
            player: betterPlayer,
            controller: widget.controller,
            castController: castController,
            onCastPressed: widget.onCastPressed,
            onPlaylistPressed: _openPanel,
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
class _TopBarControls extends StatefulWidget {
  const _TopBarControls({
    required this.player,
    required this.controller,
    required this.castController,
    required this.onCastPressed,
    required this.onPlaylistPressed,
  });

  final BetterPlayerController player;
  final FastPixPlayerController controller;

  /// Null when the host wired no cast support: the row then carries only the
  /// queue button.
  final FastPixCastController? castController;
  final VoidCallback? onCastPressed;

  /// Opens the playlist queue.
  final VoidCallback onPlaylistPressed;

  @override
  State<_TopBarControls> createState() => _TopBarControlsState();
}

class _TopBarControlsState extends State<_TopBarControls> {
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
  void didUpdateWidget(_TopBarControls oldWidget) {
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

  /// Whether the host allows the queue button at all.
  /// Whether the cast glyph shows before a receiver is found. Defaults to
  /// true so the feature is discoverable, matching the configuration default.
  bool get _castVisibleWithoutDevices =>
      widget.controller.configuration?.controlsConfiguration
          .showCastWhenNoDevices ??
      true;

  bool get _panelAllowed =>
      widget.controller.configuration?.controlsConfiguration
          .showPlaylistPanel ??
      true;

  @override
  Widget build(BuildContext context) {
    final controls =
        widget.player.betterPlayerConfiguration.controlsConfiguration;
    final controlsEnabled = widget.player.controlsEnabled;
    // With controls turned off there is nothing to fade with, so the buttons
    // are simply always there — otherwise they could never be reached.
    final visible = !controlsEnabled || _controlsVisible;
    final castController = widget.castController;

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
              // Leftmost of the row, so the cast glyph stays where viewers
              // have always found it.
              if (_panelAllowed) _buildPlaylistButton(controls),
              if (castController != null)
                FastPixCastButton(
                  controller: castController,
                  onPressed: widget.onCastPressed,
                  showWhenNoDevices: _castVisibleWithoutDevices,
                ),
              if (controlsEnabled) _buildTopBarReservation(controls),
            ],
          ),
        ),
      ),
    );
  }

  /// The queue button, drawn only once there is a playlist worth opening.
  ///
  /// Its own [StreamBuilder] rather than a rebuild of the whole row: the
  /// playlist changes far less often than the controls fade, and the cast glyph
  /// has no interest in either.
  Widget _buildPlaylistButton(BetterPlayerControlsConfiguration controls) {
    return StreamBuilder<FastPixPlaylistState>(
      stream: widget.controller.playlistStateStream,
      initialData: widget.controller.playlistState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? widget.controller.playlistState;
        if (state.count < 2) return const SizedBox.shrink();
        return _PlaylistNavButton(
          icon: Icons.playlist_play_rounded,
          color: controls.iconsColor,
          semanticLabel: 'Playlist',
          onPressed: widget.onPlaylistPressed,
        );
      },
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


/// Playlist previous/next, drawn over the player at the edges of its middle
/// row.
///
/// This is an overlay rather than an addition to better_player's control skin
/// because that skin is the engine's, not ours — the same reason
/// [_CastControlBarButton] is an overlay. It follows the same rules: it fades
/// with the controls, listening to the player directly so a fade does not
/// rebuild the player subtree, and it lets taps through once they are gone so
/// the edges of the video stay a place you can tap to bring them back.
///
/// The buttons sit at the far left and right edges, outboard of the ±10s skip
/// pair better_player centres in the outer thirds of its middle row, so the two
/// never collide whether or not `enableSkips` is on.
class _PlaylistNavOverlay extends StatefulWidget {
  const _PlaylistNavOverlay({
    required this.player,
    required this.controller,
    required this.panelOpen,
    required this.onClosePanel,
  });

  final BetterPlayerController player;
  final FastPixPlayerController controller;

  /// Whether the queue is open. Owned by the player state, because the button
  /// that opens it lives in the top bar.
  final bool panelOpen;
  final VoidCallback onClosePanel;

  @override
  State<_PlaylistNavOverlay> createState() => _PlaylistNavOverlayState();
}

class _PlaylistNavOverlayState extends State<_PlaylistNavOverlay> {
  /// Whether the player's controls are on screen. Starts true for the same
  /// reason [_CastControlBarButtonState] does: the player shows them on
  /// initialize unless they are disabled entirely.
  bool _controlsVisible = true;

  /// Where the playlist is. Seeded synchronously so the buttons are correct on
  /// the first frame rather than after the first navigation.
  late FastPixPlaylistState _playlist = widget.controller.playlistState;

  StreamSubscription<FastPixPlaylistState>? _playlistSubscription;

  @override
  void initState() {
    super.initState();
    widget.player.addEventsListener(_onPlayerEvent);
    _subscribeToPlaylist();
  }

  @override
  void didUpdateWidget(_PlaylistNavOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      oldWidget.player.removeEventsListener(_onPlayerEvent);
      widget.player.addEventsListener(_onPlayerEvent);
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      _playlistSubscription?.cancel();
      _playlist = widget.controller.playlistState;
      _subscribeToPlaylist();
    }
  }

  @override
  void dispose() {
    _playlistSubscription?.cancel();
    widget.player.removeEventsListener(_onPlayerEvent);
    super.dispose();
  }

  void _subscribeToPlaylist() {
    _playlistSubscription =
        widget.controller.playlistStateStream.listen((state) {
      if (!mounted) return;
      setState(() => _playlist = state);
    });
  }

  /// Mirror the controls' own show/hide, as the cast button does.
  void _onPlayerEvent(BetterPlayerEvent event) {
    final bool? visible = switch (event.betterPlayerEventType) {
      BetterPlayerEventType.controlsVisible => true,
      BetterPlayerEventType.controlsHiddenStart => false,
      _ => null,
    };
    if (visible == null || visible == _controlsVisible || !mounted) return;
    setState(() => _controlsVisible = visible);
  }

  FastPixPlayerControlsConfiguration? get _config =>
      widget.controller.configuration?.controlsConfiguration;

  @override
  Widget build(BuildContext context) {
    final config = _config;
    final arrows = config?.showPlaylistControls ?? true;
    final panel = config?.showPlaylistPanel ?? true;
    // One item is not a playlist to navigate, so nothing is drawn rather than
    // buttons sitting there permanently disabled.
    if (_playlist.count < 2 || !(arrows || panel)) {
      return const SizedBox.shrink();
    }

    final controls =
        widget.player.betterPlayerConfiguration.controlsConfiguration;
    final controlsEnabled = widget.player.controlsEnabled;
    // With controls turned off there is nothing to fade with, so the buttons
    // are simply always there — otherwise they could never be reached.
    final visible = !controlsEnabled || _controlsVisible;

    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1.0 : 0.0,
            duration: controls.controlsHideTime,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (arrows)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _PlaylistNavButton(
                        icon: Icons.skip_previous_rounded,
                        color: controls.iconsColor,
                        semanticLabel: 'Previous video',
                        // From the state, not the controller: the state is what
                        // this overlay rebuilds on, so the two can never
                        // disagree mid-frame.
                        onPressed:
                            _playlist.canGoPrevious ? _goPrevious : null,
                      ),
                      _PlaylistNavButton(
                        icon: Icons.skip_next_rounded,
                        color: controls.iconsColor,
                        semanticLabel: 'Next video',
                        onPressed: _playlist.canGoNext ? _goNext : null,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        // Outside the fade: an open queue stays put while the controls behind
        // it time out, which is what every player's queue does.
        if (widget.panelOpen && panel)
          FastPixPlaylistPanel(
            controller: widget.controller,
            onDismiss: widget.onClosePanel,
          ),
      ],
    );
  }


  // Fire-and-forget: navigation reports failure by returning false and by the
  // playlist state that follows, both of which this overlay already reflects.
  void _goPrevious() => unawaited(widget.controller.previous());

  void _goNext() => unawaited(widget.controller.next());
}

/// One playlist navigation glyph.
///
/// A null [onPressed] is the end of the playlist: the glyph dims and stops
/// taking taps rather than disappearing, so the row does not reflow when the
/// viewer reaches either end.
class _PlaylistNavButton extends StatelessWidget {
  const _PlaylistNavButton({
    required this.icon,
    required this.color,
    required this.semanticLabel,
    required this.onPressed,
  });

  final IconData icon;
  final Color color;
  final String semanticLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1.0 : 0.3,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, color: color, size: 32),
        tooltip: semanticLabel,
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(),
      ),
    );
  }
}
