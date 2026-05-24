import 'package:flutter/material.dart';

/// Cinematic editorial palette — warm near-black + single cinema-leader
/// orange accent. Replaces the previous indigo/violet "Stremio-clone"
/// palette. Sourced from the MediaHub redesign brief:
///
///   --bg: oklch(0.135 0.005 60)
///   --accent: oklch(0.72 0.18 38)
///   --ok: oklch(0.78 0.16 145)
///
/// OKLCH values converted to sRGB and stored here as flat constants.
abstract final class AppColors {
  // ==========================================================================
  // Backgrounds — warm near-black with subtle warm cast
  // ==========================================================================
  /// Page background — deepest surface (window body)
  static const Color bgPage = Color(0xFF0A0806);

  /// Alternate page surface (sidebar, drawer chrome)
  static const Color bgPageAlt = Color(0xFF080706);

  /// Elevated surface (buttons, inputs, pills)
  static const Color bgSurface = Color(0xFF100E0C);

  /// Higher-elevation surface (cards, panels, hover state)
  static const Color bgSurfaceHi = Color(0xFF191714);

  /// Highest-elevation surface (modal background, selected row)
  static const Color bgSurfaceHigher = Color(0xFF272321);

  // ==========================================================================
  // Foregrounds — warm off-white scale
  // ==========================================================================
  /// Primary text — warm off-white
  static const Color fg = Color(0xFFF6F1E9);

  /// Secondary text
  static const Color fg1 = Color(0xFFC9C3BC);

  /// Tertiary text (subtitles, captions)
  static const Color fg2 = Color(0xFF857F79);

  /// Muted text (timestamps, hashes, deemphasized labels)
  static const Color fg3 = Color(0xFF514C47);

  // ==========================================================================
  // Hairline rules — almost invisible by design
  // ==========================================================================
  /// 6% white — section dividers, row separators
  static const Color line = Color(0x0FFFFFFF);

  /// 12% white — stronger borders (modals, key surfaces)
  static const Color lineStrong = Color(0x1FFFFFFF);

  // ==========================================================================
  // Accent — cinema-leader orange. The ONE color that means something.
  // ==========================================================================
  /// Primary accent — active state, primary CTA, current row indicator
  static const Color accent = Color(0xFFFF7448);

  /// Hover/pressed variant
  static const Color accentHi = Color(0xFFFF885C);

  /// 16% accent — soft fill (selected chip, badge background)
  static const Color accentSoft = Color(0x29FF7448);

  /// 8% accent — ghost fill (subtle highlight)
  static const Color accentGhost = Color(0x14FF7448);

  // ==========================================================================
  // Status — restrained. Use sparingly.
  // ==========================================================================
  /// Ready / seeding / downloaded
  static const Color ok = Color(0xFF6ED274);

  /// 14% ok — soft fill
  static const Color okSoft = Color(0x246ED274);

  /// Queued / checking / warning
  static const Color warn = Color(0xFFF3B94C);

  /// Error / missing
  static const Color err = Color(0xFFFF5F5B);

  // ==========================================================================
  // Glass overlays — used by floating chrome stacked over hero artwork
  // (back / favorite / watchlist buttons on details, etc.). Constants
  // rather than `Colors.white.withAlpha(N)` literals so call sites stay
  // `const`-correct.
  // ==========================================================================
  /// 8% white — base glass fill
  static const Color glassFill = Color(0x14FFFFFF);

  /// 11% white — slightly stronger glass fill (hover state)
  static const Color glassFillStrong = Color(0x1CFFFFFF);

  /// 15% white — glass border / emphasis stroke
  static const Color glassBorder = Color(0x26FFFFFF);

  /// 30% black — soft scrim over imagery (gradient top)
  static const Color scrimSoft = Color(0x50000000);

  /// 60% black — stronger scrim over imagery (gradient bottom / text)
  static const Color scrimStrong = Color(0xA0000000);

  // ==========================================================================
  // Legacy aliases — kept for call sites that haven't migrated yet. Each
  // alias has confirmed external references; the dead 45+ siblings of
  // these were removed in the editorial consolidation. See git log for
  // the full deletion list.
  // ==========================================================================
  static const Color seedColor = accent;
  static const Color accentPrimary = accent;

  /// Warm amber attention accent — distinct from the primary orange
  /// and the green ok. Used for decorative gradients and "draw the eye"
  /// callouts (drawer header gradient, AUTO-GRAB button, calendar week
  /// chip).
  static const Color accentAmber = warn;

  static const Color success = ok;
  static const Color warning = warn;
  static const Color error = err;
  static const Color info = accent;

  static const Color downloading = accent;
  static const Color seeding = ok;
  static const Color paused = fg3;
  static const Color errorState = err;

  // Used by `getRatingColor`. Rating thresholds are quality-of-source
  // signals, not status semantics — keep them mapped to the palette.
  static const Color ratingExcellent = ok;
  static const Color ratingGood = accent;
  static const Color ratingFair = warn;
  static const Color ratingPoor = err;

  // Gradient preset — used by `empty_state.dart` for the error
  // illustration backdrop.
  static const List<Color> gradientError = [err, err];
}

/// Extension to get torrent state colors — restrained editorial mapping.
extension TorrentStateColor on String {
  Color get torrentStateColor {
    switch (toLowerCase()) {
      case 'downloading':
      case 'dl':
      case 'forceddl':
        return AppColors.downloading;
      case 'uploading':
      case 'seeding':
      case 'stalledup':
      case 'forcedup':
        return AppColors.seeding;
      case 'pauseddl':
      case 'pausedup':
      case 'stoppeddl':
      case 'stoppedup':
      case 'paused':
        return AppColors.paused;
      case 'queueddl':
      case 'queuedup':
      case 'queued':
        return AppColors.warn;
      case 'checkingdl':
      case 'checkingup':
      case 'checkingresumedata':
      case 'checking':
        return AppColors.warn;
      case 'error':
      case 'missingfiles':
        return AppColors.errorState;
      default:
        return AppColors.paused;
    }
  }
}

/// Extension to get quality badge colors — all neutral mono tags in the
/// editorial design, with 4K reserved for the accent treatment.
extension QualityColor on String {
  Color get qualityColor {
    final lower = toLowerCase();
    if (lower.contains('2160') ||
        lower.contains('4k') ||
        lower.contains('uhd')) {
      return AppColors.accent;
    } else if (lower.contains('1080')) {
      return AppColors.fg1;
    } else if (lower.contains('720')) {
      return AppColors.fg2;
    } else {
      return AppColors.fg3;
    }
  }
}

Color getRatingColor(double rating) {
  if (rating >= 8.0) return AppColors.ratingExcellent;
  if (rating >= 6.0) return AppColors.ratingGood;
  if (rating >= 4.0) return AppColors.ratingFair;
  return AppColors.ratingPoor;
}
