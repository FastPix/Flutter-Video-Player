import 'dart:async';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cast_service.dart';
import 'custom_ui/fastpix_custom_controls.dart';
import 'playback_config.dart';
import 'widgets/precache_panel.dart';
import 'widgets/playlist_rail.dart';
import 'widgets/preload_badge.dart';
import 'catalog.dart';
import 'models/demo_stream.dart';
import 'theme.dart';
import 'widgets/cast_scrubber.dart';
import 'widgets/cast_sheets.dart';
import 'widgets/stream_form_sheet.dart';

/// Player screen, laid out the way a watch page is: video first, then title
/// and actions, then the detail below the fold.
class WatchScreen extends StatefulWidget {
  const WatchScreen({
    super.key,
    required this.title,
    required this.items,
    this.startIndex = 0,
    this.resumeFrom,
  });

  /// Name of the playlist, shown above the up-next rail. The app's to know.
  final String title;

  /// The videos to play, in catalogue order.
  ///
  /// Handed to the player once, as a playlist, and never consulted again: from
  /// then on the *player* is the authority on order, on which item is active
  /// and on what is warmed next. This screen keeps no position of its own,
  /// because an automatic advance moves the player's index without asking the
  /// app — and an app-held copy would silently drift out of step with what is
  /// on screen the first time a video ends.
  ///
  /// [DemoStream.toDataSource] is the only seam between the app's catalogue
  /// type and the SDK's source type; past [setPlaylist] no `DemoStream` is
  /// read again.
  final List<DemoStream> items;

  /// Where playback starts. The player owns the position from then on.
  final int startIndex;

