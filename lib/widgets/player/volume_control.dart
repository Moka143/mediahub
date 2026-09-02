import 'package:flutter/material.dart';

import '../../design/app_tokens.dart';

/// Volume control widget
class VolumeControl extends StatefulWidget {
  final double volume;
  final ValueChanged<double> onVolumeChanged;

  const VolumeControl({
    super.key,
    required this.volume,
    required this.onVolumeChanged,
  });

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  bool _showSlider = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _showSlider = true),
      onExit: (_) => setState(() => _showSlider = false),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        padding: EdgeInsets.only(right: _showSlider ? AppSpacing.sm : 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(
                widget.volume == 0
                    ? Icons.volume_off_rounded
                    : widget.volume < 50
                    ? Icons.volume_down_rounded
                    : Icons.volume_up_rounded,
                color: Colors.white,
              ),
              onPressed: () {
                widget.onVolumeChanged(widget.volume > 0 ? 0 : 100);
              },
            ),
            if (_showSlider)
              SizedBox(
                width: 100,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 10,
                    ),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: widget.volume,
                    min: 0,
                    max: 100,
                    onChanged: widget.onVolumeChanged,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
