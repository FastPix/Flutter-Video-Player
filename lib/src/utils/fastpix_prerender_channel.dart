import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The id the engine's native side knows [engine] by, or null before its
/// player exists.
///
/// It is the key of the engine's platform view and of its native player
/// registry, so it is the only identity Dart and native share for a player.
/// The engine marks the getter for tests only; nothing else exposes it.
int? fastPixEngineTextureId(BetterPlayerController engine) =>
    // ignore: invalid_use_of_visible_for_testing_member
    engine.videoPlayerController?.textureId;

/// Which job an engine player's native view has.
enum FastPixPrerenderRole {
  /// The player the viewer is watching; native owners may select it.
  active('active'),

  /// The hidden prerender; Picture-in-Picture and Now Playing must never
  /// select it.
  prerender('prerender'),

  /// No longer a prerender, and not promoted: forgotten without announcing it
  /// to the native owners, since its view goes with the hidden slot.
  released('released');

  const FastPixPrerenderRole(this.value);
  final String value;
}

/// The native side of prerendering: layer roles and the platform's
/// presentation-readiness signal, per engine player (`textureId`).
///
/// Injectable so the prerender manager can be tested without a platform.
abstract class FastPixPrerenderPlatform {
  /// Whether the native first-frame hook can run on this build.
  Future<bool> isSupported();

  /// Mark [textureId]'s native view. Sent before a hidden view mounts, and for
  /// both players at promotion.
  Future<void> setRole(int textureId, FastPixPrerenderRole role);

  /// Position [textureId] exactly at [position] and report when a frame is
  /// ready for presentation on its mounted surface, through [frameReady].
  ///
  /// Returns false when the hook cannot run for it.
  Future<bool> watchFirstFrame(
    int textureId, {
    required Duration position,
    required double rate,
  });

  /// Stop watching [textureId]. Harmless when nothing is watched.
  Future<void> stopWatching(int textureId);

  /// The textureIds whose frame became ready, as native reports them.
  Stream<int> get frameReady;

  /// The textureIds native could not position at their start.
  Stream<int> get seekFailed;
}

/// [FastPixPrerenderPlatform] over `fastpix_video_player/prerender`.
class FastPixPrerenderChannel implements FastPixPrerenderPlatform {
  FastPixPrerenderChannel._() {
    _channel.setMethodCallHandler(_handle);
  }

  static FastPixPrerenderChannel? _instance;

  /// The process-wide channel, installed on first use.
  static FastPixPrerenderChannel get instance =>
      _instance ??= FastPixPrerenderChannel._();

  static const MethodChannel _channel = MethodChannel(
    'fastpix_video_player/prerender',
  );

  final StreamController<int> _frames = StreamController<int>.broadcast();
  final StreamController<int> _seekFailures =
      StreamController<int>.broadcast();
  Future<bool>? _supported;

  Future<Object?> _handle(MethodCall call) async {
    final arguments = call.arguments;
    final textureId = arguments is Map ? arguments['textureId'] : null;
    if (textureId is! int) return null;
    switch (call.method) {
      case 'frameReady':
        _frames.add(textureId);
      case 'seekFailed':
        _seekFailures.add(textureId);
    }
    return null;
  }

  @override
  Future<bool> isSupported() => _supported ??= () async {
        try {
          return await _channel.invokeMethod<bool>('isSupported') ?? false;
        } on MissingPluginException {
          return false;
        } on PlatformException catch (error) {
          debugPrint('[FastPixPrerender] isSupported failed: $error');
          return false;
        }
      }();

  @override
  Future<void> setRole(int textureId, FastPixPrerenderRole role) =>
      _invoke('setRole', {'textureId': textureId, 'role': role.value});

  @override
  Future<bool> watchFirstFrame(
    int textureId, {
    required Duration position,
    required double rate,
  }) async {
    try {
      final answer = await _channel.invokeMethod<String>('watchFirstFrame', {
        'textureId': textureId,
        'positionMs': position.inMilliseconds,
        'rate': rate,
      });
      return answer == 'ok';
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('[FastPixPrerender] watchFirstFrame failed: $error');
      return false;
    }
  }

  @override
  Future<void> stopWatching(int textureId) =>
      _invoke('stopWatching', {'textureId': textureId});

  @override
  Stream<int> get frameReady => _frames.stream;

  @override
  Stream<int> get seekFailed => _seekFailures.stream;

  Future<void> _invoke(String method, Map<String, Object?> arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No native side: there is nothing to mark or stop.
    } on PlatformException catch (error) {
      debugPrint('[FastPixPrerender] $method failed: $error');
    }
  }
}
