import 'package:better_player_plus/better_player_plus.dart';

import '../models/fastpix_custom_ui_event.dart';
import '../models/fastpix_player_event.dart';
import '../models/fastpix_subtitle_track.dart';
import 'fastpix_engine_accessor.dart';

/// Owns subtitle listing, switching, and disabling for the custom-UI API.
///
/// The engine models "subtitles off" as a source of type
/// [BetterPlayerSubtitlesSourceType.none], which it appends to every source
/// list. That sentinel is hidden from [getTracks] — turning subtitles off is
/// [disable], and a null [current] means off — so a menu shows only real
/// tracks plus its own "Off" control.
class FastPixSubtitleTrackManager {
  final FastPixEngineAccessor _engine;
  final FastPixPlayerEventManager _eventManager;

  FastPixSubtitleTrackManager(this._engine, this._eventManager);

  /// Subtitle tracks the engine offers — both in-manifest tracks and external
  /// files — excluding the "off" sentinel. Empty until the engine has set the
  /// source up, and for streams with no captions.
  List<FastPixSubtitleTrack> getTracks() {
    final sources = _realSources();
    if (sources.isEmpty) return const <FastPixSubtitleTrack>[];
    return List<FastPixSubtitleTrack>.unmodifiable([
      for (int i = 0; i < sources.length; i++)
        FastPixSubtitleTrack.fromSource(sources[i], i),
    ]);
  }

  /// The active subtitle track, or null when subtitles are off.
  FastPixSubtitleTrack? get current {
    final active = _engine()?.betterPlayerSubtitlesSource;
    if (active == null || active.type == BetterPlayerSubtitlesSourceType.none) {
      return null;
    }
    final sources = _realSources();
    for (int i = 0; i < sources.length; i++) {
      if (identical(sources[i], active) ||
          _sameSource(sources[i], active)) {
        return FastPixSubtitleTrack.fromSource(sources[i], i);
      }
    }
    return null;
  }

  /// Switch to [track]. A no-op when the track is no longer present.
  Future<void> setTrack(FastPixSubtitleTrack track) async {
    final controller = _engine();
    if (controller == null) return;

    final sources = _realSources();
    for (int i = 0; i < sources.length; i++) {
      if (FastPixSubtitleTrack.fromSource(sources[i], i) == track) {
        await controller.setupSubtitleSource(sources[i]);
        _eventManager.emit(
          FastPixSubtitleChangedEvent(
            timestamp: DateTime.now(),
            track: track,
          ),
        );
        return;
      }
    }
  }

  /// Turn subtitles off by selecting the engine's "none" source.
  Future<void> disable() async {
    final controller = _engine();
    if (controller == null) return;

    final off = controller.betterPlayerSubtitlesSourceList.firstWhere(
      (source) => source.type == BetterPlayerSubtitlesSourceType.none,
      orElse: () => BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.none,
      ),
    );
    await controller.setupSubtitleSource(off);
    _eventManager.emit(
      FastPixSubtitleChangedEvent(timestamp: DateTime.now(), track: null),
    );
  }

  /// Whether the engine has any real (non-"off") subtitle sources yet.
  bool get hasTracks => _realSources().isNotEmpty;

  /// The source list with the "off" sentinel removed.
  List<BetterPlayerSubtitlesSource> _realSources() {
    final all = _engine()?.betterPlayerSubtitlesSourceList ??
        const <BetterPlayerSubtitlesSource>[];
    return all
        .where((source) => source.type != BetterPlayerSubtitlesSourceType.none)
        .toList(growable: false);
  }

  static bool _sameSource(
    BetterPlayerSubtitlesSource a,
    BetterPlayerSubtitlesSource b,
  ) =>
      a.name == b.name && a.type == b.type;
}
