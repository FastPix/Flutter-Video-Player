import 'package:flutter/material.dart';
import 'package:better_player_plus/better_player_plus.dart';
import 'fastpix_player_controller.dart';
import 'models/fastpix_player_drm_error.dart';
import 'models/fastpix_player_event.dart';
import 'models/fastpix_player_event_types.dart';
import 'utils/fastpix_playback_diagnostics.dart';

/// Main FastPix Player widget
class FastPixPlayer extends StatefulWidget {
  /// Player controller (required)
  final FastPixPlayerController controller;

  /// Widget width
  final double? width;

  /// Widget height
  final double? height;

  /// Whether to show loading indicator
  final bool showLoadingIndicator;

  /// Loading indicator color
  final Color? loadingIndicatorColor;

  final VoidCallback? onReplay;

  /// Placeholder widget builder
  final Widget Function()? placeholderWidgetBuilder;

  /// Builder for the DRM failure state.
  ///
  /// Called when the stream is DRM protected and playback failed for a DRM
  /// reason, for example an expired DRM token or an unsupported device. Takes
  /// precedence over [errorWidgetBuilder] for DRM failures. When both are
  /// omitted, a default message built from the failure is shown.
  final Widget Function(FastPixDrmException error)? drmErrorWidgetBuilder;

  /// Builder for the generic failure state.
  ///
  /// Called for any playback error — network, manifest, or a DRM failure when
  /// [drmErrorWidgetBuilder] is not supplied.
  final Widget Function(FastPixPlayerErrorEvent error)? errorWidgetBuilder;

  /// Whether to probe the FastPix endpoints after a failure to work out its
  /// real cause, since the platform players report every load failure with the
  /// same opaque message. The result is appended to the default error UI.
  final bool diagnoseErrors;

  const FastPixPlayer({
    super.key,
    required this.controller,
    this.width,
    this.onReplay,
    this.height,
    this.showLoadingIndicator = true,
    this.loadingIndicatorColor,
    this.placeholderWidgetBuilder,
    this.drmErrorWidgetBuilder,
    this.errorWidgetBuilder,
    this.diagnoseErrors = true,
  });

  @override
  State<FastPixPlayer> createState() => _FastPixPlayerState();
}

class _FastPixPlayerState extends State<FastPixPlayer> {
  BetterPlayerController? _betterPlayerController;
  bool _isInitialized = false;
  FastPixPlayerErrorEvent? _error;
  FastPixPlaybackDiagnosis? _diagnosis;
  bool _diagnosing = false;

