# Introduction:

This SDK simplifies HLS video playback by offering a wide range of customization options for an enhanced viewing experience. It streamlines streaming setup by utilizing playback IDs that have reached the "ready" status to generate stream URLs. These playback IDs enable seamless integration and video playback within the FastPix-player, making the entire streaming process efficient and user-friendly.

# Key Features:

- ## Playback Control:
    - The `playbackId` allows for easy video playback by linking directly to the media file. Playback is available as soon as the media status is "ready."
    - `autoPlay`: Automatically starts playback once the video is loaded, providing a seamless user experience.
    - `loop`: Allows the video to repeat automatically after it finishes, perfect for continuous viewing scenarios.

- ## Security:
    - the `token` attribute is required to play private or DRM protected streams
    - **Note:** You can skip the token for public streams.

- ## DRM playback:
    - Protected media plays through the FastPix license server using `drmConfiguration`, with Widevine on Android and FairPlay on iOS.
    - License and certificate URLs are derived from the playback ID, so only the DRM token has to be supplied.
    - DRM failures are normalized into stable error codes with actionable messages, so callers can refresh a token, retry, or fall back without parsing platform error strings.

- ## Inbuilt error handling:
    - The player includes inbuilt error handling that displays appropriate error messages, helping developers quickly understand and address any issues that arise during playback.

- ## Auto detection of subtitles:
    - The player automatically detects subtitles from the manifest file and displays them during playback. This ensures that users can easily access available subtitle tracks without additional configuration.
    - Users can switch between available subtitles during playback, offering a personalized viewing experience. This feature allows viewers to choose their preferred language option easily.

- ## Advanced stream control:
    - The player supports `onDemand` and `live` stream capabilities by utilizing specified `streamType`, enabling a versatile playback experience based on content type.
    - Manage video quality with `minResolution`, `maxResolution`, `resolution` and `renditionOrder` options, allowing either automated or controlled playback quality adjustments.

# Prerequisites:

