import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

import 'cast_service.dart';
import 'playback_config.dart';
import 'widgets/precache_panel.dart';
import 'widgets/preload_badge.dart';
import 'catalog.dart';
import 'models/demo_stream.dart';
import 'theme.dart';
import 'models/playback_queue.dart';
import 'widgets/cast_scrubber.dart';
import 'widgets/cast_sheets.dart';
import 'widgets/stream_form_sheet.dart';

/// Player screen, laid out the way a watch page is: video first, then title
/// and actions, then the detail below the fold.
class WatchScreen extends StatefulWidget {
  const WatchScreen({super.key, required this.queue});

  /// The playlist being played, and where in it playback starts.
  final PlaybackQueue queue;

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  final CastService _cast = CastService.instance;

  /// Held in State rather than read from the widget, because advancing to the
  /// next video swaps the source in place instead of pushing a new route —
  /// which is what lets the warmed player be adopted without a screen
  /// transition in between.
  late PlaybackQueue _queue = widget.queue;

  /// The video currently loaded.
  DemoStream get _stream => _queue.current;

  FastPixPlayerController? _controller;
  String? _streamUrl;
  bool _loading = true;

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
  final ValueNotifier<Duration?> _draggingPosition =
      ValueNotifier<Duration?>(null);

  /// Whether the volume panel is open over the casting surface.
  final ValueNotifier<bool> _showVolume = ValueNotifier<bool>(false);

  /// Whether playback rolls on to the next item when one finishes.
  bool _autoAdvance = true;

  @override
  void initState() {
    super.initState();
    Catalog.instance.markWatched(_stream);
    _warmUpcoming();
    _load();
  }

  /// Declare the rest of the playlist to the preload manager.
  ///
  /// A playlist is the best case this feature has: while the current video
  /// plays there is *minutes* of dwell, so the next item is reliably fully
  /// warm by the time the viewer reaches it — unlike a home screen, where a
  /// warm-up is racing a tap that may land in under a second.
  ///
  /// Safe to call on every advance. The manager reconciles declaratively:
  /// the item just consumed is gone, survivors are left alone, and only the
  /// newly-in-range item starts work.
  void _warmUpcoming() {
    FastPixPreloadManager.instance.preload(
      // Both directions. Warming only forward leaves the previous button as a
      // guaranteed cold start, and [PlaybackQueue.warmWindow] interleaves the
      // two so a small window still covers each way.
      _queue.warmWindow().map((stream) => stream.toDataSource()).toList(),
      // Must match what _load() passes to initialize(), or adoption is refused
      // on a fingerprint mismatch — silently, and it looks like a cold start.
      configuration: demoPlayerConfiguration(),
      // `player` here, `network` on the home screen — the difference is dwell.
      //
      // A warm-up only pays off if it finishes before the tap. Browsing a home
      // screen gives it a second or two; a playlist gives it the whole of the
      // current video, so the next item is reliably ready. That is the one
      // place a full player warm is worth a hardware decoder.
      //
      // `network` fetches the manifest and throws the bytes away — it warms
      // DNS and the CDN edge but builds nothing, so playback still constructs
      // a player and buffers. Only `player` produces something adoptable.
      strategy: FastPixPreloadStrategy.player,
      // Self-clamps to `maxPlayerWindow`: 1 on Android, 3 on iOS. Asking for
      // more is harmless — the manager drops the excess rather than queueing
      // it, because exceeding the device's decoder budget does not fail the
      // warm-up, it fails live playback.
      window: 4,
    );
  }

