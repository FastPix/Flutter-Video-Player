import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';

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

  final VideoDetailsData? videoData;
  final List<String>? customData;

  final FastPixPlayerVideoQuality? minResolution;
  final FastPixPlayerVideoQuality? maxResolution;
  final FastPixPlayerVideoQuality? resolution;
  final FastpixPlayerRenditionOrder? renditionOrder;

  /// Video thumbnail URL
  final String? thumbnailUrl;

  /// Video duration in seconds
  final Duration? duration;

  /// Whether the video is live stream
  final StreamType streamType;

  /// Video headers for authentication
  final Map<String, String>? headers;

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

  /// Base URL for the streaming service
  static const String _baseUrl = 'https://stream.fastpix.io';

  const FastPixPlayerDataSource({
    required this.playbackId,
    required this.format,
    this.customDomain,
    this.token,
    this.title,
    this.videoData,
    this.customData,
    this.description,
    this.thumbnailUrl,
    this.duration,
    this.minResolution,
    this.maxResolution,
    this.renditionOrder,
    this.resolution,
    this.streamType = StreamType.onDemand,
    this.headers,
    this.drmEnabled = false,
    this.cacheEnabled = true,
    this.cacheDirectory,
    this.maxCacheSize,
    this.useHlsSubtitles = false,
    this.subtitles,
    this.showSubtitles = false,
    this.loop = false,
    this.startAt,
    this.endAt,
  });

  /// Get the constructed streaming URL
  String get url {
    final extension = format == FastPixStreamingFormat.hls ? '.m3u8' : '.mpd';

    if (playbackId.isEmpty) {
      throw ArgumentError('Playback ID cannot be empty');
    }

    final hasToken = token?.isNotEmpty == true;
    final hasCustomDomain = customDomain?.isNotEmpty == true;
    final hasQualityControl =
        minResolution != null ||
                maxResolution != null ||
                resolution != null ||
                renditionOrder != null
            ? true
            : false;

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
      if (minResolution != FastPixPlayerVideoQuality.auto) {
        queryParams.add('minResolution=${minResolution?.resolution}');
      }
      if (maxResolution != FastPixPlayerVideoQuality.auto) {
        queryParams.add('maxResolution=${maxResolution?.resolution}');
      }
      if (resolution != FastPixPlayerVideoQuality.auto) {
        queryParams.add('resolution=${resolution?.resolution}');
      }
      if (renditionOrder != FastpixPlayerRenditionOrder.auto) {
        queryParams.add('renditionOrder=${renditionOrder?.order}');
      }
    }

    // Append query parameters if any exist
    if (queryParams.isNotEmpty) {
      final separator = baseUrl.contains('?') ? '&' : '?';
      baseUrl += '$separator${queryParams.join('&')}';
    }

    // Debug logging removed for production
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
      cacheConfiguration: BetterPlayerCacheConfiguration(
        useCache: cacheEnabled,
        maxCacheSize:
            maxCacheSize ?? 100 * 1024 * 1024, // Default 100MB if not specified
        preCacheSize: 10 * 1024 * 1024, // 10MB pre-cache
      ),
      headers: enhancedHeaders,
      videoFormat: BetterPlayerVideoFormat.hls,
      liveStream: streamType == StreamType.live,
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
    FastPixPlayerVideoQuality? minResolution,
    FastPixPlayerVideoQuality? maxResolution,
    FastPixPlayerVideoQuality? resolution,
    FastpixPlayerRenditionOrder? renditionOrder,
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
    bool? drmEnabled,
    VideoDetailsData? videoData,
    List<String>? customData,
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
      minResolution: minResolution ?? this.minResolution,
      maxResolution: maxResolution ?? this.maxResolution,
      resolution: resolution ?? this.resolution,
      renditionOrder: renditionOrder ?? this.renditionOrder,
      drmEnabled: drmEnabled ?? this.drmEnabled,
      customData: customData ?? this.customData,
      videoData: videoData ?? this.videoData,
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
    FastPixPlayerVideoQuality? minResolution,
    FastPixPlayerVideoQuality? maxResolution,
    FastPixPlayerVideoQuality? resolution,
    FastpixPlayerRenditionOrder? renditionOrder,
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
    bool drmEnabled = false,
    VideoDetailsData? videoData,
    List<String>? customData,
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
      minResolution: minResolution,
      maxResolution: maxResolution,
      resolution: resolution,
      renditionOrder: renditionOrder,
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
      videoData: videoData,
      customData: customData,
      customDomain: customDomain,
      drmEnabled: drmEnabled,
    );
  }
}
