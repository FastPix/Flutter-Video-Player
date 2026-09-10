# Introduction:

This SDK simplifies HLS video playback by offering a wide range of customization options for an enhanced viewing experience. It streamlines streaming setup by utilizing playback IDs that have reached the "ready" status to generate stream URLs. These playback IDs enable seamless integration and video playback within the FastPix-player, making the entire streaming process efficient and user-friendly.

# Key Features:

- **Playback Control**
    - The `playbackId` allows for easy video playback by linking directly to the media file. Playback is available as soon as the media status is "ready."
    - `autoPlay`: Automatically starts playback once the video is loaded, providing a seamless user experience.
    - `loop`: Allows the video to repeat automatically after it finishes, perfect for continuous viewing scenarios.

- **Security**
    - The `token` attribute is required to play private or DRM protected streams.
    - **Note:** You can skip the token for public streams.

- **DRM playback**
    - Protected media plays through the FastPix license server using `drmConfiguration`, with Widevine on Android and FairPlay on iOS.
    - License and certificate URLs are derived from the playback ID, so only the DRM token has to be supplied.
    - DRM failures are normalized into stable error codes with actionable messages, so callers can refresh a token, retry, or fall back without parsing platform error strings.
    - Screenshots and screen recording are blocked during DRM playback on Android by default — see [Screen capture protection](#screen-capture-protection).

- **Inbuilt error handling**
    - The player includes inbuilt error handling that displays appropriate error messages, helping developers quickly understand and address any issues that arise during playback.

- **Auto detection of subtitles**
    - The player automatically detects subtitles from the manifest file and displays them during playback. This ensures that users can easily access available subtitle tracks without additional configuration.
    - Users can switch between available subtitles during playback, offering a personalized viewing experience. This feature allows viewers to choose their preferred language option easily.

- **Chromecast**
    - `FastPixCastController` discovers receivers, manages the session, and hands playback back and forth between the phone and the TV with `startCastingFrom` / `stopCastingTo`, so playback resumes at the position it left off.
    - Remote transport control (play, pause, seek, stop), receiver volume, and subtitle selection, with cast state, device list and subtitle tracks exposed as streams for driving cast UI.
    - Cast failures are normalized into stable error codes the same way DRM failures are, including the Android 13+ nearby devices permission that otherwise makes discovery silently find nothing.

- **Preloading and precaching**
    - `FastPixPreloadManager` warms upcoming sources so the next tap skips the manifest fetch, the DRM license acquisition and decoder setup — either the network path alone, or a whole player that playback then adopts.
    - `FastPixPrecacheManager` writes bytes to disk ahead of playback, so a later session starts a round trip closer to the first frame.
    - Both are best effort and never a precondition: any failure falls through to ordinary playback, and neither reports on the playback error channel — see [Preloading and Precaching](#preloading-and-precaching).

- **Playlists and skip segments**
    - One controller plays an ordered list of sources: `setPlaylist` or `setPlaylistFromJson`, `next()` / `previous()` / `jumpTo(index)`, autoplay-next and repeat, with the queue drawn by `FastPixPlaylistPanel`.
    - The SDK warms the items either side of the active one automatically, so an advance starts from a warm player rather than a cold manifest fetch.
    - An item can declare intro, recap, song and credits ranges, and the player offers a skip once playback is inside one — see [Playlists](#playlists).

- **Custom UI**
    - `FastPixVideoSurface` renders video and nothing else, so an app can stack its own transport over it and never use the bundled skin.
    - The controller exposes the whole functionality API behind those controls: a playback state stream, scrubbing, playback rate, quality levels, audio tracks and subtitle tracks — see [Building a custom UI](#building-a-custom-ui).

- **Picture-in-Picture**
    - `controller.pip` enters, exits and toggles a PiP window on Android and iOS, and can open one automatically when the app goes to the background.
    - The window's content is yours to build with `pipBuilder`, or left to the bundled layout — see [Picture-in-Picture](#picture-in-picture).

- **Advanced stream control**
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
To get started with the SDK, first install the FastPix Player SDK. You can use the `flutter pub add fastpix_video_player` command to add it directly:
Or
Add the dependency in your `pubspec.yaml`:
```yaml
dependencies:
  fastpix_video_player: 1.1.2
```

### Basic Usage Example

```dart
import 'package:flutter/material.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';

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
      description: 'A sample HLS stream from stream.fastpix.com',
      thumbnailUrl: 'https://www.example.com/thumbnail.jpg',
    );

    // workspaceId, viewerId and beaconUrl are positional and required: they
    // identify the stream to FastPix analytics.
    final configuration = FastPixPlayerConfiguration(
      'your-workspace-id',
      'your-viewer-id',
      'your-beacon-url',
      controlsConfiguration: const FastPixPlayerControlsConfiguration(
        autoPlay: true,
      ),
    );

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

The quality parameters live on the data source itself and travel to FastPix as
URL parameters. A dimension left unset — or set to `auto` — is not sent at all,
leaving the choice to the player.

```dart
final dataSource = FastPixPlayerDataSource.hls(
  playbackId: 'your-playback-id',

  // Target a specific resolution
  resolution: FastPixPlayerVideoQuality.p720,

  // Or set a min/max resolution range
  minResolution: FastPixPlayerVideoQuality.p480,
  maxResolution: FastPixPlayerVideoQuality.p1080,

  // Rendition order (quality selection priority)
  renditionOrder: FastpixPlayerRenditionOrder.desc, // High to low quality
);
```

### Player Widgets

FastPix Player provides multiple widget options:

#### Basic Player Widget
```dart
FastPixPlayer(
  controller: controller,
  width: 350,
  height: 200,
  showLoadingIndicator: true,
  loadingIndicatorColor: Colors.white,
)
```

The widget sizes itself from the video's own aspect ratio; there is no aspect
ratio parameter to set.

#### Player Widget With A Cast Button

Pass a `FastPixCastController` to put the cast glyph in the player's own control
bar. `onCastPressed` is left to the app so the device picker matches the rest of
it — without it the button is inert.

```dart
FastPixPlayer(
  controller: controller,
  castController: cast,
  onCastPressed: onCastPressed,
)
```

#### Headless Surface For A Custom UI

`FastPixVideoSurface` draws the video alone, leaving every control to the app.
See [Building a custom UI](#building-a-custom-ui).

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

// Lifecycle
controller.reset();
await controller.dispose();
```

To play a different stream on the same controller, call `loadPlaybackId` with
the new data source. It releases the outgoing player, clears the retained
errors and state from the previous attempt, and reopens the analytics event
sequence, so a second video needs neither a second controller nor a re-mount.
`initialize` still works for that too, and stays the entry point for the first
source.

### Public Media

```dart
final liveDataSource = FastPixPlayerDataSource.hls(
  playbackId: 'live-stream-id',
  streamType: StreamType.onDemand, // By Default StreamType is on-demand
  cacheEnabled: false // Disable cache for streaming
);

final liveConfiguration = FastPixPlayerConfiguration(
  'your-workspace-id',
  'your-viewer-id',
  'your-beacon-url',
  controlsConfiguration: const FastPixPlayerControlsConfiguration(
    autoPlay: true,
  ),
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
  'your-workspace-id',
  'your-viewer-id',
  'your-beacon-url',
  controlsConfiguration: const FastPixPlayerControlsConfiguration(
    autoPlay: true,
  ),
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

Caching is unaffected by DRM on Android. media3 keeps `DrmSessionManager` and `CacheDataSource` orthogonal, so cached segments stay encrypted on disk and the license is fetched fresh at playback to decrypt them — ordinary behaviour for a streaming player. Only *offline* playback needs a persistent license, which is a separate feature.

On iOS, caching is disabled for HLS playback, DRM or not, so `cacheEnabled: true` is ignored there. The cause is not DRM: the engine's cache serves bytes through a local proxy, and that proxy does not survive a signed FastPix URL. An unprotected stream fails outright with `CoreMediaErrorDomain error -12642`, a hard failure rather than a slow start. Other iOS formats still honour `cacheEnabled`.

The single delegate slot is a separate constraint. An `AVURLAsset` has exactly one `AVAssetResourceLoader` delegate, which FairPlay already owns on protected content, and that is why *precaching* is refused for DRM on iOS.

#### Screen capture protection

`secureScreen` applies Android's `FLAG_SECURE` while a DRM source plays, and is **on by default**. The flag belongs to the Activity, so the whole host app is unscreenshottable until the player is disposed — set it to `false` if screenshots elsewhere in your app must keep working.

```dart
FastPixPlayerDrmConfiguration(
  drmToken: 'drm-jwt-token',
  secureScreen: false,
);
```

No effect on iOS, where FairPlay already blanks protected video in recordings.

#### DRM Error Handling

An unusable DRM setup is rejected before playback starts: `initialize` throws a `FastPixDrmException` and also emits a `FastPixPlayerDrmErrorEvent`, so a bad configuration surfaces immediately instead of as an endless spinner. Only three codes are reachable this way — a missing DRM token, a missing playback token, and an unsupported platform — and the check runs only when the data source carries a DRM configuration at all. Every other code below is classified from a platform error, so it arrives after playback has already been attempted.

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

## Preloading and Precaching

Two independent optimisations for the tap-to-first-frame path. Both are **best effort and never a precondition**: every failure — a timeout, a refused adoption, an exhausted decoder budget, a missing platform channel — falls through to exactly the playback you get today. Neither can make playback fail or wait, and both report on their own event channel so a warm-up that did not finish never surfaces as a playback error.

|  | Preloading | Precaching |
| --- | --- | --- |
| Lives in | Memory, this app session | Disk, survives a restart |
| Warms | Connection, manifest, optionally a whole player | Manifest and segment bytes |
| Entry point | `FastPixPreloadManager.instance` | `FastPixPrecacheManager.instance` |

They share no state. Use them together rather than choosing between them.

### Preloading

Declare what is coming next. `preload` takes the state of the world rather than a command — it diffs against what it already holds, cancels departures, keeps survivors, and starts only arrivals — so it is safe to call on every scroll frame.

```dart
await FastPixPreloadManager.instance.preload(
  upcomingSources,                 // the next few items, in order
  configuration: playerConfiguration,
  strategy: FastPixPreloadStrategy.player,
  window: 3,
  warmDrm: true,
);
```

**Strategies.** `network` (the default) fetches the manifest so DNS and the CDN edge are hot; it allocates no platform player, and its `window` is unbounded. `player` builds a real, detached player and acquires the DRM license, so playback can adopt it and start immediately.

**How deep a network warm goes** is set once on the manager, not per call. `FastPixPreloadManager.instance.warmDepth` takes `FastPixWarmDepth.master` (the default, one request), `variant` (the master plus the chosen rendition playlist) or `segments` (the variant plus its opening segments, two by default). Deeper is warmer and costs more bandwidth against the video already playing.

**Every warm is capped at twelve seconds**, `FastPixPreloadManager.warmTimeout`. A warm that overruns is failed and logged, and playback cold-starts. Network warms run one at a time so they do not compete with each other for the same bandwidth.

**The window is capped for `player`.** One on Android, three on iOS — `FastPixPreloadManager.maxPlayerWindow`. An Android warm is a whole ExoPlayer plus, for DRM, a `MediaDrm` session that the device caps separately. Requests past the cap are dropped rather than queued, and the clamp is logged, because exceeding it does not fail the preload — it fails live playback minutes later.

**Adoption requires a matching configuration.** Pass `initialize` the same `FastPixPlayerConfiguration` you passed `preload`. `BetterPlayerConfiguration` is final on the controller, so a player warmed for different controls or fit can never be corrected; a mismatch is refused and logged with both fingerprints, and playback cold-starts. Set `adoptPreloaded: false` on `initialize` to force a cold start when measuring baseline latency.

A `player` warm is skipped, with a logged reason, while a Cast session is active (a local decoder would be spent on playback happening on the receiver), for live streams (a parked live player drifts behind the live edge), and for DRM when `warmDrm: false`. A `network` warm is subject to none of these — it holds no decoder and acquires no license. A source already in the window is left alone rather than re-warmed, under either strategy.

```dart
FastPixPreloadManager.instance.statusOf(playbackId);  // queued | loading | ready | failed | cancelled
FastPixPreloadManager.instance.isReady(playbackId);
FastPixPreloadManager.instance.cancel(playbackId);    // on eviction, never on mount
FastPixPreloadManager.instance.clearAll();
FastPixPreloadManager.instance.dispose();             // releases every warm player; the manager stays usable
```

Do not call `cancel` when the player mounts. Adoption happens after mount, so cancelling there throws away exactly the work about to be used.

Wire up Cast awareness once, if you cast:

```dart
FastPixPreloadManager.instance.isCastActive = () => castController.isConnected;
```

Lifecycle events arrive as `FastPixPreloadStartedEvent`, `…ReadyEvent`, `…FailedEvent`, `…CancelledEvent` and `…ConsumedEvent` on `FastPixPreloadManager.instance.eventManager`. All five carry the playback ID, the strategy and the network type in effect, so a warm can be attributed to the connection that paid for it; `…Ready` adds `elapsed` and `…Failed` adds `reason`.

### Precaching

Writes bytes to disk ahead of playback, in the cache the player reads from.

```dart
final status = await FastPixPrecacheManager.instance.precacheManifest(source);
final bytes = FastPixPrecacheManager.instance.bytesWrittenFor(source.playbackId);

await FastPixPrecacheManager.instance.precacheAll(upcomingSources);
await FastPixPrecacheManager.instance.stop(source);   // abandon a warm in flight
FastPixPrecacheManager.instance.statusOf(playbackId); // idle | cached | failed | unsupported
FastPixPrecacheManager.instance.clearStatuses();
```

`precacheManifest` never throws; it returns `idle`, `cached`, `failed` or `unsupported`. A platform that reports success but writes **zero bytes is treated as a failure** — the byte count is the honest signal, and `bytesWrittenFor` exposes it. A repeat request for something already cached or already in flight is coalesced and returns `cached` rather than fetching twice. `precacheAll` runs a list sequentially on purpose, since these requests share bandwidth with the video currently playing. A manifest is read up to `FastPixPrecacheManager.manifestByteCeiling`, 512 KB.

Refused, with the reason reported, on platforms other than Android and iOS, for live sources (a live playlist is rewritten continuously, so a cached copy is stale on arrival), for `cacheEnabled: false`, and for DRM on iOS — caching there needs the asset's resource-loader delegate, which FairPlay already owns on protected content.

**Android.** The master playlist is written into the same media3 cache playback reads from, so a warm feeds the next start. media3 keys HLS entries by request URI and offers no override for it, so this pays off while the URL is stable; if the playback token is re-resolved between the warm and playback, the entry is written under one key and read under another and the warm is silently unused. Preloading is unaffected by that, because it keys by playback ID in Dart.

**iOS.** Playlists and the opening segments are fetched and stored on disk keyed by playback ID, which survives a token refresh. Playback does not yet read from that store, so on iOS precaching currently costs bandwidth and disk without shortening a later start — prefer preloading there today.

Events arrive as `FastPixPrecacheStartedEvent`, `…CachedEvent` and `…FailedEvent` on `FastPixPrecacheManager.instance.eventManager`. `…Cached` carries `bytesWritten`; `…Failed` carries the refusal `status` alongside its `reason`, which is how a genuine failure is told apart from an unsupported source.

### Watching what happened

Both features fail silently by design, so every decision is logged — skips and refusals as loudly as successes. Logging is on in debug builds and silent in release; force it with `FastPixWarmLog.enabled = true`.

```bash
flutter run | grep -E "preloading|precaching"
adb logcat  | grep -E "preloading|precaching"
```

The line worth grepping for is `ADOPTED`, and its absence is the difference between preloading working and preloading merely running.


## Chromecast

Casting is not screen mirroring. The receiver fetches the stream itself, directly from FastPix, and `FastPixCastController` only sends it commands. Three consequences shape the whole API:

- The stream URL has to be reachable by the receiver, so authentication must travel in the URL. `FastPixPlayerDataSource.url` already carries the playback token as a query parameter, but `headers` are **dropped** — the receiver makes its own request and never sees them.
- Local and remote playback are mutually exclusive. Use `startCastingFrom` and `stopCastingTo` to move between them rather than driving both players by hand.
- DRM streams cannot be cast through Google's Default Media Receiver. See [DRM on Chromecast](#drm-on-chromecast).

Casting is supported on Android and iOS. On any other platform the controller settles on `FastPixCastState.unavailable` instead of throwing, so cast UI can be built unconditionally and let the state hide it.

### Platform setup

#### Android

Add the discovery permissions and the Cast framework configuration to `android/app/src/main/AndroidManifest.xml`:

```xml
<!-- Cast discovery runs over mDNS on the local network -->
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />

<!-- Android 13 (API 33) and above gate local network discovery behind a
     runtime permission. Without it MediaRouter reports no Cast routes and
     raises nothing. `neverForLocation` avoids the extra location prompt. -->
<uses-permission
    android:name="android.permission.NEARBY_WIFI_DEVICES"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />

<application ...>
    <!-- Google Cast framework configuration -->
    <meta-data
        android:name="com.google.android.gms.cast.framework.OPTIONS_PROVIDER_CLASS_NAME"
        android:value="com.felnanuke.google_cast.GoogleCastOptionsProvider" />

    <!-- Media notification service for cast controls -->
    <service
        android:name="com.google.android.gms.cast.framework.media.MediaNotificationService"
        android:exported="false"
        android:foregroundServiceType="mediaPlayback" />
</application>
```

The runtime `NEARBY_WIFI_DEVICES` request is made by the SDK itself from `startDiscovery()`; the manifest entry is all your app has to add. Casting also needs Google Play Services — when it is missing or too old the failure arrives as `FP_CAST_PLAY_SERVICES_UNAVAILABLE`.

#### iOS

Add the local network keys to `ios/Runner/Info.plist`. `NSBonjourServices` must list the Cast service and, when you use a custom receiver, the service for its application ID:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>${PRODUCT_NAME} uses the local network to discover Cast-enabled devices on your WiFi network.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>${PRODUCT_NAME} uses Bluetooth to discover nearby Cast-enabled devices.</string>
<key>NSBonjourServices</key>
<array>
    <string>_googlecast._tcp</string>
    <string>_YOUR_APP_ID._googlecast._tcp</string>
</array>
```

iOS gives no callback when the local network permission is denied: discovery simply returns zero devices, which is indistinguishable from a network with no receivers on it.

### Quick start

```dart
final cast = FastPixCastController(
  // Defaults to Google's Default Media Receiver. A custom receiver ID is
  // needed for branding, DRM, or receiver-side analytics.
  appId: 'YOUR_RECEIVER_APP_ID',
  // Set to fmp4 for CMAF packaged streams — see "Segment format" below.
  segmentFormat: FastPixCastSegmentFormat.fmp4,
);

// Cast state drives the cast button: show it only once a receiver exists.
cast.stateStream.listen((state) => setState(() => _canCast = state.canCast));
cast.devicesStream.listen((devices) => setState(() => _devices = devices));

await cast.initialize();

// Discovery is expensive in battery and Wi-Fi traffic. Start it when cast UI
// opens and stop it when it closes.
await cast.startDiscovery();
```

### Moving playback between the phone and the TV

`startCastingFrom` connects, pauses the local player, and loads the stream on the receiver at the position playback had reached. The connection is established *before* local playback is touched, so a receiver that fails to connect leaves the phone playing exactly where it was; if the receiver connects but the stream fails to load, the session is torn down and the error is rethrown — so a load failure arrives as an exception, not as `false`. Local playback resumes only if it was playing when casting started; a source that was paused stays paused, at the right position.

```dart
// Phone -> TV
try {
  final started = await cast.startCastingFrom(playerController, device);
  if (!started) showMessage(cast.lastError?.message ?? 'Could not connect');
} on UnsupportedError catch (error) {
  // DRM streams are refused here without a custom receiver
  showMessage(error.message.toString());
} on StateError catch (error) {
  // The player has no data source yet — initialize it before casting
  showMessage(error.message);
} catch (error) {
  // The session came up but the stream would not load. It has already been
  // torn down and local playback resumed.
  showMessage('Could not start playback on the TV');
}

// TV -> phone, resuming at the receiver's position
await cast.stopCastingTo(playerController);
```

Keep the `FastPixPlayer` widget mounted while casting — hide it rather than removing it. Unmounting tears down the platform player, and `stopCastingTo` then has nothing to hand playback back to; it reports `FP_CAST_RESUME_UNAVAILABLE` and the session still ends cleanly.

Both a session and the discovered device list can change from outside the app — the Google Home app, another sender, the TV powering off — so treat `stateStream` and the cast events as the single source of truth rather than assuming a command succeeded.

### Controlling the receiver

```dart
await cast.play();
await cast.pause();
await cast.stop();                              // stops playback, keeps the session
await cast.seekTo(const Duration(minutes: 2));
await cast.setVolume(0.4);                      // receiver hardware volume

cast.remotePositionStream.listen((position) => setState(() => _position = position));

final isPlaying = cast.isRemotePlaying;
final position = cast.remotePosition;           // last position the receiver reported
```

`remoteVolume` is what this app last asked for, not ground truth: the Cast plugin provides no callback for volume, so changes made from the TV remote, the Google Home app, or the phone's volume buttons are not reflected.

To end the session entirely:

```dart
await cast.disconnect();                        // stops the receiver
await cast.disconnect(stopReceiver: false);     // leaves it playing for other senders
```

### Subtitles while casting

Subtitle tracks come from two places and are reported the same way: tracks declared in `FastPixPlayerDataSource.subtitles` are sent to the receiver on load, and tracks inside the HLS manifest are found by the receiver itself. Both appear in `textTracks` only once the receiver has reported a media status.

```dart
cast.textTracksStream.listen((tracks) => setState(() => _tracks = tracks));
cast.activeTextTrackStream.listen((id) => setState(() => _activeId = id));

await cast.selectTextTrack(track);   // only tracks from `textTracks`
await cast.disableTextTrack();       // subtitles off
```

The selection is not recorded locally — the receiver confirms it in its next media status, which is also how a change made from a TV remote or another sender arrives.

### Cast events

Cast events are ordinary `FastPixPlayerEvent`s. Pass the player's event manager to the constructor to have them reach the same listeners as playback events:

```dart
final cast = FastPixCastController(eventManager: playerController.eventManager);

cast.addEventListener(FastPixPlayerEventTypes.castAvailable, (event) {
  // A receiver became reachable — the moment to reveal a cast button
});
cast.addEventListener(FastPixPlayerEventTypes.castStarted, (event) { /* ... */ });
cast.addEventListener(FastPixPlayerEventTypes.castEnded, (event) {
  final ended = event as FastPixCastEndedEvent;
  // Fired whichever side ended the session, with the last remote position
  debugPrint('${ended.device?.name} stopped at ${ended.position}');
});
cast.addEventListener(FastPixPlayerEventTypes.castError, (event) {
  final error = event as FastPixCastErrorEvent;
  debugPrint('${error.code}: ${error.message}');
});
```

| Event type | Class | Fired when |
| --- | --- | --- |
| `castAvailable` | `FastPixCastAvailableEvent` | The first receiver becomes reachable |
| `castStarted` | `FastPixCastStartedEvent` | A session becomes live |
| `castEnded` | `FastPixCastEndedEvent` | A session ends, whichever side ended it |
| `castError` | `FastPixCastErrorEvent` | Discovery, a session, or a remote load fails |

`castError` deliberately does **not** extend `FastPixPlayerErrorEvent`: a cast failure is not a local playback failure, and the phone may still be playing perfectly.

### Cast Error Handling

The most recent failure stays on `cast.lastError`, so UI that mounts after the failure can still render it. Branch on the classification rather than on the message:

```dart
final error = cast.lastError;
if (error != null) {
  if (error.isPermissionRelated) {
    await cast.openPermissionSettings();   // a permanently denied grant only Settings can fix
  } else if (error.isContentUnsupported) {
    // Never offer a retry — this content can never play on a receiver
  } else if (error.isRetryable) {
    // Trying again may work
  } else if (error.isFatal) {
    // Hide the cast button: casting is unusable on this device
  }
}
```

An empty device list on Android 13+ is usually the nearby devices permission. `requiresNearbyDevicesPermission` tells you whether that explanation can even apply on the current device, so the UI does not report a permission problem that does not exist:

```dart
if (await cast.requiresNearbyDevicesPermission) {
  // Safe to suggest enabling "Nearby devices" for this app
}
```

#### Cast Error Codes

| Code | Meaning |
| --- | --- |
| `FP_CAST_INIT_FAILED` | The Google Cast context could not be created |
| `FP_CAST_PLAY_SERVICES_UNAVAILABLE` | Google Play Services is missing or too old (Android) |
| `FP_CAST_NEARBY_PERMISSION_DENIED` | The Android 13+ `NEARBY_WIFI_DEVICES` permission was not granted |
| `FP_CAST_LOCAL_NETWORK_PERMISSION_DENIED` | The iOS local network permission was denied (reserved — iOS exposes no callback for it) |
| `FP_CAST_DISCOVERY_FAILED` | Discovery could not be started, stopped, or continued |
| `FP_CAST_DEVICE_UNAVAILABLE` | The chosen receiver is no longer in the discovered list |
| `FP_CAST_CONNECT_FAILED` | A session could not be established with the receiver |
| `FP_CAST_CONNECT_TIMEOUT` | The receiver did not establish a session before the timeout elapsed |
| `FP_CAST_SESSION_TAKEN` | The receiver is already running a session for another sender |
| `FP_CAST_SESSION_FAILED` | An established session failed after it had connected |
| `FP_CAST_DISCONNECT_FAILED` | The session could not be ended cleanly |
| `FP_CAST_DRM_UNSUPPORTED` | DRM protected content was loaded without a custom receiver configured |
| `FP_CAST_MEDIA_UNSUPPORTED` | The receiver refused the media: unsupported container or codec |
| `FP_CAST_LOAD_FAILED` | The load request failed for another reason |
| `FP_CAST_COMMAND_FAILED` | A transport command (play, pause, stop, seek, subtitle change) failed |
| `FP_CAST_VOLUME_FAILED` | A volume change was rejected by the receiver |
| `FP_CAST_RESUME_UNAVAILABLE` | Casting stopped but local playback could not resume |
| `FP_CAST_UNKNOWN` | The Cast SDK failed for a reason that maps to none of the above |

### DRM on Chromecast

Chromecast receivers speak Widevine only — never FairPlay — and Google's Default Media Receiver cannot perform a license request at all. Loading a DRM protected source without a custom receiver is refused: `loadMedia` throws `UnsupportedError` and emits `FP_CAST_DRM_UNSUPPORTED`.

The refusal happens at load time, not before connecting. `startCastingFrom` connects to the receiver and pauses local playback first, so a DRM source tears the fresh session down again on the way out. Check for DRM yourself before offering the cast button if you would rather the receiver were never woken.

With a custom receiver configured through `appId`, the SDK sends the license details in the media's `customData`, using the Widevine license URL derived from the playback ID even when the phone plays the same title locally through FairPlay:

```json
{
  "licenseUrl": "https://.../drm/license/widevine/{playbackId}?token=...",
  "protectionSystem": "widevine"
}
```

Your receiver application reads `loadRequest.media.customData.licenseUrl` and configures its playback manager with it. The FastPix license endpoint carries its token as a query parameter, so the receiver needs no custom headers.

### Segment format

A Cast receiver is a web player and has to know how the segments are packaged before it can build a playback pipeline. When the manifest does not make that obvious the receiver assumes MPEG-TS, and an fMP4/CMAF stream then connects, displays its title, and never starts playing — with no error on either side.

If casting connects but nothing plays, this is almost always the cause:

```dart
FastPixCastController(segmentFormat: FastPixCastSegmentFormat.fmp4);
```

Modern packaging is fMP4/CMAF, and any stream serving both Widevine and FairPlay from one source — which is how FastPix DRM works — is CMAF. `FastPixCastSegmentFormat.auto` (the default) sends no hint and is correct for plain MPEG-TS streams.

### What does not survive the trip

Because the receiver fetches and renders the stream itself, several data source options have no effect while casting:

- `headers` are dropped — authentication has to be in the URL, which the FastPix playback token already is.
- Resolution hints (`resolution`, `minResolution`, `maxResolution`, `renditionOrder`) are sent as URL parameters, but adaptive switching is then the receiver's decision.
- `cacheEnabled`, `loop` and `endAt` are local player behaviours with no receiver equivalent.

### Lifecycle

`dispose()` releases every subscription and stream the controller opened but deliberately **does not end a live session** — a viewer who started casting expects the TV to keep playing when they leave the player screen. Call `disconnect()` first if the session should stop with the screen. For the same reason, hold the cast controller at app scope rather than rebuilding it per screen.

```dart
await cast.stopDiscovery();
await cast.dispose();
```

## Playlists

One controller plays a whole list. `setPlaylist` takes the ordered sources and
loads the one at `startIndex`; every later item replaces the playing source in
place, so there is no second controller and no re-mount.

```dart
await controller.setPlaylist(
  [
    FastPixPlayerDataSource.hls(playbackId: 'first-playback-id', title: 'Episode 1'),
    FastPixPlayerDataSource.hls(playbackId: 'second-playback-id', title: 'Episode 2'),
    FastPixPlayerDataSource.hls(playbackId: 'third-playback-id', title: 'Episode 3'),
  ],
  configuration: configuration,
);

controller.autoPlayNext = true;
controller.repeatMode = FastPixPlaylistRepeatMode.all;
```

The same list can arrive as JSON — a top-level array of objects where
`playbackId` is required, every other field is optional and unknown keys are
ignored.

```dart
await controller.setPlaylistFromJson(response.body, configuration: configuration);
```

An empty list, an entry with no playback ID, unparseable JSON or a start index
outside the list is rejected with a `FastPixPlaylistException` that names what is
wrong and where. The SDK rejects these cases rather than failing silently: a playlist that arrives empty
almost always means the app's own fetch or filter returned nothing, and a silent failure would leave a blank player with no diagnostic. A rejected playlist leaves existing playback and playlist state untouched.

### Navigation

```dart
final moved = await controller.next();      // false at the last item
await controller.previous();
await controller.jumpTo(4);

controller.currentPlaylistIndex;  // -1 when nothing in the list is active
controller.currentPlaylistItem;
controller.playlistCount;
controller.canGoNext;
controller.canGoPrevious;
```

Navigation returns whether the position moved rather than throwing at the
boundaries, so a button can drive it directly. A refused move emits nothing and
does not interrupt what is playing.

`repeatMode` decides what a finished item leads to: `off` stops at the last
item and emits `playlistEnded`, `one` replays the active item without changing
the index, and `all` wraps from the last item back to the first. The SDK suppresses automatic advance while a Cast session is connected, because the local player is not the surface being watched — but explicit navigation still works.

### Playing a single source without a playlist

`loadPlaybackId` swaps the playing source on the same controller. When the
source is one of the playlist's items the active index moves to it and
navigation continues from there. When it is not, the source plays and the playlist
reports no active position until the next navigation or playlist.

```dart
await controller.loadPlaybackId(
  FastPixPlayerDataSource.hls(playbackId: 'another-playback-id'),
);
```

### Preload windowing

With a playlist set, the SDK warms the items around the active one after each
load, interleaved outward from the current index and preferring the item ahead
at equal distance. `preloadRadius` is the depth on each side; set it to `0` to
declare nothing and drive [preloading](#preloading-and-precaching) yourself.

```dart
controller.preloadRadius = 2; // default
```

### Watching the playlist

`playlistStateStream` publishes a snapshot on every active-item change, which
is what the bundled queue panel uses.

```dart
StreamBuilder<FastPixPlaylistState>(
  stream: controller.playlistStateStream,
  initialData: controller.playlistState,
  builder: (context, snapshot) {
    final state = snapshot.data!;
    return Text(state.position); // "2 of 3"
  },
);
```

The event bus carries the same updates as discrete events: `playlistChanged`,
`playlistItemChanged` (with the index it left, the index it moved to, the
playback ID and why) and `playlistEnded`. Every ordinary playback event 
also carries `playbackId` and, when a playlist is set, `playlistIndex` in its
`data` map, so an event log shows which item it describes.

### The queue panel

```dart
FastPixPlaylistPanel(
  controller: controller,
  onDismiss: () => setState(() => _panelOpen = false),
  title: 'Up next',
)
```

The panel draws itself from the controller alone, so there is no second ordered
list to keep in step with what is playing. The bundled skin opens it from the
control bar; `showPlaylistPanel` and `showPlaylistControls` on
`FastPixPlayerControlsConfiguration` turn the panel and the previous and next arrows
off.

## Skip segments 

An item can declare the ranges a viewer usually skips. The player reports when
playback enters one and offers `skipCurrentSegment()` to jump to its end.

```dart
FastPixPlayerDataSource.hls(
  playbackId: 'your-playback-id',
  skipSegments: const [
    FastPixSkipSegment(
      start: Duration(seconds: 5),
      end: Duration(seconds: 35),
      type: FastPixSkipType.intro,
    ),
    FastPixSkipSegment(
      start: Duration(minutes: 22),
      end: Duration(minutes: 24),
      type: FastPixSkipType.credits,
    ),
  ],
)
```

```dart
controller.addEventListener(FastPixPlayerEventTypes.skipAvailable, (event) {
  final segment = (event as FastPixSkipAvailableEvent).segment;
  showSkipButton(segment.type);
});
controller.addEventListener(FastPixPlayerEventTypes.skipHidden, (_) => hideSkipButton());

await controller.skipCurrentSegment(); // false when nothing is active
```

The SDK holds segments until the item's duration is known, then validates then once at that
point, because two of the four rules — a start at or beyond the duration, an end
beyond it — need a duration that does not exist when the playlist is supplied.
The SDK rejects an invalid segments on its own with a `skipFailed` event that names the reason, and
its valid siblings keep working. On a live source, where the duration
never settles, segments stay pending: the SDK offers no skip and reports no failure.

`enableSkips` on `FastPixPlayerControlsConfiguration` draws the skip button in
the bundled skin. A custom UI listens for the events instead.

## Picture-in-Picture

`controller.pip` drives the Picture-in-Picture(PiP) window on both platforms over the SDK's own
platform channel, so PiP never routes through the engine's fullscreen path.

```dart
if (await controller.pip.isPipAvailable()) {
  await controller.pip.togglePip();
}

controller.pip.isPipActive;
controller.pip.enabled = false;                   // master off switch
controller.pip.autoEnterOnBackground = true;      // open PiP on leaving the app
controller.pip.setPipAudioBehavior(mixWithOthers: false);

controller.addEventListener(FastPixPlayerEventTypes.pipChanged, (event) {
  final active = (event as FastPixPipChangedEvent).isActive;
});
```

PiP survives a playlist advance, and captions scale to the window rather than
rendering at full-player size inside it. Supply the window's content with
`pipBuilder` on `FastPixPlayer` or `FastPixVideoSurface`; the SDK uses the
bundled `fastPixDefaultPipLayout`.

### Picture-in-Picture platform setup

Android — mark the activity as PiP capable and let it handle the configuration
changes itself, in `android/app/src/main/AndroidManifest.xml`:

```xml
<activity
    android:name=".MainActivity"
    android:supportsPictureInPicture="true"
    android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
    ... >
```

iOS — PiP keeps playing while the app is in the background, which needs the
audio background mode in `ios/Runner/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

## Building a custom UI

`FastPixVideoSurface` renders the video and nothing else. Stack your own
controls over it and the bundled skin is never involved.

```dart
Stack(
  children: [
    FastPixVideoSurface(controller: controller),
    MyControls(controller: controller),
  ],
)
```

Everything those controls need is on the controller, and none of it reaches
past the SDK to the underlying engine.

```dart
// Transport
await controller.togglePlayPause();
await controller.seekForward();                   // 10s by default
await controller.seekBackward(const Duration(seconds: 30));
await controller.setPlaybackRate(1.5);
controller.supportedPlaybackRates;

// A single stream to build the whole bar from
StreamBuilder<FastPixPlaybackState>(
  stream: controller.playbackStateStream,
  initialData: controller.playbackState,
  builder: (context, snapshot) {
    final state = snapshot.data!;
    // position, duration, bufferedPosition, isPlaying, isBuffering, playbackRate
    return MySeekBar(state: state);
  },
);

// Scrubbing, so the bar does not fight the position updates mid-drag
controller.beginScrub();
controller.updateScrub(position);
await controller.endScrub(position);

// Tracks and quality
controller.getQualityLevels();
await controller.setQualityLevel(level);
await controller.setQualityAuto();
controller.getAudioTracks();
await controller.setAudioTrack(audioTrack);
controller.getSubtitleTracks();
await controller.setSubtitleTrack(subtitleTrack);
await controller.disableSubtitles();

// Fullscreen and cast
controller.toggleFullscreen();
await controller.toggleCast();
```

Quality selection is a ceiling rather than an exact selection on both platforms: the
player still adapts below the level you set.

Track lists arrive with the manifest, not at initialization. Listen for
`qualityLevelsReady`, `audioTracksReady` and `subtitleTracksReady` to populate
menus when there is something to put in them, and for
`qualityLevelChanged`, `audioTrackChanged`, `subtitleChanged`,
`playbackRateChanged`, `scrubStarted` and `scrubEnded` to follow the state.

Failures from these calls do not throw. They arrive on the playback error
channel the app already listens to, carrying a `FastPixCustomUIErrorCode`:
`trackUnavailable`, `trackSwitchFailed`, `qualitySelectionUnsupported`,
`playbackRateUnsupported`, `castUnavailable`, `playerNotReady`, `pipUnsupported`,
or `pipFailed`.

## Custom Domain

### Public Media

```dart
final liveDataSource = FastPixPlayerDataSource.hls(
  playbackId: 'live-stream-id',
  streamType: StreamType.onDemand, // By Default StreamType is on-demand
  customDomain: 'your custom domain goes here' // Ex: xyz.com
);

final liveConfiguration = FastPixPlayerConfiguration(
  'your-workspace-id',
  'your-viewer-id',
  'your-beacon-url',
  controlsConfiguration: const FastPixPlayerControlsConfiguration(
    autoPlay: true,
    showTimeIndicator: false, // Hide the time indicator for live streams
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
  'your-workspace-id',
  'your-viewer-id',
  'your-beacon-url',
  controlsConfiguration: const FastPixPlayerControlsConfiguration(
    autoPlay: true,
    showTimeIndicator: false, // Hide the time indicator for live streams
  ),
);
```

## API Reference

### FastPixPlayerController

The main controller class that manages the player state and configuration:

#### Initialization
- `initialize(dataSource, configuration)`: Initialize the player with data source and configuration. Throws a `FastPixDrmException` when the DRM configuration cannot produce a successful license request

#### Playback and transport
- `play()`, `pause()`, `togglePlayPause()`, `seekTo(position)`, `setVolume(volume)`
- `seekForward([offset])` / `seekBackward([offset])`: Jump by `offset`, 10 seconds by default, clamped to the source
- `setPlaybackRate(rate)`, `playbackRate`, `supportedPlaybackRates`
- `playbackState` / `playbackStateStream`: A `FastPixPlaybackState` snapshot — position, duration, buffered position, playing, buffering, rate
- `beginScrub([position])`, `updateScrub(position)`, `endScrub(position)`, `isScrubbing`
- `enterFullscreen()`, `exitFullscreen()`, `toggleFullscreen()`, `isFullscreen`

#### Tracks and quality
- `getQualityLevels()`, `getCurrentQualityLevel()`, `setQualityLevel(level)`, `setQualityAuto()`, `isQualityAuto`
- `getAudioTracks()`, `getCurrentAudioTrack()`, `setAudioTrack(track)`
- `getSubtitleTracks()`, `getCurrentSubtitleTrack()`, `setSubtitleTrack(track)`, `disableSubtitles()`

#### Playlist
- `setPlaylist(items, {startIndex, configuration})`: Load an ordered list, throwing a `FastPixPlaylistException` when it cannot be played
- `setPlaylistFromJson(json, {startIndex, configuration})`: The same, from a JSON array
- `loadPlaybackId(source)`: Replace the playing source in place
- `clearPlaylist()`: Leave playback running and make navigation unavailable
- `next()`, `previous()`, `jumpTo(index)`: Return whether the position moved
- `hasPlaylist`, `playlistCount`, `currentPlaylistIndex`, `currentPlaylistItem`, `playlistItemAt(index)`, `canGoNext`, `canGoPrevious`
- `playlistState` / `playlistStateStream`: A `FastPixPlaylistState` snapshot per active-item change
- `autoPlayNext`: Whether a finished item advances to the next (default `false`)
- `repeatMode`: `off`, `one` or `all` (default `off`)
- `preloadRadius`: How many items either side of the active one are warmed after a load (default `2`, `0` disables)

#### Skip segment control
- `activeSkipSegment`: The segment playback is inside, or `null`
- `skipCurrentSegment()`: Jump to the end of the active segment, reporting whether playback moved

#### Picture-in-Picture control
- `pip`: The `FastPixPipManager` — `enterPip()`, `exitPip()`, `togglePip()`, `isPipActive`, `isPipAvailable()`, `enabled`, `autoEnterOnBackground`, `setPipAudioBehavior(mixWithOthers:)`

#### Cast
- `cast`, `attachCastController(controller)`, `isCasting`, `toggleCast()`

#### Events
- `addEventListener(type, listener)`, `addGlobalListener(listener)`, `removeEventListener(type, listener)`, `removeGlobalListener(listener)`, `removeAllEventListeners(type)`, `removeAllListeners()`

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
- `customDomain`: Custom streaming domain (defaults to `stream.fastpix.com`)
- `token`: Authentication token for protected streams ([how to generate](https://fastpix.com/docs/video-security/generate-jwts-for-secure-media))
- `drmConfiguration`: DRM configuration for protected media. Requires `token` to be set as well
- `streamType`: Set to `StreamType.onDemand | StreamType.live` for live streams
- `headers`: Optional HTTP headers for authentication
- `cacheEnabled`: Enable/disable the player's playback cache. Honoured on Android, including for DRM sources; ignored on iOS HLS, where it cannot coexist with AVFoundation's single resource-loader slot. This flag covers caching *during* playback only — caching a source ahead of time is a separate API, `FastPixPrecacheManager`
- `loop`: Enable/disable video looping
- `resolution`, `minResolution`, `maxResolution`, `renditionOrder`: Quality parameters, sent to FastPix as URL parameters — see [Quality Control](#quality-control)
- `showSubtitles`: Whether to show subtitles by default
- `skipSegments`: Intro, recap, song and credits ranges the player offers to skip — see [Skip segments](#skip-segments)
- `startAt` / `endAt`: Play only part of the source

#### Properties
- `drmEnabled`: Whether this source is DRM protected

#### Factory Constructors
- `FastPixPlayerDataSource.hls()`: Create an HLS data source

### FastPixPlayerConfiguration

Main configuration class for player behaviour. The first three parameters are
positional and required — they identify the stream to FastPix analytics.

- `workSpaceId`, `viewerId`, `beaconUrl` (positional, required)
- `controlsConfiguration`: A `FastPixPlayerControlsConfiguration`
- `qualityConfiguration`: A `FastPixPlayerQualityConfiguration`
- `copyWith()`: Create a copy with updated values

### FastPixPlayerControlsConfiguration

Governs the bundled skin. Ignored by a custom UI built on `FastPixVideoSurface`.

- Visibility: `showControls`, `controlsVisibility`, `controlsAutoHideDuration`, `controlsShowDuration`
- Buttons: `showPlayPauseButton`, `showProgressBar`, `showTimeIndicator`, `showFullscreenButton`, `showQualitySelector`, `showSubtitleSelector`, `showVolumeSlider`, `showSeekBar`, `enableRetry`
- Playlist and skips: `showPlaylistControls`, `showPlaylistPanel`, `enableSkips` (default `false`)
- Cast: `showCastWhenNoDevices` (default `true`)
- Playback: `autoPlay`
- Colours: `controlsBackgroundColor`, `controlsForegroundColor`, `progressBarColor`, `progressBarPlayedColor`, `progressBarBufferedColor`

### FastPixPlayerDrmConfiguration

DRM configuration for protected media:

#### Required Parameters
- `drmToken` (required): JWT authorizing access to the FastPix DRM license server ([how to generate](https://fastpix.com/docs/web-player/play-drm-protected-content#how-to-generate-drm-tokens))

#### Optional Parameters
- `drmType`: DRM system to use. Defaults to FairPlay on iOS and Widevine everywhere else
- `headers`: Additional headers sent with the license request
- `secureScreen`: Block screenshots and screen recording while this source plays (default `true`). Android only, and window wide — see [Screen capture protection](#screen-capture-protection)

#### Members
- `resolvedDrmType`: DRM system for the current platform, honouring an explicit `drmType`
- `licenseUrl(playbackId)`: License server URL for the playback ID
- `certificateUrl(playbackId)`: FairPlay application certificate URL, `null` for DRM systems that do not use one
- `validate({required playbackId, required hasPlaybackToken})`: Fail fast with a `FastPixDrmException` when the configuration cannot produce a successful license request. Both parameters are named
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

### Quality parameters

Set on `FastPixPlayerDataSource`, not on a separate object. Each one left unset,
or set to `auto`, is not sent at all.

#### Resolution Control
- `resolution`: Target resolution, a `FastPixPlayerVideoQuality`
- `minResolution`: Lowest allowed resolution
- `maxResolution`: Highest allowed resolution

#### Rendition Control
- `renditionOrder`: Selection order, a `FastpixPlayerRenditionOrder` (`auto`, `asc`, `desc`)

### FastPixCastController

Drives Chromecast playback for a FastPix stream.

#### Constructor Parameters
- `appId`: Cast application ID of the receiver to look for. Defaults to Google's Default Media Receiver
- `stopCastingOnAppTerminated`: Whether the receiver stops playing when the app is terminated (default `true`)
- `segmentFormat`: How the HLS streams being cast are packaged (`auto`, `fmp4`, `mpegTs`)
- `verbose`: Print a trace of the cast handshake, tagged `[FastPixCast]`
- `eventManager`: Event manager to dispatch cast events through. Pass `player.eventManager` to share listeners with playback events

#### Lifecycle
- `initialize()`: Initialize the Cast context. Repeat calls are a no-op; settles on `unavailable` on unsupported platforms instead of throwing
- `startDiscovery()` / `stopDiscovery()`: Start and stop scanning for receivers
- `dispose()`: Release subscriptions and streams. Does **not** end a live session

#### Sessions
- `connect(device, {timeout})`: Start a session and wait until it is established. Returns whether it connected
- `disconnect({stopReceiver = true})`: End the current session
- `startCastingFrom(player, device)`: Move playback from the local player to the receiver, continuing where it left off. Returns `false` when the receiver does not connect; throws `StateError` when the player has no data source, `UnsupportedError` for DRM sources without a custom receiver, and rethrows a load failure after resuming locally
- `stopCastingTo(player)`: Move playback back from the receiver to the local player

#### Media
- `loadMedia(dataSource, {startAt, autoPlay})`: Load a stream on the connected receiver. Throws `StateError` when no session is connected and `UnsupportedError` for DRM sources without a custom receiver
- `play()`, `pause()`, `stop()`, `seekTo(position)`: Remote transport control
- `setVolume(volume)`: Set the receiver's device volume (0.0–1.0)
- `selectTextTrack(track)` / `disableTextTrack()`: Change the subtitle track on the receiver

#### State
- `state` / `stateStream`: Current `FastPixCastState` and its changes
- `devices` / `devicesStream`: Discovered receivers
- `connectedDevice`: The receiver currently playing, or `null`
- `isConnected`, `isRemotePlaying`, `hasCustomReceiver`
- `remotePosition` / `remotePositionStream`: Position reported by the receiver
- `remoteVolume` / `remoteVolumeStream`: Volume as this app last set it — external changes are invisible
- `textTracks` / `textTracksStream`: Subtitle tracks the receiver is offering
- `activeTextTrack`: The selected subtitle track, or `null` when off
- `activeTextTrackStream`: The selected track's **ID**, not the track itself, or `null` each time subtitles go off
- `remotePositionStream`: Does not replay its latest value to a new listener — seed your UI from `remotePosition` when you subscribe
- `lastError`: Most recent `FastPixCastErrorEvent`, or `null`

#### Permissions
- `requiresNearbyDevicesPermission`: Whether this device gates discovery behind the Android 13+ nearby devices permission
- `openPermissionSettings()`: Open the system settings page for this app

#### Listeners
- `addEventListener(type, listener)` / `removeEventListener(type, listener)`
- `addGlobalListener(listener)` / `removeGlobalListener(listener)`

### FastPixCastDevice

A receiver discovered on the local network:

- `id`: Stable identifier, used to connect to it
- `name`: Name the user gave the device, e.g. "Living Room TV"
- `modelName`: Hardware model, e.g. "Chromecast"
- `statusText`: Text the receiver is currently displaying, when it reports any
- `isOnLocalNetwork`: Whether the receiver is on the same local network

### FastPixCastTextTrack

A subtitle or caption track the receiver is offering:

- `id`: Receiver-assigned track ID, used to select it
- `label`: Label to show, falling back to the language code and then the track ID
- `languageCode`: RFC 5646 language code, when the receiver reported one
- `isClosedCaption`: Whether the track is closed captions rather than plain subtitles

### FastPixPlaylistState

Snapshot of the playlist, published on every active-item change:

- `index`: Active item, `-1` when nothing in the list is playing
- `item`: The active `FastPixPlayerDataSource`, or `null`
- `count`, `canGoNext`, `canGoPrevious`, `hasPlaylist`
- `position`: Human readable position, e.g. `2 of 3`

### FastPixSkipSegment

A range of an item a viewer can skip:

- `start`, `end`: Range bounds
- `type`: `FastPixSkipType.intro | recap | song | credits`
- `length`, `contains(position)`

### FastPixPlaylistException

Thrown when a playlist cannot be played:

- `code`: `emptyPlaylist`, `missingPlaybackId`, `malformedJson`, `malformedEntry` or `startIndexOutOfRange`
- `message`: Human readable description
- `itemIndex`: Position of the offending entry, when the failure is about one

### FastPixPlaybackState

Everything a control bar draws itself from: `position`, `duration`,
`bufferedPosition`, `isPlaying`, `isBuffering`, `playbackRate`.

### FastPixQualityLevel

- `id`, `label`, `width`, `height`, `bitrate`, `isAuto`

### FastPixAudioTrack / FastPixSubtitleTrack

- `id`, `label`, `language`, and on subtitles `isEmbedded` for a track that came from the manifest

### FastPixCastErrorEvent

Emitted for every cast failure:

- `errorCode`: Normalized `FastPixCastErrorCode`
- `code`: Stable string code, e.g. `FP_CAST_CONNECT_TIMEOUT`
- `message`: Human readable, actionable description
- `underlyingError`: Raw platform error string, when the failure came from the Cast SDK
- `isFatal`: Casting is unusable until the user changes something outside the app — hide the cast button
- `isPermissionRelated`: Fixable from the system settings app; pair with `openPermissionSettings()`
- `isContentUnsupported`: This content can never play on a receiver — do not offer a retry
- `isRetryable`: The same action may succeed if simply tried again

### Widgets

#### FastPixPlayer
Basic player widget with minimal controls.

DRM related properties:
- `drmErrorWidgetBuilder`: Builder for the DRM failure state. Takes precedence over `errorWidgetBuilder` for DRM failures
- `errorWidgetBuilder`: Builder for the generic failure state
- `diagnoseErrors`: Whether to probe the FastPix endpoints after a failure to work out its real cause (default `true`)

#### FastPixVideoSurface
Headless video surface for a custom UI — video and nothing else.

- `controller`: The player controller
- `aspectRatio`: Overrides the video's own ratio
- `backgroundColor`, `placeholder`: What is drawn behind and before the first frame
- `pipBuilder`: Content for the Picture-in-Picture window

#### FastPixPlaylistPanel
The playlist queue drawn over the video, with the active item marked.

- `controller`, `onDismiss` (required)
- `title`, `width`, `backgroundColor`, `foregroundColor`, `accentColor`

#### FastPixSkipType
- `intro`, `recap`, `song`, `credits`

#### FastPixPlaylistRepeatMode
- `off`: Stop at the last item
- `one`: Replay the active item
- `all`: Wrap from the last item to the first

#### FastPixCustomUIErrorCode
- `trackUnavailable`, `trackSwitchFailed`, `qualitySelectionUnsupported`, `playbackRateUnsupported`, `castUnavailable`, `playerNotReady`, `pipUnsupported`, `pipFailed`

#### FastPixPlayerVideoQuality
- `auto`, `p140`, `p240`, `p360`, `p480`, `p720`, `p1080`, `p1440`, `p2160`, `p4320`

#### FastpixPlayerRenditionOrder
- `auto`: Let the player choose
- `asc`: Lowest rendition first
- `desc`: Highest rendition first

#### FastPixDrmType
- `widevine`: Widevine, used on Android
- `fairplay`: FairPlay, used on iOS

#### FastPixCastState
- `unavailable`: Casting cannot be used on this device at all
- `noDevices`: Cast is ready but no receiver has been discovered yet
- `devicesFound`: At least one receiver is available — show the cast button
- `connecting`: A session is being established
- `connected`: A session is live; the receiver is playing the stream
- `error`: Discovery or the session failed; the reason is on `lastError`

Extension getters for gating cast UI: `canCast`, `isCasting`, `hasSession`.

#### FastPixCastSegmentFormat
- `auto`: Send no hint and let the receiver work it out (default)
- `fmp4`: fMP4 / CMAF segments
- `mpegTs`: Classic MPEG-TS segments

## Additional Information

FastPix Player is designed specifically for streaming content from `stream.fastpix.com` and other streaming services. It automatically constructs the correct streaming URLs based on your playback ID, custom domain, and chosen format, ensuring optimal performance and compatibility.

The controller-based API ensures predictable behavior by centralizing all data source and configuration management through the controller, eliminating the random behavior that could occur with duplicate parameter passing.

### Key Features Summary

- **Streaming-Only**: Optimized for HLS streaming
- **Quality Control**: Advanced resolution and quality management
- **Live Streaming**: Optimized for live content
- **Caching**: Intelligent video caching
- **Custom Domains**: Support for custom streaming domains
- **Authentication**: Token-based authentication
- **DRM**: Widevine and FairPlay playback through the FastPix license server
- **Playlists**: Ordered playback in one controller, with autoplay-next, repeat and automatic preload windowing
- **Skip Segments**: Intro, recap, song and credits ranges with a skip offered in place
- **Custom UI**: A headless video surface plus the full functionality API behind your own controls
- **Picture-in-Picture**: PiP on Android and iOS, with automatic entry on backgrounding
- **Chromecast**: Discovery, session management, and handoff between local and receiver playback
- **Error Handling**: Comprehensive error management

For issues, feature requests, or contributions, please visit the project repository.