## Getting started with FastPix Flutter Player:
To get started with the FastPix Player SDK we need some prerequisites, follow these steps:
1. **Log in to the FastPix Dashboard**: Navigate to the [FastPix-Dashboard](https://dashboard.fastpix.com) and log in with your credentials.
2. **Create Media**: Start by creating a media using a pull or push method. You can also use our APIs instead for [Push media](https://fastpix.com/docs/upload-videos/upload-videos-from-device) or [Pull media](https://fastpix.com/docs/upload-videos/upload-videos-from-a-url).
3. **Retrieve Media Details**: After creation, access the media details by navigating to the "View Media" page.
4. **Get Playback ID**: From the media details, obtain the playback ID.
5. **Play Video**: Use the playback ID in the FastPix-player to play the video seamlessly.


# Installation:
To get started with the SDK, first install the FastPix Player SDK , you can use `flutter pub add fastpix_player` command to directly add it:
Or
Add the dependency in your `pubspec.yaml`:
```yaml
dependencies:
  fastpix_video_player: 1.0.1
```

### Basic Usage Example

```dart
import 'package:flutter/material.dart';
import 'package:fastpix_player/fastpix_video_player.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FastPix Player Demo',
      home: Scaffold(
        appBar: AppBar(title: const Text('FastPix Player Example')),
        body: const Center(
          child: FastPixPlayerDemo(),
        ),
      ),
    );
  }
}

class FastPixPlayerDemo extends StatefulWidget {
  const FastPixPlayerDemo({super.key});

  @override
  State<FastPixPlayerDemo> createState() => _FastPixPlayerDemoState();
}

class _FastPixPlayerDemoState extends State<FastPixPlayerDemo> {
  late FastPixPlayerController controller;

  @override
  void initState() {
    super.initState();
    
    // Create HLS data source
    final dataSource = FastPixPlayerDataSource.hls(
      playbackId: 'your-playback-id-here',
      title: 'Sample HLS Stream',
      description: 'A sample HLS stream from staging.metrix.com',
      thumbnailUrl: 'https://www.example.com/thumbnail.jpg',
    );

    final configuration = FastPixPlayerConfiguration();

    // Initialize the controller
    controller = FastPixPlayerController();
    controller.initialize(dataSource: dataSource, configuration: configuration);
  }

  @override
  Widget build(BuildContext context) {
    return FastPixPlayer(
      controller: controller,
      width: 350,
      height: 200,
      aspectRatio: FastPixAspectRatio.ratio16x9,
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}
```

### Quality Control

FastPix Player provides advanced quality control options:

```dart
// Quality control configuration
final qualityControl = FastPixPlayerQualityControl(
  // Target specific resolution
  resolution: FastPixResolution.p720,
  
  // Or set min/max resolution range
  minResolution: FastPixResolution.p480,
  maxResolution: FastPixResolution.p1080,
  
  // Rendition order (quality selection priority)
  renditionOrder: FastPixRenditionOrder.desc, // High to low quality
);

// Apply quality control to data source
final dataSource = FastPixPlayerDataSource.hls(
  playbackId: 'your-playback-id',
  qualityControl: qualityControl,
);
```

### Player Widgets

FastPix Player provides multiple widget options:

#### Basic Player Widget
```dart
FastPixPlayer( controller: controller,
  width: 350,
  height: 200,
  aspectRatio: FastPixAspectRatio.ratio16x9,
  showLoadingIndicator: true,
  loadingIndicatorColor: Colors.white,
  showErrorDetails: false,
)
```

### Controller Methods

The `FastPixPlayerController` provides comprehensive control over the player:

```dart
// Playback control
await controller.play();
await controller.pause();
await controller.seekTo(Duration(seconds: 30));
await controller.setVolume(0.5);

// State information
final isPlaying = controller.isPlaying;
final isPaused = controller.isPaused;
final isFinished = controller.isFinished;
final currentState = controller.currentState;

// Position and duration
final currentPosition = controller.getCurrentPosition();
final totalDuration = controller.getTotalDuration();

// Data source management
await controller.updateDataSource(newDataSource);
await controller.updateConfiguration(newConfiguration);
await controller.updateDataSourceAndConfiguration(
  dataSource: newDataSource,
  configuration: newConfiguration,
);
```

### Public Media

```dart
final liveDataSource = FastPixPlayerDataSource.hls(
  playbackId: 'live-stream-id',
  streamType: StreamType.onDemand, // By Default StreamType is on-demand
  cacheEnabled: false // Disable cache for streaming
);

final liveConfiguration = FastPixPlayerConfiguration(
  autoPlayConfiguration: FastPixPlayerAutoPlayConfiguration(
    autoPlay: FastPixAutoPlay.enabled,
  ),
  controlsConfiguration: FastPixPlayerControlsConfiguration(),
);
```

### Private Media
For private media, token is required. See [Generate JWTs for secure media](https://fastpix.com/docs/video-security/generate-jwts-for-secure-media) for how to create a signing key and generate the playback token, and [Secure video playback](https://fastpix.com/docs/web-player/secure-video-playback) for how the token is passed and validated.

```dart
final liveDataSource = FastPixPlayerDataSource.hls(
  playbackId: 'live-stream-id',
  streamType: StreamType.onDemand, // By Default StreamType is on-demand
  token: 'jwt-token' // Token is required for private media
);

final liveConfiguration = FastPixPlayerConfiguration(
  autoPlayConfiguration: FastPixPlayerAutoPlayConfiguration(
    autoPlay: FastPixAutoPlay.enabled,
  ),
  controlsConfiguration: FastPixPlayerControlsConfiguration(),
);
```

### DRM Protected Media

FastPix serves DRM protected media as HLS with CBCS encryption. Playback requires two JWTs: the playback `token` on the data source and the `drmToken` used to authorize the license request. When the token is generated with the **DRM License** feature enabled, the same value can be used for both.

License and certificate URLs are derived from the playback ID, so only the DRM token has to be supplied.

Generate both JWTs with the FastPix JWT generator — see [Set up DRM encryption](https://fastpix.com/docs/video-security/set-up-drm-encryption) for enabling DRM on a media, and [How to generate DRM tokens](https://fastpix.com/docs/web-player/play-drm-protected-content#how-to-generate-drm-tokens) for issuing the `token` and `drmToken` (enable the **DRM License** feature to reuse a single token for both).

```dart
final drmDataSource = FastPixPlayerDataSource.hls(
  playbackId: 'your-playback-id',
  token: 'jwt-token', // Required: DRM protected media is always private
  drmConfiguration: FastPixPlayerDrmConfiguration(
    drmToken: 'drm-jwt-token', // JWT authorizing the license request
  ),
);
```

`drmType` defaults to Widevine on Android and FairPlay on iOS. Pass it explicitly to override it, and use `headers` to add headers to the license request:

```dart
FastPixPlayerDrmConfiguration(
  drmToken: 'drm-jwt-token',
  drmType: FastPixDrmType.widevine, // widevine (Android) | fairplay (iOS)
  headers: {'X-Custom-Header': 'value'},
);
```

Local caching is disabled automatically for DRM sources, since encrypted segments must never be cached.

> **iOS note:** `better_player_plus` routes FairPlay through an EZDRM specific resource loader that rewrites the license URL, so FastPix FairPlay playback does not currently work on iOS without patching the plugin. Widevine playback on Android is fully supported.

#### DRM Error Handling

An unusable DRM setup is rejected before playback starts: `initialize` throws a `FastPixDrmException` and also emits a `FastPixPlayerDrmErrorEvent`, so a bad configuration surfaces immediately instead of as an endless spinner. Failures that happen during playback are classified from the platform error into the same set of codes.

```dart
try {
  await controller.initialize(
    dataSource: drmDataSource,
    configuration: configuration,
  );
} on FastPixDrmException catch (error) {
  debugPrint('${error.code}: ${error.message}');
  if (error.isTokenRelated) {
    // Re-issue the DRM token and retry
  } else if (error.isRetryable) {
    // A plain retry may succeed
  }
}

// DRM failures are also delivered to `error` listeners
controller.addEventListener(FastPixPlayerEventTypes.error, (event) {
  if (event is FastPixPlayerDrmErrorEvent) {
    debugPrint('${event.code} ${event.message}');
  }
});
```

The most recent DRM failure stays available on the controller as `controller.lastDrmError`, and any playback failure as `controller.lastError`.

##### DRM Error Codes

| Code | Meaning |
| --- | --- |
| `FP_DRM_CONFIGURATION_MISSING` | The media is DRM protected but playback was configured without `drmConfiguration` |
| `FP_DRM_MISSING_DRM_TOKEN` | `drmConfiguration.drmToken` is empty |
| `FP_DRM_MISSING_PLAYBACK_TOKEN` | The playback `token` on the data source is empty |
| `FP_DRM_UNSUPPORTED_PLATFORM` | Widevine requested on iOS, or FairPlay on Android |
| `FP_DRM_LICENSE_UNAUTHORIZED` | The license server rejected the request — expired or invalid DRM token |
| `FP_DRM_LICENSE_REQUEST_FAILED` | The license request failed (network, 5xx, timeout) |
| `FP_DRM_CERTIFICATE_REQUEST_FAILED` | The FairPlay application certificate could not be fetched |
| `FP_DRM_PROVISIONING_FAILED` | The device could not be provisioned with the DRM provider |
| `FP_DRM_DEVICE_NOT_SUPPORTED` | No secure decoder, revoked device, or unsupported DRM scheme |
| `FP_DRM_UNKNOWN` | A DRM failure that could not be classified further |

`isTokenRelated` indicates that re-issuing credentials is likely to help; `isRetryable` that a plain retry may succeed.

#### DRM Error UI and Diagnostics

`FastPixPlayer` renders its own failure state and can probe the FastPix manifest, license and certificate endpoints to explain the failure — the platform players report every load failure with the same opaque message, so the probe separates a bad playback ID (manifest 404) from an expired playback token (manifest 403) from a rejected DRM token (license 401/403).

```dart
FastPixPlayer(
  controller: controller,
  diagnoseErrors: true, // Default: probe the endpoints after a failure
  drmErrorWidgetBuilder: (error) => Text('DRM: ${error.message}'),
  errorWidgetBuilder: (error) => Text(error.message),
)
```

The diagnosis can also be requested directly:

```dart
final diagnosis = await controller.diagnosePlayback();
debugPrint(diagnosis?.summary);            // Human readable cause
debugPrint(diagnosis?.probes.join(' · ')); // Per-endpoint results
```

## Custom Domain

### Public Media

```dart
final liveDataSource = FastPixPlayerDataSource.hls(
  playbackId: 'live-stream-id',
  streamType: StreamType.onDemand, // By Default StreamType is on-demand
  customDomain: 'your custom domain goes here' // Ex: xyz.com
);

final liveConfiguration = FastPixPlayerConfiguration(
  autoPlayConfiguration: FastPixPlayerAutoPlayConfiguration(
    autoPlay: FastPixAutoPlay.enabled,
  ),
  controlsConfiguration: FastPixPlayerControlsConfiguration(
    showTimeRemaining: false, // Hide time remaining for live streams
  ),
);
```

### Private Media
For private media, token is required.

```dart
final liveDataSource = FastPixPlayerDataSource.hls(
  playbackId: 'live-stream-id',
  streamType: StreamType.onDemand, // By Default StreamType is on-demand
  token: 'jwt-token', // Token is required for private media
  customDomain: 'your custom domain goes here' // Ex: xyz.com
);

final liveConfiguration = FastPixPlayerConfiguration(
  autoPlayConfiguration: FastPixPlayerAutoPlayConfiguration(
    autoPlay: FastPixAutoPlay.enabled,
  ),
  controlsConfiguration: FastPixPlayerControlsConfiguration(
    showTimeRemaining: false, // Hide time remaining for live streams
  ),
);
```

## API Reference

### FastPixPlayerController

The main controller class that manages the player state and configuration:

#### Initialization
- `initialize(dataSource, configuration)`: Initialize the player with data source and configuration. Throws a `FastPixDrmException` when the DRM configuration cannot produce a successful license request

#### DRM
- `lastDrmError`: Most recent `FastPixDrmException`, or `null` when DRM playback has not failed
- `lastError`: Most recent playback error of any kind, DRM or not
- `diagnosePlayback()`: Probe the FastPix manifest, license and certificate endpoints and return a `FastPixPlaybackDiagnosis` explaining the failure

#### Cleanup
- `dispose()`: Clean up resources
- `reset()`: Clear player state, including the retained DRM and playback errors

### FastPixPlayerDataSource

The main data source class that handles streaming configuration:

#### Required Parameters
- `playbackId` (required): The unique identifier for your stream

#### Optional Parameters
- `title`: Optional title for the stream
- `description`: Optional description
- `customDomain`: Custom streaming domain (defaults to staging.metrix.com)
- `token`: Authentication token for protected streams ([how to generate](https://fastpix.com/docs/video-security/generate-jwts-for-secure-media))
- `drmConfiguration`: DRM configuration for protected media. Requires `token` to be set as well
- `streamType`: Set to `StreamType.onDomand | StreamType.live` for live streams
- `headers`: Optional HTTP headers for authentication
- `cacheEnabled`: Enable/disable video caching (always disabled for DRM sources)
- `loop`: Enable/disable video looping
- `qualityControl`: Quality control parameters
- `showSubtitles`: Whether to show subtitles by default

#### Properties
- `drmEnabled`: Whether this source is DRM protected

#### Factory Constructors
- `FastPixPlayerDataSource.hls()`: Create an HLS data source

### FastPixPlayerConfiguration

Main configuration class for player behavior:

### FastPixPlayerDrmConfiguration

DRM configuration for protected media:

#### Required Parameters
- `drmToken` (required): JWT authorizing access to the FastPix DRM license server ([how to generate](https://fastpix.com/docs/web-player/play-drm-protected-content#how-to-generate-drm-tokens))

#### Optional Parameters
- `drmType`: DRM system to use. Defaults to FairPlay on iOS and Widevine on Android
- `headers`: Additional headers sent with the license request

#### Members
- `resolvedDrmType`: DRM system for the current platform, honouring an explicit `drmType`
- `licenseUrl(playbackId)`: License server URL for the playback ID
- `certificateUrl(playbackId)`: FairPlay application certificate URL, `null` for DRM systems that do not use one
- `validate(playbackId, hasPlaybackToken)`: Fail fast with a `FastPixDrmException` when the configuration cannot produce a successful license request
- `copyWith()`: Create a copy with updated values

### FastPixDrmException

Thrown for DRM configuration and playback failures:

- `errorCode`: Normalized `FastPixDrmErrorCode`
- `code`: Stable string code, also used as the `code` on emitted error events
- `message`: Human readable, actionable description
- `playbackId`: Playback ID the failure relates to, when known
- `underlyingError`: Raw platform error string, when the failure came from the player
- `isTokenRelated`: Whether retrying with a freshly issued DRM token is likely to help
- `isRetryable`: Whether a plain retry may succeed

### FastPixPlayerQualityControl

Advanced quality control parameters:

#### Resolution Control
- `resolution`: Target resolution (auto, p360, p480, p720, p1080, p1440, p2160)
- `minResolution`: Minimum allowed resolution
- `maxResolution`: Maximum allowed resolution

#### Rendition Control
- `renditionOrder`: Quality selection order (default_, asc, desc)

### Widgets

#### FastPixPlayer
Basic player widget with minimal controls.

DRM related properties:
- `drmErrorWidgetBuilder`: Builder for the DRM failure state. Takes precedence over `errorWidgetBuilder` for DRM failures
- `errorWidgetBuilder`: Builder for the generic failure state
- `diagnoseErrors`: Whether to probe the FastPix endpoints after a failure to work out its real cause (default `true`)

#### FastPixAspectRatio
- `fit`: Fit to screen
- `ratio16x9`: 16:9 aspect ratio
- `ratio4x3`: 4:3 aspect ratio
- `ratio1x1`: 1:1 aspect ratio (square)
- `stretch`: Stretch to fill

#### FastPixAutoPlay
- `enabled`: Auto play enabled
- `disabled`: Auto play disabled
- `wifiOnly`: Auto play only on WiFi

#### FastPixResolution
- `auto`: Auto resolution selection
- `p360`: 360p resolution
- `p480`: 480p resolution
- `p720`: 720p resolution
- `p1080`: 1080p resolution
- `p1440`: 1440p resolution
- `p2160`: 2160p (4K) resolution

#### FastPixDrmType
- `widevine`: Widevine, used on Android
- `fairplay`: FairPlay, used on iOS

## Additional Information

FastPix Player is designed specifically for streaming content from staging.metrix.com and other streaming services. It automatically constructs the correct streaming URLs based on your playback ID, custom domain, and chosen format, ensuring optimal performance and compatibility.

The controller-based API ensures predictable behavior by centralizing all data source and configuration management through the controller, eliminating the random behavior that could occur with duplicate parameter passing.

### Key Features Summary

- **Streaming-Only**: Optimized for HLS streaming
- **Quality Control**: Advanced resolution and quality management
- **Live Streaming**: Optimized for live content
- **Caching**: Intelligent video caching
- **Custom Domains**: Support for custom streaming domains
- **Authentication**: Token-based authentication
- **DRM**: Widevine and FairPlay playback through the FastPix license server
- **Error Handling**: Comprehensive error management

For issues, feature requests, or contributions, please visit the project repository.
