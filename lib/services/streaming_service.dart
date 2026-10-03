import 'dart:async';

import 'package:collection/collection.dart';

import '../models/stream_request.dart';
import '../models/streaming_session.dart';
import '../models/torrent.dart';
import '../models/torrent_file.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import '../utils/poll_loop.dart';
import 'app_logger.dart';
import 'local_streaming_server.dart';
import 'piece_geometry.dart';
import 'streaming/buffer_policy.dart';
import 'streaming/file_selection.dart';
import 'streaming/video_file_locator.dart';
import 'torrent_engine.dart';

// Re-exported so callers keep importing the session types from the
// service that produces them, rather than tracking a second path.
export '../models/streaming_session.dart';
export 'streaming/buffer_policy.dart';

/// Where the player should read the video from.
enum StreamSource {
  /// Straight off disk. The file is finished, so there is nothing to wait for
  /// — and handing mpv a multi-gigabyte HTTP body makes it try, and fail, to
  /// build a demuxer file cache. That was the "download finished but it still
  /// didn't play" case.
  disk,

  /// The engine's own HTTP endpoint. It serves the file while downloading,
  /// honours Range, and blocks on missing pieces instead of answering zeros.
  engine,

  /// A local proxy in front of a partially-written file, for a backend that
  /// only downloads. See [LocalStreamingServer].
  proxy,
}

/// Everything about one session that is not part of what listeners see.
class _SessionTracking {
  _SessionTracking({required this.addedTorrent});

  /// Whether this session added the torrent, rather than finding it already
  /// in the engine. Decides whether it may deselect the torrent's other
  /// files — see [mayTrimTorrent].
  final bool addedTorrent;

  PollLoop? loop;
  BufferWatch? buffer;

  /// Consecutive polls that could not confirm the torrent's metadata — the
  /// torrent not listed yet, or listed with no files.
  int metadataMisses = 0;

  /// When the engine first failed to answer, in the current run of failures.
  DateTime? engineSilentSince;

  /// Where the selected file sits in the torrent's pieces; fixed once known.
  int pieceSize = 0;
  FilePieceMap? pieceMap;
}

/// Runs streaming sessions: adds the torrent, waits for its metadata, picks
/// the file, buffers until the start of it can be played, and hands the
/// player a source.
///
///  1. Add the torrent with streaming-friendly settings.
///  2. Wait for its metadata and file list ([metadataTimeout]).
///  3. Pick the file — the indexer's index, its file name, the episode code,
///     or the largest video — and, for a season pack, stop the rest.
///  4. Buffer until the head of the file is down ([BufferPolicy] decides when
///     waiting stops being worth it).
///  5. Go ready with the right [StreamSource].
///
/// Based on Stremio's approach to torrent streaming.
class StreamingService {
  StreamingService(
    this._engine, {
    this.metadataTimeout = defaultMetadataTimeout,
    this.engineSilenceLimit = defaultEngineSilenceLimit,
    this.pollingInterval = defaultPollingInterval,
  });

  final TorrentEngine _engine;

  /// How long a session may go without the torrent's file list before it is
  /// given up as dead — a magnet nobody is seeding never delivers metadata.
  final Duration metadataTimeout;

  /// How long the engine may go without answering before a session gives
  /// up. Long enough for its health check to notice a crash and restart it.
  final Duration engineSilenceLimit;

  /// How often a session is checked while it gets ready.
  final Duration pollingInterval;

  final Map<String, StreamingSession> _sessions = {};
  final Map<String, _SessionTracking> _tracking = {};
  final Map<String, StreamController<StreamingSession>> _sessionControllers =
      {};

  /// Local HTTP proxy keyed by session id. Started when a session reaches
  /// [StreamingState.ready] on a downloader engine, and torn down on
  /// cancel/dispose. mpv reads from the proxy URL instead of the on-disk file
  /// so it doesn't choke on the zero-padded regions the engine leaves for
  /// un-downloaded bytes.
  final Map<String, LocalStreamingServer> _streamingServers = {};

  static const Duration defaultMetadataTimeout = Duration(minutes: 2);
  static const Duration defaultEngineSilenceLimit = Duration(seconds: 30);
  static const Duration defaultPollingInterval = Duration(seconds: 2);

