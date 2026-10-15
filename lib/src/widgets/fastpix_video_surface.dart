import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';

import '../fastpix_player_controller.dart';
import '../models/fastpix_player_event.dart';
import '../models/fastpix_player_event_types.dart';
import '../utils/fastpix_aspect_ratio.dart';
import '../utils/fastpix_video_size_watcher.dart';
import 'fastpix_pip_layout.dart';
import 'fastpix_player_slots.dart';

/// A headless video surface: it renders the video and nothing else — no
/// controls, no gestures, no overlays (Feature 1).
///
/// This is the presentation half of the custom-UI mechanism. An application
/// composes its own widgets *over* this surface using the functionality-only
/// API on [FastPixPlayerController]. The default skin ([FastPixPlayer]) is
/// untouched and remains the default experience; this is an opt-in alternative.
///
/// **Headlessness comes from configuration, not from this widget.** The engine
/// bakes its control skin into the player at build time, so to get a truly bare
/// surface the controller must be initialized with
/// `FastPixPlayerControlsConfiguration(showControls: false)`. This widget adds
/// no controls of its own and passes every gesture straight through to whatever
/// the app stacks on top.
///
/// **A failure draws no panel.** The surface reports a playback failure — the
/// `error` event and [FastPixPlayerController.lastError] — and keeps drawing
/// what it was drawing: the video box or the placeholder. What a viewer sees about the failure is the host's to draw,
/// over this surface or through [errorBuilder].
///
/// Multiple surfaces may be bound to one controller. The surface tolerates being
/// built before the player is ready (it shows [placeholder] until then) and the
/// player being disposed while displayed (it falls back to [placeholder]).
class FastPixVideoSurface extends StatefulWidget {
  /// The controller whose video to render. Initialize it (via
  /// [FastPixPlayerController.initialize]) before or after mounting — the
  /// surface waits for readiness either way.
  final FastPixPlayerController controller;

  /// Aspect ratio of the surface, as width divided by height: `16 / 9`,
  /// `9 / 16` for a reel, `2 / 3`, `1`.
  ///
  /// Defaults to 16:9. Pass a value to pin this surface to a fixed shape.
  /// With [matchVideoAspectRatio] this is only the shape used until the video
  /// reports its own.
  ///
  /// The video is fitted into the box by
  /// [FastPixPlayerConfiguration.videoFit] — letterboxed by default, with the
  /// bars showing as [backgroundColor], or cropped to fill with
  /// [FastPixVideoFit.cover].
  final double? aspectRatio;

  /// Size the surface to the video's own shape once it is known. Until then it
  /// uses [aspectRatio], else 16:9. See [FastPixPlayer.matchVideoAspectRatio].
  final bool matchVideoAspectRatio;

  /// Optional background painted behind the video (visible as letterbox bars).
  /// Defaults to black.
  final Color backgroundColor;

  /// Shown until the player is ready, or if it becomes unavailable. Defaults to
  /// a plain [backgroundColor] box at [aspectRatio].
  final WidgetBuilder? placeholder;

  /// What the Picture-in-Picture window shows while one is open.
  ///
  /// Defaults to [fastPixDefaultPipLayout] — the bare video, full-bleed, with
  /// no surrounding interface. Supply a builder to put something else there;
  /// the video widget it is handed must appear in the tree it returns, or the
  /// engine controller is disposed and the playback ends.
  final FastPixPipBuilder? pipBuilder;

  /// What to draw in place of the video when playback fails.
  ///
  /// Null, the default, draws nothing extra: the surface stays as it was.
  /// Supply a builder to replace the surface with the host's own
  /// failure UI; [FastPixPlayerController.diagnosePlayback] is there to call
  /// for the reason.
  final Widget Function(BuildContext context, FastPixPlayerErrorEvent error)?
      errorBuilder;

  /// Currently has no effect, and is kept so existing code still compiles.
  ///
  /// It drove the endpoint probe behind the surface's failure panel, which the
  /// surface no longer draws; a probe whose answer nothing shows would only be
  /// a hidden network request. Call [FastPixPlayerController.diagnosePlayback]
  /// from the host's own `error` listener instead.
  final bool diagnoseErrors;