  @override
  void initState() {
    super.initState();
    // Playback can fail at any point (an expiring DRM license, a dropped
    // connection), so the error state is driven by the event stream rather
    // than only by the initial wait.
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.error,
      _onErrorEvent,
    );
    _initializeController();
  }

  @override
  void didUpdateWidget(FastPixPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;

    // A new controller means a new playback attempt. Without this the state
    // stays bound to the old controller and keeps showing its error — which is
    // what happens when only the DRM token changes, since the stream URL (and
    // so any key derived from it) is unchanged.
    oldWidget.controller.removeEventListener(
      FastPixPlayerEventTypes.error,
      _onErrorEvent,
    );
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.error,
      _onErrorEvent,
    );
    setState(() {
      _error = null;
      _diagnosis = null;
      _diagnosing = false;
      _betterPlayerController = null;
      _isInitialized = false;
    });
    _initializeController();
  }

  @override
  void dispose() {
    widget.controller.removeEventListener(
      FastPixPlayerEventTypes.error,
      _onErrorEvent,
    );
    super.dispose();
  }

  void _onErrorEvent(FastPixPlayerEvent event) {
    if (event is! FastPixPlayerErrorEvent || !mounted) return;
    setState(() => _error = event);
    _diagnose();
  }

  /// The platform error text cannot distinguish a bad playback ID from an
  /// expired token or a rejected license, so ask the FastPix endpoints.
  Future<void> _diagnose() async {
    if (!widget.diagnoseErrors || _diagnosing) return;
    // Rebuild so the detail line can say the work is under way, rather than
    // leaving a gap that later fills with text out of nowhere.
    setState(() => _diagnosing = true);
    try {
      final diagnosis = await widget.controller.diagnosePlayback();
      if (!mounted) return;
      setState(() => _diagnosis = diagnosis);
    } finally {
      if (mounted) {
        setState(() => _diagnosing = false);
      } else {
        _diagnosing = false;
      }
    }
  }

  /// Initialize the controller
  Future<void> _initializeController() async {
    await _waitForControllerReady();
    _betterPlayerController = widget.controller.betterPlayerController;
    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
  }

  /// Wait for the controller to be ready
  Future<void> _waitForControllerReady() async {
    // Wait until the controller has a BetterPlayerController
    // Use exponential backoff for better performance with timeout
    int delay = 50;
    int totalWaitTime = 0;
    const maxWaitTime = 5000; // 5 seconds timeout

    while (widget.controller.betterPlayerController == null) {
      // A failure before the player exists means it never will be created:
      // stop waiting and let build() surface the error.
      if (widget.controller.lastError != null) {
        return;
      }
      await Future.delayed(Duration(milliseconds: delay));
      totalWaitTime += delay;
      if (totalWaitTime >= maxWaitTime) {
        break;
      }

      delay = delay < 200 ? delay * 2 : 200; // Cap at 200ms
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error ?? widget.controller.lastError;
    if (error != null) {
      return _buildErrorWidget(error);
    }
    if (!_isInitialized) {
      return _buildPlaceholderWidget();
    }
    if (_betterPlayerController == null) {
      return _buildPlaceholderWidget();
    }
    return _buildPlayerWidget();
  }

  /// Opaque platform text that tells a viewer nothing and must not be shown as
  /// the headline. ExoPlayer reports every load failure this way.
  static final RegExp _opaquePlatformError = RegExp(
    r'source error|video player had error|unknown error',
    caseSensitive: false,
  );

  /// The line shown the instant the error arrives. Chosen once and never
  /// replaced, so the diagnosis can only add to what the viewer already read.
  String _headline(FastPixPlayerErrorEvent error) {
    if (error is FastPixPlayerDrmErrorEvent &&
        error.drmErrorCode != FastPixDrmErrorCode.unknown) {
      // An identified DRM cause is already the most specific thing we know.
      return error.message;
    }
    return _opaquePlatformError.hasMatch(error.message)
        ? 'Playback failed'
        : error.message;
  }

  /// The line below the headline: what we are still working out, then what we
  /// found. Null when there is nothing more to say than the headline.
  String? _detail(FastPixPlayerErrorEvent error) {
    if (_diagnosis != null) return _diagnosis!.summary;
    if (_diagnosing) return 'Working out why…';
    // No probe ran, so the raw platform text is all we have left to offer.
    final raw =
        error is FastPixPlayerDrmErrorEvent
            ? error.underlyingError
            : error.message;
    return raw != null && raw != _headline(error) ? raw : null;
  }

  /// Build the failure widget for [error], DRM or otherwise
  Widget _buildErrorWidget(FastPixPlayerErrorEvent error) {
    final isDrm = error is FastPixPlayerDrmErrorEvent;

    if (isDrm && widget.drmErrorWidgetBuilder != null) {
      return widget.drmErrorWidgetBuilder!(
        FastPixDrmException(
          error.drmErrorCode,
          error.message,
          playbackId: error.playbackId,
          underlyingError: error.underlyingError,
        ),
      );
    }
    if (widget.errorWidgetBuilder != null) {
      return widget.errorWidgetBuilder!(error);
    }

    widget.controller.updatePlayerDimensions(
      width: widget.width,
      height: widget.height,
    );

    return Container(
      width: widget.width ?? widget.controller.playerWidth(),
      height: widget.height ?? widget.controller.playerHeight(),
      color: Colors.black,
      padding: const EdgeInsets.all(16),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isDrm ? Icons.lock_outline : Icons.error_outline,
                color: Colors.white70,
                size: 32,
              ),
              const SizedBox(height: 8),
              // The headline is fixed the moment the error arrives and never
              // changes: a message that rewrites itself reads as the first one
              // having been wrong.
              Text(
                _headline(error),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              // The detail only ever fills in — from "working it out" to the
              // answer — so nothing already on screen is contradicted.
              if (_detail(error) case final detail?) ...[
                const SizedBox(height: 6),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
              if (error.code != null || _diagnosis != null) ...[
                const SizedBox(height: 6),
                Text(
                  [
                    if (error.code != null) error.code!,
                    if (_diagnosis != null) _diagnosis!.probes.join('  ·  '),
                  ].join('  ·  '),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Build the player widget
  Widget _buildPlayerWidget() {
    Widget playerWidget = AspectRatio(
      aspectRatio:
          16 / 9, // Default 16:9 aspect ratio - could be made configurable
      child: BetterPlayer(controller: _betterPlayerController!),
    );

    // Always update controller with player dimensions (including defaults)
    widget.controller.updatePlayerDimensions(
      width: widget.width,
      height: widget.height,
    );

    // Use explicit dimensions if provided, otherwise let the controller calculate defaults
    final finalWidth = widget.width;
    final finalHeight = widget.height;

    if (finalWidth != null || finalHeight != null) {
      playerWidget = SizedBox(
        width: finalWidth,
        height: finalHeight,
        child: playerWidget,
      );
    }

    return playerWidget;
  }

  /// Build placeholder widget
  Widget _buildPlaceholderWidget() {
    if (widget.placeholderWidgetBuilder != null) {
      return widget.placeholderWidgetBuilder!();
    }

    // Update controller with dimensions first to get calculated defaults
    widget.controller.updatePlayerDimensions(
      width: widget.width,
      height: widget.height,
    );

    return Container(
      width: widget.width ?? widget.controller.playerWidth(),
      height: widget.height ?? widget.controller.playerHeight(),
      color: Colors.black,
      child: Center(
        child:
            widget.showLoadingIndicator
                ? CircularProgressIndicator(
                  color: widget.loadingIndicatorColor ?? Colors.white,
                )
                : const SizedBox.shrink(),
      ),
    );
  }
}
