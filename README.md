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
1. **Log in to the FastPix Dashboard**: Navigate to the [FastPix-Dashboard](https://dashboard.fastpix.io) and log in with your credentials.
2. **Create Media**: Start by creating a media using a pull or push method. You can also use our APIs instead for [Push media](https://docs.fastpix.io/docs/upload-videos-directly) or [Pull media](https://docs.fastpix.io/docs/upload-videos-from-url).
3. **Retrieve Media Details**: After creation, access the media details by navigating to the "View Media" page.
4. **Get Playback ID**: From the media details, obtain the playback ID.
5. **Play Video**: Use the playback ID in the FastPix-player to play the video seamlessly.


# Installation:
To get started with the SDK, first install the FastPix Player SDK , you can use `flutter pub add fastpix_player` command to directly add it:
Or
Add the dependency in your `pubspec.yaml`:
```yaml
dependencies:
  fastpix_player: 0.1.0
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
      description: 'A sample HLS stream from staging.metrix.io',
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
For private media, token is required.

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
- `initialize(dataSource, configuration)`: Initialize the player with data source and configuration

#### Cleanup
- `dispose()`: Clean up resources

### FastPixPlayerDataSource

The main data source class that handles streaming configuration:

#### Required Parameters
- `playbackId` (required): The unique identifier for your stream

#### Optional Parameters
- `title`: Optional title for the stream
- `description`: Optional description
- `customDomain`: Custom streaming domain (defaults to staging.metrix.io)
- `token`: Authentication token for protected streams
- `streamType`: Set to `StreamType.onDomand | StreamType.live` for live streams
- `headers`: Optional HTTP headers for authentication
- `cacheEnabled`: Enable/disable video caching
- `loop`: Enable/disable video looping
- `qualityControl`: Quality control parameters
- `showSubtitles`: Whether to show subtitles by default

#### Factory Constructors
- `FastPixPlayerDataSource.hls()`: Create an HLS data source

### FastPixPlayerConfiguration

Main configuration class for player behavior:

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

## Additional Information

FastPix Player is designed specifically for streaming content from staging.metrix.io and other streaming services. It automatically constructs the correct streaming URLs based on your playback ID, custom domain, and chosen format, ensuring optimal performance and compatibility.

The controller-based API ensures predictable behavior by centralizing all data source and configuration management through the controller, eliminating the random behavior that could occur with duplicate parameter passing.

### Key Features Summary

- **Streaming-Only**: Optimized for HLS streaming
- **Quality Control**: Advanced resolution and quality management
- **Live Streaming**: Optimized for live content
- **Caching**: Intelligent video caching
- **Custom Domains**: Support for custom streaming domains
- **Authentication**: Token-based authentication
- **Error Handling**: Comprehensive error management

For issues, feature requests, or contributions, please visit the project repository.