  const FastPixVideoSurface({
    super.key,
    required this.controller,
    this.aspectRatio,
    this.matchVideoAspectRatio = false,
    this.backgroundColor = Colors.black,
    this.placeholder,
    this.pipBuilder,
    this.errorBuilder,
    this.diagnoseErrors = true,
  }) : assert(
         aspectRatio == null || (aspectRatio > 0 && aspectRatio < double.infinity),
         'aspectRatio must be positive and finite',
       );

  @override
  State<FastPixVideoSurface> createState() => _FastPixVideoSurfaceState();
}

class _FastPixVideoSurfaceState extends State<FastPixVideoSurface> {
  BetterPlayerController? _betterPlayerController;
  bool _ready = false;

  /// The failure for [FastPixVideoSurface.errorBuilder], or null while nothing
  /// fatal has happened.
  ///
  /// Read from [FastPixPlayerController.lastError] rather than kept from the
  /// event: the `error` channel also carries failures that did not stop
  /// playback — a cast route that could not be offered, a playlist that was
  /// rejected — and those never set `lastError`. Reading it in `build` also
  /// covers a failure that happened before this surface was mounted.
  FastPixPlayerErrorEvent? get _error => widget.controller.lastError;

  /// Marks this surface as mounted, and identifies which surface a controller
  /// is currently showing through.
  ///
  /// It used to anchor the engine's iOS PiP window, whose `RenderBox` the
  /// engine read to place a layer. PiP is owned natively now and finds its own
  /// layer, so the key no longer travels to any platform — it stays because
  /// registration is still how a controller knows a surface is on screen.
  final GlobalKey _pipKey = GlobalKey();

  /// Rebuilds this surface when the engine reports a new video size, so the
  /// engine's own `FittedBox` re-reads it. Without that, a source change on
  /// Android leaves the new video fitted to the previous one's dimensions.
  late final FastPixVideoSizeWatcher _videoSize;

  /// The shape to lay the video box out at: the video's own when matching it
  /// and known, else the caller's pin, else 16:9.
  double get _effectiveAspectRatio => fastPixResolveAspectRatio(
    aspectRatio: widget.aspectRatio,
    matchVideo: widget.matchVideoAspectRatio,
    videoSize: _videoSize.size,
  );

  /// Whether a PiP window is showing this playback, or about to.
  ///
  /// Read live from the controller, never cached. A PiP request is *pending*
  /// from the moment it is made, but only the window opening is announced,
  /// and Android shrinks the whole activity to the thumbnail in between. A
  /// cached flag still read "inline" through that gap, so the inline layout
  /// was built — and measured — at thumbnail size. The PiP window then scaled
  /// from a box already the window's size, and captions came out at full,
  /// unscaled size until the next normal-size frame corrected it.
  bool get _pipActive => widget.controller.pip.isPipActiveOrPending;

  /// Keeps each player the *same element* across a Picture-in-Picture
  /// transition and across a prerender's promotion.
  ///
  /// Entering PiP replaces this widget's layout, which re-parents the player.
  /// Without a `GlobalKey` Flutter treats a re-parented subtree as a new one:
  /// the old element is unmounted, and unmounting `BetterPlayer` disposes the
  /// engine controller — ending the very playback the PiP window exists to
  /// show. A global key moves the element instead of rebuilding it. The key
  /// belongs to the engine player, so a promoted prerender moves too.
  final FastPixPlayerSlots _slots = FastPixPlayerSlots();

  /// The prerender in this controller's hidden slot, or null.
  BetterPlayerController? get _hidden =>
      fastPixPrerenderEngines[widget.controller]?.value;

  /// How large the player was drawn while it was still on the page, so a PiP
  /// window can render a scaled copy of it. See [fastPixPipVideoBox].
  final FastPixInlinePlayerSize _inlineSize = FastPixInlinePlayerSize();