  /// Polls in a row that must find no metadata before [metadataTimeout] may
  /// end a session. One unlucky poll is not evidence.
  static const int metadataMissTolerance = 3;

  /// Get a stream of session updates for a specific session
  Stream<StreamingSession>? getSessionStream(String sessionId) {
    return _sessionControllers[sessionId]?.stream;
  }

  /// Get a specific session by ID
  StreamingSession? getSession(String sessionId) => _sessions[sessionId];

  bool _isLive(String sessionId) => _sessions[sessionId]?.isActive ?? false;

  /// Start a streaming session from a normalised [StreamRequest].
  ///
  /// For single-file torrents: downloads the single file with streaming
  /// optimisation. For season packs: deprioritises the other episodes, so a
  /// 40 GB pack doesn't get pulled to watch one.
  ///
  /// This is the single implementation of the streaming workflow; the
  /// next-episode / binge flow routes through here too.
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
    final sessionId =
        '${request.infoHash}_${DateTime.now().millisecondsSinceEpoch}';

    final initial = StreamingSession(
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
    _sessions[sessionId] = initial;
    // What to hand back if the session is cancelled before this returns.
    final cancelled = initial.copyWith(state: StreamingState.cancelled);
    _sessionControllers[sessionId] =
        StreamController<StreamingSession>.broadcast();
    _notifySession(sessionId);

    AppLog.i(
      '[StreamingService] Starting session $sessionId — '
      '${request.displayName} (single file: ${request.isSingleFile}, '
      'fileIdx: ${request.fileIdx}, filename: ${request.filename})',
    );

    try {
      // Was it there before us? Only then may this session trim it.
      final present = await _engine.tryGetTorrents(hashes: [request.infoHash]);
      final addedBySession = present != null && present.isEmpty;

      var added = await _engine.addTorrent(
        magnetLink: request.magnetUri,
        savePath: savePath,
        sequentialDownload: true,
      );
      if (!added) {
        // qBittorrent reports a duplicate add as a failure ("Fails." on 4.x,
        // 4xx on 5.x) — but for us it isn't one: the torrent we want is
        // already there. This is the normal case for the second episode of a
        // season pack.
        added = await _isTorrentPresent(request.infoHash);
        if (added) {
          AppLog.d(
            '[StreamingService] Torrent already present — continuing with '
            'the existing one',
          );
        }
      }
      if (!_isLive(sessionId)) return _sessions[sessionId] ?? cancelled;

      if (!added) {
        _fail(
          sessionId,
          "Couldn't add this torrent to the engine. Try another source.",
        );
        return _sessions[sessionId]!;
      }

      _tracking[sessionId] = _SessionTracking(addedTorrent: addedBySession);
      _updateSession(
        sessionId,
        (s) => s.copyWith(
          torrentHash: request.infoHash,
          state: StreamingState.selectingFiles,
        ),
      );
      _startMonitoring(sessionId);
      return _sessions[sessionId]!;
    } catch (e) {
      AppLog.e('[StreamingService] Error starting streaming: $e');
      if (_isLive(sessionId)) {
        _fail(
          sessionId,
          'Something went wrong starting the stream. Try again.',
        );
      }
      return _sessions[sessionId] ?? cancelled;
    }
  }

  /// Whether the engine already holds a torrent with this info hash.
  ///
  /// Used to tell a genuine add failure apart from a duplicate add, which
  /// qBittorrent also reports as a failure. Compared case-insensitively:
  /// engines lower-case hashes, indexers don't always.
  Future<bool> _isTorrentPresent(String infoHash) async {
    final torrents = await _engine.tryGetTorrents(hashes: [infoHash]);
    final wanted = infoHash.toLowerCase();
    return torrents?.any((t) => t.hash.toLowerCase() == wanted) ?? false;
  }

  /// Cancel a streaming session
  Future<void> cancelSession(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;

    AppLog.d('[StreamingService] Cancelling session $sessionId');

    _tracking.remove(sessionId)?.loop?.dispose();

    // Tear down the local HTTP proxy if one was started for this session.
    await _streamingServers.remove(sessionId)?.stop();

    _updateSession(
      sessionId,
      (s) => s.copyWith(state: StreamingState.cancelled),
    );

    await _sessionControllers.remove(sessionId)?.close();
    _sessions.remove(sessionId);
  }

