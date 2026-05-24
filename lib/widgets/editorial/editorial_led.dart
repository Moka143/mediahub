import 'package:flutter/material.dart';

/// Tiny LED-style status dot with optional glow. Used inline next to
/// labels (sidebar status, row indicators).
class EditorialLed extends StatelessWidget {
  const EditorialLed({
    super.key,
    required this.color,
    this.size = 6,
    this.glow = true,
  });

  final Color color;
  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: glow
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.6),
                  blurRadius: size,
                ),
              ]
            : null,
      ),
    );
  }
}
