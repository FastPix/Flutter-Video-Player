import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/foundation.dart';

/// Makes preloading visible in the demo app.
///
/// Warming is deliberately invisible in production — a warm start and a cold
/// start differ only in latency, and an adopted player reports a near-zero
/// time-to-first-frame either way. That is exactly what makes it hard to tell
/// a working preload from a broken one, so the demo subscribes to the event
/// channel and renders what it hears.
///
/// The signal that matters most is [wasAdopted]. Without it, "playback felt
/// fast" is the only evidence, and that is not evidence.
class PreloadProbe extends ChangeNotifier {
  PreloadProbe._() {
    for (final type in FastPixPlayerEventTypes.preload) {
      FastPixPreloadManager.instance.eventManager.addEventListener(type, _on);
    }
  }

  static final PreloadProbe instance = PreloadProbe._();

  final Map<String, FastPixPreloadStatus> _status =
      <String, FastPixPreloadStatus>{};
  final Map<String, Duration> _readyIn = <String, Duration>{};
  final Set<String> _adopted = <String>{};
  final List<String> _log = <String>[];

  /// Where [playbackId] is in the window.
  FastPixPreloadStatus statusOf(String playbackId) =>
      _status[playbackId] ?? FastPixPreloadStatus.queued;

  /// How long the warm-up took, once it finished.
  ///
  /// Compare against dwell — the gap between the warm starting and the tap. A
  /// warm that regularly takes longer than dwell never finishes, and the
  /// window is not buying anything.
  Duration? readyIn(String playbackId) => _readyIn[playbackId];

  /// Whether this playback started from a warmed player.
  ///
  /// The only honest way to separate warm from cold: `onPreloadConsumed` is
  /// emitted at handover, before playback reports any timing of its own.
  bool wasAdopted(String playbackId) => _adopted.contains(playbackId);

  /// Most recent events, newest first. Rendered by the debug sheet.
  List<String> get log => List<String>.unmodifiable(_log);

  void _on(FastPixPlayerEvent event) {
    if (event is! FastPixPreloadEvent) return;
    final id = event.playbackId;

    switch (event.type) {
      case FastPixPlayerEventTypes.preloadStarted:
        _status[id] = FastPixPreloadStatus.loading;
      case FastPixPlayerEventTypes.preloadReady:
        _status[id] = FastPixPreloadStatus.ready;
        if (event is FastPixPreloadReadyEvent) _readyIn[id] = event.elapsed;
      case FastPixPlayerEventTypes.preloadFailed:
        _status[id] = FastPixPreloadStatus.failed;
      case FastPixPlayerEventTypes.preloadCancelled:
        _status[id] = FastPixPreloadStatus.cancelled;
        _readyIn.remove(id);
      case FastPixPlayerEventTypes.preloadConsumed:
        // Ownership has transferred to the playing controller, so the entry is
        // gone from the window — but the fact that it happened is what the UI
        // needs to keep.
        _adopted.add(id);
        _status.remove(id);
    }

    final detail = _detailOf(event);
    // The network is on every line, not just the interesting ones: a warm-up
    // that ran on cellular spent the viewer's data allowance on a video they
    // may never open, and that is only auditable if every entry says which it
    // was.
    _log.insert(
      0,
      '${event.type}  $id  '
      '[${event.strategy.name} · ${event.networkType.label}]$detail',
    );
    if (_log.length > 60) _log.removeLast();

    notifyListeners();
  }

  /// The trailing half of a log line: how long the warm took, or why it
  /// failed. Empty for the events that carry neither.
  static String _detailOf(FastPixPreloadEvent event) {
    if (event is FastPixPreloadReadyEvent) {
      return ' in ${event.elapsed.inMilliseconds}ms';
    }
    if (event is FastPixPreloadFailedEvent) {
      return ' — ${event.reason}';
    }
    return '';
  }

  /// Forget everything observed. Does not touch the preload window itself.
  void reset() {
    _status.clear();
    _readyIn.clear();
    _adopted.clear();
    _log.clear();
    notifyListeners();
  }
}
