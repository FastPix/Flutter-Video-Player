import 'package:flutter/material.dart';
import '../enums/fastpix_player_enums.dart';
import '../models/fastpix_player_quality_control.dart';

/// Widget for quality control options in FastPix Player
class FastPixQualityControlWidget extends StatefulWidget {
  /// Current quality control settings
  final FastPixPlayerQualityControl? qualityControl;

  /// Callback when quality control settings change
  final Function(FastPixPlayerQualityControl) onQualityControlChanged;

  /// Whether to show the widget
  final bool showQualityControlOptions;

  /// Background color for the control panel
  final Color? backgroundColor;

  /// Text color for labels and dropdowns
  final Color? textColor;

  /// Border color for the control panel
  final Color? borderColor;

  /// Border radius for the control panel
  final double? borderRadius;

  /// Padding for the control panel
  final EdgeInsets? padding;

  const FastPixQualityControlWidget({
    super.key,
    this.qualityControl,
    required this.onQualityControlChanged,
    this.showQualityControlOptions = true,
    this.backgroundColor,
    this.textColor,
    this.borderColor,
    this.borderRadius,
    this.padding,
  });

  @override
  State<FastPixQualityControlWidget> createState() =>
      _FastPixQualityControlWidgetState();
}

class _FastPixQualityControlWidgetState
    extends State<FastPixQualityControlWidget> {
  late FastPixResolution _minResolution;
  late FastPixResolution _maxResolution;
  late FastPixResolution _resolution;
  late FastPixRenditionOrder _renditionOrder;

  @override
  void initState() {
    super.initState();
    _initializeValues();
  }

  @override
  void didUpdateWidget(FastPixQualityControlWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.qualityControl != widget.qualityControl) {
      _initializeValues();
    }
  }

  void _initializeValues() {
    _minResolution =
        widget.qualityControl?.minResolution ?? FastPixResolution.auto;
    _maxResolution =
        widget.qualityControl?.maxResolution ?? FastPixResolution.auto;
    _resolution = widget.qualityControl?.resolution ?? FastPixResolution.auto;
    _renditionOrder =
        widget.qualityControl?.renditionOrder ?? FastPixRenditionOrder.default_;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.showQualityControlOptions) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: widget.padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.backgroundColor ?? Colors.black87,
        borderRadius: BorderRadius.circular(widget.borderRadius ?? 8),
        border:
            widget.borderColor != null
                ? Border.all(color: widget.borderColor!)
                : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Quality Control',
            style: TextStyle(
              color: widget.textColor ?? Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          _buildResolutionDropdown(),
          const SizedBox(height: 12),
          _buildMinResolutionDropdown(),
          const SizedBox(height: 12),
          _buildMaxResolutionDropdown(),
          const SizedBox(height: 12),
          _buildRenditionOrderDropdown(),
          const SizedBox(height: 16),
          _buildApplyButton(),
        ],
      ),
    );
  }

  Widget _buildResolutionDropdown() {
    return _buildDropdown<FastPixResolution>(
      label: 'Target Resolution',
      value: _resolution,
      items:
          FastPixResolution.values.map((resolution) {
            return DropdownMenuItem(
              value: resolution,
              child: Text(
                FastPixPlayerQualityControl.getResolutionDisplayName(
                  resolution,
                ),
                style: TextStyle(color: widget.textColor ?? Colors.white),
              ),
            );
          }).toList(),
      onChanged: (value) {
        if (value != null) {
          setState(() {
            _resolution = value;
          });
        }
      },
    );
  }

  Widget _buildMinResolutionDropdown() {
    return _buildDropdown<FastPixResolution>(
      label: 'Min Resolution',
      value: _minResolution,
      items:
          FastPixResolution.values.map((resolution) {
            return DropdownMenuItem(
              value: resolution,
              child: Text(
                FastPixPlayerQualityControl.getResolutionDisplayName(
                  resolution,
                ),
                style: TextStyle(color: widget.textColor ?? Colors.white),
              ),
            );
          }).toList(),
      onChanged: (value) {
        if (value != null) {
          setState(() {
            _minResolution = value;
          });
        }
      },
    );
  }

  Widget _buildMaxResolutionDropdown() {
    return _buildDropdown<FastPixResolution>(
      label: 'Max Resolution',
      value: _maxResolution,
      items:
          FastPixResolution.values.map((resolution) {
            return DropdownMenuItem(
              value: resolution,
              child: Text(
                FastPixPlayerQualityControl.getResolutionDisplayName(
                  resolution,
                ),
                style: TextStyle(color: widget.textColor ?? Colors.white),
              ),
            );
          }).toList(),
      onChanged: (value) {
        if (value != null) {
          setState(() {
            _maxResolution = value;
          });
        }
      },
    );
  }

  Widget _buildRenditionOrderDropdown() {
    return _buildDropdown<FastPixRenditionOrder>(
      label: 'Rendition Order',
      value: _renditionOrder,
      items:
          FastPixRenditionOrder.values.map((order) {
            return DropdownMenuItem(
              value: order,
              child: Text(
                FastPixPlayerQualityControl.getRenditionOrderDisplayName(order),
                style: TextStyle(color: widget.textColor ?? Colors.white),
              ),
            );
          }).toList(),
      onChanged: (value) {
        if (value != null) {
          setState(() {
            _renditionOrder = value;
          });
        }
      },
    );
  }

  Widget _buildDropdown<T>({
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: widget.textColor ?? Colors.white70,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          height: 50,
          decoration: BoxDecoration(
            border: Border.all(
              color: widget.textColor?.withValues(alpha: 0.3) ?? Colors.white30,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              items: items,
              onChanged: onChanged,
              dropdownColor: widget.backgroundColor ?? Colors.black87,
              icon: Icon(
                Icons.arrow_drop_down,
                color: widget.textColor ?? Colors.white,
              ),
              style: TextStyle(
                color: widget.textColor ?? Colors.white,
                fontSize: 14,
              ),
              isExpanded: true,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildApplyButton() {
    final qualityControl = FastPixPlayerQualityControl(
      minResolution:
          _minResolution == FastPixResolution.auto ? null : _minResolution,
      maxResolution:
          _maxResolution == FastPixResolution.auto ? null : _maxResolution,
      resolution: _resolution == FastPixResolution.auto ? null : _resolution,
      renditionOrder:
          _renditionOrder == FastPixRenditionOrder.default_
              ? null
              : _renditionOrder,
    );

    final isValid = qualityControl.isValid();
    final hasChanges = qualityControl.hasParameters;

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed:
            isValid && hasChanges
                ? () {
                  widget.onQualityControlChanged(qualityControl);
                }
                : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        child: Text(
          'Apply Quality Settings',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}
