import '../utils/constants.dart';

/// Represents a torrent in qBittorrent
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
      pieceSize: json['piece_size'] as int? ?? 0,
      piecesNum: json['pieces_num'] as int? ?? 0,
      piecesHave: json['pieces_have'] as int? ?? 0,
      contentPath: json['content_path'] as String? ?? '',
      sequentialDownload: json['seq_dl'] as bool? ?? false,
      firstLastPiecePriority: json['f_l_piece_prio'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'hash': hash,
      'name': name,
      'size': size,
      'progress': progress,
      'dlspeed': dlspeed,
      'upspeed': upspeed,
      'eta': eta,
      'state': state,
      'num_seeds': numSeeds,
      'num_leechs': numLeeches,
      'ratio': ratio,
      'added_on': addedOn,
      'completion_on': completionOn,
      'save_path': savePath,
      'downloaded': downloaded,
      'uploaded': uploaded,
      'num_complete': numComplete,
      'num_incomplete': numIncomplete,
      'category': category,
      'tags': tags,
      'priority': priority,
      'amount_left': amountLeft,
      'tracker': tracker,
      'seen_complete': seenComplete,
      'last_activity': lastActivity,
      'total_size': totalSize,
      'piece_size': pieceSize,
      'pieces_num': piecesNum,
      'pieces_have': piecesHave,
      'content_path': contentPath,
      'seq_dl': sequentialDownload,
      'f_l_piece_prio': firstLastPiecePriority,
    };
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

  /// Returns true if streaming mode is enabled (sequential + first/last piece priority)
  bool get isStreamingMode => sequentialDownload && firstLastPiecePriority;

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

  Torrent copyWith({
    String? hash,
    String? name,
    int? size,
    double? progress,
    int? dlspeed,
    int? upspeed,
    int? eta,
    String? state,
    int? numSeeds,
    int? numLeeches,
    double? ratio,
    int? addedOn,
    int? completionOn,
    String? savePath,
    int? downloaded,
    int? uploaded,
    int? numComplete,
    int? numIncomplete,
    String? category,
    String? tags,
    int? priority,
    int? amountLeft,
    String? tracker,
    int? seenComplete,
    int? lastActivity,
    int? totalSize,
    int? pieceSize,
    int? piecesNum,
    int? piecesHave,
    String? contentPath,
    bool? sequentialDownload,
    bool? firstLastPiecePriority,
  }) {
    return Torrent(
      hash: hash ?? this.hash,
      name: name ?? this.name,
      size: size ?? this.size,
      progress: progress ?? this.progress,
      dlspeed: dlspeed ?? this.dlspeed,
      upspeed: upspeed ?? this.upspeed,
      eta: eta ?? this.eta,
      state: state ?? this.state,
      numSeeds: numSeeds ?? this.numSeeds,
      numLeeches: numLeeches ?? this.numLeeches,
      ratio: ratio ?? this.ratio,
      addedOn: addedOn ?? this.addedOn,
      completionOn: completionOn ?? this.completionOn,
      savePath: savePath ?? this.savePath,
      downloaded: downloaded ?? this.downloaded,
      uploaded: uploaded ?? this.uploaded,
      numComplete: numComplete ?? this.numComplete,
      numIncomplete: numIncomplete ?? this.numIncomplete,
      category: category ?? this.category,
      tags: tags ?? this.tags,
      priority: priority ?? this.priority,
      amountLeft: amountLeft ?? this.amountLeft,
      tracker: tracker ?? this.tracker,
      seenComplete: seenComplete ?? this.seenComplete,
      lastActivity: lastActivity ?? this.lastActivity,
      totalSize: totalSize ?? this.totalSize,
      pieceSize: pieceSize ?? this.pieceSize,
      piecesNum: piecesNum ?? this.piecesNum,
      piecesHave: piecesHave ?? this.piecesHave,
      contentPath: contentPath ?? this.contentPath,
      sequentialDownload: sequentialDownload ?? this.sequentialDownload,
      firstLastPiecePriority:
          firstLastPiecePriority ?? this.firstLastPiecePriority,
    );
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
      pieceSize: update['piece_size'] as int? ?? pieceSize,
      piecesNum: update['pieces_num'] as int? ?? piecesNum,
      piecesHave: update['pieces_have'] as int? ?? piecesHave,
      contentPath: update['content_path'] as String? ?? contentPath,
      sequentialDownload: update['seq_dl'] as bool? ?? sequentialDownload,
      firstLastPiecePriority:
          update['f_l_piece_prio'] as bool? ?? firstLastPiecePriority,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Torrent &&
          runtimeType == other.runtimeType &&
          hash == other.hash;

  @override
  int get hashCode => hash.hashCode;
}
