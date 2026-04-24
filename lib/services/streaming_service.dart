import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import '../models/local_media_file.dart';
import '../models/torrentio_stream.dart';
import '../models/torrent.dart';
import '../models/torrent_file.dart';
import 'qbittorrent_api_service.dart';

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
  final TorrentioStream stream;
  final String? showImdbId;
  final String? showName;
  final String? movieImdbId;
  final int? season;
  final int? episode;
  final String? episodeCode;
  final DateTime createdAt;
  
  StreamingState state;
  String? torrentHash;
  String? contentPath;
  String? selectedFilePath;
  int? selectedFileIndex;
  double bufferProgress;
  String? errorMessage;
  LocalMediaFile? videoFile;
  
  StreamingSession({
    required this.id,
    required this.stream,
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
  }) : createdAt = DateTime.now();
  
  bool get isActive => state != StreamingState.idle && 
                       state != StreamingState.error && 
                       state != StreamingState.cancelled;
                       
  bool get isReady => state == StreamingState.ready || state == StreamingState.playing;
  
  StreamingSession copyWith({
    StreamingState? state,
    String? torrentHash,
    String? contentPath,
    String? selectedFilePath,
    int? selectedFileIndex,
    double? bufferProgress,
    String? errorMessage,
    LocalMediaFile? videoFile,
  }) {
    return StreamingSession(
      id: id,
      stream: stream,
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
  final Map<String, StreamController<StreamingSession>> _sessionControllers = {};
  final Set<String> _checkingProgress = {}; // prevents concurrent checks per session
  
  /// Video file extensions to look for
  static const videoExtensions = {
    'mkv', 'mp4', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', 'mpg', 'mpeg', 'ts', 'm2ts'
  };
  
  /// Minimum contiguous piece percentage at the start of the file.
  /// The piece-level check verifies these are actually downloaded in order.
  static const double minPiecePercent = 0.03; // 3% of pieces

  /// Minimum absolute buffer (bytes) before streaming is ready.
  /// Scales with file size — see [_minBufferBytesFor].
  static const int _minBufferSmall = 50 * 1024 * 1024;  // 50 MB  (files < 1 GB)
  static const int _minBufferMedium = 100 * 1024 * 1024; // 100 MB (files 1–4 GB)
  static const int _minBufferLarge = 200 * 1024 * 1024;  // 200 MB (files > 4 GB)

  /// Maximum time to wait for metadata
  static const Duration metadataTimeout = Duration(minutes: 2);

  /// Maximum time to wait for initial buffer
  static const Duration bufferTimeout = Duration(minutes: 5);

  /// Returns the minimum bytes needed before a file is ready to stream.
  static int _minBufferBytesFor(int fileSizeBytes) {
    if (fileSizeBytes > 4 * 1024 * 1024 * 1024) return _minBufferLarge;
    if (fileSizeBytes > 1 * 1024 * 1024 * 1024) return _minBufferMedium;
    return _minBufferSmall;
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
  
  /// Start a streaming session for a TorrentioStream
  /// 
  /// For single-file torrents: Downloads the single file with streaming optimization
  /// For season packs: Downloads only the specified file (using fileIdx)
  Future<StreamingSession> startStreaming({
    required TorrentioStream stream,
    String? showImdbId,
    String? showName,
    String? movieImdbId,
    int? season,
    int? episode,
    String? episodeCode,
    String? savePath,
  }) async {
    // Generate unique session ID
    final sessionId = '${stream.infoHash}_${DateTime.now().millisecondsSinceEpoch}';
    
    // Create session
    final session = StreamingSession(
      id: sessionId,
      stream: stream,
      showImdbId: showImdbId,
      showName: showName,
      movieImdbId: movieImdbId,
      season: season,
      episode: episode,
      episodeCode: episodeCode,
      state: StreamingState.addingTorrent,
    );
    
    _sessions[sessionId] = session;
    _sessionControllers[sessionId] = StreamController<StreamingSession>.broadcast();
    _notifySession(sessionId);
    
    debugPrint('[StreamingService] Starting session $sessionId');
    debugPrint('[StreamingService] Stream: ${stream.name}');
    debugPrint('[StreamingService] Is single file: ${stream.isSingleFile}');
    debugPrint('[StreamingService] FileIdx: ${stream.fileIdx}');
    debugPrint('[StreamingService] Filename: ${stream.filename}');
    
    try {
      // Add torrent with streaming-optimized settings.
      // Only sequentialDownload — firstLastPiecePrio conflicts by also
      // prioritising the LAST piece, which breaks strict in-order delivery.
      final success = await _qbtService.addTorrent(
        magnetLink: stream.magnetUri,
        savePath: savePath,
        sequentialDownload: true,
        firstLastPiecePrio: false,
      );
      
      if (!success) {
        _updateSession(sessionId, 
          state: StreamingState.error,
          errorMessage: 'Failed to add torrent to qBittorrent',
        );
        return _sessions[sessionId]!;
      }
      
      // Update with torrent hash
      _updateSession(sessionId,
        torrentHash: stream.infoHash,
        state: StreamingState.selectingFiles,
      );
      
      // Start monitoring for file selection and buffering
      _startMonitoring(sessionId);
      
      return _sessions[sessionId]!;
    } catch (e) {
      debugPrint('[StreamingService] Error starting streaming: $e');
      _updateSession(sessionId,
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
    
    debugPrint('[StreamingService] Cancelling session $sessionId');
    
    // Stop monitoring
    _monitoringTimers[sessionId]?.cancel();
    _monitoringTimers.remove(sessionId);
    
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
      final torrent = torrents.firstWhereOrNull((t) => 
        t.hash.toLowerCase() == session.stream.infoHash.toLowerCase()
      );
      
      if (torrent == null) {
        // Torrent not found yet, might still be adding
        if (DateTime.now().difference(session.createdAt) > metadataTimeout) {
          _updateSession(sessionId,
            state: StreamingState.error,
            errorMessage: 'Timeout waiting for torrent metadata',
          );
        }
        return;
      }
      
      // Update content path
      _updateSession(sessionId, contentPath: torrent.contentPath);
      
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
      debugPrint('[StreamingService] Error checking progress: $e');
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
      debugPrint('[StreamingService] Error getting files: $e');
      return; // Will retry on next poll
    }
    
    if (files.isEmpty) {
      debugPrint('[StreamingService] No files yet, waiting for metadata...');
      return; // Still loading metadata
    }
    
    debugPrint('[StreamingService] Torrent has ${files.length} files');
    
    // Find the video file to stream
    int? targetFileIndex;
    String? targetFilePath;
    
    if (session.stream.isSingleFile) {
      // Single file torrent - find the largest video file
      debugPrint('[StreamingService] Single-file torrent - selecting largest video');
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
      debugPrint('[StreamingService] Season pack - using fileIdx: ${session.stream.fileIdx}');
      
      if (session.stream.fileIdx != null && session.stream.fileIdx! < files.length) {
        // Use the provided file index
        targetFileIndex = session.stream.fileIdx!;
        targetFilePath = files[targetFileIndex].name;
        debugPrint('[StreamingService] Selected file at index $targetFileIndex: $targetFilePath');
      } else if (session.stream.filename != null) {
        // Try to match by filename
        final targetFilename = session.stream.filename!.split('/').last.toLowerCase();
        final match = files.asMap().entries.firstWhereOrNull((e) => 
          e.value.name.toLowerCase().contains(targetFilename) ||
          targetFilename.contains(e.value.name.split('/').last.toLowerCase())
        );
        if (match != null) {
          targetFileIndex = match.key;
          targetFilePath = match.value.name;
          debugPrint('[StreamingService] Matched by filename: $targetFilePath');
        }
      }
      
      // Fallback: find video file matching episode pattern
      if (targetFileIndex == null && session.season != null && session.episode != null) {
        final pattern = _buildEpisodePattern(session.season!, session.episode!);
        final match = files.asMap().entries.firstWhereOrNull((e) => 
          _isVideoFile(e.value.name) && pattern.hasMatch(e.value.name)
        );
        if (match != null) {
          targetFileIndex = match.key;
          targetFilePath = match.value.name;
          debugPrint('[StreamingService] Matched by episode pattern: $targetFilePath');
        }
      }
      
      // Last fallback: largest video file
      if (targetFileIndex == null) {
        debugPrint('[StreamingService] No match found, falling back to largest video');
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
      _updateSession(sessionId,
        state: StreamingState.error,
        errorMessage: 'No video file found in torrent',
      );
      return;
    }
    
    debugPrint('[StreamingService] Selected file index $targetFileIndex: $targetFilePath');
    
    // For season packs, disable all other files to save bandwidth
    if (session.stream.isSeasonPack && files.length > 1) {
      debugPrint('[StreamingService] Disabling non-target files in season pack');
      try {
        // Set all files to skip (priority 0)
        final allFileIds = List.generate(files.length, (i) => i);
        await _qbtService.setFilePriority(torrent.hash, allFileIds, 0);
        
        // Set target file to high priority
        await _qbtService.setFilePriority(torrent.hash, [targetFileIndex], 7);
        
        debugPrint('[StreamingService] File priorities set successfully');
      } catch (e) {
        debugPrint('[StreamingService] Error setting file priorities: $e');
        // Continue anyway - might already be set
      }
    }
    
    // Update session with selected file info
    _updateSession(sessionId,
      state: StreamingState.buffering,
      selectedFileIndex: targetFileIndex,
      selectedFilePath: targetFilePath,
    );
  }
  
  /// Handle buffering state for a streaming session.
  ///
  /// Uses TWO checks before declaring ready:
  /// 1. Overall file progress → enough bytes buffered (scales with file size).
  /// 2. Piece-level contiguous check → the first N pieces are actually
  ///    downloaded in order, so the player won't hit gaps.
  Future<void> _handleBuffering(String sessionId, Torrent torrent) async {
    final session = _sessions[sessionId];
    if (session == null || session.selectedFileIndex == null) return;

    double fileProgress = 0;
    int fileSizeBytes = 0;

    try {
      final files = await _qbtService.getTorrentFiles(torrent.hash);
      if (session.selectedFileIndex! < files.length) {
        final file = files[session.selectedFileIndex!];
        fileProgress = file.progress;
        fileSizeBytes = file.size.round();
      }
    } catch (e) {
      debugPrint('[StreamingService] Error getting file progress: $e');
    }

    final bufferedBytes = (fileSizeBytes * fileProgress).round();
    final minBytes = _minBufferBytesFor(fileSizeBytes);

    debugPrint('[StreamingService] Buffer progress: ${(fileProgress * 100).toStringAsFixed(1)}% '
        '(${_formatBytes(bufferedBytes)} / ${_formatBytes(fileSizeBytes)}) '
        '[need ${_formatBytes(minBytes)}]');

    _updateSession(sessionId, bufferProgress: fileProgress);

    // Byte threshold: enough absolute data for the player to start.
    final bytesOk = bufferedBytes >= minBytes;

    // Piece-level contiguous check: verify the FIRST pieces are actually
    // downloaded in order — prevents starting when pieces are scattered.
    bool piecesOk = false;
    if (bytesOk) {
      try {
        piecesOk = await _qbtService.isReadyForStreaming(
          torrent.hash,
          minProgress: minPiecePercent,
        );
      } catch (e) {
        debugPrint('[StreamingService] Piece check failed: $e');
        // Fall back to byte-only check if piece API fails
        piecesOk = true;
      }
    }

    if (bytesOk && piecesOk) {
      debugPrint('[StreamingService] Buffer ready! '
          '${_formatBytes(bufferedBytes)} buffered, pieces contiguous.');

      final videoFile = await _findVideoFile(session);

      _updateSession(sessionId,
        state: StreamingState.ready,
        videoFile: videoFile,
      );

      // Stop monitoring — mpv cache-pause handles ongoing buffering
      _monitoringTimers[sessionId]?.cancel();
    } else {
      if (DateTime.now().difference(session.createdAt) > bufferTimeout) {
        _updateSession(sessionId,
          state: StreamingState.error,
          errorMessage: 'Timeout waiting for buffer',
        );
        _monitoringTimers[sessionId]?.cancel();
      }
    }
  }
  
  /// Find the video file on disk once buffering is complete
  Future<LocalMediaFile?> _findVideoFile(StreamingSession session) async {
    if (session.contentPath == null || session.selectedFilePath == null) return null;
    
    try {
      String fullPath;
      if (session.stream.isSingleFile) {
        fullPath = session.contentPath!;
      } else {
        // Normalise segments so mixed separators from qBittorrent don't double up.
        final segments = session.selectedFilePath!
            .split(RegExp(r'[\\/]'))
            .where((s) => s.isNotEmpty);
        fullPath = p.normalize(p.join(session.contentPath!, p.joinAll(segments)));
      }

      final file = File(fullPath);
      if (!await file.exists()) {
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

      debugPrint('[StreamingService] Video file path: $fullPath');

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
      debugPrint('[StreamingService] Error finding video file: $e');
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
      '(?:s0?$season[xe]0?$episode)|(?:[^0-9]0?$season[xe]0?$episode[^0-9])|(?:s${s}e${e})',
      caseSensitive: false,
    );
  }
  
  /// Format bytes to human-readable string
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  
  /// Dispose all resources
  void dispose() {
    for (final timer in _monitoringTimers.values) {
      timer.cancel();
    }
    _monitoringTimers.clear();
    
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
