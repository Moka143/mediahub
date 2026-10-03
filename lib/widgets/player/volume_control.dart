import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';

/// Volume control: a mute button, with a slider that opens on hover or
/// keyboard focus.
class VolumeControl extends StatefulWidget {
  final double volume;
  final ValueChanged<double> onVolumeChanged;

  /// Mute, or unmute back to the previous level. The button used to set the
  /// volume to 0 or 100 directly, so unmuting after muting at 30 blasted
  /// playback at full volume.
  final VoidCallback onToggleMute;

  const VolumeControl({
    super.key,
    required this.volume,
    required this.onVolumeChanged,
    required this.onToggleMute,
  });

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  static const double _sliderWidth = 100;

  bool _hovered = false;
  bool _focused = false;

  bool get _showSlider => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final muted = widget.volume == 0;
    // Tracks focus anywhere inside, so tabbing to the button opens the
    // slider for a keyboard user the way hovering does for a mouse.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.onMedia.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          padding: _showSlider
              ? const EdgeInsets.only(right: AppSpacing.sm)
              : EdgeInsets.zero,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: muted ? 'Unmute (M)' : 'Mute (M)',
                icon: Icon(
                  muted
                      ? Icons.volume_off_rounded
                      : widget.volume < 50
                      ? Icons.volume_down_rounded
                      : Icons.volume_up_rounded,
                  color: AppColors.onMedia,
                ),
                onPressed: widget.onToggleMute,
              ),
              if (_showSlider)
                SizedBox(
                  width: _sliderWidth,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 5,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 10,
                      ),
                      activeTrackColor: AppColors.onMedia,
                      inactiveTrackColor: AppColors.onMedia.withValues(
                        alpha: 0.3,
                      ),
                      thumbColor: AppColors.onMedia,
                    ),
                    child: Slider(
                      value: widget.volume.clamp(0.0, 100.0),
                      min: 0,
                      max: 100,
                      semanticFormatterCallback: (v) => 'Volume ${v.round()}%',
                      onChanged: widget.onVolumeChanged,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
