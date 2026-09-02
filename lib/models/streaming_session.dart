import 'local_media_file.dart';
import 'stream_request.dart';

/// Represents the state of a streaming session
enum StreamingState {
  /// Initial state before adding torrent
  idle,

  /// Torrent added, waiting for metadata
  addingTorrent,

  /// Metadata received, selecting files
  selectingFiles,

  /// Files selected, buffering initial pieces
  buffering,

  /// Ready to play - enough data buffered
  ready,

  /// Currently playing
  playing,

  /// Error occurred
  error,

  /// Session cancelled
  cancelled,
}

/// What to do about a session that hasn't reached its buffer threshold yet.
enum BufferOutcome {
  /// Enough bytes are down — start playing.
  ready,

  /// Progressing at a workable rate; keep waiting.
  waiting,

  /// No bytes arriving at all. A peer problem, not a speed problem.
  stalled,

  /// Moving, but so slowly that reaching the threshold isn't worth waiting
  /// for. Better to say so than to spin and fail later.
  tooSlow,

  /// [StreamingService.bufferHardCeiling] elapsed. Distinct from [tooSlow]
  /// because it is the one outcome `allowSlowBuffer` must NOT swallow — a
  /// background prefetch is allowed to be slow indefinitely by the rate
  /// checks, so without a deadline it polls qBittorrent forever.
  gaveUp,
}

/// Download-rate telemetry for one session's buffering phase.
///
/// Exists so [StreamingService.assessBuffering] can tell "slow but viable"
/// from "not happening" — a distinction a wall-clock deadline cannot make.
class BufferWatch {
  BufferWatch(this.startedAt) : lastProgressAt = startedAt;

  final DateTime startedAt;
  int lastBytes = 0;
  DateTime lastProgressAt;
  double bytesPerSecond = 0;

  /// Fold in a new observation. Rate is exponentially smoothed so one slow
  /// poll doesn't condemn a torrent and one fast poll doesn't rescue it.
  void observe(int bytes, DateTime now) {
    if (bytes <= lastBytes) return;
    final seconds = now.difference(lastProgressAt).inMilliseconds / 1000.0;
    if (seconds > 0) {
      final sample = (bytes - lastBytes) / seconds;
      bytesPerSecond = bytesPerSecond == 0
          ? sample
          : bytesPerSecond * 0.7 + sample * 0.3;
    }
    lastBytes = bytes;
    lastProgressAt = now;
  }
}

/// Represents a streaming session for a single video
class StreamingSession {
  final String id;

  /// What we were asked to stream, normalised away from whichever indexer
  /// produced it. See [StreamRequest].
  final StreamRequest request;

  final String? showImdbId;
  final String? showName;
  final String? movieImdbId;
  final int? season;
  final int? episode;
  final String? episodeCode;

  /// When this session was first created. Drives the [metadataTimeout] check
  /// in the monitoring loop and seeds the buffering rate window.
  ///
  /// **Must be threaded through [copyWith].** `_updateSession` copies the
  /// session on every 2 s poll tick as a heartbeat; if `copyWith` let the
  /// constructor default this back to `DateTime.now()`, session age would
  /// never exceed one poll interval and both timeouts would be dead code.
  final DateTime createdAt;

  StreamingState state;
  String? torrentHash;
  String? contentPath;
  String? selectedFilePath;
  int? selectedFileIndex;
  double bufferProgress;
  String? errorMessage;
  LocalMediaFile? videoFile;

  /// HTTP URL the player should open instead of [videoFile.path] while the
  /// torrent is still downloading. Populated once the local streaming proxy
  /// is up. Null when streaming isn't available (or once the file is
  /// fully downloaded and direct file playback is fine).
  String? streamUrl;

  /// Latest qBittorrent download rate for this torrent in bytes/second.
  /// Refreshed on every monitoring poll. Drives the "X MB/s" hint in the
  /// prep overlay so the user can tell whether the torrent has peers vs.
  /// is stuck waiting on metadata.
  int downloadRateBytesPerSec;

  /// When true, [assessBuffering] outcomes of `tooSlow` / `stalled` do
  /// **not** fail the session. Used for background next-episode prefetch:
  /// that torrent shares the pipe with the episode currently playing, so
  /// a 10-minute projected wait is expected — aborting would freeze the
  /// pill on "Too slow to stream" and never update again.
  final bool allowSlowBuffer;

  StreamingSession({
    required this.id,
    required this.request,
    this.showImdbId,
    this.showName,
    this.movieImdbId,
    this.season,
    this.episode,
    this.episodeCode,
    this.state = StreamingState.idle,
    this.torrentHash,
    this.contentPath,
    this.selectedFilePath,
    this.selectedFileIndex,
    this.bufferProgress = 0.0,
    this.errorMessage,
    this.videoFile,
    this.streamUrl,
    this.downloadRateBytesPerSec = 0,
    this.allowSlowBuffer = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isActive =>
      state != StreamingState.idle &&
      state != StreamingState.error &&
      state != StreamingState.cancelled;

  bool get isReady =>
      state == StreamingState.ready || state == StreamingState.playing;

  /// Deliberately NOT `??`-merged: an error belongs to one update, so every
  /// subsequent copy clears it. Pass it explicitly on any copy that must keep
  /// it — a `finally` that only flips a loading flag will otherwise wipe the
  /// `catch` above it.
  StreamingSession copyWith({
    StreamingState? state,
    String? torrentHash,
    String? contentPath,
    String? selectedFilePath,
    int? selectedFileIndex,
    double? bufferProgress,
    String? errorMessage,
    LocalMediaFile? videoFile,
    String? streamUrl,
    int? downloadRateBytesPerSec,
  }) {
    return StreamingSession(
      id: id,
      request: request,
      showImdbId: showImdbId,
      showName: showName,
      movieImdbId: movieImdbId,
      season: season,
      episode: episode,
      episodeCode: episodeCode,
      state: state ?? this.state,
      torrentHash: torrentHash ?? this.torrentHash,
      contentPath: contentPath ?? this.contentPath,
      selectedFilePath: selectedFilePath ?? this.selectedFilePath,
      selectedFileIndex: selectedFileIndex ?? this.selectedFileIndex,
      bufferProgress: bufferProgress ?? this.bufferProgress,
      errorMessage: errorMessage,
      videoFile: videoFile ?? this.videoFile,
      streamUrl: streamUrl ?? this.streamUrl,
      downloadRateBytesPerSec:
          downloadRateBytesPerSec ?? this.downloadRateBytesPerSec,
      allowSlowBuffer: allowSlowBuffer,
      // Preserved deliberately — see the field doc.
      createdAt: createdAt,
    );
  }
}

/// Service for managing robust streaming of torrents
///
/// This service handles the complete streaming workflow:
/// 1. Add torrent with streaming-optimized settings
/// 2. Wait for metadata and file list
/// 3. Select the correct file (using fileIdx for season packs)
/// 4. Monitor buffering progress
/// 5. Provide ready callback when enough is buffered
///
/// Based on Stremio's approach to torrent streaming.
