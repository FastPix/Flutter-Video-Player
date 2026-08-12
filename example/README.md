# fastpix_player_example

A runnable demo of the [`fastpix_video_player`](../) package. It plays a FastPix
HLS stream from a playback ID, supports private (token protected) and DRM
protected media, and streams the player's events into an on-screen log.

## Running

The example depends on the package from the parent directory (`path: ../`), so
no publishing step is needed:

```bash
cd example
flutter pub get
flutter run
```

## Using the demo

1. **Playback ID** — paste a playback ID that has reached the `ready` status in
   the [FastPix Dashboard](https://dashboard.fastpix.com).
2. **Token** — only needed for private and DRM protected media. Leave it empty
   for public streams.
3. **DRM protected** — leave this off for ordinary streams. Turning it on
   reveals the **DRM token** field. DRM is opt-in on purpose: routing clear
   media through Widevine/FairPlay never plays, so a leftover token in the field
   cannot silently turn a plain playback ID into a DRM load.
4. **DRM token** — the JWT authorizing the license request. When the token was
   generated with the **DRM License** feature enabled, the same value works for
   both the token and DRM token fields.
5. **Load & play** — builds the data source and initializes the controller.

Below the player the demo shows the constructed stream URL and a live log of
every player event. DRM failures are logged with their error code and actionable
message; an invalid DRM setup also surfaces as a snackbar instead of an endless
spinner.

## Usage example

The core of [`lib/main.dart`](lib/main.dart), condensed:

```dart
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

// Tear down any previous playback before starting a new one.
await _controller?.dispose();

final dataSource = FastPixPlayerDataSource.hls(
  playbackId: playbackId,
  // Only for private / DRM media
  token: token.isEmpty ? null : token,
  // Only when DRM is explicitly switched on — a leftover token must not
  // silently make an ordinary stream a DRM one.
  drmConfiguration: !drmEnabled || drmToken.isEmpty
      ? null
      : FastPixPlayerDrmConfiguration(drmToken: drmToken),
  title: 'Sample HLS Stream',
  videoData: VideoDetailsData(videoId: playbackId, title: 'Sample HLS'),
);

// workSpaceId / viewerId / beaconUrl feed the FastPix metrics SDK.
final configuration = FastPixPlayerConfiguration(
  'demo-workspace',
  'demo-viewer',
  'metrix.ws.fastpix.io',
  controlsConfiguration: const FastPixPlayerControlsConfiguration(
    autoPlay: true,
    enableRetry: true,
  ),
);

final controller = FastPixPlayerController();
controller.addGlobalListener((event) {
  // DRM failures carry a code and an actionable message; everything else
  // is logged by type.
  if (event is FastPixPlayerDrmErrorEvent) {
    debugPrint('${event.type} [${event.code}] ${event.message}');
  } else {
    debugPrint(event.type);
  }
});

try {
  await controller.initialize(
    dataSource: dataSource,
    configuration: configuration,
  );
} on FastPixDrmException catch (error) {
  // The controller already emitted the error event; surface it here too so a
  // bad DRM setup is visible instead of an endless spinner.
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('DRM: ${error.message}')),
  );
}
```

And in `build`:

```dart
FastPixPlayer(
  // No key needed: the player re-initializes itself when it is given a
  // different controller. Keying off the stream URL would miss a changed DRM
  // token, which does not appear in that URL.
  controller: controller,
  height: 220,
)
```

## What it demonstrates

- Building an HLS data source with `FastPixPlayerDataSource.hls(...)`, including
  `drmConfiguration` for protected media.
- Configuring FastPix metrics through `FastPixPlayerConfiguration` (workspace
  ID, viewer ID, beacon URL) and `VideoDetailsData`.
- Listening to every event with `controller.addGlobalListener(...)` and handling
  `FastPixPlayerDrmErrorEvent` separately.
- Catching `FastPixDrmException` from `controller.initialize(...)` so a bad DRM
  configuration is reported immediately.
- Disposing the previous controller before starting a new playback, and handing
  `FastPixPlayer` a new controller to restart playback — no widget key is
  needed, which matters because a changed DRM token does not change the stream
  URL.

## Platform setup

### Android

Streaming needs the internet permission, already present in
`android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

DRM playback on Android uses Widevine and is fully supported.

### iOS

The Runner project targets **iOS 13.0**, which is what `better_player_plus`
requires. In your own app, set the same minimum in `ios/Podfile`:

```ruby
platform :ios, '13.0'
```

and make sure `IPHONEOS_DEPLOYMENT_TARGET` in the Xcode project is not lower.
`flutter run` installs the pods for you; run them by hand after changing the
Podfile:

```bash
cd ios && pod install
```

Two iOS behaviours are worth knowing about:

- **Caching is disabled for HLS on iOS.** `better_player` serves cached bytes
  through an `AVAssetResourceLoader`, which can stand in for a single file but
  not for a playlist that resolves to many segment URLs. With it enabled
  AVFoundation rejects an otherwise healthy stream with `CoreMediaErrorDomain`
  `-12642`, so the package turns the cache off for iOS HLS regardless of
  `cacheEnabled`.
- **FairPlay does not work yet.** `better_player_plus` routes FairPlay through
  an EZDRM specific resource loader that rewrites the license URL, so FastPix
  FairPlay playback does not currently work on iOS without patching the plugin.
  Toggling DRM on in the demo on an iOS device will therefore fail at the
  license step; use Android to try DRM playback.

Streaming over HTTPS needs no App Transport Security exception, and the example
ships without one.

For the full API, see the [package README](../README.md).