  /// Start monitoring a session for file selection and buffering
  void _startMonitoring(String sessionId) {
    final tracking = _tracking[sessionId];
    if (tracking == null) return;
    tracking.loop?.dispose();
    tracking.loop =
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

  /// One monitoring tick.
  Future<void> _checkSessionProgress(String sessionId) async {
    final session = _sessions[sessionId];
    final tracking = _tracking[sessionId];
    if (session == null || !session.isActive || tracking == null) {
      tracking?.loop?.stop();
      return;
    }

    final torrents = await _engine.tryGetTorrents(
      hashes: [session.request.infoHash],
    );
    if (!_isLive(sessionId)) return;
    if (torrents == null) {
      _engineSilent(sessionId, tracking);
      return;
    }
    tracking.engineSilentSince = null;

    final wanted = session.request.infoHash.toLowerCase();
    final torrent = torrents.firstWhereOrNull(
      (t) => t.hash.toLowerCase() == wanted,
    );
    if (torrent == null) {
      _torrentMissing(sessionId, session, tracking);
      return;
    }

    // Heartbeat: refresh content path AND progress on every poll so the
    // listener sees forward motion during the metadata → file-selection
    // phases, even when state itself hasn't changed yet.
    _updateSession(
      sessionId,
      (s) => s.copyWith(
        contentPath: torrent.contentPath,
        bufferProgress: torrent.progress,
        downloadRateBytesPerSec: torrent.dlspeed,
      ),
    );

    switch (session.state) {
      case StreamingState.addingTorrent:
      case StreamingState.selectingFiles:
        await _handleFileSelection(sessionId, torrent);
      case StreamingState.buffering:
        await _handleBuffering(sessionId, torrent);
      default:
        break;
    }
  }

  /// The engine did not answer this poll. A short silence is a restart or a
  /// busy moment; a long one ends the session. One failed poll used to be
  /// read as "the torrent is gone" and could fail a healthy session.
  void _engineSilent(String sessionId, _SessionTracking tracking) {
    final since = tracking.engineSilentSince ??= DateTime.now();
    if (DateTime.now().difference(since) < engineSilenceLimit) {
      _updateSession(sessionId, (s) => s.copyWith()); // heartbeat
      return;
    }
    AppLog.w(
      '[StreamingService] Giving up — the engine has not answered for '
      '${engineSilenceLimit.inSeconds}s',
    );
    _fail(
      sessionId,
      'The torrent engine stopped responding. Try again in a moment.',
    );
  }

  /// The engine answered, but without this torrent.
  void _torrentMissing(
    String sessionId,
    StreamingSession session,
    _SessionTracking tracking,
  ) {
    tracking.metadataMisses++;
    if (session.state == StreamingState.buffering) {
      // It was there and has gone: removed in Transfers, most likely.
      if (tracking.metadataMisses >= metadataMissTolerance) {
        _fail(sessionId, 'This download was removed from Transfers.');
      }
      return;
    }
    _metadataMiss(sessionId, session, tracking, counted: true);
  }

  /// No metadata yet. Fails the session once [metadataTimeout] has passed
  /// *and* the last [metadataMissTolerance] polls all came up empty.
  void _metadataMiss(
    String sessionId,
    StreamingSession session,
    _SessionTracking tracking, {
    bool counted = false,
  }) {
    if (!counted) tracking.metadataMisses++;
    // Heartbeat so the overlay does not look frozen while metadata arrives,
    // which can take 30+ s on a low-peer torrent.
    _updateSession(sessionId, (s) => s.copyWith(bufferProgress: 0));
    final age = DateTime.now().difference(session.createdAt);
    if (age >= metadataTimeout &&
        tracking.metadataMisses >= metadataMissTolerance) {
      AppLog.w(
        '[StreamingService] Giving up — no metadata after '
        '${age.inSeconds}s',
      );
      _fail(
        sessionId,
        "Couldn't get this torrent's details — it may have no peers. "
        'Try another source.',
      );
    }
  }

  /// Pick the file to stream and point the engine at it.
  Future<void> _handleFileSelection(String sessionId, Torrent torrent) async {
    final files = await _engine.tryGetTorrentFiles(torrent.hash);
    final session = _sessions[sessionId];
    final tracking = _tracking[sessionId];
    if (session == null || !session.isActive || tracking == null) return;
    if (files == null) {
      _engineSilent(sessionId, tracking);
      return;
    }
    if (files.isEmpty) {
      AppLog.d('[StreamingService] No files yet, waiting for metadata…');
      _metadataMiss(sessionId, session, tracking);
      return;
    }
    tracking.metadataMisses = 0;

    final target = selectStreamFile(
      request: session.request,
      files: files,
      season: session.season,
      episode: session.episode,
    );
    if (target == null) {
      _fail(
        sessionId,
        'This torrent has no video file to play. Try another source.',
      );
      return;
    }
    final file = files[target];
    AppLog.i(
      '[StreamingService] Selected file $target of ${files.length}: '
      '${file.name}',
    );

    // Judged on the SELECTED FILE, not the torrent: a season pack whose
    // earlier episode finished reports the torrent complete while the episode
    // asked for now was never fetched.
    if (!file.isComplete) {
      await _focusOn(sessionId, torrent, files, target);
      if (!_isLive(sessionId)) return;
    }

    _updateSession(
      sessionId,
      (s) => s.copyWith(
        state: StreamingState.buffering,
        selectedFileIndex: target,
        selectedFilePath: file.name,
        bufferProgress: file.progress,
      ),
    );

    // Same-poll buffer check — if the file already has enough bytes there is
    // no reason to wait a full 2 s for the next poll to discover it.
    await _handleBuffering(sessionId, torrent, files: files);
  }

  /// Point the engine at [target]: select it, stop the rest of a season pack
  /// (unless another session is playing them), resume the torrent if it was
  /// stopped, and make it download in order.
  Future<void> _focusOn(
    String sessionId,
    Torrent torrent,
    List<TorrentFile> files,
    int target,
  ) async {
    final session = _sessions[sessionId];
    final tracking = _tracking[sessionId];
    if (session == null || tracking == null) return;

    if (session.request.isSeasonPack && files.length > 1) {
      // Select the target first. rqbit refuses a selection with nothing in
      // it, so deselecting first could leave nothing selected and be refused
      // — and the episode from an abandoned session kept downloading.
      await _engine.setFilePriority(torrent.hash, [
        target,
      ], FilePriority.maximum.value);
      if (!_isLive(sessionId)) return;

      if (mayTrimTorrent(addedBySession: tracking.addedTorrent, files: files)) {
        final skip = filesToDeselect(
          files: files,
          target: target,
          protectedIndexes: _filesPlayingElsewhere(torrent.hash, sessionId),
        );
        if (skip.isNotEmpty) {
          AppLog.d(
            '[StreamingService] Deselecting ${skip.length} other files of '
            'the pack',
          );
          await _engine.setFilePriority(
            torrent.hash,
            skip,
            FilePriority.doNotDownload.value,
          );
          if (!_isLive(sessionId)) return;
        }
      } else {
        AppLog.d(
          '[StreamingService] The whole pack was queued before this session '
          '— leaving its other files alone',
        );
      }
    }

    // A torrent that finished an earlier episode may have been stopped — by
    // the user, or by the stop-seeding setting — and will never fetch the
    // newly wanted file while it stays that way. Deliberately after the
    // priority change: that drops the torrent's progress below 100%, so the
    // auto-stop does not simply stop it again on its next poll.
    if (torrent.isPaused) {
      AppLog.d(
        '[StreamingService] Torrent is stopped (state=${torrent.state}) but '
        'the target file is incomplete — resuming',
      );
      await _engine.resumeTorrents([torrent.hash]);
      if (!_isLive(sessionId)) return;
    }

    // Sequential is only set on add. Re-streaming a season pack (E04 after
    // E03) reuses the existing torrent — possibly with sequential off — so
    // pieces would arrive randomly and the player could not open.
    if (_engine.capabilities.pieceLevelControl) {
      final ok = await _engine.ensureInOrderDownload(
        torrent.hash,
        resetPicker: true,
      );
      AppLog.d(
        '[StreamingService] in-order download '
        '${ok ? "applied" : "failed"} for ${torrent.hash}',
      );
    }
  }

  /// Files of torrent [hash] that other live sessions are playing.
  Set<int> _filesPlayingElsewhere(String hash, String exceptSession) {
    final wanted = hash.toLowerCase();
    return {
      for (final entry in _sessions.entries)
        if (entry.key != exceptSession &&
            entry.value.isActive &&
            entry.value.request.infoHash.toLowerCase() == wanted &&
            entry.value.selectedFileIndex != null)
          entry.value.selectedFileIndex!,
    };
  }

  /// Which of the three ways to reach the bytes applies right now.
  ///
  /// Pure and static because it is the decision this whole phase turns on,
  /// and because the disk case is easy to lose: it is checked *before* the
  /// engine is asked, since a finished file should not be served over HTTP by
  /// anyone.
  static StreamSource chooseStreamSource({
    required bool fileComplete,
    required String? engineUrl,
  }) {
    if (fileComplete) return StreamSource.disk;
    return engineUrl != null ? StreamSource.engine : StreamSource.proxy;
  }

  /// Find the file, stand up the source the player will read, and go ready.
  ///
  /// Re-checks after every await that the session is still live: a cancel
  /// that lands while the file is being located or the proxy is starting
  /// used to leave a listening server behind with nothing to stop it.
  Future<void> _promoteToReady(
    String sessionId,
    Torrent torrent,
    List<TorrentFile> files,
  ) async {
    final session = _sessions[sessionId];
    final idx = session?.selectedFileIndex;
    if (session == null || !session.isActive || idx == null) return;
    if (idx < 0 || idx >= files.length) return;
    final file = files[idx];

    final located = await locateTorrentFile(
      savePath: torrent.savePath,
      contentPath: torrent.contentPath,
      nameInTorrent: file.name,
      showName: session.showName,
      season: session.season,
      episode: session.episode,
      torrentHash: torrent.hash,
    );
    if (!_isLive(sessionId)) return;

    final engineUrl = _engine.streamUrl(torrent.hash, idx);
    final source = chooseStreamSource(
      fileComplete: file.isComplete,
      engineUrl: engineUrl,
    );

    // The engine serves its own stream and may not have created the file
    // yet. Every other source reads the file itself.
    if (source != StreamSource.engine && !located.exists) {
      AppLog.w(
        '[StreamingService] Video file not on disk: ${located.file.path}',
      );
      _fail(sessionId, "Couldn't find the video file on disk. Try again.");
      return;
    }

    String? streamUrl;
    switch (source) {
      case StreamSource.disk:
        AppLog.i(
          '[StreamingService] File complete — opening '
          '${located.file.path} directly',
        );

      case StreamSource.engine:
        // No proxy on this path. Drop any left over from an earlier
        // promotion of the same session.
        await _streamingServers.remove(sessionId)?.stop();
        if (!_isLive(sessionId)) return;
        streamUrl = engineUrl;
        AppLog.i('[StreamingService] Engine stream URL: $streamUrl');

      case StreamSource.proxy:
        // The downloader path: the file is pre-allocated and its gaps read
        // back as zeros, so something has to serve only the bytes that are
        // really there. If that cannot start, the session fails: playing the
        // file directly instead hands mpv those zeros.
        final server = LocalStreamingServer(
          engine: _engine,
          filePath: located.file.path,
          torrentHash: torrent.hash,
          fileIndex: idx,
          logTag: _proxyTag(session),
        );
        try {
          await server.start();
        } catch (e) {
          AppLog.e('[StreamingService] Failed to start local proxy: $e');
          await server.stop();
          if (_isLive(sessionId)) {
            _fail(sessionId, "Couldn't start the video stream. Try again.");
          }
          return;
        }
        if (!_isLive(sessionId)) {
          await server.stop();
          return;
        }
        await _streamingServers[sessionId]?.stop();
        _streamingServers[sessionId] = server;
        streamUrl = server.url;
        AppLog.i('[StreamingService] Local proxy URL: $streamUrl');
    }

    _updateSession(
      sessionId,
      (s) => s.copyWith(
        state: StreamingState.ready,
        videoFile: located.file,
        streamUrl: streamUrl,
        bufferProgress: 1.0,
      ),
    );

    // Stop readiness monitoring. The player tracks the download edge while
    // playback continues.
    _tracking[sessionId]?.loop?.stop();
  }

  /// Distinguishes concurrent proxies in the log: the session being watched
  /// from the next episode being prefetched behind it.
  static String _proxyTag(StreamingSession session) {
    final role = session.allowSlowBuffer ? 'next' : 'main';
    final what = session.episodeCode;
    return what == null ? role : '$role $what';
  }

  /// Buffering: wait for the head of the selected file, give up when
  /// [BufferPolicy] says so.
  ///
  /// Readiness is a *contiguous head* of the selected file, read from the
  /// piece map — not overall progress: 30% scattered across a season-pack
  /// episode still leaves mpv unable to parse the header.
  Future<void> _handleBuffering(
    String sessionId,
    Torrent torrent, {
    List<TorrentFile>? files,
  }) async {
    final fileList = files ?? await _engine.tryGetTorrentFiles(torrent.hash);
    final session = _sessions[sessionId];
    final tracking = _tracking[sessionId];
    final idx = session?.selectedFileIndex;
    if (session == null || !session.isActive || tracking == null) return;
    if (idx == null) return;
    if (fileList == null) {
      _engineSilent(sessionId, tracking);
      return;
    }
    if (idx < 0 || idx >= fileList.length) return;

    final file = fileList[idx];
    final bufferedBytes = (file.size * file.progress).round();
    _updateSession(sessionId, (s) => s.copyWith(bufferProgress: file.progress));

    final now = DateTime.now();
    final watch = tracking.buffer ??= BufferWatch(session.createdAt);
    watch.observe(bufferedBytes, now);

    if (file.isComplete) {
      AppLog.i('[StreamingService] File complete — ready');
      await _promoteToReady(sessionId, torrent, fileList);
      return;
    }

    final headReady = await _headIsPlayable(tracking, torrent, fileList, idx);
    if (!_isLive(sessionId)) return;
    if (headReady) {
      AppLog.i(
        '[StreamingService] Buffer ready (start of the file is down, '
        '${Formatters.formatBytesCompact(bufferedBytes)} on disk)',
      );
      await _promoteToReady(sessionId, torrent, fileList);
      return;
    }

    if (!torrent.sequentialDownload && _engine.capabilities.pieceLevelControl) {
      AppLog.d(
        '[StreamingService] sequential is off while waiting for the file '
        'start — re-enabling',
      );
      await _engine.ensureInOrderDownload(torrent.hash);
      if (!_isLive(sessionId)) return;
    }

    // What readiness needs is a contiguous head; the projection only asks
    // whether enough bytes to probe the file will arrive in reasonable time.
    const minBytes = LocalStreamingServer.prefixProbeBytes;
    final outcome = BufferPolicy.assess(
      bufferedBytes: bufferedBytes,
      minBytes: minBytes,
      bytesPerSecond: watch.bytesPerSecond,
      sinceLastProgress: now.difference(watch.lastProgressAt),
      sinceStart: now.difference(watch.startedAt),
    );

    switch (outcome) {
      case BufferOutcome.waiting:
        AppLog.d(
          '[StreamingService] Buffering '
          '${(file.progress * 100).toStringAsFixed(1)}% '
          '(${Formatters.formatBytesCompact(bufferedBytes)} of '
          '${Formatters.formatBytesCompact(file.size)}) — waiting for the '
          'start of the file',
        );

      case BufferOutcome.stalled:
        if (session.allowSlowBuffer) break;
        AppLog.w(
          '[StreamingService] Giving up — no bytes for '
          '${BufferPolicy.stallWindow.inSeconds}s at '
          '${Formatters.formatBytesCompact(bufferedBytes)}',
        );
        _fail(
          sessionId,
          'Nothing is downloading from this source. Try another one.',
        );

      case BufferOutcome.tooSlow:
        if (session.allowSlowBuffer) break;
        final rate = Formatters.formatSpeed(watch.bytesPerSecond.round());
        AppLog.w(
          '[StreamingService] Giving up — $rate is too slow to reach '
          '${Formatters.formatBytesCompact(minBytes)}',
        );
        _fail(
          sessionId,
          'Too slow to stream ($rate). Download it instead, or pick another '
          'source.',
        );

      case BufferOutcome.gaveUp:
        // Deliberately NOT gated on allowSlowBuffer. A background prefetch
        // may be slow for as long as it likes, but it may not poll forever.
        AppLog.w(
          '[StreamingService] Giving up — '
          '${BufferPolicy.hardCeiling.inMinutes} min elapsed at '
          '${Formatters.formatBytesCompact(bufferedBytes)}',
        );
        _fail(
          sessionId,
          'Still not ready after ${BufferPolicy.hardCeiling.inMinutes} '
          'minutes. Try another source.',
        );
    }
  }

  /// True when the first piece's worth of the selected file is downloaded —
  /// the bytes mpv probes to open it.
  ///
  /// Through the file's real offset in the torrent ([FilePieceMap]): for a
  /// season-pack episode that starts partway into its first piece, "the first
  /// piece is done" covers only a sliver of the file.
  Future<bool> _headIsPlayable(
    _SessionTracking tracking,
    Torrent torrent,
    List<TorrentFile> files,
    int idx,
  ) async {
    if (files[idx].isComplete) return true;

    if (tracking.pieceSize <= 0) {
      tracking.pieceSize = torrent.pieceSize > 0
          ? torrent.pieceSize
          : await _engine.getPieceSize(torrent.hash);
    }
    if (tracking.pieceSize <= 0) {
      AppLog.d('[StreamingService] head check: piece size not known yet');
      return false;
    }
    final map = tracking.pieceMap ??= PieceGeometry.forFile(
      files: files,
      fileIndex: idx,
      pieceSize: tracking.pieceSize,
    );
    if (map == null) return false;

    final states = await _engine.getPieceStates(torrent.hash);
    if (states == null || states.isEmpty) {
      AppLog.d('[StreamingService] head check: no piece states');
      return false;
    }
    final ready = map.headReady(states, bytes: map.pieceSize);
    if (!ready) {
      AppLog.d(
        '[StreamingService] head not ready: $map, first '
        '${map.firstUnavailableFrom(0, states)} bytes down, '
        'seq=${torrent.sequentialDownload}',
      );
    }
    return ready;
  }

  void _fail(String sessionId, String message) {
    AppLog.w('[StreamingService] Session $sessionId failed: $message');
    _updateSession(
      sessionId,
      (s) => s.copyWith(state: StreamingState.error, errorMessage: message),
    );
    final tracking = _tracking[sessionId];
    tracking?.loop?.stop();
    tracking?.buffer = null;
  }

  /// Apply [change] to a session and notify listeners.
  ///
  /// Takes the change as a function of the session rather than mirroring
  /// every [StreamingSession.copyWith] parameter, so a new session field needs
  /// adding in one place.
  void _updateSession(
    String sessionId,
    StreamingSession Function(StreamingSession session) change,
  ) {
    final session = _sessions[sessionId];
    if (session == null) return;
    _sessions[sessionId] = change(session);
    _notifySession(sessionId);
  }

  /// Notify listeners of a session update
  void _notifySession(String sessionId) {
    final session = _sessions[sessionId];
    if (session == null) return;
    if (_sessionControllers[sessionId]?.isClosed ?? true) return;
    _sessionControllers[sessionId]!.add(session);
  }

  /// Dispose all resources
  void dispose() {
    for (final tracking in _tracking.values) {
      tracking.loop?.dispose();
    }
    _tracking.clear();

    for (final server in _streamingServers.values) {
      // Fire-and-forget — dispose is sync and the server cleans up its own
      // sockets internally.
      unawaited(server.stop());
    }
    _streamingServers.clear();

    for (final controller in _sessionControllers.values) {
      unawaited(controller.close());
    }
    _sessionControllers.clear();

    _sessions.clear();
  }
}
