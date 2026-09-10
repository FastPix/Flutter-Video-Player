# Changelog

## [1.1.2]

### Added
- **Playlists**: `setPlaylist(items, {startIndex, configuration})` and `setPlaylistFromJson(json, ...)` play an ordered list on one controller
- **Navigation**: `next()`, `previous()`, `jumpTo(index)`, each reporting whether the index moved, plus `clearPlaylist()`, the index getters, `playlistState` and `playlistStateStream`
- **Autoplay and repeat**: `autoPlayNext` (default `false`) and `repeatMode` (`off` / `one` / `all`, default `off`), independent of `FastPixPlayerDataSource.loop`
- **Playlist validation**: `FastPixPlaylistException` with a `FastPixPlaylistErrorCode` and the offending `itemIndex`. A rejected playlist changes nothing
- **Source switching**: `loadPlaybackId(source)` replaces the playing source, disposing the outgoing engine player, recycling the metrics session and reopening the analytics sequence
- **Preload windowing**: playlist neighbours are warmed after each load, `preloadRadius` deep (default `2`, `0` disables)
- **Skip segments**: `skipSegments` on the data source, with `activeSkipSegment`, `skipCurrentSegment()` and the `skipAvailable` / `skipHidden` events
- **Skip validation**: once per source, at the first usable duration. A rejected segment emits `skipFailed` and leaves its siblings active
- **Data source**: `skipSegments`, `startAt`, `endAt` and `fromJson`
- **Custom UI**: `FastPixVideoSurface` draws video alone. The controller adds `playbackStateStream`, `togglePlayPause()`, `seekForward()` / `seekBackward()`, scrub, `setPlaybackRate()`, and quality, audio and subtitle selection. Failures reach the error channel as a `FastPixCustomUIErrorCode` instead of throwing
- **Picture-in-Picture**: `controller.pip` — `enterPip()`, `exitPip()`, `togglePip()`, `isPipAvailable()`, `isPipActive`, `enabled`, `autoEnterOnBackground`, `setPipAudioBehavior()` — plus `FastPixPipChangedEvent` and `pipBuilder`. Needs `android:supportsPictureInPicture` and the iOS `audio` background mode
- **Playlist panel**: `FastPixPlaylistPanel`, the queue the bundled skin opens
- **Event types**: `playlistChanged`, `playlistItemChanged`, `playlistEnded`, `skipAvailable`, `skipHidden`, `skipCompleted`, `skipFailed`, `playbackRateChanged`, `scrubStarted`, `scrubEnded`, `qualityLevelsReady`, `qualityLevelChanged`, `audioTracksReady`, `audioTrackChanged`, `subtitleTracksReady`, `subtitleChanged`, `pipChanged`
- **Controls configuration**: `enableSkips` (default `false`), `showPlaylistControls`, `showPlaylistPanel`, `showCastWhenNoDevices`
- **`sourceGeneration`**: a `ValueListenable<int>`, incremented once per source load

### Changed
- Every playback event carries `playbackId`, and `playlistIndex` when a playlist is set. Nothing existing changed
- `FastPixPlayer` and `FastPixVideoSurface` re-read the engine player on `sourceGeneration` instead of latching it at mount
- The cast glyph shows before discovery finds a receiver, governed by `showCastWhenNoDevices`
- Picture-in-Picture survives a playlist advance
- Captions are scaled to the Picture-in-Picture window
- Automatic advance is suppressed while casting; explicit navigation still works
- `dispose()` releases the playlist, so no advance, warm or event follows it


## [1.0.2]

### Added
- **Preloading**: `FastPixPreloadManager` warms upcoming sources so the next tap skips the manifest fetch, license acquisition and decoder setup. Two strategies — `network` warms the connection and manifest, `player` builds a detached player that playback then adopts. Warm depth, per-platform player caps, Cast awareness and a full event stream included
- **Precaching**: `FastPixPrecacheManager` writes manifest and segment bytes to disk ahead of playback, with byte accounting, request coalescing and its own event stream. Reads back into playback on Android; on iOS it stores but does not yet shorten a later start
- **Chromecast**: `FastPixCastController` for discovery, session management, remote transport control, receiver volume and subtitle selection, with `startCastingFrom` / `stopCastingTo` moving playback between phone and TV at the position it left off. Cast failures are normalized into `FastPixCastErrorCode`, including the Android 13+ nearby devices permission that otherwise makes discovery find nothing silently
- **Screen capture protection**: `secureScreen` on `FastPixPlayerDrmConfiguration` applies Android's `FLAG_SECURE` while a DRM source plays. On by default, best effort, and window wide

