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
  // Legacy aliases — keep existing call sites compiling while we migrate.
  // These all resolve to the new editorial palette so the visual identity
  // is consistent even where code hasn't been updated yet.
  // ==========================================================================
  static const Color seedColor = accent;
  static const Color accentPrimary = accent;
  static const Color accentSecondary = ok;
  static const Color accentTertiary = warn;
  static const Color seedDeep = accent;
  static const Color accentPrimaryDeep = accentHi;
  static const Color accentTertiaryDeep = warn;

  /// Status colors — torrent states map to the restrained palette.
  static const Color success = ok;
  static const Color successLight = okSoft;
  static const Color successDark = ok;

  static const Color warning = warn;
  static const Color warningLight = Color(0x24F3B94C);
  static const Color warningDark = warn;

  static const Color error = err;
  static const Color errorLight = Color(0x29FF5F5B);
  static const Color errorDark = err;

  static const Color info = accent;
  static const Color infoLight = accentSoft;
  static const Color infoDark = accentHi;

  // Torrent states — downloading = accent, seeding = ok, paused = muted,
  // queued = warn, checking = warn, error = err.
  static const Color downloading = accent;
  static const Color downloadingLight = accentSoft;
  static const Color downloadingDark = accentHi;

  static const Color seeding = ok;
  static const Color seedingLight = okSoft;
  static const Color seedingDark = ok;

  static const Color paused = fg3;
  static const Color pausedLight = bgSurfaceHi;
  static const Color pausedDark = fg2;

  static const Color queued = warn;
  static const Color queuedLight = Color(0x24F3B94C);
  static const Color queuedDark = warn;

  static const Color checking = warn;
  static const Color checkingLight = Color(0x24F3B94C);
  static const Color checkingDark = warn;

  static const Color errorState = err;
  static const Color errorStateLight = Color(0x29FF5F5B);
  static const Color errorStateDark = err;

  // Quality badges — in the editorial design these are all neutral mono
  // tags; 4K gets the accent treatment when emphasized. Light variants
  // map to subtle surface tints so the legacy code still renders.
  static const Color quality4K = accent;
  static const Color quality4KLight = accentSoft;
  static const Color quality1080p = fg1;
  static const Color quality1080pLight = bgSurfaceHi;
  static const Color quality720p = fg2;
  static const Color quality720pLight = bgSurface;
  static const Color qualitySD = fg3;
  static const Color qualitySDLight = bgSurface;

  // Health/signal indicators
  static const Color healthGood = ok;
  static const Color healthMedium = warn;
  static const Color healthPoor = err;

  // Rating colors — use accent for highlights, muted for everything else.
  static const Color ratingExcellent = ok;
  static const Color ratingGood = accent;
  static const Color ratingFair = warn;
  static const Color ratingPoor = err;

  // Connection status
  static const Color connected = ok;
  static const Color connecting = warn;
  static const Color disconnected = err;

  // Surface aliases
  static const Color surfaceLight = Color(0xFFFAFAFA);
  static const Color surfaceMedium = Color(0xFFF4F4F5);
  static const Color surfaceDark = bgSurface;
  static const Color surfaceDarkElevated = bgSurfaceHi;

  // Gradient presets — kept for legacy hero/CTA call sites.
  // The editorial design uses a single accent + restraint; these
  // resolve to subtle accent-to-foreground washes instead of the
  // previous indigo→pink candy gradient.
  static const List<Color> gradientPrimary = [accent, accentHi];
  static const List<Color> gradientSuccess = [ok, ok];
  static const List<Color> gradientWarning = [warn, accent];
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
        return AppColors.queued;
      case 'checkingdl':
      case 'checkingup':
      case 'checkingresumedata':
      case 'checking':
        return AppColors.checking;
      case 'error':
      case 'missingfiles':
        return AppColors.errorState;
      default:
        return AppColors.paused;
    }
  }

  Color get torrentStateLightColor {
    switch (toLowerCase()) {
      case 'downloading':
      case 'dl':
      case 'forceddl':
        return AppColors.downloadingLight;
      case 'uploading':
      case 'seeding':
      case 'stalledup':
      case 'forcedup':
        return AppColors.seedingLight;
      case 'pauseddl':
      case 'pausedup':
      case 'stoppeddl':
      case 'stoppedup':
      case 'paused':
        return AppColors.pausedLight;
      case 'queueddl':
      case 'queuedup':
      case 'queued':
        return AppColors.queuedLight;
      case 'checkingdl':
      case 'checkingup':
      case 'checkingresumedata':
      case 'checking':
        return AppColors.checkingLight;
      case 'error':
      case 'missingfiles':
        return AppColors.errorStateLight;
      default:
        return AppColors.pausedLight;
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
      return AppColors.quality4K;
    } else if (lower.contains('1080')) {
      return AppColors.quality1080p;
    } else if (lower.contains('720')) {
      return AppColors.quality720p;
    } else {
      return AppColors.qualitySD;
    }
  }

  Color get qualityLightColor {
    final lower = toLowerCase();
    if (lower.contains('2160') ||
        lower.contains('4k') ||
        lower.contains('uhd')) {
      return AppColors.quality4KLight;
    } else if (lower.contains('1080')) {
      return AppColors.quality1080pLight;
    } else if (lower.contains('720')) {
      return AppColors.quality720pLight;
    } else {
      return AppColors.qualitySDLight;
    }
  }
}

Color getRatingColor(double rating) {
  if (rating >= 8.0) return AppColors.ratingExcellent;
  if (rating >= 6.0) return AppColors.ratingGood;
  if (rating >= 4.0) return AppColors.ratingFair;
  return AppColors.ratingPoor;
}

Color getHealthColor(int seeds) {
  if (seeds >= 10) return AppColors.healthGood;
  if (seeds >= 3) return AppColors.healthMedium;
  return AppColors.healthPoor;
}
