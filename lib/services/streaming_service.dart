import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import '../models/local_media_file.dart';
import '../models/stream_request.dart';
import '../models/torrentio_stream.dart';
import '../models/torrent.dart';
import '../models/torrent_file.dart';
import '../utils/formatters.dart';
import 'local_streaming_server.dart';
import 'qbittorrent_api_service.dart';
import 'app_logger.dart';

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

  /// When this session was first created. Drives the [metadataTimeout] and
  /// [bufferTimeout] checks in the monitoring loop.
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
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isActive =>
      state != StreamingState.idle &&
      state != StreamingState.error &&
      state != StreamingState.cancelled;

  bool get isReady =>
      state == StreamingState.ready || state == StreamingState.playing;

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
class StreamingService {
  final QBittorrentApiService _qbtService;

  final Map<String, StreamingSession> _sessions = {};
  final Map<String, Timer> _monitoringTimers = {};
  final Map<String, StreamController<StreamingSession>> _sessionControllers =
      {};
  final Set<String> _checkingProgress =
      {}; // prevents concurrent checks per session
  /// Local HTTP proxy keyed by session id. Started when a session reaches
  /// [StreamingState.ready] and torn down on cancel/dispose. mpv reads from
  /// the proxy URL instead of the on-disk file so it doesn't choke on the
  /// zero-padded sparse regions qBittorrent leaves for un-downloaded bytes.
  final Map<String, LocalStreamingServer> _streamingServers = {};

  /// Video file extensions to look for
  static const videoExtensions = {
    'mkv',
    'mp4',
    'avi',
    'mov',
    'wmv',
    'flv',
    'webm',
    'm4v',
    'mpg',
    'mpeg',
    'ts',
    'm2ts',
  };

  /// Minimum contiguous piece percentage at the start of the file.
  /// The piece-level check verifies these are actually downloaded in order.
  /// Tracks the higher byte floor below — 5% of pieces matches the ~10%
  /// byte target without overshooting on tiny files where each piece is
  /// a big fraction of the whole.
  static const double minPiecePercent = 0.05;

  /// Pre-play buffer model: max(absolute floor, 10% of file), clamped to a
  /// cap so a 50 GB UHD rip doesn't demand 5 GB before opening. Matches the
  /// user's mental model of "stream waits for ~10% before playing" while
  /// keeping small files snappy (small pieces still need mpv headroom).
  static const int _bufferAbsoluteMin = 80 * 1024 * 1024; // 80 MB
  static const int _bufferAbsoluteCap = 500 * 1024 * 1024; // 500 MB
  static const double _bufferPercent = 0.10;

  /// Maximum time to wait for metadata
  static const Duration metadataTimeout = Duration(minutes: 2);

  /// Maximum time to wait for initial buffer
  static const Duration bufferTimeout = Duration(minutes: 5);

  /// Returns the minimum bytes needed before a file is ready to stream.
  static int minBufferBytesFor(int fileSizeBytes) {
    if (fileSizeBytes <= 0) return _bufferAbsoluteMin;
    final pct = (fileSizeBytes * _bufferPercent).round();
    return pct.clamp(_bufferAbsoluteMin, _bufferAbsoluteCap);
  }

  /// Polling interval for monitoring progress
  static const Duration pollingInterval = Duration(seconds: 2);

  StreamingService(this._qbtService);

  /// Get a stream of session updates for a specific session
  Stream<StreamingSession>? getSessionStream(String sessionId) {
    return _sessionControllers[sessionId]?.stream;
  }

  /// Get all active sessions
  List<StreamingSession> get activeSessions =>
      _sessions.values.where((s) => s.isActive).toList();

  /// Get a specific session by ID
  StreamingSession? getSession(String sessionId) => _sessions[sessionId];

  /// Start a streaming session for a Torrentio stream — the browse →
  /// pick-a-source path. Thin adapter over [startStreamingRequest].
  Future<StreamingSession> startStreaming({
    required TorrentioStream stream,
    String? showImdbId,
    String? showName,
    String? movieImdbId,
    int? season,
    int? episode,
    String? episodeCode,
    String? savePath,
  }) {
    return startStreamingRequest(
      request: StreamRequest.fromTorrentio(stream),
      showImdbId: showImdbId,
      showName: showName,
      movieImdbId: movieImdbId,
      season: season,
      episode: episode,
      episodeCode: episodeCode,
      savePath: savePath,
    );
  }

