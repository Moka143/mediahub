import 'package:flutter/material.dart';

/// Modern semantic color palette for the app
/// These colors are used for status indicators, badges, and semantic meanings
abstract final class AppColors {
  // ==========================================================================
  // Primary brand color - Modern deep indigo/violet
  // ==========================================================================
  static const Color seedColor = Color(0xFF6366F1); // Indigo 500

  // Accent colors for gradients and highlights
  static const Color accentPrimary = Color(0xFF8B5CF6); // Violet
  static const Color accentSecondary = Color(0xFF06B6D4); // Cyan
  static const Color accentTertiary = Color(0xFFF472B6); // Pink

  // ==========================================================================
  // Status colors (semantic) - Modern, vibrant
  // ==========================================================================
  static const Color success = Color(0xFF10B981); // Emerald
  static const Color successLight = Color(0xFFD1FAE5);
  static const Color successDark = Color(0xFF059669);

  static const Color warning = Color(0xFFF59E0B); // Amber
  static const Color warningLight = Color(0xFFFEF3C7);
  static const Color warningDark = Color(0xFFD97706);

  static const Color error = Color(0xFFEF4444); // Red
  static const Color errorLight = Color(0xFFFEE2E2);
  static const Color errorDark = Color(0xFFDC2626);

  static const Color info = Color(0xFF3B82F6); // Blue
  static const Color infoLight = Color(0xFFDBEAFE);
  static const Color infoDark = Color(0xFF2563EB);

  // ==========================================================================
  // Torrent state colors - Modern gradient-friendly
  // ==========================================================================
  static const Color downloading = Color(0xFF3B82F6); // Blue 500
  static const Color downloadingLight = Color(0xFFDBEAFE);
  static const Color downloadingDark = Color(0xFF1D4ED8);

  static const Color seeding = Color(0xFF10B981); // Emerald 500
  static const Color seedingLight = Color(0xFFD1FAE5);
  static const Color seedingDark = Color(0xFF059669);

  static const Color paused = Color(0xFF6B7280); // Gray 500
  static const Color pausedLight = Color(0xFFF3F4F6);
  static const Color pausedDark = Color(0xFF4B5563);

  static const Color queued = Color(0xFFF59E0B); // Amber 500
  static const Color queuedLight = Color(0xFFFEF3C7);
  static const Color queuedDark = Color(0xFFD97706);

  static const Color checking = Color(0xFF8B5CF6); // Violet 500
  static const Color checkingLight = Color(0xFFEDE9FE);
  static const Color checkingDark = Color(0xFF7C3AED);

  static const Color errorState = Color(0xFFEF4444); // Red 500
  static const Color errorStateLight = Color(0xFFFEE2E2);
  static const Color errorStateDark = Color(0xFFDC2626);

  // ==========================================================================
  // Quality badge colors - Modern with gradients
  // ==========================================================================
  static const Color quality4K = Color(0xFF8B5CF6); // Violet
  static const Color quality4KLight = Color(0xFFEDE9FE);
  static const Color quality1080p = Color(0xFF3B82F6); // Blue
  static const Color quality1080pLight = Color(0xFFDBEAFE);
  static const Color quality720p = Color(0xFF10B981); // Emerald
  static const Color quality720pLight = Color(0xFFD1FAE5);
  static const Color qualitySD = Color(0xFF6B7280); // Gray
  static const Color qualitySDLight = Color(0xFFF3F4F6);

  // ==========================================================================
  // Health/signal indicator colors
  // ==========================================================================
  static const Color healthGood = Color(0xFF10B981);
  static const Color healthMedium = Color(0xFFF59E0B);
  static const Color healthPoor = Color(0xFFEF4444);

  // ==========================================================================
  // Rating colors - Gold/star themed
  // ==========================================================================
  static const Color ratingExcellent = Color(0xFF10B981); // 8+
  static const Color ratingGood = Color(0xFFFBBF24); // 6-8 (Amber 400)
  static const Color ratingFair = Color(0xFFF59E0B); // 4-6
  static const Color ratingPoor = Color(0xFFEF4444); // <4

  // ==========================================================================
  // Connection status colors
  // ==========================================================================
  static const Color connected = Color(0xFF10B981);
  static const Color connecting = Color(0xFFF59E0B);
  static const Color disconnected = Color(0xFFEF4444);

  // ==========================================================================
  // Surface colors for cards and containers
  // ==========================================================================
  static const Color surfaceLight = Color(0xFFFAFAFA);
  static const Color surfaceMedium = Color(0xFFF4F4F5);
  static const Color surfaceDark = Color(0xFF18181B);
  static const Color surfaceDarkElevated = Color(0xFF27272A);

  // ==========================================================================
  // Gradient presets
  // ==========================================================================
  static const List<Color> gradientPrimary = [
    Color(0xFF6366F1),
    Color(0xFF8B5CF6),
  ];

  static const List<Color> gradientSuccess = [
    Color(0xFF10B981),
    Color(0xFF06B6D4),
  ];

  static const List<Color> gradientWarning = [
    Color(0xFFF59E0B),
    Color(0xFFF97316),
  ];

  static const List<Color> gradientError = [
    Color(0xFFEF4444),
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
