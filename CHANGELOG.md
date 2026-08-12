# Changelog

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
