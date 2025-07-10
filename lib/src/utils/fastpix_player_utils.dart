import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../enums/fastpix_player_enums.dart';

/// Utility functions for FastPix Player
class FastPixPlayerUtils {
  /// Check if device is connected to WiFi
  static Future<bool> isConnectedToWifi() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } on SocketException catch (_) {
      return false;
    }
  }

  /// Format duration to MM:SS format
  static String formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  /// Format duration to HH:MM:SS format
  static String formatDurationLong(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(duration.inHours);
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$hours:$minutes:$seconds';
  }

  /// Convert FastPix aspect ratio to BoxFit
  static BoxFit aspectRatioToBoxFit(FastPixAspectRatio aspectRatio) {
    switch (aspectRatio) {
      case FastPixAspectRatio.fit:
        return BoxFit.contain;
      case FastPixAspectRatio.ratio16x9:
        return BoxFit.cover;
      case FastPixAspectRatio.ratio4x3:
        return BoxFit.cover;
      case FastPixAspectRatio.ratio1x1:
        return BoxFit.cover;
      case FastPixAspectRatio.stretch:
        return BoxFit.fill;
    }
  }

  /// Convert FastPix aspect ratio to AspectRatio widget
  static double aspectRatioToDouble(FastPixAspectRatio aspectRatio) {
    switch (aspectRatio) {
      case FastPixAspectRatio.fit:
        return 16 / 9; // Default aspect ratio
      case FastPixAspectRatio.ratio16x9:
        return 16 / 9;
      case FastPixAspectRatio.ratio4x3:
        return 4 / 3;
      case FastPixAspectRatio.ratio1x1:
        return 1 / 1;
      case FastPixAspectRatio.stretch:
        return 16 / 9; // Default aspect ratio
    }
  }

  /// Convert FastPix video quality to string
  static String videoQualityToString(FastPixVideoQuality quality) {
    switch (quality) {
      case FastPixVideoQuality.auto:
        return 'Auto';
      case FastPixVideoQuality.low:
        return 'Low';
      case FastPixVideoQuality.medium:
        return 'Medium';
      case FastPixVideoQuality.high:
        return 'High';
      case FastPixVideoQuality.ultra:
        return 'Ultra';
    }
  }

  /// Convert string to FastPix video quality
  static FastPixVideoQuality stringToVideoQuality(String quality) {
    switch (quality.toLowerCase()) {
      case 'auto':
        return FastPixVideoQuality.auto;
      case 'low':
        return FastPixVideoQuality.low;
      case 'medium':
        return FastPixVideoQuality.medium;
      case 'high':
        return FastPixVideoQuality.high;
      case 'ultra':
        return FastPixVideoQuality.ultra;
      default:
        return FastPixVideoQuality.auto;
    }
  }

  /// Convert FastPix player state to string
  static String playerStateToString(FastPixPlayerState state) {
    switch (state) {
      case FastPixPlayerState.initialized:
        return 'Initialized';
      case FastPixPlayerState.ready:
        return 'Ready';
      case FastPixPlayerState.playing:
        return 'Playing';
      case FastPixPlayerState.paused:
        return 'Paused';
      case FastPixPlayerState.buffering:
        return 'Buffering';
      case FastPixPlayerState.finished:
        return 'Finished';
      case FastPixPlayerState.error:
        return 'Error';
    }
  }

  /// Validate video URL
  static bool isValidVideoUrl(String url) {
    if (url.isEmpty) return false;

    final uri = Uri.tryParse(url);
    if (uri == null) return false;

    final supportedExtensions = [
      '.mp4',
      '.m3u8',
      '.mpd',
      '.webm',
      '.avi',
      '.mov',
      '.mkv',
      '.flv',
    ];

    final path = uri.path.toLowerCase();
    return supportedExtensions.any((ext) => path.endsWith(ext));
  }

  /// Get file extension from URL
  static String? getFileExtension(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final path = uri.path;
    final lastDotIndex = path.lastIndexOf('.');
    if (lastDotIndex == -1) return null;

    return path.substring(lastDotIndex + 1).toLowerCase();
  }

  /// Check if video format is supported
  static bool isVideoFormatSupported(String format) {
    final supportedFormats = [
      'mp4',
      'm3u8',
      'mpd',
      'webm',
      'avi',
      'mov',
      'mkv',
      'flv',
    ];
    return supportedFormats.contains(format.toLowerCase());
  }

  /// Calculate buffer percentage
  static double calculateBufferPercentage(Duration buffered, Duration total) {
    if (total.inMilliseconds == 0) return 0.0;
    return (buffered.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Convert bytes to human readable format
  static String bytesToHumanReadable(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Get network type
  static Future<String> getNetworkType() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        // This is a simplified check - in a real app you'd use connectivity_plus package
        return 'WiFi';
      }
    } on SocketException catch (_) {
      return 'Mobile';
    }
    return 'Unknown';
  }

  /// Check if the current platform is iOS
  static bool get isIOS => Platform.isIOS;

  /// Check if the current platform is Android
  static bool get isAndroid => Platform.isAndroid;

  /// Get platform-specific headers for better compatibility
  static Map<String, String> getPlatformHeaders() {
    if (isIOS) {
      return {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1',
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
        'Connection': 'keep-alive',
        'Cache-Control': 'no-cache',
      };
    } else if (isAndroid) {
      return {'Content-Type': 'application/octet-stream'};
    }
    return {};
  }

  /// Validate HLS URL format
  static bool isValidHlsUrl(String url) {
    return url.endsWith('.m3u8') || url.contains('.m3u8');
  }

  /// Get iOS-specific error message for common HLS errors
  static String getIosErrorMessage(String error) {
    if (error.contains('CoreMediaErrorDomain error -12642')) {
      return 'HLS stream format issue. This may be due to incompatible stream configuration or network issues.';
    } else if (error.contains('CoreMediaErrorDomain')) {
      return 'iOS media playback error. Please check your network connection and try again.';
    }
    return error;
  }

  /// Check if the stream requires authentication
  static bool requiresAuthentication(String url) {
    return url.contains('token=') || url.contains('auth=');
  }

  /// Debug logging for iOS
  static void debugLog(String message) {
    if (kDebugMode) {
      print('[FastPix Player] $message');
    }
  }
}
