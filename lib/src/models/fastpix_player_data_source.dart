import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';

/// Supported streaming formats for FastPix Player
enum FastPixStreamingFormat {
  /// HLS (HTTP Live Streaming) format
  hls,
}

enum StreamType { live, onDemand }

/// Buffering tuned for play-start latency rather than for the engine's own
/// conservative defaults.
///
/// **Opt-in.** Nothing applies this for you — pass it to
/// [FastPixPlayerDataSource.bufferingConfiguration] if you want it. It is not
/// part of preloading or precaching: it changes how *every* playback starts,
/// warmed or cold, so it is offered rather than imposed.
///
/// ExoPlayer will not render a first frame until [bufferForPlaybackMs] of media
/// is held, so that value is a floor on the time a viewer spends watching a
/// spinner — and at the stock 3,000 ms it is the largest remaining item on the
/// tap path once the manifest and the licence have been warmed away. Playback
/// then continues filling the buffer normally; starting earlier does not mean
/// holding less.
///
/// What each value is doing:
///
/// * `bufferForPlaybackMs: 500` — start on half a second of media. The single
///   change that moves perceived start time.
/// * `bufferForPlaybackAfterRebufferMs: 2000` — deliberately **higher** than
///   the start value. A rebuffer means the network already failed to keep up,
///   so resuming on 500 ms would stall again within seconds; a viewer forgives
///   one longer pause far more readily than a repeated stutter.
/// * `minBufferMs: 15000` / `maxBufferMs: 50000` — a 15–50 s cushion. The
///   engine's 6,553,600 ms ceiling lets it buffer far ahead of the playhead,
///   which on mobile spends the viewer's data on media they may never reach.
///
/// Android only. On iOS this is ignored — AVFoundation exposes no equivalent
/// control and manages its own buffer.
///
/// Override per source via [FastPixPlayerDataSource.bufferingConfiguration] if
/// your own measurements disagree. These values came from production
/// measurement on one catalogue; they are a better starting point than the
/// engine defaults, not a universal answer.
const BetterPlayerBufferingConfiguration fastPixPlayStartBuffering =
    BetterPlayerBufferingConfiguration(
      minBufferMs: 15000,
      maxBufferMs: 50000,
      bufferForPlaybackMs: 500,
      bufferForPlaybackAfterRebufferMs: 2000,
    );

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

  /// DRM configuration. When set, the stream is played back through the
  /// FastPix license server. Requires [token] to be set as well.
  final FastPixPlayerDrmConfiguration? drmConfiguration;

  /// Whether this source is DRM protected
  bool get drmEnabled => drmConfiguration != null;

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

  /// How much media must be buffered before the first frame is shown, and how
  /// much is held ahead of the playhead.
  ///
  /// **Defaults to the engine's own values, so playback is unchanged unless
  /// you opt in.** Pass [fastPixPlayStartBuffering] to trade a larger starting
  /// buffer for a faster first frame; that is a change to playback behaviour
  /// in its own right, independent of preloading, and wants its own testing.
  ///
  /// Android only; the field is ignored on iOS, where AVFoundation decides for
  /// itself.
  ///
  /// Whatever is set here is part of the preload fingerprint. A warmed player
  /// is built with these values and cannot change them afterwards, so warming
  /// and playback must agree or the adoption is refused. That holds at the
  /// engine defaults just as it does at any other setting — both paths derive
  /// this from the same data source, so they agree by construction.
  final BetterPlayerBufferingConfiguration bufferingConfiguration;

  /// Whether captions declared inside the HLS manifest are offered.
  ///
  /// On by default, since FastPix carries captions in the manifest.
  final bool useHlsSubtitles;

  /// External subtitle files, offered alongside any the manifest declares.
  final List<FastPixPlayerSubtitle>? subtitles;

  /// Whether an external track is selected before playback starts.
  ///
  /// Picks the [FastPixPlayerSubtitle.isDefault] track, else the first. Has no
  /// effect on in-manifest tracks, which are offered but start off.
  final bool showSubtitles;

  /// Whether to loop the video
  final bool loop;

  /// Stretches of this video a viewer may want to jump over — an intro, a
  /// recap, a song, the credits.
  ///
  /// Optional; a source declaring none behaves exactly as it did before. The
  /// player holds them as pending configuration until this media's duration is
  /// known, validates them once against it, and then reports when playback
  /// enters and leaves each one. See [FastPixPlayerController.skipCurrentSegment].
  ///
  /// Deliberately separate from
  /// [FastPixPlayerControlsConfiguration.enableSkips], which means the engine's
  /// own ±10 second buttons.
  final List<FastPixSkipSegment>? skipSegments;

  /// Where playback of this source begins, or null for the start.
  ///
  /// Applied before the first frame is shown: the player is positioned here
  /// and only then started, so a resumed video never shows its opening
  /// seconds first. Belongs to the source, so a playlist item carrying one
  /// starts there every time it is loaded.
  final Duration? startAt;

  /// End time for the video
  final Duration? endAt;

  /// Base URL for the streaming service
  static const String _baseUrl = 'https://stream.fastpix.com';

  /// Origin every playback URL is built on.
  ///
  /// Exposed so `warmPlaybackHosts()` warms the host the player will actually
  /// contact, rather than a literal duplicated at the call site — a warm
  /// pointed at the wrong host costs nothing, throws nothing, and reports
  /// success while warming nothing.
  static const String streamingHost = _baseUrl;

  /// Origin serving images — seek-preview spritesheets — for sources with no
  /// [customDomain].
  static const String defaultImagesHost = 'https://images.fastpix.com';

  /// Origin serving this source's images, derived from [customDomain], or null
  /// when it cannot be derived.
  ///
  /// FastPix serves images from the stream host with the token `stream`
  /// replaced by `images` in the first label, and nothing else changed:
  ///
  /// ```
  /// stream.fastpix.com        -> images.fastpix.com
  /// stream.fastpix.io         -> images.fastpix.io
  /// venus-stream.fastpix.dev  -> venus-images.fastpix.dev
  /// ```
  ///
  /// The rule reads the host rather than memorising it. Both native SDKs map
  /// this with a hard-coded table and both are already wrong — iOS has no
  /// entry for `stream.fastpix.com`, so production media gets no seek preview
  /// at all there — because a table stops being correct the moment FastPix
  /// adds an environment.
  ///
  /// No [customDomain] means the stream host is `stream.fastpix.com`, so the
  /// images host is [defaultImagesHost].
  ///
  /// Null means the host is genuinely unknown: a `customDomain` that is an
  /// apex or vanity host carries nothing to derive from. Callers skip images
  /// rather than fall back, since a guessed host would only buy a 404 on the
  /// seek path to reach the same time-only preview.
  String? get imagesHost {
    final domain = customDomain?.trim();
    if (domain == null || domain.isEmpty) return defaultImagesHost;

    // A domain pasted from a browser or a config file may carry a scheme and a
    // trailing slash; neither belongs in the label being rewritten.
    // Lowercased because host names are case-insensitive: `Stream.fastpix.co`
    // plays perfectly well, so it must not be the one spelling that silently
    // loses seek previews.
    final bare = domain
        .replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '')
        .replaceAll(RegExp(r'/+$'), '')
        .toLowerCase();
    if (bare.isEmpty) return defaultImagesHost;

    final split = bare.indexOf('.');
    if (split <= 0) return null;
    final label = bare.substring(0, split);
    final rest = bare.substring(split);

    // Either the whole label is `stream`, or it is an environment prefix
    // joined to it by a hyphen (`venus-stream`). Anything else — `xyz`, `cdn`,
    // `streaming` — is not a FastPix stream host and must not be rewritten.
    final String imagesLabel;
    if (label == 'stream') {
      imagesLabel = 'images';
    } else if (label.endsWith('-stream')) {
      imagesLabel =
          '${label.substring(0, label.length - 'stream'.length)}images';
    } else {
      return null;
    }

    return 'https://$imagesLabel$rest';
  }

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
    this.drmConfiguration,
    this.cacheEnabled = true,
    this.cacheDirectory,
    this.maxCacheSize,
    this.bufferingConfiguration = const BetterPlayerBufferingConfiguration(),
    this.useHlsSubtitles = true,
    this.subtitles,
    this.showSubtitles = false,
    this.loop = false,
    this.skipSegments,
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

    // DRM protected media is always private: the playback token is required in
    // addition to the DRM token used for the license request. Validation also
    // covers the DRM token and the platform/DRM system combination, and throws
    // a [FastPixDrmException] describing what to fix.
    drmConfiguration?.validate(
      playbackId: playbackId,
      hasPlaybackToken: hasToken,
    );
    final hasCustomDomain = customDomain?.isNotEmpty == true;

    // Build base URL
    String baseUrl =
        hasCustomDomain
            ? 'https://$customDomain/$playbackId$extension'
            : '$_baseUrl/$playbackId$extension';

    final queryParams = _buildQueryParameters(hasToken: hasToken);

    // Append query parameters if any exist
    if (queryParams.isNotEmpty) {
      final separator = baseUrl.contains('?') ? '&' : '?';
      baseUrl += '$separator${queryParams.join('&')}';
    }

    // Debug logging removed for production
    return baseUrl;
  }

  /// Build the query string parameters for [url].
  ///
  /// A quality parameter is only sent when the caller pinned that dimension to
  /// something other than `auto`.
  List<String> _buildQueryParameters({required bool hasToken}) {
    final queryParams = <String>[];

    if (hasToken) {
      queryParams.add('token=$token');
    }

    final hasQualityControl =
        minResolution != null ||
        maxResolution != null ||
        resolution != null ||
        renditionOrder != null;

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

    return queryParams;
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
    // Caching is unusable for HLS on iOS: better_player serves cached bytes
    // through a `CachingPlayerItem`, a single-file downloader that cannot stand
    // in for a playlist resolving to many segment URLs. With it enabled
    // AVFoundation rejects an otherwise healthy stream with
    // CoreMediaErrorDomain -12642.
    //
    // Since HLS is the only format here, this excludes iOS entirely — which
    // also settles the DRM question on that platform: caching and FairPlay both
    // need the asset's `AVAssetResourceLoader`, and an asset has exactly one
    // delegate, so the two could not coexist there anyway.
    //
    // DRM is deliberately NOT excluded on Android. media3 keeps
    // `DrmSessionManager` and `CacheDataSource` orthogonal, and cached segments
    // stay encrypted on disk — the licence is fetched fresh at playback and
    // decrypts them then. That is ordinary behaviour for a streaming player.
    // Only *offline* playback needs a persistent licence, which is a separate
    // feature with its own key management.
    final isIosHls =
        FastPixPlayerUtils.isIOS && format == FastPixStreamingFormat.hls;

    // iOS HLS caching is enabled for unprotected sources and **must** stay off
    // for protected ones.
    //
    // The engine branches on this flag, and the two branches are not equivalent
    // (`BetterPlayer.swift:184`):
    //
    // ```swift
    // if useCache {
    //     item = cacheManager.getCachingPlayerItemForNormalPlayback(...)
    // } else {
    //     let asset = AVURLAsset(...)
    //     if let certificateUrl { asset.resourceLoader.setDelegate(delegate, ...) }
    // }
    // ```
    //
    // The FairPlay content-key delegate is attached **only in the else
    // branch**. Enabling the cache for a DRM source therefore hands playback an
    // item with no key handling at all — the stream fails rather than plays
    // slower, and it fails in a way that reads as a licensing problem. That is
    // the `-12642` class of failure, and it is why caching and FairPlay cannot
    // coexist here.
    //
    // ## Why not even for unprotected HLS
    //
    // The cached branch routes through the engine's local
    // `HLSCachingReverseProxyServer` (`127.0.0.1:8080`), which looks like it
    // should be safe: ordinary HTTP, no resource loader, nothing competing for
    // the single delegate slot an asset has.
    //
    // It was tried, on an unprotected FastPix stream with no DRM anywhere in
    // the picture, and it fails outright:
    //
    // ```
    // useCache=true
    // Failed to load video: CoreMediaErrorDomain error -12642
    // ```
    //
    // So the proxy does not survive a signed FastPix URL — plausibly it drops
    // the `?token=` or the headers when rewriting, and the CDN refuses the
    // forwarded request. Whatever the cause, the result is a hard failure
    // rather than a slow start, which is worse than no caching at all.
    //
    // See `example/integration_test/ios_cache_path_test.dart`, which reproduces
    // it. Re-enable this only if that test goes green.
    final useCache = cacheEnabled && !isIosHls;

    return BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      url,
      cacheConfiguration: BetterPlayerCacheConfiguration(
        useCache: useCache,
        maxCacheSize:
            maxCacheSize ?? 100 * 1024 * 1024, // Default 100MB if not specified
        preCacheSize: 10 * 1024 * 1024, // 10MB pre-cache
      ),
      headers: enhancedHeaders,
      videoFormat: BetterPlayerVideoFormat.hls,
      // Set here rather than at the player, so the preload manager's warmed
      // player is built with the identical load control by construction.
      bufferingConfiguration: bufferingConfiguration,
      liveStream: streamType == StreamType.live,
      // In-manifest captions are found by the player; external files are
      // declared here. Both feed the same subtitle menu.
      useAsmsSubtitles: useHlsSubtitles,
      subtitles: _toBetterPlayerSubtitlesSources(),
      drmConfiguration: drmConfiguration?.toBetterPlayerDrmConfiguration(
        playbackId,
      ),
    );
  }

  /// External subtitle tracks in better_player's shape.
  List<BetterPlayerSubtitlesSource>? _toBetterPlayerSubtitlesSources() {
    final tracks = subtitles;
    if (tracks == null || tracks.isEmpty) return null;

    // Exactly one track may be pre-selected; marking several leaves
    // better_player picking whichever it scans last.
    final int defaultIndex = tracks.indexWhere((track) => track.isDefault);
    int selectedIndex = -1;
    if (showSubtitles) {
      selectedIndex = defaultIndex >= 0 ? defaultIndex : 0;
    }

    return <BetterPlayerSubtitlesSource>[
      for (int i = 0; i < tracks.length; i++)
        BetterPlayerSubtitlesSource(
          type: BetterPlayerSubtitlesSourceType.network,
          name: tracks[i].name,
          urls: <String>[tracks[i].url],
          selectedByDefault: i == selectedIndex,
        ),
    ];
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
    BetterPlayerBufferingConfiguration? bufferingConfiguration,
    bool? useHlsSubtitles,
    List<FastPixPlayerSubtitle>? subtitles,
    bool? showSubtitles,
    bool? loop,
    List<FastPixSkipSegment>? skipSegments,
    Duration? startAt,
    Duration? endAt,
    String? token,
    String? customDomain,
    FastPixPlayerDrmConfiguration? drmConfiguration,
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
      bufferingConfiguration:
          bufferingConfiguration ?? this.bufferingConfiguration,
      useHlsSubtitles: useHlsSubtitles ?? this.useHlsSubtitles,
      subtitles: subtitles ?? this.subtitles,
      showSubtitles: showSubtitles ?? this.showSubtitles,
      loop: loop ?? this.loop,
      skipSegments: skipSegments ?? this.skipSegments,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      token: token ?? this.token,
      customDomain: customDomain ?? this.customDomain,
      minResolution: minResolution ?? this.minResolution,
      maxResolution: maxResolution ?? this.maxResolution,
      resolution: resolution ?? this.resolution,
      renditionOrder: renditionOrder ?? this.renditionOrder,
      drmConfiguration: drmConfiguration ?? this.drmConfiguration,
      customData: customData ?? this.customData,
      videoData: videoData ?? this.videoData,
    );
  }

  /// Build a source from one playlist JSON entry.
  ///
  /// The contract is deliberately forgiving in one direction and strict in the
  /// other: `playbackId` is required and must be a non-empty string, every
  /// other field is optional, and **unknown keys are ignored** — so a producer
  /// can add fields without breaking integrations already in the field.
  ///
  /// Anything unreadable throws [FastPixPlaylistException] naming the problem
  /// and, for a playlist, the offending position. A playlist is adopted whole
  /// or not at all, so a bad entry is reported rather than skipped: a silently
  /// shortened playlist is far harder to diagnose than a rejected one.
  ///
  /// ```json
  /// {
  ///   "playbackId": "abc123",
  ///   "title": "Episode 1",
  ///   "token": "…",
  ///   "drmToken": "…",
  ///   "customDomain": "stream.example.com",
  ///   "thumbnailUrl": "https://…/thumb.jpg",
  ///   "duration": 1425.5,
  ///   "streamType": "onDemand",
  ///   "skipSegments": [{"start": 0, "end": 30, "type": "intro"}]
  /// }
  /// ```
  ///
  /// Times — `duration`, and each segment's `start` and `end` — are seconds.
  factory FastPixPlayerDataSource.fromJson(
    Map<String, dynamic> json, {

    /// Position in the playlist, quoted in any failure so the caller can find
    /// the entry that is wrong.
    int? itemIndex,
  }) {
    final playbackId = json['playbackId'];
    if (playbackId is! String || playbackId.isEmpty) {
      _rejectEntry(
        FastPixPlaylistErrorCode.missingPlaybackId,
        'Every playlist entry needs a non-empty "playbackId".',
        itemIndex,
      );
    }

    final drmToken = _readString(json, 'drmToken', itemIndex);
    final title = _readString(json, 'title', itemIndex);
    final streamType = _readStreamType(json, itemIndex);

    return FastPixPlayerDataSource.hls(
      playbackId: playbackId,
      token: _readString(json, 'token', itemIndex),
      customDomain: _readString(json, 'customDomain', itemIndex),
      title: title,
      description: _readString(json, 'description', itemIndex),
      thumbnailUrl: _readString(json, 'thumbnailUrl', itemIndex),
      duration: _readSeconds(json, 'duration', itemIndex),
      streamType: streamType,
      drmConfiguration: drmToken == null
          ? null
          : FastPixPlayerDrmConfiguration(drmToken: drmToken),
      skipSegments: _readSkipSegments(json, itemIndex),
      videoData: VideoDetailsData(
        videoId: playbackId,
        title: title ?? playbackId,
      ),
    );
  }

  /// Reject a playlist entry, naming its position when one was supplied.
  ///
  /// The readers below are static rather than closures inside
  /// [FastPixPlayerDataSource.fromJson] so that each validation rule can be
  /// read on its own, without the factory carrying all of them at once.
  static Never _rejectEntry(
    FastPixPlaylistErrorCode code,
    String message,
    int? itemIndex,
  ) =>
      throw FastPixPlaylistException(code, message, itemIndex: itemIndex);

  static String? _readString(
    Map<String, dynamic> json,
    String key,
    int? itemIndex,
  ) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) {
      _rejectEntry(
        FastPixPlaylistErrorCode.malformedEntry,
        'Playlist entry "$key" must be a string.',
        itemIndex,
      );
    }
    return value.isEmpty ? null : value;
  }

  static Duration? _readSeconds(
    Map<String, dynamic> json,
    String key,
    int? itemIndex,
  ) {
    final value = json[key];
    if (value == null) return null;
    if (value is! num) {
      _rejectEntry(
        FastPixPlaylistErrorCode.malformedEntry,
        'Playlist entry "$key" must be a number of seconds.',
        itemIndex,
      );
    }
    return Duration(milliseconds: (value * 1000).round());
  }

  static StreamType _readStreamType(Map<String, dynamic> json, int? itemIndex) {
    final streamType = _readString(json, 'streamType', itemIndex);
    if (streamType == null) return StreamType.onDemand;
    if (streamType == 'live') return StreamType.live;
    if (streamType == 'onDemand') return StreamType.onDemand;
    _rejectEntry(
      FastPixPlaylistErrorCode.malformedEntry,
      'Playlist entry "streamType" must be "live" or "onDemand".',
      itemIndex,
    );
  }

  static List<FastPixSkipSegment>? _readSkipSegments(
    Map<String, dynamic> json,
    int? itemIndex,
  ) {
    final value = json['skipSegments'];
    if (value == null) return null;
    if (value is! List) {
      _rejectEntry(
        FastPixPlaylistErrorCode.malformedEntry,
        'Playlist entry "skipSegments" must be an array.',
        itemIndex,
      );
    }
    return <FastPixSkipSegment>[
      for (final entry in value)
        if (entry is Map)
          FastPixSkipSegment.fromJson(
            Map<String, dynamic>.from(entry),
            itemIndex: itemIndex,
          )
        else
          _rejectEntry(
            FastPixPlaylistErrorCode.malformedEntry,
            'Every "skipSegments" entry must be an object.',
            itemIndex,
          ),
    ];
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
    BetterPlayerBufferingConfiguration bufferingConfiguration =
        const BetterPlayerBufferingConfiguration(),
    bool useHlsSubtitles = true,
    List<FastPixPlayerSubtitle>? subtitles,
    bool showSubtitles = false,
    bool loop = false,
    List<FastPixSkipSegment>? skipSegments,
    Duration? startAt,
    Duration? endAt,
    String? token,
    String? customDomain,
    FastPixPlayerDrmConfiguration? drmConfiguration,
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
      bufferingConfiguration: bufferingConfiguration,
      useHlsSubtitles: useHlsSubtitles,
      subtitles: subtitles,
      showSubtitles: showSubtitles,
      loop: loop,
      skipSegments: skipSegments,
      startAt: startAt,
      endAt: endAt,
      token: token,
      videoData: videoData,
      customData: customData,
      customDomain: customDomain,
      drmConfiguration: drmConfiguration,
    );
  }
}
