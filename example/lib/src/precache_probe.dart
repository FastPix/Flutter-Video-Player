import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/foundation.dart';

/// Makes precaching visible in the demo app.
///
/// Precaching is harder to observe than preloading: the platform reports no
/// completion, so the SDK's `statusOf()` only records what *this process asked
/// for*. Everything here is therefore about making the request and its
/// refusals legible. Proving the bytes landed needs `adb logcat | grep
/// CacheWorker`; proving playback reads them needs a proxy.
class PrecacheProbe extends ChangeNotifier {
  PrecacheProbe._() {
    for (final type in FastPixPlayerEventTypes.precache) {
      FastPixPrecacheManager.instance.eventManager.addEventListener(type, _on);
    }
  }

  static final PrecacheProbe instance = PrecacheProbe._();

  final Map<String, FastPixPrecacheStatus> _status =
      <String, FastPixPrecacheStatus>{};
  final Map<String, String> _detail = <String, String>{};

  /// Between `started` and its outcome. The SDK has no such state — the
  /// platform never reports progress — so the demo tracks it itself.
  final Set<String> _working = <String>{};

  final List<String> _log = <String>[];

  FastPixPrecacheStatus statusOf(String playbackId) =>
      _status[playbackId] ?? FastPixPrecacheStatus.idle;

  bool isWorking(String playbackId) => _working.contains(playbackId);

  /// File count and rendition on success, or the refusal reason on failure.
  String? detailOf(String playbackId) => _detail[playbackId];

  List<String> get log => List<String>.unmodifiable(_log);

  void _on(FastPixPlayerEvent event) {
    if (event is! FastPixPrecacheEvent) return;
    final id = event.playbackId;

    switch (event) {
      case FastPixPrecacheStartedEvent():
        _working.add(id);
        _detail[id] = 'resolving manifest…';
      case FastPixPrecacheCachedEvent(:final bytesWritten):
        _working.remove(id);
        _status[id] = FastPixPrecacheStatus.cached;
        // A real byte count. Zero is reported as a failure by the SDK, so any
        // number here means bytes genuinely landed in the player's cache.
        _detail[id] = 'master playlist cached · $bytesWritten bytes';
      case FastPixPrecacheFailedEvent(:final status, :final reason):
        _working.remove(id);
        _status[id] = status;
        _detail[id] = reason;
    }

    _log.insert(0, '${event.type}  $id  ${_detail[id] ?? ''}');
    if (_log.length > 60) _log.removeLast();
    notifyListeners();
  }

  void reset() {
    _status.clear();
    _detail.clear();
    _working.clear();
    _log.clear();
    notifyListeners();
  }
}