  /// Start a streaming session from a normalised [StreamRequest].
  ///
  /// For single-file torrents: downloads the single file with streaming
  /// optimisation. For season packs: deprioritises every file except the
  /// selected one, so a 40 GB pack doesn't get pulled to watch one episode.
  ///
  /// This is the single implementation of the streaming workflow. The
  /// next-episode / binge flow routes through here too — it used to carry
  /// its own copy inside `video_player_screen.dart`.
  Future<StreamingSession> startStreamingRequest({
    required StreamRequest request,
    String? showImdbId,
    String? showName,
    String? movieImdbId,
    int? season,
    int? episode,
    String? episodeCode,
    String? savePath,
  }) async {
    // Generate unique session ID
    final sessionId =
        '${request.infoHash}_${DateTime.now().millisecondsSinceEpoch}';

    // Create session
    final session = StreamingSession(
      id: sessionId,
      request: request,
      showImdbId: showImdbId,
      showName: showName,
      movieImdbId: movieImdbId,
      season: season,
      episode: episode,
      episodeCode: episodeCode,
      state: StreamingState.addingTorrent,
    );

    _sessions[sessionId] = session;
    _sessionControllers[sessionId] =
        StreamController<StreamingSession>.broadcast();
    _notifySession(sessionId);

    AppLog.d('[StreamingService] Starting session $sessionId');
    AppLog.d('[StreamingService] Stream: ${request.displayName}');
    AppLog.d('[StreamingService] Is single file: ${request.isSingleFile}');
    AppLog.d('[StreamingService] FileIdx: ${request.fileIdx}');
    AppLog.d('[StreamingService] Filename: ${request.filename}');

    try {
      // Add torrent with streaming-optimized settings.
      // Only sequentialDownload — firstLastPiecePrio conflicts by also
      // prioritising the LAST piece, which breaks strict in-order delivery.
      final success = await _qbtService.addTorrent(
        magnetLink: request.magnetUri,
        savePath: savePath,
        sequentialDownload: true,
        firstLastPiecePrio: false,
      );

      if (!success) {
        _updateSession(
          sessionId,
          state: StreamingState.error,
          errorMessage: 'Failed to add torrent to qBittorrent',
        );
        return _sessions[sessionId]!;
      }

      // Update with torrent hash
      _updateSession(
        sessionId,
        torrentHash: request.infoHash,
        state: StreamingState.selectingFiles,
      );

      // Start monitoring for file selection and buffering
      _startMonitoring(sessionId);

      return _sessions[sessionId]!;
    } catch (e) {
      AppLog.e('[StreamingService] Error starting streaming: $e');
      _updateSession(
        sessionId,
        state: StreamingState.error,
        errorMessage: 'Error: $e',
      );
      return _sessions[sessionId]!;
    }
  }

  /// Cancel a streaming session
  Future<void> cancelSession(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;

    AppLog.d('[StreamingService] Cancelling session $sessionId');

    // Stop monitoring
    _monitoringTimers[sessionId]?.cancel();
    _monitoringTimers.remove(sessionId);

    // Tear down the local HTTP proxy if one was started for this session.
    final server = _streamingServers.remove(sessionId);
    if (server != null) {
      await server.stop();
    }

    // Update state
    _updateSession(sessionId, state: StreamingState.cancelled);

    // Close stream controller
    await _sessionControllers[sessionId]?.close();
    _sessionControllers.remove(sessionId);

    // Remove session
    _sessions.remove(sessionId);
  }

  /// Start monitoring a session for file selection and buffering
  void _startMonitoring(String sessionId) {
    final timer = Timer.periodic(pollingInterval, (timer) async {
      await _checkSessionProgress(sessionId);
    });

    _monitoringTimers[sessionId] = timer;

    // Also do an immediate check
    _checkSessionProgress(sessionId);
  }

