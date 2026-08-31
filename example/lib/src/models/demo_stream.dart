import 'package:fastpix_video_player/fastpix_video_player.dart';

/// One entry in the demo catalog.
///
/// Holds what a viewer picks from the home screen plus everything needed to
/// build a [FastPixPlayerDataSource] for it, so the watch screen never has to
/// ask for a playback ID again.
class DemoStream {
  /// FastPix playback ID.
  final String playbackId;

  final String title;

  final String? description;

  /// Host serving the stream, or null for the package default.
  ///
  /// FastPix runs more than one environment and an account's media lives in
  /// only one of them; asking the wrong host returns a 404 that reads exactly
  /// like a deleted asset, so it stays configurable per stream.
  final String? streamHost;

  /// Playback token, for private or DRM streams.
  final String? token;

  /// License token. Only used when [drmEnabled] is set.
  final String? drmToken;

  /// Whether to play this through Widevine/FairPlay.
  ///
  /// Opt-in: a leftover DRM token must not route clear media through DRM,
  /// which never plays.
  final bool drmEnabled;

  final bool isLive;

  /// External subtitle files, on top of any the manifest declares.
  final List<FastPixPlayerSubtitle> subtitles;

  /// Whether a subtitle track starts on.
  final bool subtitlesOnByDefault;

  const DemoStream({
    required this.playbackId,
    required this.title,
    this.description,
    this.streamHost,
    this.token,
    this.drmToken,
    this.drmEnabled = false,
    this.isLive = false,
    this.subtitles = const <FastPixPlayerSubtitle>[],
    this.subtitlesOnByDefault = false,
  });

  /// Short line under the title on cards and the hero.
  String get badgeLine {
    final parts = <String>[
      if (isLive) 'LIVE' else 'HLS',
      if (drmEnabled) 'DRM',
      if (subtitles.isNotEmpty) 'CC',
    ];
    return parts.join(' · ');
  }

  FastPixPlayerDataSource toDataSource() {
    return FastPixPlayerDataSource.hls(
      playbackId: playbackId,
      customDomain: streamHost?.isEmpty ?? true ? null : streamHost,
      token: token?.isEmpty ?? true ? null : token,
      drmConfiguration:
          !drmEnabled || (drmToken?.isEmpty ?? true)
              ? null
              : FastPixPlayerDrmConfiguration(drmToken: drmToken!),
      streamType: isLive ? StreamType.live : StreamType.onDemand,
      title: title,
      description: description,
      subtitles: subtitles.isEmpty ? null : subtitles,
      showSubtitles: subtitlesOnByDefault,
      videoData: VideoDetailsData(videoId: playbackId, title: title),
    );
  }

  /// Serialised so the catalog survives an app restart.
  ///
  /// Persistence exists for one reason beyond convenience: testing precaching
  /// means force-stopping the app and replaying the *same* source. Re-entering
  /// it by hand risks a different `token`, which produces a different URL and
  /// therefore a different cache key — a guaranteed miss that looks exactly
  /// like precaching not working.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'playbackId': playbackId,
    'title': title,
    'description': description,
    'streamHost': streamHost,
    'token': token,
    'drmToken': drmToken,
    'drmEnabled': drmEnabled,
    'isLive': isLive,
    'subtitlesOnByDefault': subtitlesOnByDefault,
    'subtitles': subtitles
        .map(
          (track) => <String, dynamic>{
            'url': track.url,
            'name': track.name,
            'languageCode': track.languageCode,
            'languageName': track.languageName,
            'isDefault': track.isDefault,
          },
        )
        .toList(),
  };

  /// Rebuild from [toJson]. Returns null for anything unreadable, so one bad
  /// entry cannot stop the rest of the catalog loading.
  static DemoStream? fromJson(Map<String, dynamic> json) {
    final playbackId = json['playbackId'];
    final title = json['title'];
    if (playbackId is! String || playbackId.isEmpty || title is! String) {
      return null;
    }
    return DemoStream(
      playbackId: playbackId,
      title: title,
      description: json['description'] as String?,
      streamHost: json['streamHost'] as String?,
      token: json['token'] as String?,
      drmToken: json['drmToken'] as String?,
      drmEnabled: json['drmEnabled'] == true,
      isLive: json['isLive'] == true,
      subtitlesOnByDefault: json['subtitlesOnByDefault'] == true,
      subtitles: <FastPixPlayerSubtitle>[
        for (final track in (json['subtitles'] as List<dynamic>? ?? const []))
          if (track is Map<String, dynamic> && track['url'] is String)
            FastPixPlayerSubtitle(
              url: track['url'] as String,
              name: track['name'] as String? ?? 'Subtitle',
              languageCode: track['languageCode'] as String?,
              languageName: track['languageName'] as String?,
              isDefault: track['isDefault'] == true,
            ),
      ],
    );
  }

  DemoStream copyWith({
    String? playbackId,
    String? title,
    String? description,
    String? streamHost,
    String? token,
    String? drmToken,
    bool? drmEnabled,
    bool? isLive,
    List<FastPixPlayerSubtitle>? subtitles,
    bool? subtitlesOnByDefault,
  }) {
    return DemoStream(
      playbackId: playbackId ?? this.playbackId,
      title: title ?? this.title,
      description: description ?? this.description,
      streamHost: streamHost ?? this.streamHost,
      token: token ?? this.token,
      drmToken: drmToken ?? this.drmToken,
      drmEnabled: drmEnabled ?? this.drmEnabled,
      isLive: isLive ?? this.isLive,
      subtitles: subtitles ?? this.subtitles,
      subtitlesOnByDefault: subtitlesOnByDefault ?? this.subtitlesOnByDefault,
    );
  }
}