  /// Where in the *first* item to pick up, when the viewer is returning to
  /// something they had already started. Null starts at the beginning.
  ///
  /// Applied as a seek once the engine reports a duration, not through
  /// `FastPixPlayerDataSource.startAt`: that field is part of the preload
  /// fingerprint, so setting it would refuse the warmed player this screen
  /// exists to demonstrate.
  final Duration? resumeFrom;

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen>
    with WidgetsBindingObserver {
  final CastService _cast = CastService.instance;

  /// Whether the player has already been handed the cast controller.
  bool _castAttached = false;

  // A stable key so the surface (and its video texture) is the SAME element
  // whether it is drawn inside the normal page, the PiP layout, or the
  // app-owned fullscreen layout. Without it, switching layouts would tear down
  // and rebuild the player, causing a flicker/black frame.
  final GlobalKey _surfaceKey = GlobalKey();

  // App-owned fullscreen. Fullscreen is handled here (rotate + fill the
  // screen) instead of through the engine's fullscreen route, because the
  // default skin — and with it that route — is gone. Owning it also keeps a
  // PiP session from tearing a route down, and mirrors how the iOS SDK keeps
  // PiP and fullscreen independent.
  bool _appFullscreen = false;

  /// Tells the native side what this screen supports, so iOS has the answer
  /// before it asks for it as the app comes back to the foreground.
  static const MethodChannel _orientationChannel =
      MethodChannel('fastpix_demo/orientation');

  void _toggleFullscreen() {
    setState(() => _appFullscreen = !_appFullscreen);
    _applyPresentation();
  }

  /// Put the device into the presentation this screen's fullscreen state asks
  /// for. Idempotent, so it can be re-asserted freely.
  void _applyPresentation() {
    // Native first: this is the answer iOS uses at presentation time, and it
    // has to be in place *before* the app leaves, not after it comes back.
    _orientationChannel
        .invokeMethod<void>('set', {'fullscreen': _appFullscreen})
        .catchError((Object error) {
      debugPrint('[FastPixOrientation] native call FAILED: $error');
    });

    if (_appFullscreen) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations(
        const [DeviceOrientation.portraitUp],
      );
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-assert the presentation across a trip out of the app — which, with
    // automatic Picture-in-Picture on, is a trip a viewer takes *from*
    // fullscreen. iOS re-evaluates orientation as it foregrounds, so a lock
    // set only once has already lost by the time `resumed` arrives.
    if (_appFullscreen &&
        (state == AppLifecycleState.resumed ||
            state == AppLifecycleState.inactive)) {
      _applyPresentation();
    }
  }

  /// One controller for the whole playlist.
  ///
  /// Advancing swaps the source inside it rather than building a new one,
  /// which is what lets a warmed player be adopted with no screen transition
  /// in between — and what keeps analytics, the widget tree and the engine
  /// player from being rebuilt per item.
  final FastPixPlayerController _controller = FastPixPlayerController();

  /// The screen holds no playlist position of its own: [PlaylistRail] renders
  /// from the player's own state stream, and this subscription exists only to
  /// record what has been watched and to refresh the text around the video.
  StreamSubscription<FastPixPlaylistState>? _playlistSubscription;

  bool _loading = true;

  /// Watches playback so the catalogue can remember where the viewer got to,
  /// and so a resume can be applied the moment a duration exists.
  StreamSubscription<FastPixPlaybackState>? _playbackSubscription;

  /// Where to pick up in the current item, until it has been applied. Cleared
  /// once the seek has happened, so it is a one-shot.
  Duration? _pendingResume;

  /// When the catalogue was last told where playback had reached. Progress is
  /// written on a throttle: the tick fires several times a second and each
  /// write persists to disk and rebuilds the home screen behind this one.
  DateTime _lastProgressWrite = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _progressInterval = Duration(seconds: 5);

  /// The source now playing, which is also the authority for everything shown
  /// about it: title, description, host, DRM, subtitles, URL.
  FastPixPlayerDataSource? get _current =>
      _controller.currentPlaylistItem ?? _controller.dataSource;

  /// The playback URL, or null when the source cannot build one (an invalid
  /// DRM setup throws rather than returning a broken URL).
  String? get _streamUrl {
    try {
      return _current?.url;
    } on FastPixDrmException {
      return null;
    }
  }

  // These three drive the cast overlay, which is rendered in TWO places: as a
  // sibling of the player inline, and inside better_player's fullscreen route
  // via `castOverlayBuilder`. A `setState` here rebuilds this page but not that
  // route, so the fullscreen copy would freeze mid-drag. ValueNotifiers let
  // each copy rebuild itself wherever it is mounted.

  /// Slider position while the user is dragging it, or null when they are not.
  ///
  /// Held separately so the thumb follows the finger without pushing every
  /// frame to the receiver.
  final ValueNotifier<double?> _draggingVolume = ValueNotifier<double?>(null);

  /// Scrub position while the user is dragging, held for the same reason.
  final ValueNotifier<Duration?> _draggingPosition = ValueNotifier<Duration?>(
    null,
  );

  /// Whether the volume panel is open over the casting surface.
  final ValueNotifier<bool> _showVolume = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Attach the app's cast controller so the custom transport's cast glyph
    // (and `toggleCast()`/`isCasting`) work. The app owns its lifecycle.
    //
    // Listened for rather than only read once: the service initialises
    // asynchronously, so a screen that opens first would otherwise never get a
    // controller — and the cast glyph, which draws nothing without one, would
    // stay missing for the whole session with no error anywhere.
    _attachCastWhenReady();
    _cast.addListener(_attachCastWhenReady);
    // Leaving the app mid-video should leave the video playing in a small
    // window rather than pausing it. Works on both platforms; the SDK arms
    // whichever mechanism the platform offers, and reports an error rather
    // than staying silent if it cannot. Because PiP is entered through the
    // SDK's own manager (never the engine's built-in button), the
    // `isPipActiveOrPending` guard protects it on Android — no auto-pause.
    _controller.pip.autoEnterOnBackground = true;
    // The player publishes a snapshot on every change of the active item —
    // an automatic advance included — so this is the whole of the screen's
    // playlist bookkeeping.
    _playlistSubscription = _controller.playlistStateStream.listen((state) {
      if (!mounted) return;
      final playbackId = state.item?.playbackId;
      if (playbackId != null) Catalog.instance.markWatchedId(playbackId);
      setState(() {});
    });
    _pendingResume = widget.resumeFrom;
    _playbackSubscription = _controller.playbackStateStream.listen(
      _onPlaybackState,
    );
    // Rebuild when a PiP window opens or closes. On Android this whole page
    // *is* the window, so what it renders has to change — see `build`.
    _controller.addEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
    );
    _controller.addGlobalListener(_onPlayerEvent);
    // The demo rolls on by default, as it did before this moved into the SDK.
    _controller.autoPlayNext = true;
    _load();
  }

  /// Apply a pending resume, then record progress on a throttle.
  ///
  /// The resume waits for a duration rather than firing straight after the
  /// load: the engine reports one only once it actually has the media, and
  /// seeking before then throws. This is the same "wait for the value to
  /// arrive, then do the work once" latch the SDK uses for track readiness and
  /// skip-segment validation.
  void _onPlaybackState(FastPixPlaybackState state) {
    if (!mounted || state.duration <= Duration.zero) return;

    final resume = _pendingResume;
    if (resume != null) {
      _pendingResume = null;
      if (resume < state.duration) unawaited(_controller.seekTo(resume));
      return;
    }

    final now = DateTime.now();
    if (now.difference(_lastProgressWrite) < _progressInterval) return;
    _lastProgressWrite = now;
    _recordProgress(state.position, state.duration);
  }

  /// Remember where the viewer is in whatever is playing now.
  void _recordProgress(Duration position, Duration duration) {
    final playbackId = _current?.playbackId;
    if (playbackId == null || position <= Duration.zero) return;
    Catalog.instance.recordProgress(playbackId, position, duration);
  }

  void _onPlayerEvent(FastPixPlayerEvent event) {
    // A finished item has no position worth returning to, so it offers a fresh
    // play next time rather than resuming at the credits. The playback ID comes
    // off the event itself — every event now carries the item it describes,
    // which matters here because an automatic advance has already moved the
    // playlist on by the time this is handled.
    if (event.type == FastPixPlayerEventTypes.finished) {
      final playbackId = event.data?['playbackId'];
      if (playbackId is String) Catalog.instance.clearProgress(playbackId);
    }

    // DRM failures carry a code and an actionable message; everything else is
    // logged by type. Both now carry the item they describe, so a playlist's
    // event log says which video each line belongs to.
    if (event is FastPixPlayerDrmErrorEvent) {
      _cast.log('${event.type} [${event.code}] ${event.message}');
      if (mounted) _snack('DRM: ${event.message}');
    } else {
      _cast.log(event.type);
    }
  }

  /// Hand the whole playlist to the player.
  ///
  /// What the app no longer does, because the SDK does it: track which item is
  /// playing, move between items, wire autoplay to the `finished` event, and
  /// declare the warm window after each load — including the two rules that
  /// were measured on device, that the window covers both directions and is
  /// declared only after the new item has loaded.
  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await _controller.setPlaylist(
        <FastPixPlayerDataSource>[
          for (final stream in widget.items) stream.toDataSource(),
        ],
        startIndex: widget.startIndex,
        // workSpaceId / viewerId / beaconUrl feed the FastPix metrics SDK.
        //
        // Shared with home_screen's preload() call. A warmed player's engine
        // configuration is final, so adoption is gated on a fingerprint of
        // these values — building them separately is how the two silently
        // drift apart and every adoption gets refused.
        configuration: demoPlayerConfiguration(),
      );
    } on FastPixPlaylistException catch (error) {
      if (mounted) _snack(error.message);
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  /// Reload whatever is playing, without moving the playlist.
  Future<void> _reload() async {
    final current = _current;
    if (current == null) return;
    setState(() => _loading = true);
    await _controller.loadPlaybackId(current);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _goTo(int index) async {
    // Moving deliberately means the resume no longer applies.
    _pendingResume = null;
    setState(() => _loading = true);
    await _controller.jumpTo(index);
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// A PiP window opened or closed: what this page renders depends on it.
  void _onPipChanged(FastPixPlayerEvent event) {
    if (mounted) setState(() {});
  }

  /// Hand the player the cast controller as soon as the service has one.
  ///
  /// Idempotent, and stops listening once it has attached: attaching twice
  /// would leave the player holding a controller the service may replace.
  void _attachCastWhenReady() {
    if (_castAttached || !_cast.isReady) return;
    _castAttached = true;
    _controller.attachCastController(_cast.controller);
    _cast.removeListener(_attachCastWhenReady);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cast.removeListener(_attachCastWhenReady);
    // Leave the device the way we found it if we exit while still fullscreen.
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _draggingVolume.dispose();
    _draggingPosition.dispose();
    _showVolume.dispose();
    // One last write, so leaving the screen mid-video records where it was
    // rather than losing up to five seconds of it.
    //
    // Deferred to after the frame, and reading the values *now*: this runs
    // during the tree teardown, and `recordProgress` notifies the catalogue,
    // which rebuilds the home screen underneath. Notifying from here throws
    // "setState() or markNeedsBuild() called when widget tree was locked" —
    // once per listener, every time the viewer leaves the player.
    final position = _controller.position;
    final duration = _controller.duration;
    final playbackId = _current?.playbackId;
    if (playbackId != null &&
        position > Duration.zero &&
        duration > Duration.zero) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Catalog.instance.recordProgress(playbackId, position, duration);
      });
    }
    _playbackSubscription?.cancel();
    _playlistSubscription?.cancel();
    _controller.removeEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onPipChanged,
    );
    _controller.removeGlobalListener(_onPlayerEvent);
    _controller.dispose();
    super.dispose();
  }

  // --- Cast actions -----------------------------------------------------

  Future<void> _pickDevice() async {
    final device = await showCastDevicePicker(context);
    if (device != null) await _startCasting(device);
  }

  Future<void> _startCasting(FastPixCastDevice device) async {
    final player = _controller;
    if (player.betterPlayerController == null) {
      _snack('Wait for the video to load before casting it');
      return;
    }

    try {
      final started = await _cast.controller.startCastingFrom(player, device);
      if (!started) {
        _snack(
          _cast.lastError?.message ?? 'Could not connect to ${device.name}',
        );
      }
    } on UnsupportedError catch (error) {
      // DRM streams are refused here unless a custom receiver can request a
      // license — Chromecast receivers speak Widevine only.
      _snack(error.message?.toString() ?? 'This stream cannot be cast');
    } catch (error) {
      _snack('Casting failed: $error');
    }
  }

  Future<void> _stopCasting() => _cast.controller.stopCastingTo(_controller);

  // --- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // On Android a PiP window is this activity's own window shrunk to a
    // thumbnail, so everything this page draws — app bar, up-next rail, detail
    // rows — is asked to lay out at around 192x108. It cannot: the log fills
    // with `BoxConstraints forces an infinite height`, a failed `Stack`
    // assertion and a `RenderFlex overflowed`, and a tree that throws during
    // layout paints nothing. That is the black PiP window.
    //
    // The bare surface fills the PiP window; the Scaffold chrome around it is
    // the host's to collapse, which is what this does. iOS floats a separate
    // system window and leaves the page alone, so the SDK's
    // `fastPixHostTreeBecomesPipWindow` answers the platform question.
    if (_controller.pip.isPipActiveOrPending && fastPixHostTreeBecomesPipWindow) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: FastPixVideoSurface(key: _surfaceKey, controller: _controller),
        ),
      );
    }

    // App-owned fullscreen: fill the (now landscape) screen with the video and
    // stack the controls over it. No app bar, no engine route — so a PiP
    // session entered from here keeps this layout on return.
    if (_appFullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: ListenableBuilder(
          listenable: _cast,
          builder: (context, _) {
            final isCasting = _cast.state.isCasting;
            return Stack(
              fit: StackFit.expand,
              children: [
                // Kept in the tree (offstage) while casting for the same reason
                // as inline: removing the surface disposes the platform
                // controller and handing playback back then fails.
                Offstage(
                  offstage: isCasting,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Center(
                        child: FastPixVideoSurface(
                          key: _surfaceKey,
                          controller: _controller,
                        ),
                      ),
                      Positioned.fill(child: _buildControls()),
                    ],
                  ),
                ),
                if (isCasting) _buildCastingStage(),
              ],
            );
          },
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: ListenableBuilder(
        listenable: _cast,
        builder: (context, _) {
          final isCasting = _cast.state.isCasting;

          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _buildStage(isCasting)),
              SliverToBoxAdapter(child: _buildMeta(isCasting)),
              SliverToBoxAdapter(child: _buildActions()),
              SliverToBoxAdapter(child: _buildUpNext()),
              SliverToBoxAdapter(child: _buildDetails()),
            ],
          );
        },
      ),
    );
  }

  /// The app's own transport over the headless surface. Reused inline and in
  /// the app-owned fullscreen layout, both stacked over the same surface.
  Widget _buildControls() => FastPixCustomControls(
        controller: _controller,
        isFullscreen: _appFullscreen,
        onToggleFullscreen: _toggleFullscreen,
        // The cast glyph opens the app's device picker rather than a bare
        // toggle, matching the richer cast overlay this screen shows.
        onCastPressed: _pickDevice,
      );

  /// The video area, plus the back button overlaid on it.
  Widget _buildStage(bool isCasting) {
    return Stack(
      children: [
        Container(
          color: Colors.black,
          child: SafeArea(
            bottom: false,
            // No aspect ratio pinned here: the surface sizes itself to the
            // video, so a vertical source fills a portrait box instead of
            // being letterboxed inside a landscape one. The Stack takes its
            // size from whichever child is showing — the player, or the cast
            // stage while casting, which has no video to measure.
            child: Stack(
              children: [
                // The local surface stays in the tree while casting, hidden
                // rather than removed. Removing it disposes the platform
                // controller and handing playback back then fails with "The
                // video has not been initialized yet". It is paused, so there
                // is no audio to double up.
                Offstage(
                  offstage: isCasting,
                  // The headless surface with the app-drawn transport stacked
                  // over it — no default skin, so no pause-on-drag and no
                  // engine PiP button.
                  child: Stack(
                    children: [
                      FastPixVideoSurface(
                        key: _surfaceKey,
                        controller: _controller,
                      ),
                      Positioned.fill(child: _buildControls()),
                    ],
                  ),
                ),
                if (isCasting)
                  AspectRatio(aspectRatio: 16 / 9, child: _buildCastingStage()),
                if (_loading && !isCasting)
                  const Positioned.fill(
                    child: Center(
                      child: CircularProgressIndicator(color: AppColors.accent),
                    ),
                  ),
              ],
            ),
          ),
        ),
        SafeArea(
          bottom: false,
          child: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            style: IconButton.styleFrom(
              backgroundColor: Colors.black45,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.maybePop(context),
          ),
        ),
      ],
    );
  }

  /// Replaces the video surface while a receiver is playing.
  ///
  /// Laid out as the player itself is — transport in the middle, scrubber
  /// along the bottom, icons in the top bar — because the receiver is only a
  /// different screen, not a different thing to operate. The local player, and
  /// with it its own controls, is offstage for the duration.
  /// The remote-control surface shown in place of the video while casting.
  ///
  /// Rendered twice: inline as a sibling of the offstage player, and inside
  /// better_player's fullscreen route via [FastPixPlayer.castOverlayBuilder].
  /// Only one is ever visible — inline the player is offstage, and in
  /// fullscreen this page's route is buried underneath.
  ///
  /// Listens to its own notifiers rather than relying on this page's
  /// `setState`, which does not reach the fullscreen route.
  Widget _buildCastingStage() {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        _cast,
        _showVolume,
        _draggingVolume,
        _draggingPosition,
      ]),
      builder: (context, _) => _buildCastingStageBody(),
    );
  }

  Widget _buildCastingStageBody() {
    final device = _cast.connectedDevice;

    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),

        // What the video would be showing: where it is playing.
        Align(
          alignment: const Alignment(0, -0.45),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cast_connected,
                size: 32,
                color: AppColors.accent,
              ),
              const SizedBox(height: 8),
              Text(
                'Playing on ${device?.name ?? 'receiver'}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),

        _buildRemoteTransport(),
        _buildRemoteScrubber(),
        _buildCastingTopBar(),
        if (_showVolume.value) _buildRemoteVolume(),
      ],
    );
  }

  /// The top bar of the casting surface, matching the player's own.
  Widget _buildCastingTopBar() {
    return Align(
      alignment: Alignment.topRight,
      child: SizedBox(
        height: 48,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Volume',
              iconSize: 22,
              color: _showVolume.value ? AppColors.accent : Colors.white,
              icon: Icon(
                _cast.controller.remoteVolume == 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
              ),
              onPressed: () => _showVolume.value = !_showVolume.value,
            ),
            // Subtitles on the receiver are their own control: the player's CC
            // menu drives the local player, which is paused while casting.
            IconButton(
              tooltip: 'Subtitles',
              iconSize: 22,
              color: _cast.activeTextTrackId == null
                  ? Colors.white
                  : AppColors.accent,
              icon: const Icon(Icons.closed_caption_rounded),
              onPressed: () => showCastSubtitleSheet(context),
            ),
            FastPixCastButton(
              controller: _cast.controller,
              onPressed: _stopCasting,
            ),
          ],
        ),
      ),
    );
  }

  /// Skip back, play/pause and skip forward, centred as the player has them.
  Widget _buildRemoteTransport() {
    return Align(
      // Kept clear of the bottom bar: at 16:9 on a phone the surface is only
      // ~210dp tall, and a transport row sitting any lower ran into the
      // scrubber's touch band — which is what made aiming at skip-forward land
      // on the bar and seek somewhere unrelated instead of skipping ten
      // seconds.
      alignment: const Alignment(0, 0.15),
      child: StreamBuilder<bool>(
        stream: _cast.controller.isRemotePlayingStream,
        initialData: _cast.controller.isRemotePlaying,
        builder: (context, snapshot) {
          final playing = snapshot.data ?? false;

          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                iconSize: 30,
                color: Colors.white,
                icon: const Icon(Icons.replay_10_rounded),
                onPressed: () => _seekBy(const Duration(seconds: -10)),
              ),
              const SizedBox(width: 12),
              // One button that toggles, not a play and a pause sitting side
              // by side: only one of them was ever the thing to press.
              IconButton(
                iconSize: 44,
                color: Colors.white,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
                onPressed: playing
                    ? _cast.controller.pause
                    : _cast.controller.play,
              ),
              const SizedBox(width: 12),
              IconButton(
                iconSize: 30,
                color: Colors.white,
                icon: const Icon(Icons.forward_10_rounded),
                onPressed: () => _seekBy(const Duration(seconds: 10)),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Position, scrub bar and length along the bottom of the surface.
  ///
  /// The bar drags to seek, but only when the drag starts on the bar itself —
  /// see [CastScrubber], which replaced a Material `Slider` here because a
  /// `Slider` claims its whole parent box and swallowed touches meant for the
  /// transport row above it.
  ///
  /// Dragging is held locally and only sent on release: every change is a
  /// network round-trip, so one per frame floods the session and makes the
  /// thumb fight the positions coming back.
  Widget _buildRemoteScrubber() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: StreamBuilder<Duration?>(
        stream: _cast.controller.remoteDurationStream,
        initialData: _cast.controller.remoteDuration,
        builder: (context, durationSnapshot) {
          final duration = durationSnapshot.data;

          return StreamBuilder<Duration>(
            stream: _cast.controller.remotePositionStream,
            initialData: _cast.controller.remotePosition,
            builder: (context, positionSnapshot) {
              final position =
                  _draggingPosition.value ??
                  positionSnapshot.data ??
                  Duration.zero;

              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Row(
                  children: [
                    Text(_format(position), style: _timeStyle),
                    Expanded(
                      child:
                          // A live stream reports no length, so there is no
                          // proportion to draw and nowhere to drag to.
                          duration == null
                          ? const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                'LIVE',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.8,
                                  color: AppColors.accent,
                                ),
                              ),
                            )
                          : Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: CastScrubber(
                                position: position,
                                duration: duration,
                                onChanged: (value) => setState(
                                  () => _draggingPosition.value = value,
                                ),
                                onChangeEnd: () {
                                  final target = _draggingPosition.value;
                                  if (target == null) return;
                                  // Seek first: the controller publishes the
                                  // target on to remotePositionStream
                                  // straight away, so by the time this
                                  // rebuild runs the stream already reads the
                                  // new position and dropping the drag value
                                  // cannot bounce the thumb backwards.
                                  _cast.controller.seekTo(target);
                                  _draggingPosition.value = null;
                                },
                                onCancel: () => setState(
                                  () => _draggingPosition.value = null,
                                ),
                              ),
                            ),
                    ),
                    Text(
                      duration == null ? '--:--' : _format(duration),
                      style: _timeStyle,
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// Receiver volume, shown over the surface while the volume icon is on.
  ///
  /// A panel rather than a permanent row: at 16:9 there is only room for one
  /// bar along the bottom, and the scrubber has the better claim to it.
  Widget _buildRemoteVolume() {
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 48, right: 8),
        child: Container(
          width: 190,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(20),
          ),
          child: StreamBuilder<double>(
            stream: _cast.controller.remoteVolumeStream,
            initialData: _cast.controller.remoteVolume,
            builder: (context, snapshot) {
              final volume = _draggingVolume.value ?? snapshot.data ?? 1.0;

              return Row(
                children: [
                  Icon(
                    volume == 0
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                  Expanded(
                    child: Slider(
                      value: volume,
                      onChanged: (value) => _draggingVolume.value = value,
                      onChangeEnd: (value) {
                        _draggingVolume.value = null;
                        _cast.controller.setVolume(value);
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Skip on the receiver. The controller owns the arithmetic, because only it
  /// knows which reported positions are trustworthy — computing it from the
  /// plugin's raw position stream is what produced skips that landed nowhere
  /// near ten seconds away.
  /// Add a stream to the catalog from the player screen.
  ///
  /// Nothing is interrupted. A Cast session is owned by the controller rather
  /// than by this screen, so the television keeps playing while the sheet is
  /// open; local playback continues underneath it too.
  ///
  /// The new stream lands in the catalog and can be played next. It does not
  /// replace what is on screen, which would be a surprising thing for an "add"
  /// action to do — the snackbar offers that as an explicit choice instead.
  Future<void> _addStream() async {
    final stream = await StreamFormSheet.show(context);
    if (stream == null || !mounted) return;

    Catalog.instance.save(stream);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Added ${stream.title}'),
        action: SnackBarAction(
          label: 'Cast it',
          onPressed: () => _castInstead(stream),
        ),
      ),
    );
  }

  /// Point the receiver at [stream], keeping the session open.
  ///
  /// Swaps the queue to the new stream and reloads, rather than tearing the
  /// session down and building a new one — reconnecting drops the viewer back
  /// to a device picker for a receiver they are already connected to.
  Future<void> _castInstead(DemoStream stream) async {
    setState(() => _loading = true);
    // Loading a source directly: the player moves its own index to it when the
    // stream is already one of the playlist's items, and reports no position
    // when it is not. Either way the app does not track one.
    await _controller.loadPlaybackId(stream.toDataSource());
    if (mounted) setState(() => _loading = false);

    // loadMedia takes the data source, not the local player: the receiver
    // fetches the stream itself and never sees the local controller.
    if (mounted && _cast.state.isCasting) {
      await _cast.controller.loadMedia(stream.toDataSource());
    }
  }

  void _seekBy(Duration delta) => _cast.controller.seekBy(delta);

  static const TextStyle _timeStyle = TextStyle(
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    fontSize: 11,
    color: Colors.white,
  );

  Widget _buildMeta(bool isCasting) {
    final stream = _current;
    if (stream == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            stream.title ?? stream.playbackId,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (stream.streamType == StreamType.live) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'LIVE',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  isCasting
                      ? 'Casting · ${stream.playbackId}'
                      : stream.playbackId,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The chip row under the title, in the YouTube idiom.
  ///
  /// Casting and receiver subtitles are deliberately absent: both live on the
  /// video surface now, where a viewer looks for them.
  Widget _buildActions() {
    return SizedBox(
      height: 76,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        children: [
          _ActionChip(icon: Icons.refresh, label: 'Reload', onTap: _reload),
          // Adding a stream is available here as well as on the home screen,
          // so it is reachable from anywhere in the app. It matters most while
          // casting: the receiver keeps playing regardless of which screen is
          // in front, so there is no reason to make the viewer leave the
          // player to add something.
          _ActionChip(
            icon: Icons.playlist_add_rounded,
            label: 'Add stream',
            onTap: _addStream,
          ),
          _ActionChip(
            icon: Icons.bug_report_outlined,
            label: 'Diagnostics',
            onTap: () => showCastDiagnosticsSheet(context),
          ),
        ],
      ),
    );
  }

  /// Playlist position, transport, and what is coming next.
  ///
  /// Drawn by [PlaylistRail] from the player alone — no second ordered list,
  /// and no index held here. The status pill on each upcoming card is the
  /// demonstration: while the current video plays you can watch the next one
  /// go from `warming` to `warm`, and then tapping it starts with no spinner.
  Widget _buildUpNext() => PlaylistRail(
    controller: _controller,
    title: widget.title,
    onSelect: _goTo,
  );

  Widget _buildDetails() {
    final stream = _current;
    if (stream == null) return const SizedBox.shrink();
    final drm = stream.drmConfiguration;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          const SizedBox(height: 16),

          // Warming is invisible by design — both paths render the same video
          // — so this badge is the only thing that distinguishes a working
          // preload from a broken one. Tap it for the full event feed.
          // Precaching writes disk for a LATER session; preloading warms
          // memory for the next tap. Shown together so the two are not
          // mistaken for one feature.
          PrecachePanel(dataSource: stream),
          const SizedBox(height: 10),

          Row(
            children: [
              WarmStartBadge(playbackId: stream.playbackId),
              const Spacer(),
              TextButton.icon(
                onPressed: () => PreloadDebugSheet.show(context),
                icon: const Icon(Icons.list_alt_rounded, size: 16),
                label: const Text('Preload events'),
              ),
            ],
          ),
          const SizedBox(height: 12),

          _DetailRow('Playback ID', stream.playbackId),
          _DetailRow('Host', stream.customDomain ?? 'stream.fastpix.com'),
          _DetailRow(
            'Type',
            stream.streamType == StreamType.live ? 'Live' : 'On demand',
          ),
          _DetailRow('DRM', stream.drmEnabled ? 'Enabled' : 'Off'),
          if (stream.drmEnabled)
            _DetailRow('DRM host', drm?.customDomain ?? 'api.fastpix.com'),
          // Licence acquisition is metered and sits on the tap path, and
          // preloading multiplies it: a warm window of three protected titles
          // acquires three licences for videos nobody has asked for yet.
          // Playback looks identical however many were spent, so the count is
          // the only thing that can say.
          if (stream.drmEnabled)
            _DetailRow(
              'Licences armed (session)',
              '${FastPixDrmLog.total} total · '
                  '${FastPixDrmLog.countsByPlaybackId[stream.playbackId] ?? 0} '
                  'for this video · '
                  '${FastPixDrmLog.countsByReason[FastPixDrmLog.reasonPreload] ?? 0}'
                  ' from preload',
            ),
          _DetailRow(
            'External subtitles',
            (stream.subtitles?.isEmpty ?? true)
                ? 'None — manifest tracks only'
                : stream.subtitles!.map((track) => track.name).join(', '),
          ),
          _DetailRow(
            'Skip segments',
            (stream.skipSegments?.isEmpty ?? true)
                ? 'None'
                : stream.skipSegments!
                      .map((segment) => segment.type.value)
                      .join(', '),
          ),
          if (_streamUrl != null) ...[
            const SizedBox(height: 16),
            const Text(
              'Stream URL',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(
              _streamUrl!,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ],
        ],
      ),
    );
  }

  String _format(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Material(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 17,
                  color: enabled ? Colors.white : AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: enabled ? Colors.white : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