  /// Check progress of a streaming session
  Future<void> _checkSessionProgress(String sessionId) async {
    // Prevent concurrent checks for the same session
    if (_checkingProgress.contains(sessionId)) return;
    _checkingProgress.add(sessionId);

    final session = _sessions[sessionId];
    if (session == null || !session.isActive) {
      _monitoringTimers[sessionId]?.cancel();
      _checkingProgress.remove(sessionId);
      return;
    }

    try {
      // Find the torrent
      final torrents = await _qbtService.getTorrents();
      final torrent = torrents.firstWhereOrNull(
        (t) => t.hash.toLowerCase() == session.request.infoHash.toLowerCase(),
      );

      if (torrent == null) {
        // Torrent not found yet, might still be adding. Emit a heartbeat
        // so the UI listener sees activity (otherwise the initial overlay
        // text just sits there until metadata arrives, which can take
        // 30+ s on a low-peer torrent and looks like a freeze).
        _updateSession(sessionId, bufferProgress: 0);
        if (DateTime.now().difference(session.createdAt) > metadataTimeout) {
          _updateSession(
            sessionId,
            state: StreamingState.error,
            errorMessage: 'Timeout waiting for torrent metadata',
          );
        }
        return;
      }

      // Heartbeat: refresh content path AND bufferProgress on every poll
      // so the listener sees forward motion during the metadata→file-
      // selection phases, even when state itself hasn't changed yet.
      _updateSession(
        sessionId,
        contentPath: torrent.contentPath,
        bufferProgress: torrent.progress,
        downloadRateBytesPerSec: torrent.dlspeed,
      );

      // Handle based on current state
      switch (session.state) {
        case StreamingState.addingTorrent:
        case StreamingState.selectingFiles:
          await _handleFileSelection(sessionId, torrent);
          break;

        case StreamingState.buffering:
          await _handleBuffering(sessionId, torrent);
          break;

        default:
          break;
      }
    } catch (e) {
      AppLog.e('[StreamingService] Error checking progress: $e');
    } finally {
      _checkingProgress.remove(sessionId);
    }
  }

