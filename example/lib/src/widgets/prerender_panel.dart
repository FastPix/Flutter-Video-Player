import 'dart:async';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

import '../playback_config.dart';
import '../theme.dart';

/// Makes prerendering visible in the demo app.
///
/// A promoted prerender looks like nothing at all — the next item simply has
/// no loading state or black frame before it — so this panel is the only evidence of
/// what the SDK did: how long the item now playing took to its first frame,
/// the status of the item being prerendered and the last event.
class PrerenderPanel extends StatefulWidget {
  const PrerenderPanel({super.key, required this.controller});

  final FastPixPlayerController controller;

  @override
  State<PrerenderPanel> createState() => _PrerenderPanelState();
}

class _PrerenderPanelState extends State<PrerenderPanel> {
  static const List<String> _types = <String>[
    FastPixPlayerEventTypes.prerenderRequested,
    FastPixPlayerEventTypes.prerenderReady,
    FastPixPlayerEventTypes.prerenderFailed,
  ];

  String? _playbackId;
  String _lastEvent = 'none yet';

  /// How long each prerendered item took to its hidden first frame, from its
  /// ready event.
  final Map<String, Duration> _prepared = <String, Duration>{};

  /// Why each item was skipped or failed, from its failed event.
  final Map<String, FastPixPrerenderErrorCode> _codes =
      <String, FastPixPrerenderErrorCode>{};
  late final _StartupClock _startup = _StartupClock(_onStartupMeasured);

  /// Whether the source playing now was promoted from its prerender, read
  /// when it fired ready: a promotion does so while its prerender still
  /// reads frameReady.
  bool _promoted = false;

  @override
  void initState() {
    super.initState();
    _listen(widget.controller);
  }

  @override
  void didUpdateWidget(PrerenderPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    _unlisten(oldWidget.controller);
    _listen(widget.controller);
  }

  @override
  void dispose() {
    _unlisten(widget.controller);
    super.dispose();
  }

  void _listen(FastPixPlayerController controller) {
    for (final type in _types) {
      controller.addEventListener(type, _onEvent);
    }
    controller.addEventListener(FastPixPlayerEventTypes.ready, _onReady);
    _startup.listen(controller);
  }

  void _unlisten(FastPixPlayerController controller) {
    for (final type in _types) {
      controller.removeEventListener(type, _onEvent);
    }
    controller.removeEventListener(FastPixPlayerEventTypes.ready, _onReady);
    _startup.cancel();
  }

  void _onReady(FastPixPlayerEvent event) {
    final controller = widget.controller;
    final playbackId = controller.dataSource?.playbackId;
    final promoted = playbackId != null &&
        controller.prerenderStatusOf(playbackId) ==
            FastPixPrerenderStatus.frameReady;
    if (mounted) setState(() => _promoted = promoted);
  }

  void _onStartupMeasured() {
    if (mounted) setState(() {});
  }

  void _onEvent(FastPixPlayerEvent event) {
    if (event is! FastPixPrerenderEvent || !mounted) return;
    final detail = switch (event) {
      FastPixPrerenderReadyEvent(:final timeToFirstFrame) =>
        ' in ${timeToFirstFrame.inMilliseconds}ms',
      FastPixPrerenderFailedEvent(:final code) => ' · ${code.value}',
      _ => '',
    };
    setState(() {
      _playbackId = event.playbackId;
      _lastEvent = '${event.type}$detail';
      switch (event) {
        case FastPixPrerenderReadyEvent(:final timeToFirstFrame):
          _prepared[event.playbackId] = timeToFirstFrame;
        case FastPixPrerenderFailedEvent(:final code):
          _codes[event.playbackId] = code;
        default:
          _codes.remove(event.playbackId);
      }
    });
  }

  /// How long the item now playing took to its first frame.
  ///
  /// Promoted: when its playhead moved, then how long the hidden player took
  /// to be ready beforehand. A normal load: until its playhead moved, which
  /// is also when the loader clears.
  String _startupLine(FastPixPlayerController controller) {
    final playbackId = _startup.playbackId;
    final playing = _startup.playing;
    final measured = playing == null
        ? 'First frame: measuring…'
        : 'First frame ${playing.inMilliseconds} ms';
    if (!_promoted) {
      return playing == null ? measured : '$measured (normal load)';
    }
    final prepared = playbackId == null ? null : _prepared[playbackId];
    return <String>[
      '$measured (promoted)',
      if (prepared != null) 'Prepared in ${prepared.inMilliseconds} ms',
    ].join(' · ');
  }

