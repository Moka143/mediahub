import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_typography.dart';

/// Tiny tracked-out uppercase mono label. Use for section subtitles
/// ("THIS WEEK"), table headers, badge text, breadcrumbs, timestamps —
/// anywhere the design uses 10–11px JetBrains Mono in caps.
///
/// The text is auto-uppercased by default. Pass `uppercase: false` to
/// keep the original casing (e.g. for hashes, paths, codecs).
class MonoLabel extends StatelessWidget {
  const MonoLabel(
    this.text, {
    super.key,
    this.color = AppColors.fg3,
    this.size = 10,
    this.letterSpacing = 0.14,
    this.uppercase = true,
    this.maxLines,
    this.overflow,
    this.weight = FontWeight.w400,
  });

  final String text;
  final Color color;
  final double size;
  final double letterSpacing;
  final bool uppercase;
  final int? maxLines;
  final TextOverflow? overflow;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    return Text(
      uppercase ? text.toUpperCase() : text,
      maxLines: maxLines,
      overflow: overflow ?? (maxLines != null ? TextOverflow.ellipsis : null),
      style: AppType.mono(
        size: size,
        color: color,
        letterSpacing: letterSpacing,
        weight: weight,
      ),
    );
  }
}

/// Mono *technical data* — speeds, hashes, codecs, paths. Same family
/// (JetBrains Mono) but bigger, mixed case, lighter letter-spacing
/// than [MonoLabel]. Use for facts that need to read precisely.
class MonoText extends StatelessWidget {
  const MonoText(
    this.text, {
    super.key,
    this.size = 12,
    this.color = AppColors.fg1,
    this.weight = FontWeight.w400,
    this.maxLines,
    this.overflow,
    this.height = 1.3,
    this.letterSpacing = 0,
  });

  final String text;
  final double size;
  final Color color;
  final FontWeight weight;
  final int? maxLines;
  final TextOverflow? overflow;
  final double height;
  final double letterSpacing;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: maxLines,
      overflow: overflow ?? (maxLines != null ? TextOverflow.ellipsis : null),
      style: AppType.mono(
        size: size,
        color: color,
        weight: weight,
        height: height,
        letterSpacing: letterSpacing,
      ),
    );
  }
}
