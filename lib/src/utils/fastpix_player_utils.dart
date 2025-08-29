import 'dart:io';

/// Utility functions for FastPix Player
class FastPixPlayerUtils {
  /// Check if the current platform is iOS
  static bool get isIOS => Platform.isIOS;

  /// Check if the current platform is Android
  static bool get isAndroid => Platform.isAndroid;

  // Cache platform headers for better performance
  static Map<String, String>? _iosHeaders;
  static Map<String, String>? _androidHeaders;

  /// Get platform-specific headers for better compatibility
  static Map<String, String> getPlatformHeaders() {
    if (isIOS) {
      return _iosHeaders ??= {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1',
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
        'Connection': 'keep-alive',
        'Cache-Control': 'no-cache',
      };
    } else if (isAndroid) {
      return _androidHeaders ??= {
        'Content-Type': 'application/vnd.apple.mpegurl',
      };
    }
    return {};
  }

  /// Sanitize FastPix stream URL for Better Player Plus compatibility
  /// This method handles known compatibility issues between FastPix streams and Better Player Plus
  static String sanitizeStreamUrl(String originalUrl) {
    if (!originalUrl.contains('fastpix.app')) {
      return originalUrl; // Not a FastPix stream, return as-is
    }

    String sanitizedUrl = originalUrl;

    // Remove problematic query parameters that can cause parsing issues
    sanitizedUrl = _removeProblematicQueryParams(sanitizedUrl);

    // Clean up URL encoding issues
    sanitizedUrl = _cleanUrlEncoding(sanitizedUrl);

    // Add compatibility headers if needed
    sanitizedUrl = _addCompatibilityParams(sanitizedUrl);

    return sanitizedUrl;
  }

  /// Remove query parameters that can cause Better Player Plus parsing issues
  static String _removeProblematicQueryParams(String url) {
    // Remove minResolution and maxResolution as they can cause manifest parsing issues
    final uri = Uri.parse(url);
    final queryParams = Map<String, String>.from(uri.queryParameters);

    // Remove problematic parameters
    queryParams.remove('minResolution');
    queryParams.remove('maxResolution');

    // Rebuild URL without problematic parameters
    return uri
        .replace(queryParameters: queryParams.isEmpty ? null : queryParams)
        .toString();
  }

  /// Clean up URL encoding issues that Better Player Plus might not handle well
  static String _cleanUrlEncoding(String url) {
    // Ensure proper URL formatting
    return url.trim();
  }

  /// Add compatibility parameters for Better Player Plus
  static String _addCompatibilityParams(String url) {
    final uri = Uri.parse(url);
    final queryParams = Map<String, String>.from(uri.queryParameters);

    // Add compatibility parameters
    queryParams['_compat'] = 'betterplayer';
    queryParams['_format'] = 'hls';

    return uri.replace(queryParameters: queryParams).toString();
  }

  /// Get Better Player Plus specific headers for FastPix streams
  static Map<String, String> getBetterPlayerPlusHeaders() {
    return {
      'Accept':
          'application/vnd.apple.mpegurl, application/x-mpegURL, text/plain, */*',
      'Accept-Encoding': 'identity', // Prevent compression issues
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
      'User-Agent': 'BetterPlayerPlus/1.0',
      'Connection': 'keep-alive',
    };
  }

  /// Check if a stream URL needs sanitization
  static bool needsSanitization(String url) {
    return url.contains('fastpix.app') &&
        (url.contains('minResolution') || url.contains('maxResolution'));
  }

  /// Get sanitized headers specifically for Better Player Plus compatibility
  static Map<String, String> getSanitizedHeaders(
    Map<String, String>? originalHeaders,
  ) {
    final headers = Map<String, String>.from(originalHeaders ?? {});

    // Add Better Player Plus specific headers
    headers.addAll(getBetterPlayerPlusHeaders());

    // Add platform-specific headers
    headers.addAll(getPlatformHeaders());

    return headers;
  }
}
