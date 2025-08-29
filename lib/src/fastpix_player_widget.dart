import 'package:flutter/material.dart';
import 'package:better_player_plus/better_player_plus.dart';
import 'fastpix_player_controller.dart';

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

  const FastPixPlayer({
    super.key,
    required this.controller,
    this.width,
    this.onReplay,
    this.height,
    this.showLoadingIndicator = true,
    this.loadingIndicatorColor,
    this.placeholderWidgetBuilder,
  });

  @override
  State<FastPixPlayer> createState() => _FastPixPlayerState();
}

class _FastPixPlayerState extends State<FastPixPlayer> {
  BetterPlayerController? _betterPlayerController;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeController();
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
    if (!_isInitialized) {
      return _buildPlaceholderWidget();
    }
    if (_betterPlayerController == null) {
      return _buildPlaceholderWidget();
    }
    return _buildPlayerWidget();
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
