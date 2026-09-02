import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/local_media_file.dart';
import '../models/stream_request.dart';
import '../models/streaming_session.dart';
import '../models/torrent.dart';
import '../models/torrent_file.dart';
import '../models/torrentio_stream.dart';
import '../utils/formatters.dart';
import '../utils/platform_utils.dart';
import '../utils/poll_loop.dart';
import 'app_logger.dart';
import 'local_streaming_server.dart';
import 'qbittorrent_api_service.dart';

// Re-exported so callers keep importing the session types from the
// service that produces them, rather than tracking a second path.
export '../models/streaming_session.dart';

class StreamingService {
  final QBittorrentApiService _qbtService;

  final Map<String, StreamingSession> _sessions = {};
  final Map<String, PollLoop> _monitoringLoops = {};
  final Map<String, StreamController<StreamingSession>> _sessionControllers =
      {};

  /// Sessions whose progress check is mid-flight.
  ///
  /// Mostly subsumed by [PollLoop], which already drops a tick that arrives
  /// while the previous one is still running. It is kept for the one case
  /// the loop cannot see: `_startMonitoring` called twice for the same
  /// session replaces the loop, and the outgoing loop's in-flight tick would
  /// otherwise overlap the incoming loop's immediate one.
  final Set<String> _checkingProgress = {};

  /// Buffering telemetry per session — see [BufferWatch]. Cleared when the
  /// session ends or gives up.
  final Map<String, BufferWatch> _bufferWatch = {};

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

  /// Maximum time to wait for metadata
  static const Duration metadataTimeout = Duration(minutes: 2);

  // ── Buffer patience ────────────────────────────────────────────────────
  //
  // This used to be a flat 5-minute deadline, which silently guaranteed
  // failure for a whole class of torrents: the pre-play floor is 80 MB, so
  // anything slower than 80 MB / 300 s ≈ 273 KB/s could never reach the
  // threshold before the clock ran out. A 200 KB/s torrent spun for five
  // minutes and then reported "Timeout waiting for buffer" — despite being
  // perfectly capable of streaming, it just needed seven.
  //
  // Season-pack episodes hit this disproportionately. Restricting a large
  // pack to a single wanted file narrows the piece range, so fewer peers
  // hold what we need at any moment and effective throughput drops.
  //
  // The replacement judges whether the download is *going anywhere* rather
  // than how long it has been running.

  /// Upper bound on patience for a torrent that IS making progress. A
  /// backstop against pathological cases, not the normal exit.
  static const Duration bufferHardCeiling = Duration(minutes: 20);

  /// No new bytes at all for this long ⇒ nothing is coming. Distinct from
  /// "slow": this is a torrent with no usable peers.
  static const Duration bufferStallWindow = Duration(seconds: 90);

  /// Projected time-to-ready above this ⇒ not worth streaming, say so now
  /// instead of making the user watch a spinner earn the same answer.
  static const Duration maxProjectedWait = Duration(minutes: 10);

  /// Ignore the rate estimate until it has had time to mean something —
  /// the first seconds of a torrent are all handshakes and no payload.
  ///
  /// 30 s was not enough. A torrent routinely sits near zero while it finds
  /// peers and then climbs to megabytes a second, and [BufferWatch]'s rate
  /// is exponentially smoothed, so at 30 s the estimate is still dominated
  /// by the dead start — it takes several polls to catch up with a ramp.
  /// Judging there gave up on streams that were about to be fine.
  static const Duration rateWarmup = Duration(seconds: 90);

