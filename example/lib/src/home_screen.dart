import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

import 'cast_service.dart';
import 'catalog.dart';
import 'models/demo_stream.dart';
import 'models/playback_queue.dart';
import 'playback_config.dart';
import 'theme.dart';
import 'watch_screen.dart';
import 'widgets/cast_sheets.dart';
import 'widgets/poster_card.dart';
import 'widgets/preload_badge.dart';
import 'widgets/stream_form_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Catalog _catalog = Catalog.instance;
  final CastService _cast = CastService.instance;

  @override
  void initState() {
    super.initState();
    _cast.start();
    _catalog.addListener(_warmUpcoming);
    // Deferred to after the first frame, because _warmUpcoming reads
    // ModalRoute.of(context) and an inherited-widget lookup is illegal during
    // initState — the element has no dependencies registered yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _warmUpcoming();
    });

    // While casting, a locally warmed player would spend a decoder on playback
    // that is going to happen on the receiver instead.
    // `controller` asserts when discovery has not started yet, so the ready
    // check has to come first.
    FastPixPreloadManager.instance.isCastActive =
        () => _cast.isReady && _cast.controller.isConnected;
  }

  @override
  void dispose() {
    _catalog.removeListener(_warmUpcoming);
    super.dispose();
  }

  /// Declare what the viewer is most likely to open next.
  ///
  /// Idempotent and safe to call on every catalog change: entries already warm
  /// are left alone, entries that dropped out are cancelled, and only new ones
  /// start work.
  ///
  /// Uses [FastPixPreloadStrategy.network], which allocates no decoder and is
  /// therefore safe across a whole visible list. `FastPixPreloadStrategy
  /// .player` is what enables true adoption, and it does work — measured on
  /// device at ~1.36 s to warm a real player, which then adopts with a first
  /// frame already decodable.
  ///
  /// It is still not the right choice *here*, and the reason is dwell rather
  /// than doubt. A browse screen gives a warm a second or two before the tap,
  /// so a 1.36 s warm is a coin toss, and each entry holds a hardware decoder
  /// while it gambles. The watch screen uses `player` precisely because a
  /// playlist gives it the whole of the current video instead.
  void _warmUpcoming() {
    // Only while this screen is the one being looked at.
    //
    // `preload()` is declarative: it reconciles the *whole* window, so whoever
    // calls it last wins and everything the other caller warmed is evicted.
    // That is correct for a single owner and wrong for two — and this screen
    // stays mounted underneath the watch screen, so its catalog listener kept
    // firing and kept destroying the warms the player was about to adopt.
    //
    // Measured: the watch screen would warm the next episode, this call would
    // evict it ~200 ms later, and playback reported COLD START every time.
    // Guarded because this is also a Catalog listener, and a notification can
    // land in the same frame the screen is being torn down.
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    FastPixPreloadManager.instance.preload(
      _catalog.streams.map((stream) => stream.toDataSource()).toList(),
      // Must be the same configuration watch_screen passes to initialize(),
      // or adoption is refused on a fingerprint mismatch — silently.
      configuration: demoPlayerConfiguration(),
      strategy: FastPixPreloadStrategy.network,
      window: 3,
    );
  }

  Future<void> _addStream({DemoStream? initial}) async {
    final stream = await StreamFormSheet.show(context, initial: initial);
    if (stream != null) _catalog.save(stream);
  }

  /// Open [stream] as part of a playlist rather than on its own.
  ///
  /// The catalog is the playlist: tapping any title plays it and everything
  /// after it, so there is always a "next". That is what gives preloading
  /// realistic conditions — the next item warms for the whole duration of the
  /// current one, instead of racing a tap that may land in under a second.
  ///
  /// [items] lets a rail play as its own playlist ("Live now", "On demand")
  /// rather than the whole catalog.
  void _open(DemoStream stream, {List<DemoStream>? items, String? title}) {
    final list = (items == null || items.isEmpty) ? _catalog.streams : items;
    final index = list.indexOf(stream);

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WatchScreen(
          queue: index < 0
              // Not part of the list it was opened from — play it alone.
              ? PlaybackQueue.single(stream)
              : PlaybackQueue(
                  title: title ?? 'All videos',
                  items: list,
                  index: index,
                ),
        ),
      ),
    );
  }

  Future<void> _showStreamMenu(DemoStream stream) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _addStream(initial: stream);
                },
              ),
              // Precaching is triggered from here, not the watch screen,
              // because opening a title creates a player — and ExoPlayer fills
              // its buffer on prepare whether or not it is playing, writing
              // ~100 MB of segments into the same shared cache. Those segments
              // are unreadable later (their URLs are re-signed on every
              // manifest resolution) but they still evict the small, stable
              // playlist entry precaching writes.
              ListTile(
                leading: const Icon(Icons.download_for_offline_outlined),
                title: const Text('Precache playlist'),
                subtitle: const Text('Caches the master playlist only'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final status = await FastPixPrecacheManager.instance
                      .precacheManifest(stream.toDataSource());
                  if (!mounted) return;
                  final bytes = FastPixPrecacheManager.instance
                      .bytesWrittenFor(stream.playbackId);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        status == FastPixPrecacheStatus.cached
                            ? 'Cached ${stream.title}: $bytes bytes'
                            : 'Precache ${status.name}',
                      ),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove from catalog'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _catalog.remove(stream);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[_catalog, _cast]),
        builder: (context, _) {
          return CustomScrollView(
            slivers: [
              _buildAppBar(),
              if (_catalog.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyCatalog(onAdd: _addStream),
                )
              else ...[
                SliverToBoxAdapter(child: _buildHero(_catalog.featured!)),
                SliverToBoxAdapter(child: _buildRails()),
              ],
            ],
          );
        },
      ),
      floatingActionButton:
          _catalog.isEmpty
              ? null
              : FloatingActionButton(
                onPressed: _addStream,
                backgroundColor: AppColors.accent,
                child: const Icon(Icons.add),
              ),
    );
  }

  Widget _buildAppBar() {
    // Only offered once a receiver actually exists. A cast button that opens
    // an empty list is the most common cast UX complaint.
    final canCast =
        _cast.state.canCast || _cast.state == FastPixCastState.connecting;
    final isCasting = _cast.state.isCasting;

    return SliverAppBar(
      floating: true,
      backgroundColor: AppColors.background,
      title: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: const Text(
              'F',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'FastPix',
            style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.2),
          ),
        ],
      ),
      actions: [
        if (canCast)
          IconButton(
            tooltip: isCasting ? 'Casting' : 'Cast',
            icon: Icon(isCasting ? Icons.cast_connected : Icons.cast),
            color: isCasting ? AppColors.accent : null,
            onPressed: () => showCastDiagnosticsSheet(context),
          ),
        IconButton(
          tooltip: 'Cast diagnostics',
          icon: const Icon(Icons.tune),
          onPressed: () => showCastDiagnosticsSheet(context),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildHero(DemoStream stream) {
    final colors = AppColors.posterGradient(_catalog.indexOf(stream));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          children: [
            AspectRatio(
              aspectRatio: 16 / 10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: colors,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
            ),
            // Scrim, so the title and buttons stay legible over any gradient.
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Colors.transparent, Colors.black87],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stream.badgeLine,
                    style: const TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    stream.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 26,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () => _open(stream),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Play'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.filledTonal(
                        onPressed: () => _showStreamMenu(stream),
                        icon: const Icon(Icons.more_horiz),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRails() {
    // The status pill exists only so preloading is observable while testing.
    // A shipping app would not show it — a warm start is meant to look like a
    // fast one, not like a different feature.
    Widget card(DemoStream stream, {List<DemoStream>? items, String? title}) =>
        Stack(
      children: <Widget>[
        PosterCard(
          stream: stream,
          gradientIndex: _catalog.indexOf(stream),
          onTap: () => _open(stream, items: items, title: title),
          onLongPress: () => _showStreamMenu(stream),
        ),
        Positioned(
          top: 6,
          left: 6,
          child: IgnorePointer(
            child: PreloadStatusDot(playbackId: stream.playbackId),
          ),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PosterRail(
          title: 'Continue watching',
          children: _catalog.continueWatching
              .map((s) => card(s,
                  items: _catalog.continueWatching,
                  title: 'Continue watching'))
              .toList(),
        ),
        PosterRail(
          title: 'Live now',
          children: _catalog.live
              .map((s) => card(s, items: _catalog.live, title: 'Live now'))
              .toList(),
        ),
        PosterRail(
          title: 'On demand',
          children: _catalog.onDemand
              .map((s) => card(s, items: _catalog.onDemand, title: 'On demand'))
              .toList(),
        ),
        const SizedBox(height: 90),
      ],
    );
  }
}

class _EmptyCatalog extends StatelessWidget {
  const _EmptyCatalog({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.video_library_outlined,
              size: 56,
              color: AppColors.textSecondary,
            ),
            const SizedBox(height: 20),
            const Text(
              'Your catalog is empty',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Add a FastPix playback ID to build the home screen. Streams '
              'stay for this session only.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add a stream'),
            ),
          ],
        ),
      ),
    );
  }
}
