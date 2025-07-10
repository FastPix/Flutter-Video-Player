import 'package:better_player_plus/better_player_plus.dart';
import '../enums/fastpix_player_enums.dart';
import '../utils/fastpix_player_utils.dart';
import 'fastpix_player_subtitle.dart';
import 'fastpix_player_quality_control.dart';

/// Supported streaming formats for FastPix Player
enum FastPixStreamingFormat {
  /// HLS (HTTP Live Streaming) format
  hls,
}

enum StreamType { live, onDemand }

/// Data source configuration for FastPix Player
/// Only supports HLS streaming formats
class FastPixPlayerDataSource {
  /// Playback ID for the stream
  final String playbackId;

  final String? token;

  final String? customDomain;

  /// Streaming format (HLS)
  final FastPixStreamingFormat format;

  /// Video title
  final String? title;

  final bool drmEnabled;

  /// Video description
  final String? description;

  /// Video thumbnail URL
  final String? thumbnailUrl;

  /// Video duration in seconds
  final Duration? duration;

  /// Whether the video is live stream
  final StreamType streamType;

  /// Video headers for authentication
  final Map<String, String>? headers;

  /// Video quality options
  final List<FastPixVideoQuality>? availableQualities;

  /// Initial quality selection
  final FastPixVideoQuality? initialQuality;

  /// Whether to cache the video
  final bool cacheEnabled;

  /// Cache directory path
  final String? cacheDirectory;

  /// Maximum cache size in bytes
  final int? maxCacheSize;

  /// Whether to use HLS
  final bool useHlsSubtitles;

  /// Subtitle tracks
  final List<FastPixPlayerSubtitle>? subtitles;

  /// Whether to show subtitles by default
  final bool showSubtitles;

  /// Whether to loop the video
  final bool loop;

  /// Start time for the video
  final Duration? startAt;

  /// End time for the video
  final Duration? endAt;

  /// Quality control parameters
  final FastPixPlayerQualityControl? qualityControl;

  /// Base URL for the streaming service
  static const String _baseUrl = 'https://stream.fastpix.io';
  static const String _drmUrlWidevine =
      'https://api.fastpix.app/v1/on-demand/drm/license/widevine';
  static const String _drmUrlFairPlay =
      'https://api.fastpix.app/v1/on-demand/drm/license/fairplay';
  static const String _certificateUrlFairPlay =
      'https://api.fastpix.app/v1/on-demand/drm/cert/fairplay';

  const FastPixPlayerDataSource({
    required this.playbackId,
    required this.format,
    this.customDomain,
    this.token,
    this.title,
    this.description,
    this.thumbnailUrl,
    this.duration,
    this.streamType = StreamType.onDemand,
    this.headers,
    this.availableQualities,
    this.drmEnabled = false,
    this.initialQuality,
    this.cacheEnabled = true,
    this.cacheDirectory,
    this.maxCacheSize,
    this.useHlsSubtitles = false,
    this.subtitles,
    this.showSubtitles = false,
    this.loop = false,
    this.startAt,
    this.endAt,
    this.qualityControl,
  });

  String get _certificateLicenseUrl {
    if (playbackId.isEmpty) {
      throw ArgumentError('Playback ID cannot be empty');
    }
    final hasToken = token?.isNotEmpty == true;
    if (hasToken) {
      return '$_certificateUrlFairPlay/$playbackId?token=$token';
    }
    return '$_certificateUrlFairPlay/$playbackId';
  }

  String get _drmLicenseFairPlay {
    if (playbackId.isEmpty) {
      throw ArgumentError('Playback ID cannot be empty');
    }
    final hasToken = token?.isNotEmpty == true;
    if (hasToken) {
      return '$_drmUrlFairPlay/$playbackId?token=$token';
    }
    return '$_drmUrlFairPlay/$playbackId';
  }

  String get _drmLicenseUrl {
    if (playbackId.isEmpty) {
      throw ArgumentError('Playback ID cannot be empty');
    }
    final hasToken = token?.isNotEmpty == true;
    if (hasToken) {
      return '$_drmUrlWidevine/$playbackId?token=$token';
    }
    return '$_drmUrlWidevine/$playbackId';
  }

  /// Get the constructed streaming URL
  String get url {
    final extension = format == FastPixStreamingFormat.hls ? '.m3u8' : '.mpd';

    if (playbackId.isEmpty) {
      throw ArgumentError('Playback ID cannot be empty');
    }

    final hasToken = token?.isNotEmpty == true;
    final hasCustomDomain = customDomain?.isNotEmpty == true;
    final hasQualityControl = qualityControl?.hasParameters == true;

    // Build base URL
    String baseUrl;
    if (hasCustomDomain) {
      baseUrl = 'https://$customDomain/$playbackId$extension';
    } else {
      baseUrl = '$_baseUrl/$playbackId$extension';
    }

    // Build query parameters
    final queryParams = <String>[];

    if (hasToken) {
      queryParams.add('token=$token');
    }

    if (hasQualityControl) {
      final qualityParams = qualityControl!.buildQueryParameters();
      if (qualityParams.isNotEmpty) {
        queryParams.add(qualityParams);
      }
    }

    // Append query parameters if any exist
    if (queryParams.isNotEmpty) {
      final separator = baseUrl.contains('?') ? '&' : '?';
      baseUrl += '$separator${queryParams.join('&')}';
    }

    return baseUrl;
  }