  /// What the buffer situation warrants doing right now.
  ///
  /// Split out as a pure function because the old flat deadline hid a
  /// arithmetic contradiction that no amount of manual testing on a fast
  /// connection would surface.
  @visibleForTesting
  static BufferOutcome assessBuffering({
    required int bufferedBytes,
    required int minBytes,
    required double bytesPerSecond,
    required Duration sinceLastProgress,
    required Duration sinceStart,
  }) {
    if (bufferedBytes >= minBytes) return BufferOutcome.ready;
    if (sinceStart >= bufferHardCeiling) return BufferOutcome.gaveUp;

    // Nothing arriving at all — a peer problem, not a speed problem.
    if (sinceLastProgress >= bufferStallWindow) return BufferOutcome.stalled;

    // Slow but moving: is it moving fast enough to be worth the wait?
    // Only once the rate estimate has had time to settle, so a slow start
    // doesn't condemn a torrent that is about to pick up.
    if (sinceStart >= rateWarmup && bytesPerSecond > 0) {
      final remaining = minBytes - bufferedBytes;
      final projectedSeconds = remaining / bytesPerSecond;
      if (projectedSeconds > maxProjectedWait.inSeconds) {
        return BufferOutcome.tooSlow;
      }
    }

    return BufferOutcome.waiting;
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
    bool allowSlowBuffer = false,
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
      allowSlowBuffer: allowSlowBuffer,
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
      var added = await _qbtService.addTorrent(
        magnetLink: request.magnetUri,
        savePath: savePath,
        sequentialDownload: true,
        firstLastPiecePrio: false,
      );

      if (!added) {
        // qBittorrent reports a duplicate add as a failure ("Fails." on 4.x,
        // 4xx on 5.x) — but for us it isn't one: the torrent we want is
        // already there. This is the normal case for the second episode of a
        // season pack, and treating it as fatal killed the session before
        // monitoring ever started, with no user-visible error.
        added = await _isTorrentPresent(request.infoHash);
        if (added) {
          AppLog.d(
            '[StreamingService] Torrent already present — continuing with '
            'the existing one rather than failing the session',
          );
        }
      }

      if (!added) {
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

  /// Whether qBittorrent already holds a torrent with this info hash.
  ///
  /// Used to tell a genuine add failure apart from a duplicate add, which
  /// qBittorrent also reports as a failure. Compared case-insensitively:
  /// qBittorrent lower-cases hashes, indexers don't always.
  Future<bool> _isTorrentPresent(String infoHash) async {
    try {
      final torrents = await _qbtService.getTorrents();
      final wanted = infoHash.toLowerCase();
      return torrents.any((t) => t.hash.toLowerCase() == wanted);
    } catch (e) {
      AppLog.e('[StreamingService] Could not check for existing torrent: $e');
      return false;
    }
  }

  /// Cancel a streaming session
  Future<void> cancelSession(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;

    AppLog.d('[StreamingService] Cancelling session $sessionId');

    // Stop monitoring
    _monitoringLoops.remove(sessionId)?.dispose();
    _bufferWatch.remove(sessionId);

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
    _monitoringLoops[sessionId]?.dispose();
    _monitoringLoops[sessionId] =
        PollLoop(
          name: 'stream:$sessionId',
          onTick: () => _checkSessionProgress(sessionId),
        )..start(
          pollingInterval,
          // Check immediately rather than making the first buffering update
          // wait a full interval.
          fireImmediately: true,
        );
  }

  /// Check progress of a streaming session
  Future<void> _checkSessionProgress(String sessionId) async {
    // Prevent concurrent checks for the same session
    if (_checkingProgress.contains(sessionId)) return;
    _checkingProgress.add(sessionId);

    final session = _sessions[sessionId];
    if (session == null || !session.isActive) {
      _monitoringLoops[sessionId]?.stop();
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
        final targetFilename = basenameOf(
          session.request.filename!,
        ).toLowerCase();
        final match = files.asMap().entries.firstWhereOrNull(
          (e) =>
              e.value.name.toLowerCase().contains(targetFilename) ||
              targetFilename.contains(basenameOf(e.value.name).toLowerCase()),
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

    // Fast path: the file we were asked for is already on disk. Judged on the
    // SELECTED FILE, not the torrent.
    //
    // `torrent.progress` is computed over *wanted* bytes, so a season pack
    // whose earlier episode finished reports 1.0 even though the episode being
    // asked for now was never fetched. Treating that as "ready" sent us
    // straight to _promoteToReady looking for a file that doesn't exist —
    // the silent failure for every episode after the first in a pack.
    final isAlreadyComplete = files[targetFileIndex].progress >= 0.999;

    if (!isAlreadyComplete) {
      // For season packs, disable all other files to save bandwidth. Only
      // worth doing while something still needs fetching: re-prioritising a
      // torrent whose target file is already complete can flip qBittorrent
      // into a recheck that briefly reports progress=0 on the file and never
      // recovers in the sync delta.
      if (session.request.isSeasonPack && files.length > 1) {
        AppLog.d(
          '[StreamingService] Disabling non-target files in season pack',
        );
        try {
          // Skip only incomplete extras. Zeroing already-finished episodes
          // can kick qBittorrent into a recheck and leaves sequential
          // download parked on pieces that will never be requested.
          final skipIds = [
            for (var i = 0; i < files.length; i++)
              if (i != targetFileIndex && files[i].progress < 0.999) i,
          ];
          if (skipIds.isNotEmpty) {
            await _qbtService.setFilePriority(torrent.hash, skipIds, 0);
          }
          await _qbtService.setFilePriority(torrent.hash, [targetFileIndex], 7);

          AppLog.d('[StreamingService] File priorities set successfully');
        } catch (e) {
          AppLog.e('[StreamingService] Error setting file priorities: $e');
        }
      }

      // A torrent that finished an earlier episode has been stopped — by the
      // user, or by `stopSeedingOnComplete` — and will never fetch the newly
      // wanted file while it stays that way.
      //
      // Deliberately after the priority change: re-prioritising drops
      // qBittorrent's wanted-bytes progress below 1.0, so the torrent no
      // longer looks completed and `_maybeAutoStopSeeding` won't simply stop
      // it again on its next poll.
      if (torrent.isPaused) {
        AppLog.d(
          '[StreamingService] Torrent is stopped (state=${torrent.state}) but '
          'the target file is incomplete — resuming',
        );
        try {
          await _qbtService.resumeTorrents([torrent.hash]);
        } catch (e) {
          AppLog.e('[StreamingService] Failed to resume torrent: $e');
        }
      }

      // Sequential is only set on addTorrent. Re-streaming a season pack
      // (E04 after E03) reuses the existing torrent — often with sequential
      // off from a prior seek — so pieces arrive randomly and the player
      // cannot open. Re-apply in-order download and bump the file's prefix.
      await _prepareInOrderDownload(
        torrent: torrent,
        files: files,
        targetFileIndex: targetFileIndex,
      );
    }

    // Surface a real percentage in the overlay even before buffering kicks
    // in — otherwise the user just sees "Preparing" with no progress.
    _updateSession(
      sessionId,
      state: StreamingState.buffering,
      selectedFileIndex: targetFileIndex,
      selectedFilePath: targetFilePath,
      bufferProgress: files[targetFileIndex].progress,
    );

    if (isAlreadyComplete) {
      AppLog.d(
        '[StreamingService] Selected file already complete '
        '(torrent state=${torrent.state}) — fast-pathing to ready.',
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
      _monitoringLoops[sessionId]?.stop();
      return;
    }

    String? streamUrl;
    // A finished file should be opened from disk. Feeding mpv a 2 GB HTTP
    // body makes it try (and fail) to create a demuxer file cache — the
    // "download finished but it still didn't play" case.
    final fileComplete = session.bufferProgress >= 0.999;
    if (!fileComplete) {
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
    } else {
      AppLog.d(
        '[StreamingService] File complete — opening ${videoFile.path} directly',
      );
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
    _monitoringLoops[sessionId]?.stop();
  }

  /// Handle buffering state for a streaming session.
  ///
  /// Readiness is a *contiguous prefix* of the selected file (piece states
  /// from the start), not overall file progress. 30% scattered across a
  /// season-pack episode still leaves mpv unable to parse the header.
  /// [assessBuffering] still drives stalled / too-slow give-up.
  Future<void> _handleBuffering(String sessionId, Torrent torrent) async {
    final session = _sessions[sessionId];
    if (session == null || session.selectedFileIndex == null) return;

    double fileProgress = 0;
    int fileSizeBytes = 0;

    try {
      final files = await _qbtService.getTorrentFiles(torrent.hash);
      if (session.selectedFileIndex! < files.length) {
        final selectedFile = files[session.selectedFileIndex!];
        fileProgress = selectedFile.progress;
        fileSizeBytes = selectedFile.size;
      }
    } catch (e) {
      AppLog.e('[StreamingService] Error getting file progress: $e');
    }

    final bufferedBytes = (fileSizeBytes * fileProgress).round();

    // What readiness ACTUALLY requires — a contiguous prefix, checked by
    // `_prefixIsPlayable` below — not the 80 MB pre-play floor this used to
    // pass. That floor is a superseded model: nothing waits for it any more,
    // so all it did was condemn a stream for failing to reach a threshold it
    // was never going to be asked to reach. On a 133 KB/s start the
    // projection said "11 minutes to 80 MB, give up" while the real
    // requirement was ~30 seconds away.
    const minBytes = LocalStreamingServer.prefixProbeBytes;

    AppLog.d(
      '[StreamingService] Buffer progress: ${(fileProgress * 100).toStringAsFixed(1)}% '
      '(${Formatters.formatBytesCompact(bufferedBytes)} / ${Formatters.formatBytesCompact(fileSizeBytes)}) '
      '[need ${Formatters.formatBytesCompact(LocalStreamingServer.prefixProbeBytes)} contiguous from start]',
    );

    _updateSession(sessionId, bufferProgress: fileProgress);

    final now = DateTime.now();
    final watch = _bufferWatch.putIfAbsent(
      sessionId,
      () => BufferWatch(session.createdAt),
    )..observe(bufferedBytes, now);

    final prefixReady = await _prefixIsPlayable(session, torrent);

    if (!prefixReady && !torrent.sequentialDownload) {
      AppLog.d(
        '[StreamingService] sequential is off while waiting for the file '
        'start — re-enabling',
      );
      await _qbtService.ensureInOrderDownload(torrent.hash);
    }

    // Completion short-circuit: if qBit reports the file fully done,
    // promote even if piece-state lookup failed.
    final torrentDone = torrent.isCompleted || torrent.progress >= 0.99;
    if (torrentDone && fileProgress >= 0.95) {
      if (prefixReady || fileProgress >= 0.999) {
        AppLog.d(
          '[StreamingService] Buffer ready (torrent complete)! '
          '${Formatters.formatBytesCompact(bufferedBytes)} buffered.',
        );
        await _promoteToReady(sessionId, torrent);
        return;
      }
    }

    if (prefixReady) {
      AppLog.d(
        '[StreamingService] Buffer ready (contiguous prefix)! '
        '${Formatters.formatBytesCompact(bufferedBytes)} on disk.',
      );
      await _promoteToReady(sessionId, torrent);
      return;
    }

    final outcome = assessBuffering(
      bufferedBytes: bufferedBytes,
      minBytes: minBytes,
      bytesPerSecond: watch.bytesPerSecond,
      sinceLastProgress: now.difference(watch.lastProgressAt),
      sinceStart: now.difference(watch.startedAt),
    );

    switch (outcome) {
      case BufferOutcome.ready:
        AppLog.d(
          '[StreamingService] ${Formatters.formatBytesCompact(bufferedBytes)} '
          'buffered but the start of the file is not contiguous yet — '
          'waiting for sequential pieces',
        );

      case BufferOutcome.waiting:
        break;

      case BufferOutcome.stalled:
        if (session.allowSlowBuffer) break;
        AppLog.w(
          '[StreamingService] Giving up — no bytes for '
          '${bufferStallWindow.inSeconds}s at '
          '${Formatters.formatBytesCompact(bufferedBytes)}',
        );
        _failBuffering(
          sessionId,
          'No peers for this source — nothing is downloading. Try another.',
        );

      case BufferOutcome.tooSlow:
        if (session.allowSlowBuffer) break;
        final rate = Formatters.formatSpeed(watch.bytesPerSecond.round());
        AppLog.w(
          '[StreamingService] Giving up — $rate is too slow to reach '
          '${Formatters.formatBytesCompact(minBytes)}',
        );
        _failBuffering(
          sessionId,
          'Too slow to stream ($rate). Download it instead, or pick another '
          'source.',
        );

      case BufferOutcome.gaveUp:
        // Deliberately NOT gated on allowSlowBuffer. A background prefetch
        // may be slow for as long as it likes, but it may not poll forever:
        // without this the 2 s monitoring timer outlived the app's use for
        // the session and never stopped.
        AppLog.w(
          '[StreamingService] Giving up — ${bufferHardCeiling.inMinutes} min '
          'elapsed at ${Formatters.formatBytesCompact(bufferedBytes)}',
        );
        _failBuffering(
          sessionId,
          'Gave up after ${bufferHardCeiling.inMinutes} minutes. '
          'Try another source.',
        );
    }
  }

  /// Sequential download + high priority on the selected file's leading
  /// pieces so mpv can open before the rest of the torrent arrives.
  Future<void> _prepareInOrderDownload({
    required Torrent torrent,
    required List<TorrentFile> files,
    required int targetFileIndex,
  }) async {
    try {
      final seqOk = await _qbtService.ensureInOrderDownload(
        torrent.hash,
        resetPicker: true,
      );
      AppLog.d(
        '[StreamingService] in-order download '
        '${seqOk ? "applied" : "failed"} for ${torrent.hash}',
      );
    } catch (e) {
      AppLog.e('[StreamingService] ensureInOrderDownload: $e');
    }

    var pieceSize = torrent.pieceSize;
    if (pieceSize <= 0) {
      pieceSize = await _qbtService.getPieceSize(torrent.hash);
    }
    final range = _pieceRangeFor(
      torrent,
      files,
      targetFileIndex,
      pieceSize: pieceSize,
    );
    if (range == null) {
      AppLog.d(
        '[StreamingService] no piece range for file $targetFileIndex — '
        'cannot prioritize prefix pieces',
      );
      return;
    }
    final ids = LocalStreamingServer.prefixPieceIds(
      firstPiece: range.$1,
      lastPiece: range.$2,
      pieceSize: pieceSize,
      minBytes: LocalStreamingServer.prefixProbeBytes,
    );
    if (ids.isEmpty) {
      AppLog.d(
        '[StreamingService] prefix piece ids empty '
        '(pieceSize=$pieceSize range=${range.$1}-${range.$2})',
      );
      return;
    }
    try {
      final ok = await _qbtService.setPiecePriority(torrent.hash, ids, 7);
      AppLog.d(
        '[StreamingService] prefix piece prio ${ok ? "set" : "failed"} '
        'for pieces ${ids.first}-${ids.last}',
      );
    } catch (e) {
      AppLog.e('[StreamingService] setPiecePriority: $e');
    }
  }

  (int first, int last)? _pieceRangeFor(
    Torrent torrent,
    List<TorrentFile> files,
    int fileIndex, {
    int pieceSize = 0,
  }) {
    if (fileIndex < 0 || fileIndex >= files.length) return null;
    final listed = files[fileIndex].pieceRange;
    if (listed != null && listed.length >= 2) {
      return (listed[0], listed[1]);
    }
    final size = pieceSize > 0 ? pieceSize : torrent.pieceSize;
    if (size <= 0) return null;
    return LocalStreamingServer.pieceRangeForFile(
      fileSizes: files.map((f) => f.size).toList(),
      fileIndex: fileIndex,
      pieceSize: size,
    );
  }

  /// True when the first piece of the selected file is fully downloaded —
  /// not merely that the on-disk magic bytes look like a container, which a
  /// half-written first piece can pass while the proxy still blocks at byte 0.
  Future<bool> _prefixIsPlayable(
    StreamingSession session,
    Torrent torrent,
  ) async {
    final idx = session.selectedFileIndex;
    if (idx == null) return false;
    try {
      final files = await _qbtService.getTorrentFiles(torrent.hash);
      if (idx < 0 || idx >= files.length) return false;
      if (files[idx].progress >= 0.999) return true;

      var pieceSize = torrent.pieceSize;
      if (pieceSize <= 0) {
        pieceSize = await _qbtService.getPieceSize(torrent.hash);
      }
      final range = _pieceRangeFor(torrent, files, idx, pieceSize: pieceSize);
      if (range == null) {
        AppLog.d('[StreamingService] prefix: no piece range for file $idx');
        return false;
      }

      final states = await _qbtService.getPieceStates(torrent.hash);
      if (states == null || states.isEmpty) {
        AppLog.d('[StreamingService] prefix: no piece states');
        return false;
      }

      final ready = LocalStreamingServer.prefixPiecesReady(
        pieceStates: states,
        firstPiece: range.$1,
        lastPiece: range.$2,
      );
      if (!ready) {
        final first = range.$1;
        final firstState = (first >= 0 && first < states.length)
            ? states[first]
            : -1;
        AppLog.d(
          '[StreamingService] prefix not ready: pieceSize=$pieceSize '
          'range=${range.$1}-${range.$2} firstState=$firstState '
          'seq=${torrent.sequentialDownload}',
        );
      }
      return ready;
    } catch (e) {
      AppLog.d('[StreamingService] prefix check failed: $e');
      return false;
    }
  }

  void _failBuffering(String sessionId, String message) {
    _updateSession(
      sessionId,
      state: StreamingState.error,
      errorMessage: message,
    );
    _monitoringLoops[sessionId]?.stop();
    _bufferWatch.remove(sessionId);
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
          // basenameOf, not p.basename: this string comes from qBittorrent
          // and may carry Windows separators whatever host we're on. The
          // p.basename calls below are on real local paths, where the host
          // separator is the right one.
          final selectedFileName = basenameOf(session.selectedFilePath!);
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
    for (final loop in _monitoringLoops.values) {
      loop.dispose();
    }
    _monitoringLoops.clear();
    _bufferWatch.clear();

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
