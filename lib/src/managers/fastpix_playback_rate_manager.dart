import '../models/fastpix_custom_ui_event.dart';
import '../models/fastpix_player_event.dart';
import 'fastpix_engine_accessor.dart';

/// Owns playback-speed control for the custom-UI API.
///
/// The engine (`better_player_plus`) accepts speeds in the open range `(0, 2]`
/// and *throws* outside it. The design contract is to clamp rather than fail
/// (Feature 2, "clamp playback speed to a supported range rather than fail"),
/// so this clamps into the supported range before calling the engine and never
/// lets an out-of-range request surface as an exception.
class FastPixPlaybackRateManager {
  final FastPixEngineAccessor _engine;
  final FastPixPlayerEventManager _eventManager;

  FastPixPlaybackRateManager(this._engine, this._eventManager);

  /// Speeds a menu should offer. The engine's hard ceiling is 2.0; 0.25 is the
  /// slowest that stays intelligible.
  static const List<double> supportedRates = <double>[
    0.25,
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
  ];

  /// Smallest speed the engine will accept. It rejects `<= 0`, so this is the
  /// floor a clamp maps zero and negatives onto rather than throwing.
  static const double _minRate = 0.25;
  static const double _maxRate = 2.0;

  double _rate = 1.0;

  /// The last speed applied, defaulting to normal.
  double get rate => _rate;

  /// Apply a playback speed, clamped to `[$_minRate, $_maxRate]`.
  ///
  /// Returns the speed actually applied (which may differ from [requested] when
  /// it was out of range). A no-op with no live engine returns the requested
  /// value clamped, so the reported rate stays consistent.
  Future<double> setRate(double requested) async {
    final clamped = requested.clamp(_minRate, _maxRate).toDouble();
    final controller = _engine();
    if (controller != null) {
      // The engine still validates; the clamp above guarantees we never hand it
      // a value it rejects.
      await controller.setSpeed(clamped);
    }
    if (clamped != _rate) {
      _rate = clamped;
      _eventManager.emit(
        FastPixPlaybackRateChangedEvent(
          timestamp: DateTime.now(),
          rate: clamped,
        ),
      );
    } else {
      _rate = clamped;
    }
    return clamped;
  }

  /// Reset to normal speed after a source change, without emitting — a fresh
  /// source starts at 1.0 by construction.
  void resetForNewSource() {
    _rate = 1.0;
  }
}