  @override
  void initState() {
    super.initState();
    _videoSize = FastPixVideoSizeWatcher(_onVideoSizeChanged);
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
    );
    widget.controller.pip.pendingChanges.addListener(_onPipPending);
    widget.controller.registerPipSurfaceKey(_pipKey);
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.error,
      _onErrorEvent,
    );
    // The controller can replace its source while this surface stays mounted —
    // a playlist advance does — so the engine player has to be re-read rather
    // than latched at mount. A surface still bound to the previous player is
    // rendering one that has been released.
    widget.controller.sourceGeneration.addListener(_onSourceChanged);
    fastPixPrerenderEngines[widget.controller]?.addListener(_onPrerenderChanged);
    widget.controller.attachPrerenderSurface();
    _bind();
  }

  void _onPrerenderChanged() {
    if (mounted) setState(() {});
  }

  void _onSourceChanged() {
    if (!mounted) return;
    setState(() {
      _betterPlayerController = widget.controller.betterPlayerController;
      _ready = _betterPlayerController != null;
    });
    _videoSize.watch(_betterPlayerController);
  }

  void _onVideoSizeChanged() {
    if (mounted) setState(() {});
  }

  /// A window became pending, or stopped being so; on Android that decides
  /// the layout before any window is announced.
  void _onPipPending() {
    if (mounted) setState(() {});
  }

  void _onPipChanged(FastPixPlayerEvent _) {
    if (!mounted) return;
    // Nothing to record — [_pipActive] reads the controller — only a rebuild.
    setState(() {});
  }

  /// Rebuild so `build` re-reads [FastPixPlayerController.lastError] for
  /// [FastPixVideoSurface.errorBuilder].
  ///
  /// The event itself is deliberately not stored — see [_error].
  void _onErrorEvent(FastPixPlayerEvent event) {
    if (event is! FastPixPlayerErrorEvent || !mounted) return;
    setState(() {});
  }

  @override
  void didUpdateWidget(FastPixVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.unregisterPipSurfaceKey(_pipKey);
    oldWidget.controller.sourceGeneration.removeListener(_onSourceChanged);
    fastPixPrerenderEngines[oldWidget.controller]?.removeListener(_onPrerenderChanged);
    oldWidget.controller.detachPrerenderSurface();
    oldWidget.controller.removeEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
    );
    oldWidget.controller.pip.pendingChanges.removeListener(_onPipPending);
    oldWidget.controller.removeEventListener(
      FastPixPlayerEventTypes.error,
      _onErrorEvent,
    );
    _videoSize.watch(null);
    widget.controller.registerPipSurfaceKey(_pipKey);
    widget.controller.sourceGeneration.addListener(_onSourceChanged);
    fastPixPrerenderEngines[widget.controller]?.addListener(_onPrerenderChanged);
    widget.controller.attachPrerenderSurface();
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
    );
    widget.controller.pip.pendingChanges.addListener(_onPipPending);
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.error,
      _onErrorEvent,
    );
    setState(() {
      _ready = false;
      _betterPlayerController = null;
    });
    _bind();
  }

  @override
  void dispose() {
    widget.controller.unregisterPipSurfaceKey(_pipKey);
    widget.controller.sourceGeneration.removeListener(_onSourceChanged);
    fastPixPrerenderEngines[widget.controller]?.removeListener(_onPrerenderChanged);
    widget.controller.detachPrerenderSurface();
    widget.controller.removeEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
    );
    widget.controller.pip.pendingChanges.removeListener(_onPipPending);
    widget.controller.removeEventListener(
      FastPixPlayerEventTypes.error,
      _onErrorEvent,
    );
    _videoSize.dispose();
    super.dispose();
  }

  Future<void> _bind() async {
    await _waitForControllerReady();
    if (!mounted) return;
    setState(() {
      _betterPlayerController = widget.controller.betterPlayerController;
      _ready = _betterPlayerController != null;
    });
    _videoSize.watch(_betterPlayerController);
  }

  /// Wait for the controller to build (or adopt) its engine player, using the
  /// same bounded exponential backoff as the default player widget so the two
  /// behave identically on slow initialization.
  Future<void> _waitForControllerReady() async {
    int delay = 50;
    int waited = 0;
    const maxWait = 5000;
    while (widget.controller.betterPlayerController == null) {
      // A failure before the player exists means it never will be created.
      if (widget.controller.lastError != null) return;
      await Future.delayed(Duration(milliseconds: delay));
      waited += delay;
      if (waited >= maxWait) break;
      delay = delay < 200 ? delay * 2 : 200;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only a host's own failure UI replaces the surface. With none, a failure
    // leaves the surface drawing what it was.
    final replacement = widget.errorBuilder;
    if (replacement != null) {
      if (_error case final error?) return replacement(context, error);
    }

    final betterPlayer = _betterPlayerController;
    if (!_ready || betterPlayer == null) {
      return _buildPlaceholder(context);
    }

    // The player stays at the same position in the tree for the life of this
    // surface, in and out of PiP. Replacing it — even with a wrapper — unmounts
    // its element, and that disposes the engine controller mid-playback, which
    // in a PiP session would end the very playback the window is showing.
    final hidden = _hidden;
    _slots.bind(betterPlayer, hidden);
    final Widget video = _slots.slot(
      betterPlayer,
      hidden: false,
      cover: widget.backgroundColor,
    );

    // On Android the PiP window IS this tree (the system resizes the whole
    // activity), so the page layout is replaced by the window's content. On
    // iOS the window is a separate system surface and this page stays exactly
    // as it was — replacing it would blank the page the viewer comes back to
    // without changing what the window shows. See
    // [fastPixHostTreeBecomesPipWindow].
    //
    // An opaque cover used to be composited over the video on iOS instead.
    // That existed because the engine's PiP added a *second* `AVPlayerLayer`
    // on the same player and handed that one to AVKit, leaving this one still
    // drawing — the same video in two places. The SDK owns PiP natively now
    // and attaches it to this very layer, so AVKit lifts this layer and leaves
    // its own placeholder: there is no second video and nothing to hide.
    if (_pipActive && fastPixHostTreeBecomesPipWindow) {
      final build = widget.pipBuilder ??
          (context, video) => fastPixDefaultPipLayout(
                context,
                video,
                background: widget.backgroundColor,
              );
      // Scaled here rather than inside the default layout so a host that
      // supplies its own `pipBuilder` gets the same captions too.
      // The window takes the video's shape, so draw the video at it: the
      // engine's inner box set to the video's ratio, scaled from the area the
      // picture filled inline rather than the whole player box. Restored to
      // the box's ratio by the inline path's next build.
      final videoSize = _videoSize.size;
      if (videoSize != null) {
        fastPixSyncEngineAspectRatio(
          _betterPlayerController,
          fastPixResolveAspectRatio(matchVideo: true, videoSize: videoSize),
        );
      }
      return build(
        context,
        fastPixPipVideoBox(
          context,
          video,
          inlinePlayerSize: fastPixVideoAreaWithin(
            _inlineSize.value,
            videoSize,
          ),
        ),
      );
    }

    // Mirror the layout the default player widget uses — an `AspectRatio` whose
    // child is the raw `BetterPlayer`. The engine renders a video texture that
    // needs a real, bounded box; wrapping it in a `FittedBox` (as an earlier
    // version did) hands it a degenerate/unbounded box and the video never
    // paints. Controls are absent because the player was configured with
    // `showControls: false`, which is what makes this surface headless.
    // Records the size the player is drawn at here, for the PiP branch above to
    // scale down from. Sampled from the inline path because that is the only
    // place the inline layout exists.
    _inlineSize.sampleAfterFrame(_slots.keyFor(betterPlayer), () => !_pipActive);

    final aspectRatio = _effectiveAspectRatio;
    // Before the engine widget builds, which is when it reads it.
    fastPixSyncEngineAspectRatio(_betterPlayerController, aspectRatio);
    // A prerender sits beneath the active video at its size and fit.
    final showHidden = hidden != null && !identical(hidden, betterPlayer);
    if (showHidden) fastPixSyncEngineAspectRatio(hidden, aspectRatio);

    return ColoredBox(
      color: widget.backgroundColor,
      child: AspectRatio(
        key: _pipKey,
        aspectRatio: aspectRatio,
        // Always a `Stack`, never one only while a prerender is beneath: the
        // player's element is kept alive by its `GlobalKey`, but a tree that
        // gains and loses a level around it on a state change is a rebuild
        // this surface does not need.
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showHidden)
              _slots.slot(hidden, hidden: true, cover: widget.backgroundColor),
            video,
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    if (widget.placeholder != null) return widget.placeholder!(context);
    return ColoredBox(
      color: widget.backgroundColor,
      child: AspectRatio(aspectRatio: _effectiveAspectRatio),
    );
  }
}