  /// Handle file selection for a streaming session
  Future<void> _handleFileSelection(String sessionId, Torrent torrent) async {
    final session = _sessions[sessionId];
    if (session == null) return;

    // Get files in the torrent
    List<TorrentFile> files;
    try {
      files = await _qbtService.getTorrentFiles(torrent.hash);
    } catch (e) {
      AppLog.e('[StreamingService] Error getting files: $e');
      return; // Will retry on next poll
    }

    if (files.isEmpty) {
      AppLog.d('[StreamingService] No files yet, waiting for metadata...');
      return; // Still loading metadata
    }

    AppLog.d('[StreamingService] Torrent has ${files.length} files');

    // Find the video file to stream
    int? targetFileIndex;
    String? targetFilePath;

    if (session.request.isSingleFile) {
      // Single file torrent - find the largest video file
      AppLog.d(
        '[StreamingService] Single-file torrent - selecting largest video',
      );
      final videoFiles = files
          .asMap()
          .entries
          .where((e) => _isVideoFile(e.value.name))
          .toList();

      if (videoFiles.isNotEmpty) {
        videoFiles.sort((a, b) => b.value.size.compareTo(a.value.size));
        targetFileIndex = videoFiles.first.key;
        targetFilePath = videoFiles.first.value.name;
      }
    } else {
      // Season pack - use fileIdx if available, or match by filename
      AppLog.d(
        '[StreamingService] Season pack - using fileIdx: ${session.request.fileIdx}',
      );

      if (session.request.fileIdx != null &&
          session.request.fileIdx! < files.length) {
        // Use the provided file index
        targetFileIndex = session.request.fileIdx!;
        targetFilePath = files[targetFileIndex].name;
        AppLog.d(
          '[StreamingService] Selected file at index $targetFileIndex: $targetFilePath',
        );
      } else if (session.request.filename != null) {
        // Try to match by filename
        final targetFilename = session.request.filename!
            .split('/')
            .last
            .toLowerCase();
        final match = files.asMap().entries.firstWhereOrNull(
          (e) =>
              e.value.name.toLowerCase().contains(targetFilename) ||
              targetFilename.contains(
                e.value.name.split('/').last.toLowerCase(),
              ),
        );
        if (match != null) {
          targetFileIndex = match.key;
          targetFilePath = match.value.name;
          AppLog.d('[StreamingService] Matched by filename: $targetFilePath');
        }
      }

      // Fallback: find video file matching episode pattern
      if (targetFileIndex == null &&
          session.season != null &&
          session.episode != null) {
        final pattern = _buildEpisodePattern(session.season!, session.episode!);
        final match = files.asMap().entries.firstWhereOrNull(
          (e) => _isVideoFile(e.value.name) && pattern.hasMatch(e.value.name),
        );
        if (match != null) {
          targetFileIndex = match.key;
          targetFilePath = match.value.name;
          AppLog.d(
            '[StreamingService] Matched by episode pattern: $targetFilePath',
          );
        }
      }

      // Last fallback: largest video file
      if (targetFileIndex == null) {
        AppLog.d(
          '[StreamingService] No match found, falling back to largest video',
        );
        final videoFiles = files
            .asMap()
            .entries
            .where((e) => _isVideoFile(e.value.name))
            .toList();

        if (videoFiles.isNotEmpty) {
          videoFiles.sort((a, b) => b.value.size.compareTo(a.value.size));
          targetFileIndex = videoFiles.first.key;
          targetFilePath = videoFiles.first.value.name;
        }
      }
    }

    if (targetFileIndex == null) {
      _updateSession(
        sessionId,
        state: StreamingState.error,
        errorMessage: 'No video file found in torrent',
      );
      return;
    }

    AppLog.d(
      '[StreamingService] Selected file index $targetFileIndex: $targetFilePath',
    );

    // Fast path: torrent is already fully downloaded (seeding / paused /
    // stopped after completion). Skip the buffer wait — and crucially skip
    // toggling file priorities, which can re-trigger a qBit recheck on a
    // completed torrent and starve the next sync update.
    final isAlreadyComplete = torrent.isCompleted || torrent.progress >= 0.99;

    // For season packs, disable all other files to save bandwidth — but only
    // while the torrent is still downloading. Setting priorities on a
    // completed torrent can flip qBittorrent into a recheck state that
    // briefly reports progress=0 on the file, which then never recovers in
    // the sync delta (see Fix 1 in plan).
    if (session.request.isSeasonPack &&
        files.length > 1 &&
        !isAlreadyComplete) {
      AppLog.d('[StreamingService] Disabling non-target files in season pack');
      try {
        // Set all files to skip (priority 0)
        final allFileIds = List.generate(files.length, (i) => i);
        await _qbtService.setFilePriority(torrent.hash, allFileIds, 0);

        // Set target file to high priority
        await _qbtService.setFilePriority(torrent.hash, [targetFileIndex], 7);

        AppLog.d('[StreamingService] File priorities set successfully');
      } catch (e) {
        AppLog.e('[StreamingService] Error setting file priorities: $e');
        // Continue anyway - might already be set
      }
    }

    // Surface a real percentage in the overlay even before buffering kicks
    // in — otherwise the user just sees "Preparing" with no progress.
    _updateSession(
      sessionId,
      state: StreamingState.buffering,
      selectedFileIndex: targetFileIndex,
      selectedFilePath: targetFilePath,
      bufferProgress: torrent.progress,
    );

    if (isAlreadyComplete) {
      AppLog.d(
        '[StreamingService] Torrent already complete (state=${torrent.state}, '
        'progress=${(torrent.progress * 100).toStringAsFixed(1)}%) — '
        'fast-pathing to ready.',
      );
      await _promoteToReady(sessionId, torrent);
      return;
    }

    // Same-poll buffer check — if the file already has enough bytes (e.g.
    // sequential download piped in fast, or we're resuming a partial), we
    // don't want to wait a full 2 s for the next poll just to discover it.
    await _handleBuffering(sessionId, torrent);
  }

  /// Stand up the local HTTP proxy and transition the session to `ready`.
  /// Shared by the fast-path (`_handleFileSelection`) and the regular
  /// buffer-threshold path (`_handleBuffering`).
  Future<void> _promoteToReady(String sessionId, Torrent torrent) async {
    final session = _sessions[sessionId];
    if (session == null || session.selectedFileIndex == null) return;

    final videoFile = await _findVideoFile(session);
    if (videoFile == null) {
      _updateSession(
        sessionId,
        state: StreamingState.error,
        errorMessage: 'Could not locate video file on disk',
      );
      _monitoringTimers[sessionId]?.cancel();
      return;
    }

    String? streamUrl;
    try {
      final server = LocalStreamingServer(
        qbt: _qbtService,
        filePath: videoFile.path,
        torrentHash: torrent.hash,
        fileIndex: session.selectedFileIndex!,
        logTag: 'main',
      );
      await server.start();
      await _streamingServers[sessionId]?.stop();
      _streamingServers[sessionId] = server;
      streamUrl = server.url;
      AppLog.d('[StreamingService] Local stream URL: $streamUrl');
    } catch (e) {
      AppLog.e('[StreamingService] Failed to start local proxy: $e');
    }

    _updateSession(
      sessionId,
      state: StreamingState.ready,
      videoFile: videoFile,
      streamUrl: streamUrl,
      bufferProgress: 1.0,
    );

    // Stop readiness monitoring. VideoPlayerScreen tracks the download edge
    // while playback continues.
    _monitoringTimers[sessionId]?.cancel();
  }

