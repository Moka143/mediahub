import 'dart:io';

import '../utils/formatters.dart';
import '../utils/media_quality.dart';
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

/// Smallest file the scanner will treat as real media.
///
/// Deliberately low — 1 MB is far below any watchable episode but comfortably
/// above the two things this exists to exclude: zero-byte placeholders (which
/// several public packs ship, and which qBittorrent also creates for files it
/// hasn't started) and tiny "sample" clips. The zero-byte case is the harmful
/// one: 0 of 0 bytes satisfies every percentage check as 100%, so such a file
/// looks complete to the library, to the completeness check, and to the
/// player — right up until mpv reports "Failed to recognize file format".
const int minPlayableBytes = 1024 * 1024;

/// Represents a local media file scanned from the download folder
class LocalMediaFile {
  final String path; // Full file path
  final String fileName; // File name only
  final int sizeBytes; // File size
  final DateTime modifiedDate; // Last modified
  final String? showName; // Parsed show name
  final int? seasonNumber; // Parsed from filename
  final int? episodeNumber; // Parsed from filename
  final String? quality; // canonical MediaQuality label, e.g. "1080p"
  final String extension; // "mkv", "mp4", etc.
  final int? showId; // Matched TMDB show ID (nullable)
  final String? posterPath; // Show poster path
  final WatchProgress? progress; // Watch progress (nullable)
  final String? torrentHash; // qBittorrent torrent hash if originating from one

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
    this.torrentHash,
  });

  /// Check if this file is a video
  bool get isVideo => videoExtensions.contains(extension.toLowerCase());

  /// Get episode code (S01E05 format)
  String? get episodeCode =>
      Formatters.episodeCodeOrNull(seasonNumber, episodeNumber);

  /// Get formatted file size
  String get formattedSize => Formatters.formatBytesCompact(sizeBytes);

  /// Get display title
  String get displayTitle {
    if (showName != null && episodeCode != null) {
      return '$showName $episodeCode';
    }
    return fileName;
  }

  /// Check if file has watch progress
  bool get hasProgress => progress != null && progress!.progress > 0;

  /// Check if file is completed (watched). 90%+ counts even when the
  /// persisted `isCompleted` flag never flipped.
  bool get isWatched => progress != null && progress!.isEffectivelyWatched;

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

      // Reject stubs. Torrents routinely carry zero-byte placeholder files
      // and tiny sample clips alongside the real episodes, and qBittorrent
      // creates a 0-byte entry for any file it hasn't started. A 0-byte .mkv
      // reports "100% complete" to every progress check (0 of 0 bytes is
      // 100%), so it passes as playable, reaches the library, and hands mpv
      // an empty file — which surfaces only as "Failed to recognize file
      // format" with a spinner and no explanation.
      if (stat.size < minPlayableBytes) {
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

    // Extract quality. Canonical labels via [MediaQuality] — this used to
    // uppercase whatever it matched, producing `1080P`, which then never
    // compared equal to the `1080p` the torrent indexers emit. That is what
    // made the per-show auto-download quality preference a no-op.
    final detected = MediaQuality.fromText(nameWithoutExt);
    if (detected != MediaQuality.unknown) {
      quality = detected.label;
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
    String? torrentHash,
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
      torrentHash: torrentHash ?? this.torrentHash,
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
