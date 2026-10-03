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
    double size = sizeTitle,
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
    double size = sizeBody,
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
    double size = sizeSmall,
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

  // ==========================================================================
  // Size ramp
  //
  // Every text size the UI uses. The named styles below cover the common
  // roles; a call site that needs a different family, weight or height
  // passes one of these to [ui], [mono] or [serif] — never a raw number — so
  // this stays the one list of sizes in use. Display type above
  // [sizeDisplay] (wordmarks, hero titles) is drawn for one place, and is a
  // named constant there.
  // ==========================================================================

  /// The smallest text size the app uses.
  static const double minSize = 10;

  /// 10 — tracked mono kickers and tags.
  static const double sizeLabel = minSize;

  /// 11 — dense metadata: mono figures, chips, table cells.
  static const double sizeSmall = 11;

  /// 12 — captions and helper text.
  static const double sizeCaption = 12;

  /// 13 — body copy, list rows, buttons.
  static const double sizeBody = 13;

  /// 14 — dialog text and prominent rows.
  static const double sizeLead = 14;

  /// 16 — sub-headings and emphasised figures.
  static const double sizeSubhead = 16;

  /// 18 — card and panel headings.
  static const double sizeHeading = 18;

  /// 24 — section, drawer and dialog titles.
  static const double sizeTitle = 24;

  /// 28 — the screen's name in the top bar.
  static const double sizePageTitle = 28;

  /// 32 — large display figures.
  static const double sizeHeadline = 32;

  /// 40 — hero and first-run moments.
  static const double sizeDisplay = 40;

  // ==========================================================================
  // Named type scale
  //
  // Fixed sizes for the roles the UI keeps repeating, so a screen asks for
  // "a caption" instead of picking one of nine raw sizes (8 to 36 were all in
  // use). Nothing is smaller than [minSize]: the 8–9px labels this replaces
  // shrank further under UiScale and stopped being readable. Colours default
  // to the dimmest token that still passes contrast for that role.
  // ==========================================================================

  /// Hero and first-run moments — serif italic, 40px.
  static TextStyle display({Color color = AppColors.fg}) =>
      serif(size: sizeDisplay, color: color, height: 1.0, letterSpacing: -0.02);

  /// Section, drawer and dialog titles — serif italic, 24px.
  static TextStyle title({Color color = AppColors.fg}) =>
      serif(size: sizeTitle, color: color, height: 1.05);

  /// Row and card headings — sans, 13px semibold.
  static TextStyle bodyStrong({Color color = AppColors.fg}) =>
      ui(size: sizeBody, color: color, weight: FontWeight.w600, height: 1.35);

  /// Running text — sans, 13px.
  static TextStyle body({Color color = AppColors.fg1}) =>
      ui(size: sizeBody, color: color, height: 1.5);

  /// Secondary lines, helper text, metadata — sans, 12px.
  static TextStyle caption({Color color = AppColors.fg2}) =>
      ui(size: sizeCaption, color: color, height: 1.4);

  /// Tracked-out mono kicker for section labels and tags — 10px. Callers
  /// upper-case the text themselves (`MonoLabel` does).
  static TextStyle label({Color color = AppColors.fg2}) =>
      mono(size: sizeLabel, color: color, height: 1.2, letterSpacing: 0.14);
}
