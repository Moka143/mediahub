import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';

/// The app's progress bar: a thin track with a filled share. Matches the
/// `.prog` and `.prog.thin` rules in the design's CSS.
///
/// It always spans the width it is given. It used to size itself to its
/// fill, so in a start-aligned column a 30% bar was 30% wide with no track
/// behind it — a bar that could not show how much was left.
class EditorialProgress extends StatelessWidget {
  const EditorialProgress({
    super.key,
    required this.value,
    this.thin = false,
    this.height,
    this.color = AppColors.accent,
    this.glow = true,
  });

  /// Progress 0..1. Values outside are clamped.
  final double value;

  /// The 2px variant. Default is 3px; [height] overrides both.
  final bool thin;

  final double? height;

  /// Fill colour — the accent by default; `torrentStateTone` for a torrent.
  final Color color;

  /// A soft halo on the fill. Transfers reserve it for data actually
  /// arriving, so a paused or finished bar sits flat.
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final barHeight = height ?? (thin ? 2.0 : 3.0);
    final radius = BorderRadius.circular(barHeight / 2);

    return Semantics(
      value: '${(value.clamp(0.0, 1.0) * 100).round()}%',
      child: SizedBox(
        width: double.infinity,
        height: barHeight,
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: AppColors.track),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: value.clamp(0.0, 1.0),
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color,
                    boxShadow: glow
                        ? [
                            BoxShadow(
                              color: color.withAlpha(AppOpacity.semi),
                              blurRadius: 4,
                            ),
                          ]
                        : null,
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
