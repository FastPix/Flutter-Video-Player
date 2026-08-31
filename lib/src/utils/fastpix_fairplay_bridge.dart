import 'dart:io';

import 'package:flutter/services.dart';

import '../models/fastpix_player_data_source.dart';
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

  /// Whether [source] needs the patch: FairPlay is iOS-only, and a certificate
  /// URL is what distinguishes it from Widevine.
  static bool _applies(FastPixPlayerDataSource source) =>
      Platform.isIOS &&
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

    final drm = source.drmConfiguration!;
    try {
      final installed = await _channel.invokeMethod<bool>(
        'setFairPlayConfig',
        <String, String?>{
          'certificateUrl': drm.certificateUrl(source.playbackId),
          'licenseUrl': drm.licenseUrl(source.playbackId),
        },
      );
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
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<bool>('setFairPlayConfig', const {});
    } on MissingPluginException {
      // Nothing to clear.
    } on PlatformException {
      // Nothing to clear.
    }
  }
}
