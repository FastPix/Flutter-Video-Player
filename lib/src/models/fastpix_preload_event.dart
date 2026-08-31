import '../enums/fastpix_network_type.dart';
import '../enums/fastpix_preload_strategy.dart';
import 'fastpix_player_event.dart';
import 'fastpix_player_event_types.dart';

/// Common shape for every preload lifecycle event.
///
/// [playbackId] is the identity, never the URL: a FastPix playback URL carries
/// a signed `token` query parameter that rotates independently of the media,
/// so URL-keyed events would stop matching after a token refresh — and would
/// stop matching *silently*, because a miss looks exactly like a cold start.
abstract class FastPixPreloadEvent extends FastPixPlayerEvent {
  const FastPixPreloadEvent({
    required super.type,
    required super.timestamp,
    required this.playbackId,
    required this.strategy,
    this.networkType = FastPixNetworkType.unknown,
    super.data,
  });

  /// The source this event concerns.
  final String playbackId;

  /// The network the warm-up ran over.
  ///
  /// Defaulted rather than required so a caller constructing these directly —
  /// a test, or a host replaying events — is not forced to supply something it
  /// has no way of knowing. [FastPixPreloadManager] always stamps the real
  /// value.
  ///
  /// Matters because warming is speculative: on cellular it spends the
  /// viewer's data on a video they may never open. Without this in the log
  /// there is no way to tell an expensive preload from a free one.
  final FastPixNetworkType networkType;

  /// Which strategy warmed it. Only [FastPixPreloadStrategy.player] entries
  /// can ever be adopted; a `network` entry warms the CDN path and nothing
  /// more.
  final FastPixPreloadStrategy strategy;
}

/// Fired when a source enters the window and warming begins.
class FastPixPreloadStartedEvent extends FastPixPreloadEvent {
  const FastPixPreloadStartedEvent({
    required super.timestamp,
    required super.playbackId,
    required super.strategy,
    super.networkType,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.preloadStarted);
}

/// Fired when a source is warm enough to be useful.
class FastPixPreloadReadyEvent extends FastPixPreloadEvent {
  const FastPixPreloadReadyEvent({
    required super.timestamp,
    required super.playbackId,
    required super.strategy,
    super.networkType,
    required this.elapsed,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.preloadReady);

  /// Wall time the warm-up took.
  ///
  /// Compare this against measured dwell — the gap between a warm starting and
  /// the user tapping. A warm that regularly takes longer than dwell never
  /// finishes, and the window is not buying anything.
  final Duration elapsed;
}

/// Fired when a warm-up fails or times out.
///
/// Not a playback error. The source takes the cold path and the user sees
/// nothing; this exists so a silently ineffective warm-up is detectable.
class FastPixPreloadFailedEvent extends FastPixPreloadEvent {
  const FastPixPreloadFailedEvent({
    required super.timestamp,
    required super.playbackId,
    required super.strategy,
    super.networkType,
    required this.reason,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.preloadFailed);

  /// Raw failure text, preserved rather than normalised so an unexpected
  /// platform message is still debuggable.
  final String reason;
}

/// Fired when a warmed source leaves the window before being used.
class FastPixPreloadCancelledEvent extends FastPixPreloadEvent {
  const FastPixPreloadCancelledEvent({
    required super.timestamp,
    required super.playbackId,
    required super.strategy,
    super.networkType,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.preloadCancelled);
}

/// Fired when a warmed player is handed over to a playing controller.
///
/// This is the only reliable way to separate warm starts from cold ones in
/// reporting. An adopted player reports a near-zero time-to-first-frame, so
/// warming can make startup dashboards look excellent while delivering
/// nothing; without this event the two populations cannot be told apart.
class FastPixPreloadConsumedEvent extends FastPixPreloadEvent {
  const FastPixPreloadConsumedEvent({
    required super.timestamp,
    required super.playbackId,
    required super.strategy,
    super.networkType,
    super.data,
  }) : super(type: FastPixPlayerEventTypes.preloadConsumed);
}
