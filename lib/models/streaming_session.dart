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

/// One streaming session for a single video, as `StreamingService` reports
/// it.
///
/// Immutable: every update is a [copyWith], published to the session's
/// stream, so a listener never sees a value change underneath it.
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

  /// When this session was first created. Drives the metadata timeout in the
  /// monitoring loop and seeds the buffering rate window.
  ///
  /// **Must be threaded through [copyWith].** The service copies the session
  /// on every 2 s poll tick as a heartbeat; if `copyWith` let the constructor
  /// default this back to `DateTime.now()`, session age would never exceed
  /// one poll interval and both timeouts would be dead code.
  final DateTime createdAt;

  final StreamingState state;
  final String? torrentHash;
  final String? contentPath;
  final String? selectedFilePath;
  final int? selectedFileIndex;
  final double bufferProgress;
  final String? errorMessage;
  final LocalMediaFile? videoFile;

  /// HTTP URL the player should open instead of [videoFile]'s path while the
  /// torrent is still downloading: the engine's own stream endpoint, or the
  /// local streaming proxy in front of a downloader. Null once the file is
  /// complete and is opened straight from disk.
  final String? streamUrl;

  /// Latest download rate for this torrent in bytes/second, refreshed on
  /// every monitoring poll. Drives the "X MB/s" hint in the prep overlay so
  /// the user can tell a torrent with peers from one still finding them.
  final int downloadRateBytesPerSec;

  /// When true, `tooSlow` / `stalled` buffering outcomes do **not** fail the
  /// session. Used for background next-episode prefetch: that torrent shares
  /// the pipe with the episode currently playing, so a 10-minute projected
  /// wait is expected — aborting would freeze the pill on "Too slow to
  /// stream" and never update again.
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