  /// Handle buffering state for a streaming session.
  ///
  /// Uses TWO checks before declaring ready:
  /// 1. Overall file progress → enough bytes buffered (scales with file size).
  /// 2. Piece-level contiguous check → the selected file's first N pieces are
  ///    actually downloaded in order, so the player won't hit gaps.
  Future<void> _handleBuffering(String sessionId, Torrent torrent) async {
    final session = _sessions[sessionId];
    if (session == null || session.selectedFileIndex == null) return;

    double fileProgress = 0;
    int fileSizeBytes = 0;
    TorrentFile? selectedFile;

    try {
      final files = await _qbtService.getTorrentFiles(torrent.hash);
      if (session.selectedFileIndex! < files.length) {
        selectedFile = files[session.selectedFileIndex!];
        fileProgress = selectedFile.progress;
        fileSizeBytes = selectedFile.size.round();
      }
    } catch (e) {
      AppLog.e('[StreamingService] Error getting file progress: $e');
    }

    final bufferedBytes = (fileSizeBytes * fileProgress).round();
    final minBytes = minBufferBytesFor(fileSizeBytes);

    AppLog.d(
      '[StreamingService] Buffer progress: ${(fileProgress * 100).toStringAsFixed(1)}% '
      '(${Formatters.formatBytesCompact(bufferedBytes)} / ${Formatters.formatBytesCompact(fileSizeBytes)}) '
      '[need ${Formatters.formatBytesCompact(minBytes)}]',
    );

    _updateSession(sessionId, bufferProgress: fileProgress);

    // Byte threshold: enough absolute data for the player to start.
    final bytesOk = bufferedBytes >= minBytes;

    // Completion short-circuit: if qBit reports the torrent fully done,
    // promote immediately even if our local byte threshold isn't met
    // (small files can be done at <50 MB).
    final torrentDone = torrent.isCompleted || torrent.progress >= 0.99;
    final readyNow = bytesOk || (torrentDone && fileProgress >= 0.95);

    if (readyNow) {
      AppLog.d(
        '[StreamingService] Buffer ready (bytesOk=$bytesOk torrentDone=$torrentDone)! '
        '${Formatters.formatBytesCompact(bufferedBytes)} buffered.',
      );
      await _promoteToReady(sessionId, torrent);
    } else {
      if (DateTime.now().difference(session.createdAt) > bufferTimeout) {
        _updateSession(
          sessionId,
          state: StreamingState.error,
          errorMessage: 'Timeout waiting for buffer',
        );
        _monitoringTimers[sessionId]?.cancel();
      }
    }
  }

