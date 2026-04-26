import 'package:flutter/material.dart';

/// MediaHub semantic color palette
/// Dark, cinematic, playful indigo/violet — Stremio-inspired
/// These colors are used for status indicators, badges, and semantic meanings
abstract final class AppColors {
  // ==========================================================================
  // Primary brand color - Indigo 400 (brighter for dark cinematic surfaces)
  // ==========================================================================
  static const Color seedColor = Color(0xFF818CF8); // Indigo 400

  // Accent colors for gradients and highlights
  static const Color accentPrimary = Color(0xFFA78BFA); // Violet 400
  static const Color accentSecondary = Color(0xFF22D3EE); // Cyan 400
  static const Color accentTertiary = Color(0xFFF472B6); // Pink 400

  // Deep variants used in gradients (e.g. brand logo, hero CTAs)
  static const Color seedDeep = Color(0xFF6366F1); // Indigo 500
  static const Color accentPrimaryDeep = Color(0xFF8B5CF6); // Violet 500
  static const Color accentTertiaryDeep = Color(0xFFEC4899); // Pink 500

  // ==========================================================================
  // MediaHub surface stack — deep cool-toned, slightly violet-tinted
  // ==========================================================================
  /// Page background — near-black with violet cast
  static const Color bgPage = Color(0xFF0A0A14);

  /// Alternate page surface (e.g. sidebar, drawer chrome)
  static const Color bgPageAlt = Color(0xFF0E0E1C);

  /// Elevated card surface
  static const Color bgSurface = Color(0xFF13131F);

  /// Higher-elevation surface (hover, selected, header strips)
  static const Color bgSurfaceHi = Color(0xFF1A1A2A);

  /// Highest-elevation surface (modals, dropdowns)
  static const Color bgSurfaceHigher = Color(0xFF22223A);

  // ==========================================================================
  // Status colors (semantic) - Modern, vibrant
  // ==========================================================================
  static const Color success = Color(0xFF34D399); // Emerald 400
  static const Color successLight = Color(0xFFD1FAE5);
  static const Color successDark = Color(0xFF10B981);

  static const Color warning = Color(0xFFFBBF24); // Amber 400
  static const Color warningLight = Color(0xFFFEF3C7);
  static const Color warningDark = Color(0xFFF59E0B);

  static const Color error = Color(0xFFFB7185); // Rose 400
  static const Color errorLight = Color(0xFFFEE2E2);
  static const Color errorDark = Color(0xFFEF4444);

  static const Color info = Color(0xFF818CF8); // Indigo 400
  static const Color infoLight = Color(0xFFDBEAFE);
  static const Color infoDark = Color(0xFF6366F1);

  // ==========================================================================
  // Torrent state colors - matching MediaHub palette
  // ==========================================================================
  static const Color downloading = Color(0xFF818CF8); // Indigo 400
  static const Color downloadingLight = Color(0xFFE0E7FF);
  static const Color downloadingDark = Color(0xFF6366F1);

  static const Color seeding = Color(0xFF34D399); // Emerald 400
  static const Color seedingLight = Color(0xFFD1FAE5);
  static const Color seedingDark = Color(0xFF10B981);

  static const Color paused = Color(0xFF7A7A92); // MediaHub tertiary text
  static const Color pausedLight = Color(0xFFF3F4F6);
  static const Color pausedDark = Color(0xFF54546A);

  static const Color queued = Color(0xFFFBBF24); // Amber 400
  static const Color queuedLight = Color(0xFFFEF3C7);
  static const Color queuedDark = Color(0xFFF59E0B);

  static const Color checking = Color(0xFFA78BFA); // Violet 400
  static const Color checkingLight = Color(0xFFEDE9FE);
  static const Color checkingDark = Color(0xFF8B5CF6);

  static const Color errorState = Color(0xFFFB7185); // Rose 400
  static const Color errorStateLight = Color(0xFFFEE2E2);
  static const Color errorStateDark = Color(0xFFEF4444);

  // ==========================================================================
  // Quality badge colors - MediaHub palette
  //   4K   → pink   1080p → indigo   720p → emerald   SD → gray
  // ==========================================================================
  static const Color quality4K = Color(0xFFF472B6); // Pink 400
  static const Color quality4KLight = Color(0xFFFCE7F3);
  static const Color quality1080p = Color(0xFF818CF8); // Indigo 400
  static const Color quality1080pLight = Color(0xFFE0E7FF);
  static const Color quality720p = Color(0xFF34D399); // Emerald 400
  static const Color quality720pLight = Color(0xFFD1FAE5);
  static const Color qualitySD = Color(0xFF7A7A92);
  static const Color qualitySDLight = Color(0xFFF3F4F6);

  // ==========================================================================
  // Health/signal indicator colors
  // ==========================================================================
  static const Color healthGood = Color(0xFF34D399);
  static const Color healthMedium = Color(0xFFFBBF24);
  static const Color healthPoor = Color(0xFFFB7185);

  // ==========================================================================
  // Rating colors - Gold/star themed
  // ==========================================================================
  static const Color ratingExcellent = Color(0xFF34D399); // 8+
  static const Color ratingGood = Color(0xFFFBBF24); // 6-8 (Amber 400)
  static const Color ratingFair = Color(0xFFF59E0B); // 4-6
  static const Color ratingPoor = Color(0xFFFB7185); // <4

  // ==========================================================================
  // Connection status colors
  // ==========================================================================
  static const Color connected = Color(0xFF34D399);
  static const Color connecting = Color(0xFFFBBF24);
  static const Color disconnected = Color(0xFFFB7185);

  // ==========================================================================
  // Surface colors for cards and containers
  // ==========================================================================
  static const Color surfaceLight = Color(0xFFFAFAFA);
  static const Color surfaceMedium = Color(0xFFF4F4F5);
  static const Color surfaceDark = bgSurface;
  static const Color surfaceDarkElevated = bgSurfaceHi;

  // ==========================================================================
  // Gradient presets — MediaHub brand uses an indigo→pink hero gradient
  // ==========================================================================
  static const List<Color> gradientPrimary = [
    Color(0xFF818CF8), // indigo 400
    Color(0xFFF472B6), // pink 400
  ];

  static const List<Color> gradientSuccess = [
    Color(0xFF34D399),
    Color(0xFF22D3EE),
  ];

  static const List<Color> gradientWarning = [
    Color(0xFFFBBF24),
    Color(0xFFF472B6),
  ];

  static const List<Color> gradientError = [
    Color(0xFFFB7185),
    Color(0xFFF472B6),
  ];
}

/// Extension to get torrent state colors
extension TorrentStateColor on String {
  /// Get the appropriate color for a torrent state
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

  /// Get the light variant of a torrent state color
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

/// Extension to get quality badge colors
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

/// Get rating color based on score
Color getRatingColor(double rating) {
  if (rating >= 8.0) return AppColors.ratingExcellent;
  if (rating >= 6.0) return AppColors.ratingGood;
  if (rating >= 4.0) return AppColors.ratingFair;
  return AppColors.ratingPoor;
}

/// Get health indicator color based on seed count
Color getHealthColor(int seeds) {
  if (seeds >= 10) return AppColors.healthGood;
  if (seeds >= 3) return AppColors.healthMedium;
  return AppColors.healthPoor;
}
