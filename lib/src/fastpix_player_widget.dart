import 'package:flutter/material.dart';
import 'package:better_player_plus/better_player_plus.dart';
import 'fastpix_player_controller.dart';
import 'enums/fastpix_player_enums.dart';

/// Main FastPix Player widget
class FastPixPlayer extends StatefulWidget {
  /// Player controller (required)
  final FastPixPlayerController controller;

  /// Widget width
  final double? width;

  /// Widget height
  final double? height;

  /// Aspect ratio
  final FastPixAspectRatio aspectRatio;

  /// Whether to show loading indicator
  final bool showLoadingIndicator;

  /// Loading indicator color
  final Color? loadingIndicatorColor;

  /// Error widget builder
  final Widget Function(String error)? errorWidgetBuilder;

  /// Placeholder widget builder
  final Widget Function()? placeholderWidgetBuilder;

  /// Whether to show error details (for debugging)
  final bool showErrorDetails;

  const FastPixPlayer({
    super.key,
    required this.controller,
    this.width,
    this.height,
    this.aspectRatio = FastPixAspectRatio.fit,
    this.showLoadingIndicator = true,
    this.loadingIndicatorColor,
    this.errorWidgetBuilder,
    this.placeholderWidgetBuilder,
    this.showErrorDetails = false,
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
    while (widget.controller.betterPlayerController == null) {
      await Future.delayed(const Duration(milliseconds: 100));
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
    final aspectRatio = _getAspectRatio();

    Widget playerWidget = AspectRatio(
      aspectRatio: aspectRatio,
      child: BetterPlayer(controller: _betterPlayerController!),
    );

    if (widget.width != null || widget.height != null) {
      playerWidget = SizedBox(
        width: widget.width,
        height: widget.height,
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
    return Container(
      width: widget.width,
      height: widget.height,
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

  /// Get aspect ratio value
  double _getAspectRatio() {
    switch (widget.aspectRatio) {
      case FastPixAspectRatio.fit:
        return 16 / 9;
      case FastPixAspectRatio.ratio16x9:
        return 16 / 9;
      case FastPixAspectRatio.ratio4x3:
        return 4 / 3;
      case FastPixAspectRatio.ratio1x1:
        return 1 / 1;
      case FastPixAspectRatio.stretch:
        return 16 / 9;
    }
  }

  @override
  void dispose() {
    // Don't dispose the controller as it's managed externally
    super.dispose();
  }
}