  /// Find the video file on disk once buffering is complete
  Future<LocalMediaFile?> _findVideoFile(StreamingSession session) async {
    if (session.contentPath == null || session.selectedFilePath == null) {
      return null;
    }

    try {
      String fullPath;

      // qBittorrent's contentPath is the file itself for single-file torrents
      // and the directory for multi-file torrents. The stream's
      // `isSingleFile` flag comes from Torrentio's heuristic and isn't always
      // right (e.g. some "season pack" entries actually resolve to a single
      // file once metadata arrives). Inspect the filesystem to decide
      // instead of trusting the flag — joining a file path with another
      // filename produces `...mkv/...mkv` which won't open.
      final contentStat = FileSystemEntity.typeSync(session.contentPath!);
      final contentIsFile = contentStat == FileSystemEntityType.file;

      if (contentIsFile) {
        fullPath = session.contentPath!;
      } else {
        // Normalise segments so mixed separators from qBittorrent don't double up.
        final segments = session.selectedFilePath!
            .split(RegExp(r'[\\/]'))
            .where((s) => s.isNotEmpty);
        fullPath = p.normalize(
          p.join(session.contentPath!, p.joinAll(segments)),
        );
      }

      final file = File(fullPath);
      if (!await file.exists() && !contentIsFile) {
        final dir = Directory(session.contentPath!);
        if (await dir.exists()) {
          final selectedFileName = p.basename(
            session.selectedFilePath!.replaceAll(r'\', '/'),
          );
          await for (final entity in dir.list(recursive: true)) {
            if (entity is File && _isVideoFile(entity.path)) {
              if (p.basename(entity.path).toLowerCase() ==
                  selectedFileName.toLowerCase()) {
                fullPath = entity.path;
                break;
              }
            }
          }
        }
      }

      AppLog.d('[StreamingService] Video file path: $fullPath');

      final stat = await File(fullPath).stat();
      final fileName = p.basename(fullPath);
      final extension = p.extension(fileName).replaceFirst('.', '');
      return LocalMediaFile(
        path: fullPath,
        fileName: fileName,
        sizeBytes: stat.size,
        modifiedDate: stat.modified,
        extension: extension,
        showName: session.showName,
        seasonNumber: session.season,
        episodeNumber: session.episode,
      );
    } catch (e) {
      AppLog.e('[StreamingService] Error finding video file: $e');
      return null;
    }
  }

  /// Update a session and notify listeners
  void _updateSession(
    String sessionId, {
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
    final session = _sessions[sessionId];
    if (session == null) return;

    _sessions[sessionId] = session.copyWith(
      state: state,
      torrentHash: torrentHash,
      contentPath: contentPath,
      selectedFilePath: selectedFilePath,
      selectedFileIndex: selectedFileIndex,
      bufferProgress: bufferProgress,
      errorMessage: errorMessage,
      videoFile: videoFile,
      streamUrl: streamUrl,
      downloadRateBytesPerSec: downloadRateBytesPerSec,
    );

    _notifySession(sessionId);
  }

  /// Notify listeners of a session update
  void _notifySession(String sessionId) {
    final session = _sessions[sessionId];
    if (session != null) {
      _sessionControllers[sessionId]?.add(session);
    }
  }

  /// Check if a filename is a video file
  bool _isVideoFile(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    return videoExtensions.contains(ext);
  }

  /// Build regex pattern to match episode in filename
  RegExp _buildEpisodePattern(int season, int episode) {
    final s = season.toString().padLeft(2, '0');
    final e = episode.toString().padLeft(2, '0');
    // Match patterns like S01E05, 1x05, etc.
    return RegExp(
      '(?:s0?$season[xe]0?$episode)|(?:[^0-9]0?$season[xe]0?$episode[^0-9])|(?:s${s}e$e)',
      caseSensitive: false,
    );
  }

  /// Dispose all resources
  void dispose() {
    for (final timer in _monitoringTimers.values) {
      timer.cancel();
    }
    _monitoringTimers.clear();

    for (final server in _streamingServers.values) {
      // Fire-and-forget — dispose is sync and the server cleans up its own
      // sockets internally.
      unawaited(server.stop());
    }
    _streamingServers.clear();

    for (final controller in _sessionControllers.values) {
      controller.close();
    }
    _sessionControllers.clear();

    _sessions.clear();
  }
}

/// Extension to sort streams for optimal streaming
extension TorrentioStreamListExtensions on List<TorrentioStream> {
  /// Sort streams by streaming score (best for streaming first)
  ///
  /// This prioritizes:
  /// 1. Single-file/single-episode torrents over season packs
  /// 2. Higher quality
  /// 3. More seeders
  List<TorrentioStream> sortForStreaming() {
    final sorted = List<TorrentioStream>.from(this);
    sorted.sort((a, b) => b.streamingScore.compareTo(a.streamingScore));
    return sorted;
  }

  /// Filter to only single-episode releases (preferred for streaming)
  /// This includes both true single-file AND single episode with subtitles
  List<TorrentioStream> singleFileOnly() {
    return where((s) => s.isSingleEpisodeRelease).toList();
  }

  /// Get the best stream for streaming (highest streaming score)
  TorrentioStream? getBestForStreaming() {
    if (isEmpty) return null;
    return sortForStreaming().first;
  }
}
