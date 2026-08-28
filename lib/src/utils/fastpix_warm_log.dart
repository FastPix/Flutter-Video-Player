import 'package:flutter/foundation.dart';

/// Greppable tracing for the two warm-up features.
///
/// One tag per feature, at the start of every line, so a running app can be
/// watched with nothing but a filter:
///
/// ```
/// flutter run | grep preloading
/// flutter run | grep precaching
/// adb logcat  | grep -E "preloading|precaching"
/// ```
///
/// ## Why the decisions are logged, not just the outcomes
///
/// Both features fail *silently* by design — a warm that never finished, a
/// cache entry written under a key nothing reads, an adoption refused for a
/// configuration mismatch. All of those leave playback working, so nothing
/// errors and nothing looks wrong. The only way to tell "working" from "doing
/// nothing at all" is to say out loud what was decided and why, which is why
/// skips and refusals are logged as loudly as successes.
///
/// Enabled in debug builds and silent in release, so an SDK consumer never
/// inherits our logging. Force it either way with [enabled].
class FastPixWarmLog {
  const FastPixWarmLog._();

  /// Whether anything is emitted. Defaults to debug builds only.
  static bool enabled = kDebugMode;

  static const String preloadTag = 'preloading';
  static const String precacheTag = 'precaching';

  /// One preloading line.
  ///
  /// [playbackId] is included on every line because warms overlap — a window
  /// of three means three interleaved lifecycles, and without the key the
  /// trace cannot be untangled.
  static void preload(String message, {String? playbackId}) =>
      _emit(preloadTag, message, playbackId);

  /// One precaching line.
  static void precache(String message, {String? playbackId}) =>
      _emit(precacheTag, message, playbackId);

  static void _emit(String tag, String message, String? playbackId) {
    if (!enabled) return;
    final id = playbackId == null ? '' : ' id=$playbackId';
    debugPrint('$tag$id $message');
  }
}
