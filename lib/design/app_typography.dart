import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

/// Editorial typography system — three families with clear roles.
///
/// - **Instrument Serif** (italic) for display moments: section
///   headlines, hero titles, episode numbers, screen titles. The
///   single emotional / editorial voice in the UI.
/// - **Geist** for everything UI: button labels, body copy, paragraph
///   text. Clean, neutral, modern sans.
/// - **JetBrains Mono** for technical truth: speeds, hashes, codecs,
///   file paths, timestamps, percentages, peer/seed counts. Anything
///   that is a *fact*, not a *label*.
///
/// Use the [AppType] helpers below — they wrap Google Fonts so callers
/// don't need to import the package directly.
abstract final class AppType {
  /// Serif italic display style — Instrument Serif. Use for hero titles,
  /// section headers, screen titles, anywhere you want the editorial voice.
  static TextStyle serif({
    double size = 24,
    Color color = AppColors.fg,
    double height = 1.05,
    double letterSpacing = -0.01,
    FontStyle fontStyle = FontStyle.italic,
    FontWeight fontWeight = FontWeight.w400,
  }) {
    return GoogleFonts.instrumentSerif(
      fontSize: size,
      color: color,
      fontStyle: fontStyle,
      fontWeight: fontWeight,
      height: height,
      letterSpacing: letterSpacing * size,
    );
  }

  /// UI sans style — Geist. The default voice for buttons, body copy,
  /// list rows, etc.
  static TextStyle ui({
    double size = 13,
    Color color = AppColors.fg,
    FontWeight weight = FontWeight.w400,
    double height = 1.4,
    double letterSpacing = 0,
  }) {
    return GoogleFonts.geist(
      fontSize: size,
      color: color,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  /// Mono style — JetBrains Mono. Use for technical data: speeds,
  /// hashes, codecs, paths, percentages, peer counts, timestamps.
  /// Also used for tiny uppercase "labels" (10px tracked-out tags).
  static TextStyle mono({
    double size = 11,
    Color color = AppColors.fg1,
    FontWeight weight = FontWeight.w400,
    double height = 1.3,
    double letterSpacing = 0.06,
  }) {
    return GoogleFonts.jetBrainsMono(
      fontSize: size,
      color: color,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing * size,
    );
  }

  /// Small uppercase tracked-out mono label — 10px, 0.14em, muted.
  /// Used for section subtitles, table headers, badge text, breadcrumbs.
  static TextStyle monoLabel({
    Color color = AppColors.fg3,
    double size = 10,
    double letterSpacing = 0.14,
  }) {
    return GoogleFonts.jetBrainsMono(
      fontSize: size,
      color: color,
      fontWeight: FontWeight.w400,
      height: 1.2,
      letterSpacing: letterSpacing * size,
    );
  }
}
