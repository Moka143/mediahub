import '../utils/media_names.dart';
import '../utils/media_quality.dart';

/// Represents a stream from Torrentio addon
///
/// Key concepts from Stremio/Torrentio:
/// - `fileIdx`: When present, indicates this is a multi-file torrent
///   and this is the specific file index to play. When null, it's a single-file torrent.
/// - `filename`: The specific filename within a multi-file torrent (from behaviorHints)
///
/// IMPORTANT: A torrent with video + subtitle files will have fileIdx set, but
/// it's NOT a season pack. We detect true season packs by looking for pack
/// indicators in the title (Complete, Pack, S01, Season, etc. without episode number).
///
/// For streaming, single-file/single-episode torrents are preferred as they don't
/// require downloading an entire season pack just to play one episode.
class TorrentioStream {
  final String name;
  final String title;
  final String infoHash;
  final int? fileIdx;
  final String? filename;
  final List<String> sources;

  TorrentioStream({
    required this.name,
    required this.title,
    required this.infoHash,
    this.fileIdx,
    this.filename,
    this.sources = const [],
  });

  factory TorrentioStream.fromJson(Map<String, dynamic> json) {
    final behaviorHints = json['behaviorHints'] as Map<String, dynamic>?;

    return TorrentioStream(
      name: json['name'] as String? ?? '',
      title: json['title'] as String? ?? '',
      infoHash: json['infoHash'] as String? ?? '',
      fileIdx: json['fileIdx'] as int?,
      filename: behaviorHints?['filename'] as String?,
      sources:
          (json['sources'] as List<dynamic>?)
              ?.map((s) => s.toString())
              .toList() ??
          [],
    );
  }

  /// Whether this stream is from a single-file torrent (preferred for streaming)
  ///
  /// Single-file torrents have fileIdx = null because there's only one file.
  /// Season packs/collections have fileIdx set to specify which file to play.
  ///
  /// Based on Torrentio's logic: when fileIdx is an integer, it's a multi-file
  /// torrent where that specific file index should be played.
  bool get isSingleFile => fileIdx == null;

  /// Whether this stream is from a TRUE season pack (multiple episodes)
  ///
  /// A multi-file torrent (fileIdx != null) could be:
  /// 1. A true season pack (Complete Season, S01 Pack, etc.)
  /// 2. A single episode with extras (video + SRT, sample, nfo files)
  ///
  /// We detect true season packs by looking for pack indicators AND
  /// absence of specific episode markers in a way that suggests a pack.
  bool get isSeasonPack {
    if (fileIdx == null) return false; // Single file, not a pack

    // Check if this is a true season pack vs just a release with subtitles
    return _isTrueSeasonPack;
  }

  /// Whether this is a single episode release (even if multi-file with subs)
  ///
  /// A release with video + subtitles should be treated as a single episode,
  /// not penalized as a "season pack".
  bool get isSingleEpisodeRelease {
    if (fileIdx == null) return true; // True single file

    // Multi-file but NOT a season pack = single episode with extras (subs, etc.)
    return !_isTrueSeasonPack;
  }

  /// Words in a title or release name that only ever describe more than one
  /// episode.
  static const _packIndicators = [
    'complete',
    'season pack',
    'full season',
    's01-s', // S01-S02, etc.
    'seasons',
    'collection',
    'anthology',
    'boxset',
    'box set',
  ];

  /// A bare season token — `S01` with no episode after it.
  static final RegExp _seasonToken = RegExp(
    r'\bs\d{1,2}\b',
    caseSensitive: false,
  );

  /// Internal check for true season pack indicators.
  ///
  /// Computed once: the sort comparators that rank streams read it through
  /// [streamingScore] on every comparison, and this used to build three
  /// regexes each time.
  bool get _isTrueSeasonPack => _trueSeasonPack;

  late final bool _trueSeasonPack = () {
    final titleLower = title.toLowerCase();
    final releaseLower = releaseName.toLowerCase();

    // Check for pack indicators in title or release name
    if (_packIndicators.any(
      (indicator) =>
          titleLower.contains(indicator) || releaseLower.contains(indicator),
    )) {
      return true;
    }

    // A release named for a season with no episode in it (`Show.S01.1080p`)
    // whose selected file *does* name an episode is a pack with one file
    // picked out of it. Episode codes go through the shared parser, so a
    // three-digit episode is still an episode.
    if (parseEpisodeCode(releaseName) == null &&
        _seasonToken.hasMatch(releaseLower) &&
        parseEpisodeCode(filename ?? '') != null) {
      return true;
    }

    // Anything else with a fileIdx — most often one episode plus its
    // subtitles — is not a pack.
    return false;
  }();

