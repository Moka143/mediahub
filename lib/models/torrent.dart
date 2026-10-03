import '../utils/constants.dart';

/// A torrent as the engine reports it.
///
/// Field names follow qBittorrent's Web API, which the app was first written
/// against; `RqbitEngine.torrentFromJson` maps the built-in engine onto the
/// same shape.
class Torrent {
  final String hash;
  final String name;
  final int size;
  final double progress;
  final int dlspeed;
  final int upspeed;
  final int eta;
  final String state;
  final int numSeeds;
  final int numLeeches;
  final double ratio;
  final int addedOn;
  final int completionOn;
  final String savePath;
  final int downloaded;
  final int uploaded;
  final int numComplete;
  final int numIncomplete;
  final String category;
  final String tags;
  final int priority;
  final int amountLeft;
  final String tracker;
  final int seenComplete;
  final int lastActivity;
  final int totalSize;
  final int pieceSize;
  final int piecesNum;
  final int piecesHave;
  final String contentPath;
  final bool sequentialDownload;
  final bool firstLastPiecePriority;

  Torrent({
    required this.hash,
    required this.name,
    required this.size,
    required this.progress,
    required this.dlspeed,
    required this.upspeed,
    required this.eta,
    required this.state,
    required this.numSeeds,
    required this.numLeeches,
    required this.ratio,
    required this.addedOn,
    required this.completionOn,
    required this.savePath,
    required this.downloaded,
    required this.uploaded,
    required this.numComplete,
    required this.numIncomplete,
    required this.category,
    required this.tags,
    required this.priority,
    required this.amountLeft,
    required this.tracker,
    required this.seenComplete,
    required this.lastActivity,
    required this.totalSize,
    required this.pieceSize,
    required this.piecesNum,
    required this.piecesHave,
    required this.contentPath,
    required this.sequentialDownload,
    required this.firstLastPiecePriority,
  });

  factory Torrent.fromJson(Map<String, dynamic> json) {
    return Torrent(
      hash: json['hash'] as String? ?? '',
      name: json['name'] as String? ?? 'Unknown',
      size: json['size'] as int? ?? 0,
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      dlspeed: json['dlspeed'] as int? ?? 0,
      upspeed: json['upspeed'] as int? ?? 0,
      eta: json['eta'] as int? ?? 0,
      state: json['state'] as String? ?? TorrentState.unknown,
      numSeeds: json['num_seeds'] as int? ?? 0,
      numLeeches: json['num_leechs'] as int? ?? 0,
      ratio: (json['ratio'] as num?)?.toDouble() ?? 0.0,
      addedOn: json['added_on'] as int? ?? 0,
      completionOn: json['completion_on'] as int? ?? 0,
      savePath: json['save_path'] as String? ?? '',
      downloaded: json['downloaded'] as int? ?? 0,
      uploaded: json['uploaded'] as int? ?? 0,
      numComplete: json['num_complete'] as int? ?? 0,
      numIncomplete: json['num_incomplete'] as int? ?? 0,
      category: json['category'] as String? ?? '',
      tags: json['tags'] as String? ?? '',
      priority: json['priority'] as int? ?? 0,
      amountLeft: json['amount_left'] as int? ?? 0,
      tracker: json['tracker'] as String? ?? '',
      seenComplete: json['seen_complete'] as int? ?? 0,
      lastActivity: json['last_activity'] as int? ?? 0,
      totalSize: json['total_size'] as int? ?? 0,
      pieceSize: (json['piece_size'] as num?)?.toInt() ?? 0,
      piecesNum: json['pieces_num'] as int? ?? 0,
      piecesHave: json['pieces_have'] as int? ?? 0,
      contentPath: json['content_path'] as String? ?? '',
      sequentialDownload: json['seq_dl'] as bool? ?? false,
      firstLastPiecePriority: json['f_l_piece_prio'] as bool? ?? false,
    );
  }

  /// Returns true if torrent is currently downloading
  bool get isDownloading => TorrentState.isDownloading(state);

  /// Returns true if torrent is seeding
  bool get isSeeding => TorrentState.isSeeding(state);

  /// Returns true if torrent is paused
  bool get isPaused => TorrentState.isPaused(state);

  /// Returns true if torrent has completed downloading
  bool get isCompleted => TorrentState.isCompleted(state);

  /// Returns true if torrent has an error
  bool get hasError => TorrentState.hasError(state);

  /// Returns true if torrent is active (downloading or uploading)
  bool get isActive => dlspeed > 0 || upspeed > 0;

  /// Get a user-friendly status string
  String get statusText {
    switch (state) {
      case TorrentState.error:
        return 'Error';
      case TorrentState.missingFiles:
        return 'Missing Files';
      case TorrentState.uploading:
        return 'Seeding';
      case TorrentState.pausedUP:
      case TorrentState.stoppedUP:
        return 'Paused (Seeding)';
      case TorrentState.queuedUP:
        return 'Queued (Seeding)';
      case TorrentState.stalledUP:
        return 'Seeding (Stalled)';
      case TorrentState.checkingUP:
        return 'Checking';
      case TorrentState.forcedUP:
        return 'Forced Seeding';
      case TorrentState.allocating:
        return 'Allocating';
      case TorrentState.downloading:
        return 'Downloading';
      case TorrentState.metaDL:
        return 'Fetching Metadata';
      case TorrentState.pausedDL:
      case TorrentState.stoppedDL:
        return 'Paused';
      case TorrentState.queuedDL:
        return 'Queued';
      case TorrentState.stalledDL:
        return 'Stalled';
      case TorrentState.checkingDL:
        return 'Checking';
      case TorrentState.forcedDL:
        return 'Forced Download';
      case TorrentState.checkingResumeData:
        return 'Checking Resume Data';
      case TorrentState.moving:
        return 'Moving';
      default:
        return 'Unknown';
    }
  }

