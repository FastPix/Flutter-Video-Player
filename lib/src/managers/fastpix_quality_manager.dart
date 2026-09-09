import 'package:better_player_plus/better_player_plus.dart';

import '../models/fastpix_custom_ui_event.dart';
import '../models/fastpix_player_event.dart';
import '../models/fastpix_quality_level.dart';
import 'fastpix_engine_accessor.dart';

/// Owns video-quality listing and switching for the custom-UI API.
///
/// A selection is a **ceiling, not an exact pin**, on both platforms: the
/// engine caps the adaptive ladder and the player keeps adapting below it.
/// Android's cap is a hard ExoPlayer track-selector constraint (so it lands on
/// the selected rendition whenever bandwidth permits); iOS's is an AVFoundation
/// preference, which is looser. Not a failure
/// ([FastPixCustomUIErrorCode.qualitySelectionUnsupported] names it), so this
/// reports the *requested* level and lets the engine's automatic-switch events
/// describe what is actually shown.
class FastPixQualityManager {
  final FastPixEngineAccessor _engine;
  final FastPixPlayerEventManager _eventManager;

  FastPixQualityManager(this._engine, this._eventManager);

  bool _isAuto = true;
  FastPixQualityLevel? _current;

  /// Whether quality selection is currently automatic.
  bool get isAuto => _isAuto;

  /// The active quality, or null before any track is known. [FastPixQualityLevel.automatic]
  /// while automatic.
  FastPixQualityLevel? get current =>
      _isAuto ? FastPixQualityLevel.automatic : _current;

  /// Renditions the engine has parsed, newest list each call. Always leads with
  /// [FastPixQualityLevel.automatic] so a menu can offer "Auto" as the first
  /// entry. Empty (not even Auto) until the engine has parsed the manifest, so
  /// a menu can tell "no tracks yet" from "single rendition".
  List<FastPixQualityLevel> getLevels() {
    final raw = _rawTracks();
    if (raw.isEmpty) return const <FastPixQualityLevel>[];

    final levels = <FastPixQualityLevel>[FastPixQualityLevel.automatic];
    for (final track in raw) {
      final level = FastPixQualityLevel.fromAsmsTrack(track);
      // Skip the engine's own "default/auto" sentinel track — Auto is already
      // the leading entry, and adding it again would double the row.
      if (level.isAuto) continue;
      if (!levels.contains(level)) levels.add(level);
    }
    return List<FastPixQualityLevel>.unmodifiable(levels);
  }

  /// Switch to [level]. Selecting [FastPixQualityLevel.automatic] is equivalent
  /// to [setAuto].
  Future<void> setLevel(FastPixQualityLevel level) async {
    if (level.isAuto) {
      await setAuto();
      return;
    }

    final controller = _engine();
    if (controller == null) return;

    // Find the engine track that maps to this level.
    BetterPlayerAsmsTrack? match;
    for (final track in _rawTracks()) {
      if (FastPixQualityLevel.fromAsmsTrack(track) == level) {
        match = track;
        break;
      }
    }
    if (match == null) return; // Track no longer present; caller may report.

    controller.setTrack(match);
    _isAuto = false;
    _current = level;
    _emitChanged(level, isAutomatic: false);
  }

  /// Reset quality selection to automatic.
  Future<void> setAuto() async {
    final controller = _engine();
    if (controller != null) {
      controller.setTrack(BetterPlayerAsmsTrack.defaultTrack());
    }
    _isAuto = true;
    _current = FastPixQualityLevel.automatic;
    _emitChanged(FastPixQualityLevel.automatic, isAutomatic: true);
  }

  /// Report an automatic (player-driven) quality change, so a UI can show the
  /// rendition the player switched to on its own while still in Auto mode. Does
  /// not change [isAuto].
  void reportAutomaticChange(FastPixQualityLevel? level) {
    if (!_isAuto) return;
    _emitChanged(level, isAutomatic: true);
  }

  /// Whether the engine has parsed any renditions yet.
  bool get hasTracks => _rawTracks().isNotEmpty;

  void resetForNewSource() {
    _isAuto = true;
    _current = null;
  }

  List<BetterPlayerAsmsTrack> _rawTracks() =>
      _engine()?.betterPlayerAsmsTracks ?? const <BetterPlayerAsmsTrack>[];

  void _emitChanged(FastPixQualityLevel? level, {required bool isAutomatic}) {
    _eventManager.emit(
      FastPixQualityLevelChangedEvent(
        timestamp: DateTime.now(),
        level: level,
        isAutomatic: isAutomatic,
      ),
    );
  }
}
