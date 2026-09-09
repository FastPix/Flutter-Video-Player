import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';

import '../fastpix_player_controller.dart';
import '../models/fastpix_player_event.dart';
import '../models/fastpix_player_event_types.dart';
import '../utils/fastpix_video_size_watcher.dart';
import 'fastpix_pip_layout.dart';

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
/// Multiple surfaces may be bound to one controller. The surface tolerates being
/// built before the player is ready (it shows [placeholder] until then) and the
/// player being disposed while displayed (it falls back to [placeholder]).
class FastPixVideoSurface extends StatefulWidget {
  /// The controller whose video to render. Initialize it (via
  /// [FastPixPlayerController.initialize]) before or after mounting — the
  /// surface waits for readiness either way.
  final FastPixPlayerController controller;

  /// Aspect ratio of the surface.
  ///
  /// Defaults to 16:9. Pass a value to pin this surface to a fixed shape.
  ///
  /// The video is inscribed into the box by the player's own `fit` (from the
  /// player configuration, which defaults to [BoxFit.contain]); letterbox bars
  /// show as [backgroundColor].
  final double? aspectRatio;

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

  const FastPixVideoSurface({
    super.key,
    required this.controller,
    this.aspectRatio,
    this.backgroundColor = Colors.black,
    this.placeholder,
    this.pipBuilder,
  });

  @override
  State<FastPixVideoSurface> createState() => _FastPixVideoSurfaceState();
}

class _FastPixVideoSurfaceState extends State<FastPixVideoSurface> {
  BetterPlayerController? _betterPlayerController;
  bool _ready = false;

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

  /// The shape to lay the video box out at: the caller's pin, else 16:9.
  double get _effectiveAspectRatio => widget.aspectRatio ?? 16 / 9;

  bool _pipActive = false;

  /// Keeps the player the *same element* across a Picture-in-Picture
  /// transition.
  ///
  /// Entering PiP replaces this widget's layout, which re-parents the player.
  /// Without a `GlobalKey` Flutter treats a re-parented subtree as a new one:
  /// the old element is unmounted, and unmounting `BetterPlayer` disposes the
  /// engine controller — ending the very playback the PiP window exists to
  /// show. A global key moves the element instead of rebuilding it.
  final GlobalKey _playerKey = GlobalKey();

  /// How large the player was drawn while it was still on the page, so a PiP
  /// window can render a scaled copy of it. See [fastPixPipVideoBox].
  final FastPixInlinePlayerSize _inlineSize = FastPixInlinePlayerSize();

  @override
  void initState() {
    super.initState();
    _videoSize = FastPixVideoSizeWatcher(_onVideoSizeChanged);
    _pipActive = widget.controller.pip.isPipActiveOrPending;
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
    );
    widget.controller.registerPipSurfaceKey(_pipKey);
    // The controller can replace its source while this surface stays mounted —
    // a playlist advance does — so the engine player has to be re-read rather
    // than latched at mount. A surface still bound to the previous player is
    // rendering one that has been released.
    widget.controller.sourceGeneration.addListener(_onSourceChanged);
    _bind();
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

  void _onPipChanged(FastPixPlayerEvent _) {
    if (!mounted) return;
    setState(() => _pipActive = widget.controller.pip.isPipActiveOrPending);
  }

  @override
  void didUpdateWidget(FastPixVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.unregisterPipSurfaceKey(_pipKey);
    oldWidget.controller.sourceGeneration.removeListener(_onSourceChanged);
    oldWidget.controller.removeEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
    );
    _videoSize.watch(null);
    widget.controller.registerPipSurfaceKey(_pipKey);
    widget.controller.sourceGeneration.addListener(_onSourceChanged);
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
    );
    setState(() {
      _ready = false;
      _betterPlayerController = null;
      _pipActive = widget.controller.pip.isPipActiveOrPending;
    });
    _bind();
  }

  @override
  void dispose() {
    widget.controller.unregisterPipSurfaceKey(_pipKey);
    widget.controller.sourceGeneration.removeListener(_onSourceChanged);
    widget.controller.removeEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
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
    final betterPlayer = _betterPlayerController;
    if (!_ready || betterPlayer == null) {
      return _buildPlaceholder(context);
    }

    // The player stays at the same position in the tree for the life of this
    // surface, in and out of PiP. Replacing it — even with a wrapper — unmounts
    // its element, and that disposes the engine controller mid-playback, which
    // in a PiP session would end the very playback the window is showing.
    final Widget video = BetterPlayer(key: _playerKey, controller: betterPlayer);

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
      return build(
        context,
        fastPixPipVideoBox(
          context,
          video,
          inlinePlayerSize: _inlineSize.value,
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
    _inlineSize.sampleAfterFrame(_playerKey, () => !_pipActive);

    return ColoredBox(
      color: widget.backgroundColor,
      child: AspectRatio(
        key: _pipKey,
        aspectRatio: _effectiveAspectRatio,
        child: video,
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
