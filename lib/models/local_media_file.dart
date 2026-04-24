import 'dart:io';

import 'watch_progress.dart';

/// Video file extensions supported
const videoExtensions = [
  'mp4',
  'mkv',
  'avi',
  'mov',
  'wmv',
  'flv',
  'webm',
  'm4v',
  'mpg',
  'mpeg',
  'ts',
  '3gp',
];

/// Represents a local media file scanned from the download folder
class LocalMediaFile {
  final String path; // Full file path
  final String fileName; // File name only
  final int sizeBytes; // File size
  final DateTime modifiedDate; // Last modified
  final String? showName; // Parsed show name
  final int? seasonNumber; // Parsed from filename
  final int? episodeNumber; // Parsed from filename
  final String? quality; // "720p", "1080p", "4K"
  final String extension; // "mkv", "mp4", etc.
  final int? showId; // Matched TMDB show ID (nullable)
  final String? posterPath; // Show poster path
  final WatchProgress? progress; // Watch progress (nullable)

  LocalMediaFile({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    required this.modifiedDate,
    this.showName,
    this.seasonNumber,
    this.episodeNumber,
    this.quality,
    required this.extension,
    this.showId,
    this.posterPath,
    this.progress,
  });

  /// Check if this file is a video
  bool get isVideo => videoExtensions.contains(extension.toLowerCase());

  /// Get episode code (S01E05 format)
  String? get episodeCode {
    if (seasonNumber == null || episodeNumber == null) return null;
    final s = seasonNumber.toString().padLeft(2, '0');
    final e = episodeNumber.toString().padLeft(2, '0');
    return 'S${s}E$e';
  }

  /// Get formatted file size
  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Get display title
  String get displayTitle {
    if (showName != null && episodeCode != null) {
      return '$showName $episodeCode';
    }
    return fileName;
  }

  /// Check if file has watch progress
  bool get hasProgress => progress != null && progress!.progress > 0;

  /// Check if file is completed (watched)
  bool get isWatched => progress?.isCompleted ?? false;

  /// Get watch progress value (0.0 - 1.0)
  double get watchProgress => progress?.progress ?? 0.0;

  /// Create from file system entity
  static Future<LocalMediaFile?> fromFile(File file) async {
    try {
      final stat = await file.stat();
      final fileName = file.path.split('/').last.split('\\').last;
      final ext = fileName.contains('.')
          ? fileName.split('.').last.toLowerCase()
          : '';

      if (!videoExtensions.contains(ext)) {
        return null;
      }

      final parsed = parseFileName(fileName);

      return LocalMediaFile(
        path: file.path,
        fileName: fileName,
        sizeBytes: stat.size,
        modifiedDate: stat.modified,
        showName: parsed['showName'],
        seasonNumber: parsed['season'],
        episodeNumber: parsed['episode'],
        quality: parsed['quality'],
        extension: ext,
      );
    } catch (e) {
      return null;
    }
  }

  /// Parse show name, season, episode, and quality from filename
  static Map<String, dynamic> parseFileName(String fileName) {
    String? showName;
    int? season;
    int? episode;
    String? quality;

    // Remove extension
    final nameWithoutExt = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;

    // Try S##E## pattern first (most common)
    final s01e01Pattern = RegExp(
      r'^(.+?)[.\s_-]+[Ss](\d{1,2})[Ee](\d{1,2})',
      caseSensitive: false,
    );

    // Try #x## pattern (alternative)
    final altPattern = RegExp(
      r'^(.+?)[.\s_-]+(\d{1,2})x(\d{1,2})',
      caseSensitive: false,
    );

    // Try Season # Episode # pattern
    final seasonEpPattern = RegExp(
      r'^(.+?)[.\s_-]+Season[.\s_-]*(\d{1,2})[.\s_-]*Episode[.\s_-]*(\d{1,2})',
      caseSensitive: false,
    );

    Match? match = s01e01Pattern.firstMatch(nameWithoutExt);
    if (match != null) {
      showName = _cleanShowName(match.group(1)!);
      season = int.tryParse(match.group(2)!);
      episode = int.tryParse(match.group(3)!);
    } else {
      match = altPattern.firstMatch(nameWithoutExt);
      if (match != null) {
        showName = _cleanShowName(match.group(1)!);
        season = int.tryParse(match.group(2)!);
        episode = int.tryParse(match.group(3)!);
      } else {
        match = seasonEpPattern.firstMatch(nameWithoutExt);
        if (match != null) {
          showName = _cleanShowName(match.group(1)!);
          season = int.tryParse(match.group(2)!);
          episode = int.tryParse(match.group(3)!);
        }
      }
    }

    // Extract quality
    final qualityPattern = RegExp(
      r'(2160p|4K|UHD|1080p|720p|480p|HDTV|WEB-DL|WEBRip|BluRay|BDRip)',
      caseSensitive: false,
    );
    final qualityMatch = qualityPattern.firstMatch(nameWithoutExt);
    if (qualityMatch != null) {
      quality = qualityMatch.group(1)!.toUpperCase();
      // Normalize quality
      if (quality == 'UHD' || quality == '4K') {
        quality = '2160p';
      }
    }

    return {
      'showName': showName,
      'season': season,
      'episode': episode,
      'quality': quality,
    };
  }

  /// Clean show name by replacing separators with spaces
  static String _cleanShowName(String name) {
    return name
        .replaceAll('.', ' ')
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  LocalMediaFile copyWith({
    String? path,
    String? fileName,
    int? sizeBytes,
    DateTime? modifiedDate,
    String? showName,
    int? seasonNumber,
    int? episodeNumber,
    String? quality,
    String? extension,
    int? showId,
    String? posterPath,
    WatchProgress? progress,
  }) {
    return LocalMediaFile(
      path: path ?? this.path,
      fileName: fileName ?? this.fileName,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      modifiedDate: modifiedDate ?? this.modifiedDate,
      showName: showName ?? this.showName,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      quality: quality ?? this.quality,
      extension: extension ?? this.extension,
      showId: showId ?? this.showId,
      posterPath: posterPath ?? this.posterPath,
      progress: progress ?? this.progress,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalMediaFile &&
          runtimeType == other.runtimeType &&
          path == other.path;

  @override
  int get hashCode => path.hashCode;
}
