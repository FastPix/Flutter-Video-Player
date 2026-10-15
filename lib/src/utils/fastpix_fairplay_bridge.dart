import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/fastpix_player_data_source.dart';
import 'fastpix_drm_log.dart';
import 'fastpix_warm_log.dart';

/// Hands the FairPlay URLs to the iOS patch that makes them work.
///
/// ## Why this exists
///
/// `better_player_plus` implements FairPlay for EZDRM specifically. Against a
/// FastPix licence server its delegate corrupts the signed URL, sends the wrong
/// content id, and treats an HTTP error body as a content key — so protected
/// playback cannot start. The native side substitutes a delegate that does all
/// three correctly; see `ios/Classes/FastPixFairPlayPatch.m`.
///
/// That substitute needs the certificate and licence URLs, and cannot read them
/// from the engine's own delegate: they are Swift `URL` **value** types and are
/// not `@objc`, so Objective-C has no accessor, no KVC and no usable ivar.
/// Dart already builds both to configure the engine, so it supplies them here
/// instead.
///
/// ## Best effort, always
///
/// Every failure — an old plugin build, a missing channel, a platform that has
/// none of this — resolves to the engine's own behaviour. Nothing in this file
/// can prevent or delay playback; on a non-FairPlay source it does nothing at
/// all.
class FastPixFairPlayBridge {
  const FastPixFairPlayBridge._();

  static const MethodChannel _channel = MethodChannel(
    'fastpix_video_player/precache',
  );

  /// Start listening for the platform's licence-acquisition reports.
  ///
  /// Idempotent, and called from [configure] so a host never has to. The
  /// handler is what turns `FastPixDrmLog`'s counters from "licences this SDK
  /// asked for" into "licences a server answered" — see
  /// [FastPixDrmLog.acquired].
  static void ensureListening() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler(_handle);
  }

  static bool _listening = false;

  /// Deliver a platform report as the native side sends it. Tests only.
  @visibleForTesting
  static Future<void> debugHandle(MethodCall call) => _handle(call);

  static Future<void> _handle(MethodCall call) async {
    if (call.method != 'drmLicenceAcquired') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;

    // Read defensively: this is a platform payload, and a field the native
    // side stops sending must not take licence reporting down with it.
    FastPixDrmLog.acquired(
      playbackId: '${arguments['playbackId'] ?? ''}',
      ok: arguments['ok'] == true,
      statusCode: _asInt(arguments['statusCode']),
      attempts: _asInt(arguments['attempts'], fallback: 1),
      elapsedMs: _asDouble(arguments['elapsedMs']),
      bytes: _asInt(arguments['bytes']),
    );
  }

  static int _asInt(Object? value, {int fallback = 0}) =>
      value is num ? value.toInt() : fallback;

  static double _asDouble(Object? value) =>
      value is num ? value.toDouble() : 0;

  /// Lifts the iOS-only check so a test can exercise the rest.
  ///
  /// The check reads the *host* platform, which is never iOS under
  /// `flutter test`, so without this seam nothing here is reachable — including
  /// whether a warm player is configured with its own video's URLs, which is
  /// the property this class exists to hold.
  @visibleForTesting
  static bool debugApplyOnEveryPlatform = false;

  /// Whether [source] needs the patch: FairPlay is iOS-only, and a certificate
  /// URL is what distinguishes it from Widevine.
  static bool _applies(FastPixPlayerDataSource source) =>
      (Platform.isIOS || debugApplyOnEveryPlatform) &&
      source.drmEnabled &&
      (source.drmConfiguration?.certificateUrl(source.playbackId) ?? '')
          .isNotEmpty;

  /// Configure the native patch for [source], if it is a FairPlay source.
  ///
  /// Returns whether the patch reported itself installed — false whenever it is
  /// not, which is also the answer for every source and platform this does not
  /// apply to. Never throws.
  static Future<bool> configure(FastPixPlayerDataSource source) async {
    if (!_applies(source)) return false;
    ensureListening();

    final drm = source.drmConfiguration!;
    try {
      final installed = await _channel.invokeMethod<bool>(
        'setFairPlayConfig',
        <String, String?>{
          // Named, so the patch registers this pair against this video rather
          // than only holding it as "the last one configured". A player warmed
          // in the background is built while a *different* video is playing,
          // and would otherwise capture that video's licence URL.
          'playbackId': source.playbackId,
          'certificateUrl': drm.certificateUrl(source.playbackId),
          'licenseUrl': drm.licenseUrl(source.playbackId),
        },
      );
      if (installed == true) {
        // Configuration, not an acquisition: the patch now *holds* a licence
        // URL and will POST to it when AVFoundation asks for a key. Counting
        // it as an arming would charge every iOS play twice, since the play
        // itself is counted below. The real request is numbered natively —
        // `[FastPixDRM/swizzle] licence request #N`.
        FastPixDrmLog.configured(
          playbackId: source.playbackId,
          host: Uri.tryParse(drm.resolvedBaseUrl)?.host ?? '',
        );
      }
      if (installed != true) {
        // Loudly: the alternative is the engine's EZDRM path failing later with
        // an opaque licence error that names nothing.
        FastPixWarmLog.preload(
          'FairPlay patch is NOT installed — protected playback will use the '
          'engine\'s EZDRM-only path and is expected to fail',
          playbackId: source.playbackId,
        );
      }
      return installed ?? false;
    } on MissingPluginException {
      // An app on an older build of this package. Playback proceeds exactly as
      // it would without the patch.
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Forget the configured URLs.
  ///
  /// Interception stops, and protected playback falls back to the engine's own
  /// delegate as though the patch were absent.
  static Future<void> clear() async {
    if (!Platform.isIOS && !debugApplyOnEveryPlatform) return;
    try {
      await _channel.invokeMethod<bool>('setFairPlayConfig', const {});
    } on MissingPluginException {
      // Nothing to clear.
    } on PlatformException {
      // Nothing to clear.
    }
  }
}
