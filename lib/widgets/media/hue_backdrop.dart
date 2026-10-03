import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';

/// A stable hue for [text] — the same title always gets the same colour.
double hueForText(String text) =>
    (text.codeUnits.fold<int>(0, (a, b) => a + b) % 360).toDouble();

/// A stable hue for a TMDB id.
double hueForId(int id) => ((id * 37) % 360).toDouble();

/// The placeholder drawn where artwork is missing or still loading: a
/// diagonal gradient in a hue derived from the title, so every title keeps
/// its own colour from one screen to the next.
///
/// There were five hand-rolled copies of this (detail hero, browse
/// spotlight, episode stills, Home, Calendar), each with its own lightness
/// stops — one of them computed `hue + 30 % 360`, which is `hue + 30`, and
/// handed HSL a hue past 360.
class HueBackdrop extends StatelessWidget {
  const HueBackdrop({
    super.key,
    required this.hue,
    this.dark = false,
    this.icon,
    this.iconSize = 40,
    this.borderRadius,
  });

  final double hue;

  /// Darker stops, for a page-wide backdrop that text sits on. The default
  /// is the brighter poster/thumbnail stand-in.
  final bool dark;

  /// Optional centred glyph — a film or TV icon on a missing poster.
  final IconData? icon;
  final double iconSize;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final h = hue % 360;
    final second = (h + 30) % 360;
    final colors = dark
        ? [
            HSLColor.fromAHSL(1, h, 0.5, 0.2).toColor(),
            HSLColor.fromAHSL(1, second, 0.5, 0.08).toColor(),
          ]
        : [
            HSLColor.fromAHSL(1, h, 0.6, 0.38).toColor(),
            HSLColor.fromAHSL(1, second, 0.55, 0.18).toColor(),
          ];
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: icon == null
          ? null
          : Center(
              child: Icon(
                icon,
                size: iconSize,
                color: AppColors.onMedia.withAlpha(AppOpacity.semi),
              ),
            ),
    );
  }
}
