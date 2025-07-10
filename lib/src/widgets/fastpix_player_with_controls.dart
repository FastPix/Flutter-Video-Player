import 'package:flutter/material.dart';
import '../fastpix_player_controller.dart';
import '../fastpix_player_widget.dart';
import '../enums/fastpix_player_enums.dart';
import '../models/fastpix_player_quality_control.dart';
import 'fastpix_quality_control_widget.dart';

/// Enhanced FastPix Player widget with quality control options
class FastPixPlayerWithControls extends StatefulWidget {
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

  /// Whether to show quality control options
  final bool showQualityControlOptions;

  /// Background color for quality control panel
  final Color? qualityControlBackgroundColor;

  /// Text color for quality control panel
  final Color? qualityControlTextColor;

  /// Border color for quality control panel
  final Color? qualityControlBorderColor;

  /// Border radius for quality control panel
  final double? qualityControlBorderRadius;

  /// Padding for quality control panel
  final EdgeInsets? qualityControlPadding;

  /// Callback when quality control settings change
  final Function(FastPixPlayerQualityControl)? onQualityControlChanged;

  const FastPixPlayerWithControls({
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
    this.showQualityControlOptions = true,
    this.qualityControlBackgroundColor,
    this.qualityControlTextColor,
    this.qualityControlBorderColor,
    this.qualityControlBorderRadius,
    this.qualityControlPadding,
    this.onQualityControlChanged,
  });

  @override
  State<FastPixPlayerWithControls> createState() =>
      _FastPixPlayerWithControlsState();
}

class _FastPixPlayerWithControlsState extends State<FastPixPlayerWithControls> {
  bool _showQualityControl = false;
  FastPixPlayerQualityControl? _currentQualityControl;

  @override
  void initState() {
    super.initState();
    // Initialize with current quality control from data source
    _currentQualityControl = widget.controller.dataSource?.qualityControl;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Main player widget
        FastPixPlayer(
          controller: widget.controller,
          width: widget.width,
          height: widget.height,
          aspectRatio: widget.aspectRatio,
          showLoadingIndicator: widget.showLoadingIndicator,
          loadingIndicatorColor: widget.loadingIndicatorColor,
          errorWidgetBuilder: widget.errorWidgetBuilder,
          placeholderWidgetBuilder: widget.placeholderWidgetBuilder,
          showErrorDetails: widget.showErrorDetails,
        ),

        // Quality control toggle button
        if (widget.showQualityControlOptions) ...[
          const SizedBox(height: 8),
          _buildQualityControlToggle(),

          // Quality control panel
          if (_showQualityControl) ...[
            const SizedBox(height: 8),
            _buildQualityControlPanel(),
          ],
        ],
      ],
    );
  }

  Widget _buildQualityControlToggle() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () {
          setState(() {
            _showQualityControl = !_showQualityControl;
          });
        },
        icon: Icon(
          _showQualityControl ? Icons.settings : Icons.settings_outlined,
          color: Colors.white,
        ),
        label: Text(
          _showQualityControl
              ? 'Hide Quality Settings'
              : 'Show Quality Settings',
          style: const TextStyle(color: Colors.white),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.black87,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
      ),
    );
  }

  Widget _buildQualityControlPanel() {
    return FastPixQualityControlWidget(
      qualityControl: _currentQualityControl,
      onQualityControlChanged: _onQualityControlChanged,
      showQualityControlOptions: widget.showQualityControlOptions,
      backgroundColor: widget.qualityControlBackgroundColor,
      textColor: widget.qualityControlTextColor,
      borderColor: widget.qualityControlBorderColor,
      borderRadius: widget.qualityControlBorderRadius,
      padding: widget.qualityControlPadding,
    );
  }

  void _onQualityControlChanged(
    FastPixPlayerQualityControl qualityControl,
  ) async {
    setState(() {
      _currentQualityControl = qualityControl;
    });

    // Update the data source with new quality control settings
    final currentDataSource = widget.controller.dataSource;
    if (currentDataSource != null) {
      final updatedDataSource = currentDataSource.copyWith(
        qualityControl: qualityControl,
      );

      try {
        await widget.controller.updateDataSource(updatedDataSource);

        // Call the callback if provided
        widget.onQualityControlChanged?.call(qualityControl);

        // Show success message
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Quality settings applied successfully'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        // Show error message
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to apply quality settings: $e'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    }
  }
}