  /// Merge partial update data from sync endpoint into this torrent.
  /// Only updates fields that are present in the update map.
  Torrent mergeWith(Map<String, dynamic> update) {
    return Torrent(
      hash: hash, // hash doesn't change
      name: update['name'] as String? ?? name,
      size: update['size'] as int? ?? size,
      progress: (update['progress'] as num?)?.toDouble() ?? progress,
      dlspeed: update['dlspeed'] as int? ?? dlspeed,
      upspeed: update['upspeed'] as int? ?? upspeed,
      eta: update['eta'] as int? ?? eta,
      state: update['state'] as String? ?? state,
      numSeeds: update['num_seeds'] as int? ?? numSeeds,
      numLeeches: update['num_leechs'] as int? ?? numLeeches,
      ratio: (update['ratio'] as num?)?.toDouble() ?? ratio,
      addedOn: update['added_on'] as int? ?? addedOn,
      completionOn: update['completion_on'] as int? ?? completionOn,
      savePath: update['save_path'] as String? ?? savePath,
      downloaded: update['downloaded'] as int? ?? downloaded,
      uploaded: update['uploaded'] as int? ?? uploaded,
      numComplete: update['num_complete'] as int? ?? numComplete,
      numIncomplete: update['num_incomplete'] as int? ?? numIncomplete,
      category: update['category'] as String? ?? category,
      tags: update['tags'] as String? ?? tags,
      priority: update['priority'] as int? ?? priority,
      amountLeft: update['amount_left'] as int? ?? amountLeft,
      tracker: update['tracker'] as String? ?? tracker,
      seenComplete: update['seen_complete'] as int? ?? seenComplete,
      lastActivity: update['last_activity'] as int? ?? lastActivity,
      totalSize: update['total_size'] as int? ?? totalSize,
      pieceSize: (update['piece_size'] as num?)?.toInt() ?? pieceSize,
      piecesNum: update['pieces_num'] as int? ?? piecesNum,
      piecesHave: update['pieces_have'] as int? ?? piecesHave,
      contentPath: update['content_path'] as String? ?? contentPath,
      sequentialDownload: update['seq_dl'] as bool? ?? sequentialDownload,
      firstLastPiecePriority:
          update['f_l_piece_prio'] as bool? ?? firstLastPiecePriority,
    );
  }

  /// Value equality over every field, not just [hash].
  ///
  /// Identity-by-hash made two snapshots of the same torrent equal however
  /// much they differed, so anything that compared old and new values saw no
  /// change: a provider selecting one torrent out of the list never
  /// notified, and Torrent Details froze on whatever it showed when it was
  /// opened — progress, speeds and state included. Nothing keys a map or set
  /// by [Torrent]; where a stable identity is wanted, [hash] is the key.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Torrent &&
          other.hash == hash &&
          other.name == name &&
          other.size == size &&
          other.progress == progress &&
          other.dlspeed == dlspeed &&
          other.upspeed == upspeed &&
          other.eta == eta &&
          other.state == state &&
          other.numSeeds == numSeeds &&
          other.numLeeches == numLeeches &&
          other.ratio == ratio &&
          other.addedOn == addedOn &&
          other.completionOn == completionOn &&
          other.savePath == savePath &&
          other.downloaded == downloaded &&
          other.uploaded == uploaded &&
          other.numComplete == numComplete &&
          other.numIncomplete == numIncomplete &&
          other.category == category &&
          other.tags == tags &&
          other.priority == priority &&
          other.amountLeft == amountLeft &&
          other.tracker == tracker &&
          other.seenComplete == seenComplete &&
          other.lastActivity == lastActivity &&
          other.totalSize == totalSize &&
          other.pieceSize == pieceSize &&
          other.piecesNum == piecesNum &&
          other.piecesHave == piecesHave &&
          other.contentPath == contentPath &&
          other.sequentialDownload == sequentialDownload &&
          other.firstLastPiecePriority == firstLastPiecePriority;

  @override
  int get hashCode => Object.hashAll([
    hash,
    name,
    size,
    progress,
    dlspeed,
    upspeed,
    eta,
    state,
    numSeeds,
    numLeeches,
    ratio,
    addedOn,
    completionOn,
    savePath,
    downloaded,
    uploaded,
    numComplete,
    numIncomplete,
    category,
    tags,
    priority,
    amountLeft,
    tracker,
    seenComplete,
    lastActivity,
    totalSize,
    pieceSize,
    piecesNum,
    piecesHave,
    contentPath,
    sequentialDownload,
    firstLastPiecePriority,
  ]);
}