  /// Why [playbackId] was skipped or failed, from its failed event; empty
  /// for any other status.
  String _reason(FastPixPrerenderStatus status, String playbackId) {
    final skippedOrFailed = status == FastPixPrerenderStatus.skipped ||
        status == FastPixPrerenderStatus.failed;
    final code = _codes[playbackId];
    return skippedOrFailed && code != null ? ' · ${code.value}' : '';
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final playbackId = _playbackId;
    final status =
        playbackId == null ? null : controller.prerenderStatusOf(playbackId);
    final lines = <String>[
      playbackId == null || status == null
          ? 'Nothing prerendered yet'
          : '$playbackId · ${status.value}${_reason(status, playbackId)}',
      'Last event: $_lastEvent',
      'This item: ${_promoted ? 'promoted' : 'normal load'}',
      _startupLine(controller),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'PRERENDER',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          for (final line in lines)
            Text(line, style: const TextStyle(fontSize: 12)),
          _CellularSwitch(controller: controller),
        ],
      ),
    );
  }
}

/// Shows and flips [demoPrerenderOnCellular], and hands the change to
/// [controller] at once, so the video on screen follows it without a reload.
class _CellularSwitch extends StatelessWidget {
  const _CellularSwitch({required this.controller});

  final FastPixPlayerController controller;

  void _onChanged(bool value) {
    demoPrerenderOnCellular.value = value;
    controller.updatePrerenderConfiguration(
      demoPlayerConfiguration().prerenderConfiguration,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: demoPrerenderOnCellular,
      builder: (context, enabled, _) => Row(
        children: <Widget>[
          Switch(
            key: const Key('switch-prerender-cellular'),
            value: enabled,
            onChanged: _onChanged,
          ),
          Expanded(
            child: Text(
              'prerenderOnCellular = $enabled\n'
              'Applies now, to the video on screen',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Times the item now playing from the moment it becomes active until its
/// playhead first moves.
///
/// Measured here, from the playlist and playback streams, because the SDK
/// keeps its own load clock private; it can differ from the `FIRST FRAME` log
/// line by a few tens of milliseconds.
class _StartupClock {
  _StartupClock(this._onMeasured);

  final VoidCallback _onMeasured;
  final Stopwatch _clock = Stopwatch();
  StreamSubscription<FastPixPlaylistState>? _playlistSubscription;
  StreamSubscription<FastPixPlaybackState>? _playbackSubscription;
  FastPixPlayerController? _controller;

  /// The item being timed.
  String? playbackId;

  /// When its playhead first moved; null until it has.
  Duration? playing;

  /// The first playing snapshot of this item, which the playhead must move
  /// forward from. Reset when the position jumps back or the duration
  /// changes: the outgoing item's last snapshots can still arrive after the
  /// switch.
  ({Duration position, Duration duration})? _start;

  void listen(FastPixPlayerController controller) {
    _controller = controller;
    _restart(_activeIdOf(controller));
    _playlistSubscription = controller.playlistStateStream.listen((state) {
      _follow(state.item?.playbackId);
    });
    _playbackSubscription = controller.playbackStateStream.listen(_onPlayback);
  }

  void cancel() {
    unawaited(_playlistSubscription?.cancel());
    unawaited(_playbackSubscription?.cancel());
    _controller = null;
  }

  String? _activeIdOf(FastPixPlayerController controller) =>
      (controller.currentPlaylistItem ?? controller.dataSource)?.playbackId;

  /// Start timing [id] when it differs from the item being timed.
  void _follow(String? id) {
    if (id == null || id == playbackId) return;
    _restart(id);
    _onMeasured();
  }

  void _restart(String? id) {
    playbackId = id;
    playing = null;
    _start = null;
    _clock
      ..reset()
      ..start();
  }

  void _onPlayback(FastPixPlaybackState state) {
    final controller = _controller;
    // A source loaded outside a playlist announces no playlist change.
    if (controller != null) _follow(_activeIdOf(controller));
    if (playing != null || !state.isPlaying) return;
    final start = _start;
    if (start == null ||
        state.position < start.position ||
        state.duration != start.duration) {
      _start = (position: state.position, duration: state.duration);
      return;
    }
    if (state.position <= start.position) return;
    playing = _clock.elapsed;
    _clock.stop();
    _onMeasured();
  }
}
