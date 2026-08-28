# fastpix_player_example

A runnable demo of the [`fastpix_video_player`](../) package, built as a small
streaming app rather than a single playback form. It browses a catalog of
streams, plays public, private and DRM protected media, casts to Chromecast, and
puts the preloading and precaching machinery on screen so you can watch it work.

## Running

The example depends on the package from the parent directory (`path: ../`), so
no publishing step is needed:

```bash
cd example
flutter pub get
flutter run
```

It starts with a seeded catalog of public FastPix playback IDs, so there is
something to play immediately. To use your own instead:

```bash
flutter run --dart-define=FASTPIX_PLAYBACK_IDS=id-one,id-two,id-three
```

Command line IDs take precedence over the stored catalog and replace it. The
catalog otherwise persists to `demo_catalog.json` in the application support
directory, so streams you add survive a restart.

## Using the demo

**Home** is a browse screen: a featured hero and three rails, *Continue
watching*, *Live now* and *On demand*. Every poster carries a small preload
status pill. Tapping a poster opens the watch screen with that rail as the
playlist; long pressing opens a menu to edit, precache or remove the stream.
The `+` button adds one.

**Watch** plays the stream and, below it, exposes the parts usually invisible:

- *Up next*, with previous and next controls and an **Autoplay next** switch.
  Advancing swaps the source in place rather than pushing a new screen.
- A precache panel with its status and the exact byte count written.
- A warm start badge reading `WARM START · warmed in Nms` or `COLD START`, which
  is the single clearest signal that preloading is doing anything.
- A preload event feed, and detail rows for playback ID, host, stream type, DRM
  and subtitles, ending in the fully resolved stream URL.

The seeded streams are public video on demand with no token and no DRM, so the
*Live now* rail stays empty until you add a stream with the live switch on.

### Adding a stream

The add and edit sheet takes a playback ID, an optional title, a stream host
(blank uses `stream.fastpix.com`), a token for private or DRM media, a live
switch, a DRM switch that reveals the DRM token field, and an external WebVTT
subtitle URL with its label and language.

DRM is opt in on purpose. Routing clear media through Widevine or FairPlay never
plays, so a leftover token cannot silently turn an ordinary playback ID into a
DRM load. When your token was generated with the DRM License feature enabled,
the same value works in both the token and DRM token fields.

## Chromecast

The cast glyph appears in the player's own control bar once a receiver is found.
Tapping it opens a device picker; choosing a device moves playback to the TV at
the position it had reached locally.

While casting, the video is replaced by a remote control surface with a
scrubber, skip and play controls, receiver volume, and a subtitle picker fed by
the tracks the receiver reports. It renders inline and in fullscreen. Stopping
brings playback back to the phone.

The demo is configured with a FastPix custom receiver, which is what makes DRM
casting possible at all. Google's Default Media Receiver cannot perform a
license request, so a protected stream is refused without one. None of the
seeded streams are protected, so this only matters once you add one.

A diagnostics sheet opens from the tune icon on the home screen and the
**Diagnostics** chip on the watch screen, for when casting misbehaves:

- Current cast state, and a rescan button.
- Devices found, with a count and the connected one marked.
- The last error. When Android's nearby devices permission was denied, it
  offers a shortcut to the system settings page, since that is the one failure
  the user has to fix outside the app.
- A live event log, with a clear button.
- A **fMP4 / CMAF segments** toggle, for when the receiver never starts
  playing. It is disabled during a session, because changing it rebuilds the
  controller.

## Preloading and precaching

The demo runs both, with different settings in each place, which is the point:

| | Where | Strategy | Window |
| --- | --- | --- | --- |
| Home | Whole catalog | `network` | 3 |
| Watch | Neighbours in the queue | `player` | 4 |

The home screen warms the connection and manifest broadly, because it holds no
decoders and costs little. The watch screen warms whole players for the
immediate neighbours, so the next or previous item starts instantly. Home stops
warming while the watch screen is on top, so it cannot evict the warms that are
about to be used, and cast awareness is wired up so no local decoder is spent
while playback is on a receiver.

Precaching writes the master playlist only, from the poster menu or the panel on
the watch screen. The panel reports the bytes actually written, which is the
honest signal: a platform can report success and write nothing. On Android you
can confirm bytes landed with `adb logcat | grep CacheWorker`.

## What it demonstrates

- Browsing and playing with `FastPixPlayerDataSource.hls(...)`, including
  `drmConfiguration` for protected media and external subtitle tracks.
- Sharing one `FastPixPlayerConfiguration` between preloading and playback,
  which is what makes a warmed player adoptable. A mismatch is refused.
- `FastPixPreloadManager` under both strategies, with status per source and the
  adoption result surfaced on screen.
- `FastPixPrecacheManager.precacheManifest` with byte accounting.
- `FastPixCastController` end to end: discovery, session handover with
  `startCastingFrom` / `stopCastingTo`, remote transport, volume, subtitle
  selection, and normalized error codes.
- Warming playback hosts at app start with `warmPlaybackHostsFor`, derived from
  the catalog so custom domains are warmed at the host they are played from.
- Listening with `controller.addGlobalListener(...)` and handling
  `FastPixPlayerDrmErrorEvent` separately from ordinary events.
- Catching `FastPixDrmException` from `controller.initialize(...)` so a bad DRM
  configuration is reported immediately instead of as an endless spinner.

To watch the SDK's own decisions, including every skip and refusal:

```bash
flutter run | grep -E "preloading|precaching"
```

The line worth looking for is `ADOPTED`.

## Platform setup

### Android

The example declares, in `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
<uses-permission
    android:name="android.permission.NEARBY_WIFI_DEVICES"
    android:usesPermissionFlags="neverForLocation" />
```

plus the Cast options provider and the media notification service inside
`<application>`. Only the internet permission is needed for plain playback; the
rest are for Chromecast. The runtime nearby devices request is made by the SDK
from `startDiscovery()`.

DRM playback on Android uses Widevine and is fully supported.

### iOS

The example's Runner project targets **iOS 15.0**. The package itself declares a
floor of **iOS 12.0** in its podspec, and that is the real minimum for your own
app; the example simply targets something newer. Set it in `ios/Podfile`:

```ruby
platform :ios, '12.0'
```

and make sure `IPHONEOS_DEPLOYMENT_TARGET` in the Xcode project is not lower.
`flutter run` installs the pods for you; run them by hand after changing the
Podfile:

```bash
cd ios && pod install
```

Chromecast discovery needs `NSLocalNetworkUsageDescription`,
`NSBluetoothAlwaysUsageDescription` and an `NSBonjourServices` entry listing
both `_googlecast._tcp` and the receiver specific service. The example's
`Info.plist` has all three. Streaming over HTTPS needs no App Transport Security
exception, and the example ships without one.

Two iOS behaviours are worth knowing about:

- **FairPlay works, with nothing to install.** The package ships a resource
  loader patch that installs itself when the plugin registers, which is what
  lets FairPlay reach the FastPix license server. Earlier versions needed a
  manual edit to the cached engine; that step is gone.
- **Caching is disabled for HLS on iOS.** The engine's cache serves bytes
  through a local proxy, and that proxy does not survive a signed FastPix URL:
  an unprotected stream fails outright with `CoreMediaErrorDomain -12642`. The
  package therefore ignores `cacheEnabled` for iOS HLS. Precaching is separately
  refused for DRM on iOS, because FairPlay already owns the asset's single
  resource loader slot.

For the full API, see the [package README](../README.md).
