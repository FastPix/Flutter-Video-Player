import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Claims iOS's playback audio category through **our own** plugin.
///
/// The engine offers `setMixWithOthers`, and it does set a category — but it is
/// a per-player channel method: `SwiftBetterPlayerPlugin.handle` answers
/// `FlutterMethodNotImplemented` unless the call carries a `textureId` it
/// already knows, so a call made while the source is still loading arrives as a
/// `MissingPluginException` and the category is never set. That was measured on
/// device: the exception fired on every load and the audio session stayed at
/// iOS's default `.soloAmbient`.
///
/// The category matters because `.soloAmbient` lets iOS suspend playback the
/// moment the app is backgrounded, and that suspension is what starts the
/// engine's stall loop — `BetterPlayer.swift:286` reads the suspended rate as a
/// stall and calls `play()`, iOS suspends it again, and the two trade
/// `play`/`pause` events until the analytics queue overflows.
///
/// `AVAudioSession` is process-wide and Apple's own, so our plugin can set it
/// with no player, no texture and no engine cooperation.
class FastPixAudioSession {
  const FastPixAudioSession._();

  static const MethodChannel _channel = MethodChannel(
    'fastpix_video_player/precache',
  );

  /// Gap between claim attempts, multiplied by the attempt index.
  static const Duration _retryBackoff = Duration(milliseconds: 250);

  /// Put the session into the playback category. A no-op off iOS, where the
  /// engine's own audio focus handling applies and there is no equivalent
  /// default to correct.
  ///
  /// Retried, because a single attempt is not enough: on device the first call
  /// has been seen to fail with `'!ses'` (OSStatus 561210739) when the session
  /// was not yet in a state to accept it, and a claim that fails silently costs
  /// the whole background story — `.soloAmbient` survives, iOS suspends the
  /// player the moment the app leaves the foreground, and the engine's stall
  /// handler starts trading `play`/`pause` with it until the analytics queue
  /// overflows. Attempts are cheap and the native side is idempotent, so a few
  /// spaced retries are the right trade against that.
  ///
  /// Returns false when every attempt was declined; never throws, because
  /// failing to claim the category must not fail the load that asked for it.
  static Future<bool> claimPlayback({
    bool mixWithOthers = false,
    int attempts = 3,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_retryBackoff * attempt);
        // An earlier attempt, or a claim from another call site, may have
        // landed in the meantime. Nothing left to do if so.
        if (await isPlaybackCategoryHeld(mixWithOthers: mixWithOthers)) {
          return true;
        }
      }
      try {
        final applied = await _channel.invokeMethod<bool>(
          'setAudioSessionCategory',
          <String, dynamic>{'mixWithOthers': mixWithOthers},
        );
        if (applied ?? false) return true;
      } catch (_) {
        // Channel not up yet, or the platform refused: fall through and retry.
      }
    }
    return false;
  }

  /// Whether the session already holds the playback category with the options
  /// [mixWithOthers] asks for. False off iOS and whenever the platform cannot
  /// answer.
  static Future<bool> isPlaybackCategoryHeld({
    bool mixWithOthers = false,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
    try {
      final held = await _channel.invokeMethod<bool>(
        'claimPlaybackCategoryDidApply',
        <String, dynamic>{'mixWithOthers': mixWithOthers},
      );
      return held ?? false;
    } catch (_) {
      return false;
    }
  }
}