  /// Get a streaming priority score (higher = better for streaming)
  ///
  /// This scoring system prioritizes:
  /// 1. Single-file torrents and single-episode releases (no pack download)
  /// 2. Higher quality
  /// 3. More seeders (faster download)
  ///
  /// A release with video + subtitles is treated the same as a pure single file,
  /// since we only need to download that specific content.
  ///
  /// Based on how Stremio handles stream selection.
  int get streamingScore {
    int score = 0;

    // Strongly prefer single-file OR single-episode releases for streaming
    // Both true single files and single episodes with subs get the bonus
    if (isSingleFile || isSingleEpisodeRelease) {
      score += 1000;
    } else if (isSeasonPack) {
      // True season packs get a penalty (but fileIdx makes them still usable)
      score -= 200;
    }

    // Quality bonus
    score += qualityPriority * 100;

    // Seeders bonus (capped to prevent dominating)
    score += (seeders.clamp(0, 500));

    // Size penalty for very large files (streaming efficiency)
    // Prefer smaller files when quality is similar
    if (sizeBytes > 0) {
      // Penalty for files over 4GB
      if (sizeBytes > 4 * 1024 * 1024 * 1024) {
        score -= 50;
      }
    }

    return score;
  }

  /// Release quality derived from the indexer's label (e.g. "Torrentio\n4k").
  ///
  /// See [MediaQuality]. The former private ladder had a `WEB-DL` rank its
  /// own parser could never produce, and disagreed with [EztvTorrent] on the
  /// order of the source tags.
  MediaQuality get mediaQuality => MediaQuality.fromText(name);

  /// Canonical quality label, e.g. `2160p`.
  String get quality => mediaQuality.label;

  /// Get quality priority for sorting (higher is better)
  int get qualityPriority => mediaQuality.rank;

  static final RegExp _seedersPattern = RegExp(r'👤\s*(\d+)');
  static final RegExp _sizeLabelPattern = RegExp(r'💾\s*([\d.]+\s*[KMGT]?B)');
  static final RegExp _sizePattern = RegExp(r'💾\s*([\d.]+)\s*([KMGT]?B)');

  /// Extract seeders count from title (e.g., "👤 212" -> 212). Parsed once;
  /// ranking reads it on every comparison.
  int get seeders => _seeders;

  late final int _seeders = () {
    final match = _seedersPattern.firstMatch(title);
    if (match != null) {
      return int.tryParse(match.group(1) ?? '0') ?? 0;
    }
    return 0;
  }();

  /// Extract size from title (e.g., "💾 1.45 GB" -> "1.45 GB")
  String get sizeFormatted {
    final match = _sizeLabelPattern.firstMatch(title);
    return match?.group(1) ?? 'Unknown';
  }

  /// Parse size to bytes. Parsed once, like [seeders].
  int get sizeBytes => _sizeBytes;

  late final int _sizeBytes = () {
    final match = _sizePattern.firstMatch(title);
    if (match == null) return 0;

    final value = double.tryParse(match.group(1) ?? '0') ?? 0;
    final unit = match.group(2) ?? 'B';

    switch (unit.toUpperCase()) {
      case 'TB':
        return (value * 1024 * 1024 * 1024 * 1024).round();
      case 'GB':
        return (value * 1024 * 1024 * 1024).round();
      case 'MB':
        return (value * 1024 * 1024).round();
      case 'KB':
        return (value * 1024).round();
      default:
        return value.round();
    }
  }();

  /// Extract source site from title (e.g., "⚙️ ThePirateBay")
  String get sourceSite {
    final match = RegExp(r'⚙️\s*(\w+)').firstMatch(title);
    return match?.group(1) ?? 'Unknown';
  }

  /// Get release name (first line of title)
  String get releaseName {
    return title.split('\n').first;
  }

  /// Generate magnet URI with trackers
  String get magnetUri {
    final trackers = sources
        .where((s) => s.startsWith('tracker:'))
        .map((s) => s.replaceFirst('tracker:', ''))
        .map((t) => '&tr=${Uri.encodeComponent(t)}')
        .join();

    final dn = filename != null ? '&dn=${Uri.encodeComponent(filename!)}' : '';

    return 'magnet:?xt=urn:btih:$infoHash$dn$trackers';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TorrentioStream && infoHash == other.infoHash;

  @override
  int get hashCode => infoHash.hashCode;

  @override
  String toString() =>
      'TorrentioStream(quality: $quality, seeders: $seeders, source: $sourceSite)';
}

/// Response wrapper for Torrentio API
class TorrentioResponse {
  final List<TorrentioStream> streams;

  TorrentioResponse({required this.streams});

  factory TorrentioResponse.fromJson(Map<String, dynamic> json) {
    return TorrentioResponse(
      streams:
          (json['streams'] as List<dynamic>?)
              ?.map((s) => TorrentioStream.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
