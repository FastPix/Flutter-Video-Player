import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A command from the lock screen or Control Center.
enum FastPixRemoteCommand { play, pause, toggle, seek }

/// Publishes the playing source as iOS's "Now Playing" media and carries the
/// remote commands back.
///
/// The native FastPix iOS player gets both from `AVPlayerViewController`;
/// this SDK renders through the engine's own layer, so it does them itself.
///
/// Fed from the controller's playback-state snapshots, which arrive on every
/// progress tick. Only a real change is sent: iOS advances the elapsed time on
/// its own from the rate, so a tick that lands where that extrapolation says
/// is not news.
class FastPixNowPlayingManager {
  FastPixNowPlayingManager({
    required void Function(FastPixRemoteCommand command, Duration? position)
        onCommand,
    TargetPlatform? platform,
  })  : _onCommand = onCommand,
        _platform = platform ?? defaultTargetPlatform;

  static const MethodChannel _channel = MethodChannel(
    'fastpix_video_player/now_playing',
  );

  /// The manager whose source is published, and so the one commands reach.
  static FastPixNowPlayingManager? _owner;

  final void Function(FastPixRemoteCommand command, Duration? position)
      _onCommand;
  final TargetPlatform _platform;

  /// How far the reported position may drift from where iOS will have
  /// extrapolated it before it is sent again — a seek, not a tick.
  static const Duration _driftTolerance = Duration(milliseconds: 1500);

  _Published? _last;

  bool get _isIOS => _platform == TargetPlatform.iOS;

  /// Publish the source as playing or paused at its position.
  void publish(FastPixNowPlayingInfo info) {
    if (!_isIOS) return;
    final now = DateTime.now();
    final last = _last;
    if (last != null &&
        last.info.sameMediaAs(info) &&
        (info.position - last.expectedAt(now)).abs() <= _driftTolerance) {
      return;
    }
    _last = _Published(info: info, at: now);
    _claimChannel();
    unawaited(_invoke('update', info.toArguments()));
  }

  /// Stop publishing: nothing of this source is left on the lock screen.
  void clear() {
    if (!_isIOS || _last == null) return;
    _last = null;
    if (identical(_owner, this)) {
      unawaited(_invoke('clear'));
    }
  }

  /// Clear, and let go of the channel if this manager holds it.
  void dispose() {
    clear();
    if (identical(_owner, this)) {
      _owner = null;
      try {
        _channel.setMethodCallHandler(null);
      } catch (_) {}
    }
  }

  void _claimChannel() {
    if (identical(_owner, this)) return;
    _owner = this;
    try {
      _channel.setMethodCallHandler(_handle);
    } catch (_) {
      // No binding yet; the next publish tries again.
      _owner = null;
    }
  }

  static Future<void> _handle(MethodCall call) async {
    final owner = _owner;
    if (owner == null || call.method != 'remoteCommand') return;
    final args = (call.arguments as Map?)?.cast<String, dynamic>();
    final command = switch (args?['command']) {
      'play' => FastPixRemoteCommand.play,
      'pause' => FastPixRemoteCommand.pause,
      'toggle' => FastPixRemoteCommand.toggle,
      'seek' => FastPixRemoteCommand.seek,
      _ => null,
    };
    if (command == null) return;
    final positionMs = (args?['positionMs'] as num?)?.toInt();
    owner._onCommand(
      command,
      positionMs == null ? null : Duration(milliseconds: positionMs),
    );
  }

  /// Deliver a remote command as the platform would. Tests only.
  @visibleForTesting
  static Future<void> debugSendCommand(
    String command, {
    int? positionMs,
  }) =>
      _handle(
        MethodCall('remoteCommand', <String, dynamic>{
          'command': command,
          if (positionMs != null) 'positionMs': positionMs,
        }),
      );

  static Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } catch (_) {
      // Now Playing is an extra; it must never surface as a playback error.
    }
  }
}

/// What is published as Now Playing: one snapshot of the playing source.
@immutable
class FastPixNowPlayingInfo {
  const FastPixNowPlayingInfo({
    required this.title,
    required this.duration,
    required this.position,
    required this.playing,
    required this.rate,
    required this.isLive,
  });

  final String? title;
  final Duration duration;
  final Duration position;
  final bool playing;
  final double rate;
  final bool isLive;

  /// Equal in everything but [position], which is compared with a tolerance.
  bool sameMediaAs(FastPixNowPlayingInfo other) =>
      title == other.title &&
      duration == other.duration &&
      playing == other.playing &&
      rate == other.rate &&
      isLive == other.isLive;

  Map<String, dynamic> toArguments() => <String, dynamic>{
    'title': title,
    'durationMs': duration.inMilliseconds,
    'positionMs': position.inMilliseconds,
    'playing': playing,
    'rate': rate,
    'isLive': isLive,
  };
}

class _Published {
  const _Published({required this.info, required this.at});

  final FastPixNowPlayingInfo info;
  final DateTime at;

  /// Where iOS will show the playhead by [now], having advanced it from this.
  Duration expectedAt(DateTime now) {
    if (!info.playing) return info.position;
    final elapsedMs = now.difference(at).inMilliseconds * info.rate;
    return info.position + Duration(milliseconds: elapsedMs.round());
  }
}