### Changed
- **iOS FairPlay setup is now self-contained.** The resource-loader patch ships inside the plugin and installs itself at registration, so the manual edit to the cached engine that iOS DRM used to require is no longer needed. Nothing to do on upgrade — remove the manual patch step from your build if you scripted it
- **Engine floor raised to `better_player_plus: ^1.2.1`**, from `^1.0.8`. FairPlay relies on the engine's Objective-C surface, which settled in 1.2.1. The old floor allowed older engines to satisfy the constraint, so a project resolving to one could see iOS DRM behave inconsistently. Raising the floor makes the supported engine explicit rather than resolution-dependent. Most projects already resolve to 1.2.1 or later and will see no change
- Pinned the Material control theme in the iOS player so controls render consistently across platforms
- Reworked the example app UI, including working subtitles and cast track selection

### Documentation
- Corrected the stated cause of disabled iOS HLS caching. It is the local cache proxy failing on signed FastPix URLs with `CoreMediaErrorDomain -12642`, not FairPlay holding the asset's single resource-loader delegate. The distinction matters because caching is off for unprotected iOS HLS too
- Corrected the `FastPixPlayerDrmConfiguration.validate` signature, the reachable set of pre-flight DRM error codes, two Chromecast behaviours around DRM refusal and local resume, and the Android manifest snippet, which was missing `FOREGROUND_SERVICE_MEDIA_PLAYBACK`

## [1.0.1]

### Added
- **DRM Playback**: Protected playback via `FastPixPlayerDrmConfiguration` with Widevine (Android) and FairPlay (iOS) support, configured through `FastPixPlayerDataSource.drmConfiguration`
- **DRM Error Handling**: `FastPixDrmException`, `FastPixDrmErrorCode`, and `FastPixDrmErrorClassifier` for categorized DRM failures, including token-related and retryable error detection
- **Custom Error UI**: `errorWidgetBuilder` and `drmErrorWidgetBuilder` on the player widget, plus a `diagnoseErrors` flag to run diagnostics automatically on failure
- **Example App**: Full runnable example application demonstrating standard and DRM playback

### Changed
- Caching is now automatically disabled for DRM-protected sources and for
  **all iOS playback**. On iOS, better_player's cache serves bytes through an
  `AVAssetResourceLoader`, which cannot back an HLS playlist and caused
  AVFoundation to reject healthy streams with `CoreMediaErrorDomain -12642`.
  `cacheEnabled: true` is silently ignored on iOS as a result; Android caching
  is unaffected.

### Tests
- Added coverage for playback diagnostics, DRM error classification, error widget rendering, and controller lifecycle

## [1.0.0]

### Changed
- **BREAKING**: Updated default streaming base URL from `https://stream.fastpix.io` to `https://stream.fastpix.com`
- Updated FastPix Dashboard, documentation, and streaming domain references from `.io` to `.com` across README and issue templates

## [0.2.0]

### Added
- In-built data analytics 

## [0.1.0]

### Initial Release Flutter Player SDK
- **Player Controller**: `FastPixPlayerController` for managing player state and lifecycle
- **HLS Support**: Native HLS (HTTP Live Streaming) playback support
- **Private and Public media playback support**: Simplified video playback using FastPix playback IDs
- **Auto Playback**: Configurable auto-play functionality with WiFi-only option
- **Loop Playback**: Video looping capability for continuous viewing
- **Security Features**: Token-based authentication for private
- **Error Handling**: Comprehensive error handling with categorized error types and severity levels
- **Subtitle Support**: Automatic subtitle detection and manual subtitle switching
- **Stream Type Support**: Both on-demand and live streaming capabilities
- **Quality Control**: Advanced video quality management with resolution controls
- **Progress Tracking**: Built-in progress bar with time remaining display
- **Fullscreen Support**: Fullscreen playback capability
- **Quality Selection**: Manual quality selection with quality control widget
- **Cache Management**: Video caching for improved playback performance for on-demand media playback
- **Custom Domain Support**: Support for custom streaming domains

### Platform Support
- **Android**: Full Android support with native integration
- **iOS**: Full iOS support with native integration
