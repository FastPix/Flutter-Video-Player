import 'package:flutter/foundation.dart';

/// Greppable tracing and a running count for DRM licence acquisition.
///
/// ```
/// flutter run | grep drm-licence
/// adb logcat  | grep drm-licence
/// ```
///
/// ## Why counting is the point
///
/// A licence acquisition is not free. It is a network round trip on the tap
/// path, it is metered by most licence services, and preloading multiplies it:
/// a warm window of three protected titles acquires three licences for videos
/// nobody has asked for yet, and an eviction throws that work away. None of
/// that is visible from playback, which looks identical whether the licence was
/// fetched once or four times — so the only way to know is to count.
///
/// ## What a line means, exactly
///
/// [armed] is recorded where **this package** hands a licence URL to something
/// that will fetch it — a warm player, the playing player, the iOS FairPlay
/// patch, a Cast receiver. It is the count of licence acquisitions this SDK
/// *causes*, which is the number a preload window is answerable for.
///
/// One *play* of a protected item should cost exactly one acquisition —
/// either the warm player's, reused at the tap, or the playing player's when
/// there was no warm. What it is **not** is one per video: a DRM session
/// belongs to a player instance, so a warm player that is evicted before it is
/// adopted has spent a licence that nothing reuses, and the next warm of the
/// same video acquires another. That churn is what these counters exist to
/// make visible.
///
/// It is not an HTTP-level count. The request itself is made inside media3 or
/// AVFoundation, which may retry a failure, renew an expiring licence, or
/// acquire per-key rather than per-session, and none of that passes through
/// Dart. Two places report the real thing: on iOS the FairPlay patch owns the
/// request and logs `[FastPixDRM/swizzle] licence request #N`, and on Android
/// media3's own `DefaultDrmSession` logging does
/// (`adb logcat -s DefaultDrmSession:V`). When those disagree with this count,
/// they are right and the difference is the interesting part.
///
/// Enabled in debug builds and silent in release, so an SDK consumer never
/// inherits our logging — but the counters are kept either way, so a host can
/// assert on them in a release integration test. Force logging with [enabled].
class FastPixDrmLog {
  const FastPixDrmLog._();

  /// Whether anything is printed. Counting happens regardless.
  static bool enabled = kDebugMode;

  static const String tag = 'drm-licence';

  /// Why a licence was armed. Free-form, but these are the ones the SDK emits.
  static const String reasonPreload = 'preload-warm';
  static const String reasonPlayback = 'playback';
  static const String reasonCast = 'cast';

  static final Map<String, int> _byReason = <String, int>{};
  static final Map<String, int> _byPlaybackId = <String, int>{};
  static int _total = 0;
  static int _reused = 0;

  /// Record one licence arming.
  ///
  /// [playbackId] is on every line because a preload window means several
  /// interleaved lifecycles, and a count without the key cannot say whether
  /// three acquisitions were three titles or one title three times — which is
  /// the difference between working and looping.
  static void armed({
    required String playbackId,
    required String reason,
    String? host,
    String? detail,
  }) {
    _total++;
    _byReason[reason] = (_byReason[reason] ?? 0) + 1;
    final perId = (_byPlaybackId[playbackId] ?? 0) + 1;
    _byPlaybackId[playbackId] = perId;

    if (!enabled) return;
    debugPrint(
      '$tag id=$playbackId armed reason=$reason '
      '${host == null ? '' : 'host=$host '}'
      'count(id)=$perId total=$_total'
      '${detail == null ? '' : ' $detail'}',
    );
  }

  /// Record a licence that was **not** acquired because an existing one was
  /// reused — an adopted warm player, which already holds its key.
  ///
  /// Counted separately rather than skipped: "no licence was needed here" is a
  /// fact about a play, and a reuse is the *success* case of preloading. It is
  /// also the line that keeps [total] honest — count an adopted play as an
  /// arming and every warm start is charged twice.
  static void reused({required String playbackId, String? detail}) {
    _reused++;
    if (!enabled) return;
    debugPrint(
      '$tag id=$playbackId reused — no licence acquired'
      '${detail == null ? '' : ' ($detail)'} reused=$_reused total=$_total',
    );
  }

  /// Record the iOS FairPlay patch being pointed at a licence URL.
  ///
  /// Logged, never counted: it is the *ability* to fetch a licence, not a
  /// fetch. The acquisition that follows is counted by the play that caused
  /// it, and numbered for real by the patch itself.
  static void configured({required String playbackId, String? host}) {
    if (!enabled) return;
    debugPrint(
      '$tag id=$playbackId FairPlay patch configured'
      '${host == null || host.isEmpty ? '' : ' host=$host'} '
      '(no licence acquired yet)',
    );
  }

  /// One line about a licence that was *not* armed, with the reason.
  ///
  /// A skip is as worth saying as an acquisition: `warmDrm: false` and a
  /// refused precache both look exactly like a licence that was never needed.
  static void skipped({required String playbackId, required String reason}) {
    if (!enabled) return;
    debugPrint('$tag id=$playbackId not armed: $reason');
  }

  /// Total licences armed since the last [reset].
  static int get total => _total;

  /// Plays that needed no licence because a warm player already held one.
  ///
  /// The measure of whether preloading protected content is paying for itself:
  /// every reuse is a licence acquisition that did not happen on the tap path.
  static int get reuseCount => _reused;

  /// Licences armed per reason, e.g. `{preload-warm: 3, playback: 1}`.
  static Map<String, int> get countsByReason => Map<String, int>.unmodifiable(_byReason);

  /// Licences armed per playback ID.
  static Map<String, int> get countsByPlaybackId =>
      Map<String, int>.unmodifiable(_byPlaybackId);

  /// A one-line summary, for printing at the end of a run or a test.
  static String summary() {
    if (_total == 0) return '$tag summary total=0 (none armed yet)';
    final byReason = _byReason.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(' ');
    final repeats = _byPlaybackId.entries
        .where((entry) => entry.value > 1)
        .map((entry) => '${entry.key}×${entry.value}')
        .join(' ');
    return '$tag summary total=$_total $byReason'
        '${_reused == 0 ? '' : ' reused=$_reused'}'
        '${repeats.isEmpty ? '' : ' repeated: $repeats'}';
  }

  /// Print [summary].
  static void logSummary() {
    if (!enabled) return;
    debugPrint(summary());
  }

  /// Clear the counters. Call between scenarios; a test that does not is
  /// counting the previous one as well.
  static void reset() {
    _byReason.clear();
    _byPlaybackId.clear();
    _total = 0;
    _reused = 0;
  }
}
