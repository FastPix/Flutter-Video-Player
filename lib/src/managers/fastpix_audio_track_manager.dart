import 'package:better_player_plus/better_player_plus.dart';

import '../models/fastpix_audio_track.dart';
import '../models/fastpix_custom_ui_event.dart';
import '../models/fastpix_player_event.dart';
import 'fastpix_engine_accessor.dart';

/// Owns audio-track listing and switching for the custom-UI API.
class FastPixAudioTrackManager {
  final FastPixEngineAccessor _engine;
  final FastPixPlayerEventManager _eventManager;

  FastPixAudioTrackManager(this._engine, this._eventManager);

  /// Audio tracks the engine has parsed, in stream order. Empty until the
  /// engine has parsed the manifest, and for single-audio streams the engine
  /// reports one entry (or none, which a menu should treat as "no choice").
  List<FastPixAudioTrack> getTracks() {
    final raw = _rawTracks();
    if (raw.isEmpty) return const <FastPixAudioTrack>[];
    return List<FastPixAudioTrack>.unmodifiable([
      for (int i = 0; i < raw.length; i++)
        FastPixAudioTrack.fromAsmsAudioTrack(raw[i], i),
    ]);
  }

  /// The active audio track, or null before one is known.
  FastPixAudioTrack? get current {
    final raw = _rawTracks();
    final active = _engine()?.betterPlayerAsmsAudioTrack;
    if (active == null || raw.isEmpty) return null;
    for (int i = 0; i < raw.length; i++) {
      if (_sameAudio(raw[i], active)) {
        return FastPixAudioTrack.fromAsmsAudioTrack(raw[i], i);
      }
    }
    return null;
  }

  /// Switch to [track]. A no-op when the track is no longer present.
  Future<void> setTrack(FastPixAudioTrack track) async {
    final controller = _engine();
    if (controller == null) return;

    final raw = _rawTracks();
    for (int i = 0; i < raw.length; i++) {
      if (FastPixAudioTrack.fromAsmsAudioTrack(raw[i], i) == track) {
        controller.setAudioTrack(raw[i]);
        _eventManager.emit(
          FastPixAudioTrackChangedEvent(
            timestamp: DateTime.now(),
            track: track,
          ),
        );
        return;
      }
    }
  }

  /// Whether the engine has parsed any audio tracks yet.
  bool get hasTracks => _rawTracks().isNotEmpty;

  List<BetterPlayerAsmsAudioTrack> _rawTracks() =>
      _engine()?.betterPlayerAsmsAudioTracks ??
      const <BetterPlayerAsmsAudioTrack>[];

  static bool _sameAudio(
    BetterPlayerAsmsAudioTrack a,
    BetterPlayerAsmsAudioTrack b,
  ) =>
      a.id == b.id &&
      a.label == b.label &&
      a.language == b.language &&
      a.url == b.url;
}
