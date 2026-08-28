import 'package:flutter/foundation.dart';

/// Single-tag tracing for play-start latency.
///
/// Off by default and free when off. Enable it, reproduce a play, and filter:
///
/// ```dart
/// FastPixPlayStartTrace.enabled = true;
/// ```
/// ```
/// adb logcat | grep PLAYSTART
/// flutter run --release | grep PLAYSTART
/// ```
///
/// ## Why this exists before the optimisation does
///
/// Warm-start work cannot be justified — or disproved — without numbers, and
/// the numbers only mean anything on a **release build over a real network**.
/// Debug builds and simulators produce timings that do not transfer.
///
/// Two measurements in particular decide how much warming is worth building:
///
/// * **Cold path** — where the tap-to-first-frame time actually goes. Warming
///   the wrong phase buys nothing.
/// * **Dwell** ([dwell]) — how long a warm-up actually gets to run before the
///   user taps. If dwell is shorter than the warm-up, the warm never finishes
///   and every window setting is fiction.
class FastPixPlayStartTrace {
  const FastPixPlayStartTrace._();

  /// Whether tracing emits anything. Leave false in production builds.
  static bool enabled = false;

  static const String _tag = 'PLAYSTART';

  /// Stamp the user's **actual tap**.
  ///
  /// Call this from the gesture handler, before any route push, entitlement
  /// check or page build. Stamping at player mount instead hides route
  /// transitions and pre-flight work — which is precisely the latency the user
  /// experiences as slowness, and precisely what this is meant to expose.
  static void tap(String playbackId) =>
      _emit('tap', playbackId);

  /// Report one phase of the cold path.
  ///
  /// Emit all of them and confirm they sum to within ~10% of the measured
  /// tap-to-first-frame total. If they do not sum, a phase is missing and the
  /// trace is describing a path that is not the one being paid for.
  ///
  /// Conventional names: `urlResolve`, `masterPlaylist`, `mediaPlaylist`,
  /// `drmLicence`, `prepareToFirstRequest`, `firstFrame`.
  static void phase(String playbackId, String name, Duration elapsed) =>
      _emit('phase', playbackId, '$name=${elapsed.inMilliseconds}ms');

  /// Report a warm-up transition: `requested`, `dispatched`, `completed`,
  /// `adopted`, `missed`.
  ///
  /// `adopted` is the one that matters most in aggregate. An adopted player
  /// reports a near-zero time-to-first-frame, so without an explicit marker
  /// warming makes startup dashboards look excellent while potentially
  /// delivering nothing, and warm and cold plays cannot be told apart.
  static void warm(String playbackId, String stage) =>
      _emit('warm', playbackId, stage);

  /// Report how long a warm-up actually got.
  ///
  /// [held] is the time from the warm starting to the user tapping.
  /// [stageReached] is how far it got — conventionally `NONE`, `RESOLVING`,
  /// `URL_READY` or `WARM_DISPATCHED`.
  ///
  /// This distribution is the single number that decides whether player
  /// warming is viable for a given navigation flow. A detail page carrying a
  /// trailer buys seconds; a rail that plays on click buys nothing.
  static void dwell(String playbackId, Duration held, String stageReached) =>
      _emit('dwell', playbackId, '${held.inMilliseconds}ms stage=$stageReached');

  static void _emit(String kind, String playbackId, [String? detail]) {
    if (!enabled) return;
    final suffix = detail == null ? '' : ' $detail';
    debugPrint('$_tag $kind id=$playbackId$suffix');
  }
}