  /// Move to [index] in the playlist and start it.
  ///
  /// Swaps the source in place rather than pushing a route, so an adopted
  /// player is handed straight to the same screen with no transition in
  /// between — which is where the warm start actually shows.
  Future<void> _goTo(int index) async {
    if (index < 0 || index >= _queue.items.length || index == _queue.index) {
      return;
    }
    setState(() {
      _queue = _queue.at(index);
      _loading = true;
    });
    Catalog.instance.markWatched(_stream);
    // Load FIRST, re-declare the window afterwards.
    //
    // This order is the whole feature. `warmWindow()` deliberately excludes the
    // item now playing, so calling it before `_load()` evicts the very entry
    // `initialize()` is about to adopt — the warm is thrown away microseconds
    // before it would have paid off. Measured on device: nine warms completed,
    // every single play still reported COLD START.
    //
    // It is the rule the design brief states outright: release a warm on
    // eviction or teardown, never on player mount.
    await _load();
    _warmUpcoming();
  }

  Future<void> _playNext() => _goTo(_queue.index + 1);
  Future<void> _playPrevious() => _goTo(_queue.index - 1);

  Future<void> _load() async {
    // Tear down any previous playback before starting a new one. The tree must
    // stop pointing at the old controller *before* it is disposed: initialize()
    // is async, and a rebuild during that gap — cast discovery causes plenty —
    // would render a disposed controller.
    final previous = _controller;
    if (previous != null) {
      setState(() {
        _controller = null;
        _streamUrl = null;
      });
      await previous.dispose();
    }

    final dataSource = _stream.toDataSource();

    // workSpaceId / viewerId / beaconUrl feed the FastPix metrics SDK.
    //
    // Shared with home_screen's preload() call. A warmed player's engine
    // configuration is final, so adoption is gated on a fingerprint of these
    // values — building them separately here is how the two silently drift
    // apart and every adoption gets refused.
    final configuration = demoPlayerConfiguration();

    final controller = FastPixPlayerController();
    controller.addGlobalListener((event) {
      // DRM failures carry a code and an actionable message; everything else
      // is logged by type.
      if (event is FastPixPlayerDrmErrorEvent) {
        _cast.log('${event.type} [${event.code}] ${event.message}');
      } else {
        _cast.log(event.type);
      }
    });

    // Roll on to the next item. The SDK emits `finished` already — a playlist
    // is entirely the app's concern, so this is the only wiring autoplay
    // needs.
    controller.addEventListener(FastPixPlayerEventTypes.finished, (_) {
      if (!mounted || !_autoAdvance || !_queue.hasNext) return;
      // While casting, playback is on the receiver and advancing locally would
      // fight it.
      if (_cast.state.isCasting) return;
      _playNext();
    });

    try {
      await controller.initialize(
        dataSource: dataSource,
        configuration: configuration,
      );
    } on FastPixDrmException catch (error) {
      // The controller already emitted the error event; surface it here too so
      // a bad DRM setup is visible instead of an endless spinner.
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _streamUrl = null;
        _loading = false;
      });
      _snack('DRM: ${error.message}');
      return;
    }

    if (!mounted) return;
    setState(() {
      _controller = controller;
      _streamUrl = dataSource.url;
      _loading = false;
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _draggingVolume.dispose();
    _draggingPosition.dispose();
    _showVolume.dispose();
    _controller?.dispose();
    super.dispose();
  }

  // --- Cast actions -----------------------------------------------------

  Future<void> _pickDevice() async {
    final device = await showCastDevicePicker(context);
    if (device != null) await _startCasting(device);
  }

  Future<void> _startCasting(FastPixCastDevice device) async {
    final player = _controller;
    if (player == null) {
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

  Future<void> _stopCasting() async {
    final player = _controller;
    if (player == null) {
      await _cast.controller.disconnect();
      return;
    }
    await _cast.controller.stopCastingTo(player);
  }

  // --- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
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

  /// The video area, plus the back button overlaid on it.
  Widget _buildStage(bool isCasting) {
    final controller = _controller;
    // Null until the cast service has initialized, which is what keeps the
    // player's cast glyph hidden until there is something to cast to.
    final castController = _cast.isReady ? _cast.controller : null;

    return Stack(
      children: [
        Container(
          color: Colors.black,
          child: SafeArea(
            bottom: false,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The local player stays in the tree while casting, hidden
                  // rather than removed. Removing it disposes the platform
                  // controller and handing playback back then fails with "The
                  // video has not been initialized yet". It is paused, so there
                  // is no audio to double up.
                  Offstage(
                    offstage: isCasting,
                    child:
                        controller != null
                            ? FastPixPlayer(
                              // Carries the cast controls into better_player's fullscreen
                              // route. Fullscreen is a Navigator.push, so the
                              // sibling copy below is left behind on this page
                              // — which is why a viewer who went fullscreen and
                              // then started casting had no way to seek.
                              castOverlayBuilder:
                                  (_) => _cast.state.isCasting
                                      ? _buildCastingStage()
                                      : const SizedBox.shrink(),
                              controller: controller,
                              // The cast glyph rides in the player's own
                              // control bar, the way it does on YouTube,
                              // rather than as a chip under the video.
                              castController: castController,
                              onCastPressed: _pickDevice,
                            )
                            : const ColoredBox(color: Colors.black),
                  ),
                  if (isCasting) _buildCastingStage(),
                  if (_loading && !isCasting)
                    const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.accent,
                      ),
                    ),
                ],
              ),
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
              color:
                  _cast.activeTextTrackId == null
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
                onPressed:
                    playing ? _cast.controller.pause : _cast.controller.play,
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
                  _draggingPosition.value ?? positionSnapshot.data ?? Duration.zero;

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
                                  onChanged:
                                      (value) => setState(
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
                                  onCancel:
                                      () => setState(
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
                      onChanged:
                          (value) => _draggingVolume.value = value,
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
    final index = Catalog.instance.streams.indexOf(stream);
    setState(() {
      _queue = index < 0
          ? PlaybackQueue.single(stream)
          : PlaybackQueue(
              title: _queue.title,
              items: Catalog.instance.streams,
              index: index,
            );
      _loading = true;
    });
    await _load();

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
    final stream = _stream;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            stream.title,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (stream.isLive) ...[
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
          _ActionChip(
            icon: Icons.refresh,
            label: 'Reload',
            onTap: () {
              setState(() => _loading = true);
              _load();
            },
          ),
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
  /// The status pill on each upcoming card is the point: while the current
  /// video plays you can watch the next one go from `warming` to `warm`, and
  /// then tapping it starts with no spinner. That is the feature demonstrating
  /// itself, and it is the only place in this app where it is visible.
  Widget _buildUpNext() {
    if (_queue.items.length < 2) return const SizedBox.shrink();

    final upcoming = _queue.upcoming();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${_queue.title} · ${_queue.position}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: AppColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Previous',
                onPressed: _queue.hasPrevious ? _playPrevious : null,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              IconButton(
                tooltip: 'Next',
                onPressed: _queue.hasNext ? _playNext : null,
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Switch(
                value: _autoAdvance,
                onChanged: (value) => setState(() => _autoAdvance = value),
              ),
              const Text(
                'Autoplay next',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ],
          ),
          if (upcoming.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'End of playlist.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            )
          else
            SizedBox(
              height: 132,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: upcoming.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final stream = upcoming[i];
                  return UpNextCard(
                    playbackId: stream.playbackId,
                    title: stream.title,
                    label: 'Up next · ${i + 1}',
                    onTap: () => _goTo(_queue.index + 1 + i),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildDetails() {
    final stream = _stream;

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
          PrecachePanel(dataSource: stream.toDataSource()),
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
          _DetailRow('Host', stream.streamHost ?? 'stream.fastpix.com'),
          _DetailRow('Type', stream.isLive ? 'Live' : 'On demand'),
          _DetailRow('DRM', stream.drmEnabled ? 'Enabled' : 'Off'),
          _DetailRow(
            'External subtitles',
            stream.subtitles.isEmpty
                ? 'None — manifest tracks only'
                : stream.subtitles.map((s) => s.name).join(', '),
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