  /// Convert to BetterPlayerDataSource
  BetterPlayerDataSource toBetterPlayerDataSource() {
    // Add platform-specific headers for better compatibility
    final enhancedHeaders = Map<String, String>.from(headers ?? {});
    enhancedHeaders.addAll(FastPixPlayerUtils.getPlatformHeaders());

    // Add iOS-specific headers for HLS streams to handle encoding issues
    if (format == FastPixStreamingFormat.hls && FastPixPlayerUtils.isIOS) {
      enhancedHeaders['Accept'] =
          'application/vnd.apple.mpegurl, application/x-mpegURL, text/plain, */*';
      enhancedHeaders['Accept-Encoding'] = 'identity';
      enhancedHeaders['Cache-Control'] = 'no-cache';
      enhancedHeaders['Pragma'] = 'no-cache';
    }
    return BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      url,
      headers: enhancedHeaders,
      liveStream: streamType == StreamType.live,
      bufferingConfiguration: BetterPlayerBufferingConfiguration(
        minBufferMs: 20000,
        maxBufferMs: 50000,
        bufferForPlaybackMs: 1500,
        bufferForPlaybackAfterRebufferMs: 3000,
      ),
      cacheConfiguration:
          cacheEnabled
              ? BetterPlayerCacheConfiguration(
                useCache: true,
                maxCacheSize: maxCacheSize ?? 10 * 1024 * 1024,
                maxCacheFileSize: 10 * 1024 * 1024,
              )
              : null,
      videoFormat: BetterPlayerVideoFormat.hls,
    );
  }

  /// Create a copy with updated values
  FastPixPlayerDataSource copyWith({
    String? playbackId,
    FastPixStreamingFormat? format,
    String? title,
    String? description,
    String? thumbnailUrl,
    Duration? duration,
    StreamType? streamType,
    Map<String, String>? headers,
    List<FastPixVideoQuality>? availableQualities,
    FastPixVideoQuality? initialQuality,
    bool? cacheEnabled,
    String? cacheDirectory,
    int? maxCacheSize,
    bool? useHlsSubtitles,
    List<FastPixPlayerSubtitle>? subtitles,
    bool? showSubtitles,
    bool? loop,
    Duration? startAt,
    Duration? endAt,
    String? token,
    String? customDomain,
    FastPixPlayerQualityControl? qualityControl,
    bool? drmEnabled,
  }) {
    return FastPixPlayerDataSource(
      playbackId: playbackId ?? this.playbackId,
      format: format ?? this.format,
      title: title ?? this.title,
      description: description ?? this.description,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      duration: duration ?? this.duration,
      streamType: streamType ?? this.streamType,
      headers: headers ?? this.headers,
      availableQualities: availableQualities ?? this.availableQualities,
      initialQuality: initialQuality ?? this.initialQuality,
      cacheEnabled: cacheEnabled ?? this.cacheEnabled,
      cacheDirectory: cacheDirectory ?? this.cacheDirectory,
      maxCacheSize: maxCacheSize ?? this.maxCacheSize,
      useHlsSubtitles: useHlsSubtitles ?? this.useHlsSubtitles,
      subtitles: subtitles ?? this.subtitles,
      showSubtitles: showSubtitles ?? this.showSubtitles,
      loop: loop ?? this.loop,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      token: token ?? this.token,
      customDomain: customDomain ?? this.customDomain,
      qualityControl: qualityControl ?? this.qualityControl,
      drmEnabled: drmEnabled ?? this.drmEnabled,
    );
  }

  /// Create HLS data source
  factory FastPixPlayerDataSource.hls({
    required String playbackId,
    String? title,
    String? description,
    String? thumbnailUrl,
    Duration? duration,
    StreamType streamType = StreamType.onDemand,
    Map<String, String>? headers,
    List<FastPixVideoQuality>? availableQualities,
    FastPixVideoQuality? initialQuality,
    bool cacheEnabled = true,
    String? cacheDirectory,
    int? maxCacheSize,
    bool useHlsSubtitles = false,
    List<FastPixPlayerSubtitle>? subtitles,
    bool showSubtitles = false,
    bool loop = false,
    Duration? startAt,
    Duration? endAt,
    String? token,
    String? customDomain,
    FastPixPlayerQualityControl? qualityControl,
    bool drmEnabled = false,
  }) {
    return FastPixPlayerDataSource(
      playbackId: playbackId,
      format: FastPixStreamingFormat.hls,
      title: title,
      description: description,
      thumbnailUrl: thumbnailUrl,
      duration: duration,
      streamType: streamType,
      headers: headers,
      availableQualities: availableQualities,
      initialQuality: initialQuality,
      cacheEnabled: cacheEnabled,
      cacheDirectory: cacheDirectory,
      maxCacheSize: maxCacheSize,
      useHlsSubtitles: useHlsSubtitles,
      subtitles: subtitles,
      showSubtitles: showSubtitles,
      loop: loop,
      startAt: startAt,
      endAt: endAt,
      token: token,
      customDomain: customDomain,
      qualityControl: qualityControl,
      drmEnabled: drmEnabled,
    );
  }
}
