import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_typography.dart';

/// Italic Instrument Serif text. The editorial voice — use for hero
/// titles, section headers, screen names, episode numbers. Anywhere
/// the design calls for a serif moment.
class SerifTitle extends StatelessWidget {
  const SerifTitle(
    this.text, {
    super.key,
    this.size = 28,
    this.color = AppColors.fg,
    this.maxLines,
    this.overflow,
    this.height = 1.05,
    this.letterSpacing = -0.01,
    this.fontStyle = FontStyle.italic,
    this.textAlign,
  });

  final String text;
  final double size;
  final Color color;
  final int? maxLines;
  final TextOverflow? overflow;
  final double height;
  final double letterSpacing;
  final FontStyle fontStyle;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: maxLines,
      overflow: overflow ?? (maxLines != null ? TextOverflow.ellipsis : null),
      textAlign: textAlign,
      style: AppType.serif(
        size: size,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
        fontStyle: fontStyle,
      ),
    );
  }
}
