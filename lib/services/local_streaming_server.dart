import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'qbittorrent_api_service.dart';
import 'app_logger.dart';

/// Outcome of parsing a `Range:` request header against a known file size.
///
/// When [satisfiable] is false the caller must answer 416 and ignore
/// [start]/[end]. When true, `0 <= start <= end <= size - 1` holds and the
/// body length is `end - start + 1`.
@immutable
class ParsedByteRange {
  const ParsedByteRange({
    required this.start,
    required this.end,
    required this.partial,
    required this.satisfiable,
    this.openEnded = false,
  });

  final int start;
  final int end;

  /// True when the client sent a usable `bytes=` range, so the reply is a
  /// 206 with a `Content-Range` rather than a plain 200.
  final bool partial;

  final bool satisfiable;

  /// True when the client wrote `bytes=N-` with no explicit end — i.e. "give
  /// me the rest of the resource". [end] is then a default (end-of-file)
  /// rather than something the client actually asked for, which is what makes
  /// it safe to shorten. See [LocalStreamingServer.clampOpenEndedEnd].
  final bool openEnded;
}

/// Local HTTP server that fronts a partially-downloaded torrent file for the
/// video player.
///
/// Why this exists: qBittorrent pre-allocates the full file on disk and the
/// not-yet-downloaded regions read back as zero bytes. When mpv reads those
/// zeros directly off disk, the demuxer treats them as garbage video data
/// (`Invalid NAL unit size`, `Error splitting the input into NAL units`) and
/// freezes — which is why opening the file path directly leaves the player
/// stuck on the spinner until the download finishes. With an HTTP layer in
/// between, we serve only the bytes that are *actually* downloaded and hold
/// the response open while the rest catches up. mpv then runs in its
/// well-tested network-stream mode, where `paused-for-cache` is the right
/// behaviour and clears as soon as bytes arrive.
///
/// **Piece-aware reads.** qBittorrent's "sequential download" mode is a
/// best-effort hint, not a guarantee — and once the user seeks past the head
/// we deliberately disable it (see `video_player_screen.dart`) so the piece
/// picker can pull pieces around the seek target. Either way, "downloaded
/// bytes" cannot be modelled as a single contiguous front. We query
/// `pieceStates` from qBittorrent and serve each request only up to the
/// first missing piece on or after the read position; missing pieces block
/// (with a stall ceiling) until they land. mpv's cache-pause-wait absorbs
/// the gaps.
///
/// This is the same pattern peerflix / WebTorrent / Stremio use.
class LocalStreamingServer {
  final QBittorrentApiService _qbt;
  final String filePath;
  final String torrentHash;
  final int fileIndex;

  /// Optional prefix appended to the `[LocalStreamingServer]` tag in logs —
  /// lets callers distinguish concurrent instances (e.g. the auto-next-episode
  /// proxy vs. the main session proxy).
  final String _logTag;

  /// How long to wait between piece-state polls when the requested byte is
  /// past a missing piece. Short enough that mpv doesn't time out, long
  /// enough not to hammer qBittorrent's API.
  static const Duration _waitInterval = Duration(milliseconds: 400);

  /// Cache window for piece states + file metadata. Multiple in-flight
  /// chunk reads share the same fetched state to keep API calls bounded.
  static const Duration _pieceStateCacheTtl = Duration(milliseconds: 500);

  /// Read-block size sent to mpv. Smaller chunks mean lower latency between
  /// download progress and what mpv actually sees, at the cost of slightly
  /// more syscalls.
  static const int _chunkSize = 256 * 1024; // 256 KB

  /// MKV/MP4 container indices live near the end of the file (Cues element
  /// for MKV, moov-at-end for some MP4s). On open, mpv probes that region —
  /// and on a partially-downloaded torrent it never arrives. Replying 416
  /// when the request lands in this tail window AND the bytes aren't yet
  /// downloaded lets mpv skip the optional read and proceed.
  ///
  /// A *user seek* into the unbuffered middle of the file does NOT land
  /// here, so we fall through to the blocking-read path for those — that's
  /// what makes "drag the seek bar past the download edge" eventually
  /// re-buffer instead of dying with a 416.
  static const int _tailProbeWindow = 64 * 1024 * 1024; // 64 MB

  /// Smallest run of available bytes worth answering an open-ended request
  /// with. Below this we block instead, so a barely-started file doesn't turn
  /// one request into a rapid series of near-empty ones. See
  /// [clampOpenEndedEnd].
  @visibleForTesting
  static const int minClampedChunk = 4 * 1024 * 1024; // 4 MB

  /// If we're blocking on a missing piece and qBittorrent's overall download
  /// progress on this file doesn't advance at all for this long, give up
  /// and close the connection. Without this, a hopeless seek (e.g. way past
  /// head while qBittorrent is paused or stuck on rare pieces) would tie
  /// up an HTTP socket forever.
  static const Duration _stallTimeout = Duration(minutes: 5);

  HttpServer? _server;
  final Set<HttpRequest> _activeRequests = {};

  // File metadata — all resolved on first request, then cached for the
  // server's lifetime (immutable post-add).
  int? _fileSize;
  int? _pieceSize; // bytes per piece (torrent-level)
  int? _pieceFirst; // first piece index covering this file
  int? _pieceLast; // last piece index covering this file

  // Mutable: piece states + per-file progress, refreshed per TTL.
  List<int>? _cachedPieceStates;
  double _cachedProgress = 0;
  DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _stopped = false;

  LocalStreamingServer({
    required QBittorrentApiService qbt,
    required this.filePath,
    required this.torrentHash,
    required this.fileIndex,
    String? logTag,
  }) : _qbt = qbt,
       _logTag = logTag == null
           ? 'LocalStreamingServer'
           : 'LocalStreamingServer:$logTag';

  /// HTTP URL the player should open. Available only after [start].
  String get url {
    final port = _server?.port;
    if (port == null) {
      throw StateError('LocalStreamingServer.start() not called yet');
    }
    final encoded = Uri.encodeComponent(p.basename(filePath));
    return 'http://127.0.0.1:$port/stream/$encoded';
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    AppLog.d(
      '[$_logTag] listening on 127.0.0.1:${_server!.port} '
      'for ${p.basename(filePath)}',
    );

    _server!.listen(
      _handleRequest,
      onError: (e) {
        AppLog.e('[$_logTag] listen error: $e');
      },
      cancelOnError: false,
    );
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    AppLog.d('[$_logTag] stopping');
    for (final req in _activeRequests.toList()) {
      try {
        await req.response.close();
      } catch (_) {
        // Connection may already be torn down.
      }
    }
    _activeRequests.clear();
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  /// Parse a `Range:` header against a known file [size].
  ///
  /// Callers must already have rejected `size <= 0` — every clamp here
  /// assumes at least one addressable byte.
  ///
  /// Deliberately lenient in the same ways the original inline parser was,
  /// because mpv depends on it: a header with no `bytes=` prefix, or a
  /// `bytes=` value containing no dash, yields a full-body 200 rather than a
  /// 416; only the first range of a comma-separated list is honoured; and an
  /// unparseable bound falls back to the whole file instead of failing.
  @visibleForTesting
  static ParsedByteRange parseRangeHeader(String? rangeHeader, int size) {
    var partial = false;
    var openEnded = false;
    var start = 0;
    var end = size - 1;

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final spec = rangeHeader.substring(6).split(',').first.trim();
      final dash = spec.indexOf('-');
      if (dash >= 0) {
        final lhs = spec.substring(0, dash);
        final rhs = spec.substring(dash + 1);
        if (lhs.isEmpty && rhs.isNotEmpty) {
          // bytes=-N → last N bytes. A bounded ask, not open-ended.
          final n = int.tryParse(rhs) ?? 0;
          start = (size - n).clamp(0, size - 1).toInt();
          end = size - 1;
        } else {
          start = int.tryParse(lhs) ?? 0;
          end = rhs.isEmpty ? size - 1 : (int.tryParse(rhs) ?? size - 1);
          openEnded = rhs.isEmpty;
        }
        partial = true;
      }
    }

    // Satisfiability is judged on the *raw* parsed end, before clamping.
    // `bytes=0-999999` on a small file is satisfiable and simply truncates;
    // `bytes=500-100` is not. Reordering these two steps changes behaviour.
    if (start < 0 || start >= size || end < start) {
      return ParsedByteRange(
        start: start,
        end: end,
        partial: partial,
        satisfiable: false,
        openEnded: openEnded,
      );
    }

    return ParsedByteRange(
      start: start,
      end: end.clamp(start, size - 1).toInt(),
      partial: partial,
      satisfiable: true,
      openEnded: openEnded,
    );
  }

  /// Shorten an open-ended range to what is currently on disk.
  ///
  /// **This is the difference between a stream that opens and one that
  /// hangs.** mpv opens a video with `Range: bytes=0-`, meaning "the rest of
  /// the file". Answering that literally means promising
  /// `Content-Length: <whole file>` and then stalling mid-body at the
  /// download edge — the client is left waiting on a response that claimed
  /// hundreds of MB and stopped delivering, and libav abandons the open
  /// without ever retrying. Observed on a 448 MB episode at 19.8%: one
  /// request, no second attempt, duration never resolved, permanent spinner.
  ///
  /// Serving only the currently-available run instead lets the request
  /// *finish*. `Content-Range` still advertises the full size, so the client
  /// knows there is more and simply asks for the next slice once it needs
  /// it — the same header/tail/resume pattern libav uses against a complete
  /// file.
  ///
  /// Two deliberate exceptions fall through to the blocking path:
  ///   * a bounded request (`bytes=A-B`) is honoured exactly — the client
  ///     asked for those bytes specifically, and they are typically small;
  ///   * an available run shorter than [minClampedChunk], which would other-
  ///     wise turn one stalled request into a storm of tiny ones. Notably
  ///     this covers a seek past the download edge, where nothing at [start]
  ///     is available yet — that case still blocks, so the seek-past-head
  ///     indicator and the sequential-download toggle behave as before.
  @visibleForTesting
  static int clampOpenEndedEnd({
    required int start,
    required int requestedEnd,
    required int firstUnavailableByte,
    required bool openEnded,
  }) {
    if (!openEnded) return requestedEnd;
    final availableEnd = firstUnavailableByte - 1;
    // Everything asked for is already on disk — nothing to shorten.
    if (availableEnd >= requestedEnd) return requestedEnd;
    // Too little to be worth a round trip; let the caller block instead.
    if (availableEnd - start + 1 < minClampedChunk) return requestedEnd;
    return availableEnd;
  }

  /// Whether a read at [start] lands in the container-index tail window
  /// described on [_tailProbeWindow].
  ///
  /// The window is absolute, not proportional: for a file smaller than the
  /// window this is true at every offset, so such files never take the
  /// blocking-read path.
  @visibleForTesting
  static bool isTailProbeStart(int start, int size) =>
      start >= size - _tailProbeWindow;

  Future<void> _handleRequest(HttpRequest req) async {
    _activeRequests.add(req);
    try {
      // Only accept GET / HEAD on /stream/*
      if (!req.uri.path.startsWith('/stream/')) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }

      final size = await _resolveFileSize();
      if (size <= 0) {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        await req.response.close();
        return;
      }

      final res = req.response;
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      res.headers.set(
        HttpHeaders.contentTypeHeader,
        guessContentType(filePath),
      );
      // Disable proxy/keepalive shenanigans that can confuse libavformat.
      res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');

      // Parse Range header. mpv always sends one for video streams.
      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
      final range = parseRangeHeader(rangeHeader, size);

      if (!range.satisfiable) {
        // Logged: this used to return silently, which made it impossible to
        // tell from the log whether a client had probed at all.
        AppLog.d(
          '[$_logTag] 416 unsatisfiable — ${rangeHeader ?? "(none)"} '
          'against size $size',
        );
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await res.close();
        return;
      }

      final start = range.start;
      final partial = range.partial;

      // Tail-probe fast-fail. If the request lands in the last 64 MB of the
      // file AND those bytes haven't been downloaded yet, return 416 so
      // mpv's demuxer skips the probe instead of blocking. User seeks into
      // the middle of the file fall outside the tail window and drop into
      // the blocking-read path below.
      final isTailProbe = isTailProbeStart(start, size);
      final firstMissing = await _firstUnavailableByteFrom(start);
      final startByteAvailable = firstMissing > start;
      if (isTailProbe && !startByteAvailable) {
        AppLog.d(
          '[$_logTag] 416 tail-probe — start=$start not yet downloaded '
          '(range $start-${range.end} of $size)',
        );
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        res.headers.removeAll(HttpHeaders.contentLengthHeader);
        await res.close();
        return;
      }

      // Shorten "give me the rest of the file" to the run that is actually on
      // disk, so the response can complete rather than stalling mid-body.
      final end = clampOpenEndedEnd(
        start: start,
        requestedEnd: range.end,
        firstUnavailableByte: firstMissing,
        openEnded: range.openEnded,
      );
      final clamped = end != range.end;
      final length = end - start + 1;

      res.headers.contentLength = length;
      if (partial) {
        res.statusCode = HttpStatus.partialContent;
        // Always the FULL size after the slash — that is what tells the client
        // the resource continues past this response, so it comes back for the
        // next slice instead of treating the stream as finished.
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$size',
        );
      } else {
        res.statusCode = HttpStatus.ok;
      }

      final progressPct = (_cachedProgress * 100).toStringAsFixed(1);
      AppLog.d(
        '[$_logTag] ${req.method} '
        '${rangeHeader ?? "(full)"} → $start-$end '
        '($length bytes, file=$progressPct%'
        '${clamped ? ", clamped to available" : ""}'
        '${startByteAvailable ? "" : ", waiting"})',
      );

      if (req.method == 'HEAD') {
        await res.close();
        return;
      }

      await _streamRange(req, res, start, end);
      await res.close();
    } catch (e, st) {
      AppLog.e('[$_logTag] request error: $e\n$st');
      try {
        await req.response.close();
      } catch (_) {}
    } finally {
      _activeRequests.remove(req);
    }
  }

  /// Stream [start..end] inclusive, blocking on missing pieces. Reads only
  /// up to the first missing piece on or after the current position, so we
  /// never feed mpv pre-allocated zeros from un-downloaded regions.
  ///
  /// If qBittorrent's per-file progress fails to advance for [_stallTimeout]
  /// (paused, peers gone, requested range unreachable) we close the
  /// connection so a hopeless seek doesn't pin a socket forever. Any
  /// observed download progress resets the stall timer.
  Future<void> _streamRange(
    HttpRequest req,
    HttpResponse res,
    int start,
    int end,
  ) async {
    final raf = await File(filePath).open(mode: FileMode.read);
    var position = start;
    var clientGone = false;

    // If the client disconnects mid-wait we need to bail out promptly.
    final doneSub = res.done
        .then((_) {
          clientGone = true;
        })
        .catchError((_) {
          clientGone = true;
        });

    var stallReferenceProgress = -1.0;
    var stallReferenceAt = DateTime.now();

    try {
      while (position <= end && !_stopped && !clientGone) {
        final firstMissing = await _firstUnavailableByteFrom(position);

        // Position byte itself isn't available yet — wait for the piece to
        // land. Stall-detect on overall file progress so a stuck torrent
        // doesn't hang us forever.
        if (firstMissing <= position) {
          if (_cachedProgress > stallReferenceProgress) {
            stallReferenceProgress = _cachedProgress;
            stallReferenceAt = DateTime.now();
          } else if (DateTime.now().difference(stallReferenceAt) >
              _stallTimeout) {
            AppLog.w(
              '[$_logTag] giving up at position $position — file progress '
              '${(stallReferenceProgress * 100).toStringAsFixed(1)}% has not '
              'advanced for ${_stallTimeout.inMinutes} min',
            );
            break;
          }
          await Future<void>.delayed(_waitInterval);
          continue;
        }

        // Read up to chunk size, but never past either the requested end
        // OR the first missing piece (reading further would return zeros).
        final chunkEnd = (position + _chunkSize - 1)
            .clamp(position, end)
            .toInt();
        final safeEnd = (firstMissing - 1).clamp(position, chunkEnd).toInt();
        final toRead = safeEnd - position + 1;
        if (toRead <= 0) {
          await Future<void>.delayed(_waitInterval);
          continue;
        }

        await raf.setPosition(position);
        final bytes = await raf.read(toRead);
        if (bytes.isEmpty) {
          // Shouldn't happen — qBittorrent pre-allocates the file. Treat
          // as a transient I/O blip.
          await Future<void>.delayed(_waitInterval);
          continue;
        }
        try {
          res.add(bytes);
          await res.flush();
        } on SocketException {
          clientGone = true;
          break;
        } on HttpException {
          clientGone = true;
          break;
        }
        position += bytes.length;
        // Progress made — reset the stall reference.
        stallReferenceProgress = _cachedProgress;
        stallReferenceAt = DateTime.now();
      }
    } finally {
      await raf.close();
      // Keep the future referenced so it doesn't get GC'd before we read it.
      unawaited(doneSub);
    }
  }

  /// Returns the file-relative byte offset of the first byte at or after
  /// [fromOffset] that is *not* yet downloaded. If everything from
  /// [fromOffset] to end-of-file is downloaded, returns the file size.
  ///
  /// Piece-state path (preferred): walks piece states from the piece
  /// containing [fromOffset] forward, stops at the first non-downloaded
  /// piece, and converts back to a file-relative byte offset.
  ///
  /// Linear fallback (when piece metadata isn't available — old qBittorrent
  /// without `piece_range`, or pieceStates fetch failed): pretends bytes
  /// arrive in order using the cached file progress. Less precise but
  /// matches the original behaviour and never returns wrong bytes — at
  /// worst it blocks longer than necessary in scattered-piece scenarios.
  Future<int> _firstUnavailableByteFrom(int fromOffset) async {
    final size = await _resolveFileSize();
    if (size <= 0) return 0;
    if (fromOffset >= size) return size;

    await _refreshState();

    final pieceSize = _pieceSize;
    final firstPiece = _pieceFirst;
    final lastPiece = _pieceLast;
    final pieces = _cachedPieceStates;

    if (pieceSize == null ||
        firstPiece == null ||
        lastPiece == null ||
        pieces == null ||
        pieces.isEmpty) {
      return _linearFirstUnavailable(fromOffset, size);
    }

    // Conservative simplification: assume the file's first byte aligns with
    // the start of `firstPiece`. For multi-file torrents the file may start
    // partway into the first piece (the previous file fills the rest). The
    // off-by-up-to-pieceSize that introduces is acceptable: at worst we
    // mislabel up to one piece's worth of bytes at the file boundary, and
    // the boundary piece's state is shared anyway — if it's downloaded we
    // can read those bytes; if not we (correctly) block.
    var pieceIdx = firstPiece + (fromOffset ~/ pieceSize);
    if (pieceIdx < firstPiece) pieceIdx = firstPiece;
    if (pieceIdx > lastPiece || pieceIdx >= pieces.length) return size;

    if (pieces[pieceIdx] != 2) {
      // Piece containing fromOffset itself isn't downloaded.
      return fromOffset;
    }

    // Walk forward to the first missing piece.
    for (var i = pieceIdx + 1; i <= lastPiece && i < pieces.length; i++) {
      if (pieces[i] != 2) {
        // First byte of piece `i`, expressed relative to the file.
        final fileByte = (i - firstPiece) * pieceSize;
        if (fileByte <= fromOffset) return fromOffset;
        if (fileByte >= size) return size;
        return fileByte;
      }
    }
    // All pieces from pieceIdx through lastPiece are downloaded.
    return size;
  }

  /// Linear (sequential-download) approximation used when piece metadata
  /// isn't available.
  int _linearFirstUnavailable(int fromOffset, int size) {
    if (_cachedProgress >= 0.999) return size;
    final downloaded = (size * _cachedProgress).floor();
    if (fromOffset >= downloaded) return fromOffset;
    return downloaded;
  }

  Future<int> _resolveFileSize() async {
    if (_fileSize != null && _fileSize! > 0) return _fileSize!;
    await _refreshState(forcePieceMeta: true);
    return _fileSize ?? 0;
  }

  /// Refresh per-TTL state (piece states + per-file progress). Also
  /// resolves piece metadata on first call (size/pieceFirst/pieceLast).
  Future<void> _refreshState({bool forcePieceMeta = false}) async {
    final now = DateTime.now();
    final stale = now.difference(_cachedAt) >= _pieceStateCacheTtl;
    final needPieceMeta = forcePieceMeta && _pieceSize == null;
    if (!stale && !needPieceMeta) return;

    try {
      final files = await _qbt.getTorrentFiles(torrentHash);
      if (fileIndex >= 0 && fileIndex < files.length) {
        final f = files[fileIndex];
        _fileSize = f.size.round();
        _cachedProgress = f.progress;
        if (_pieceFirst == null || _pieceLast == null) {
          final range = f.pieceRange;
          if (range != null && range.length >= 2) {
            _pieceFirst = range[0];
            _pieceLast = range[1];
          }
        }
      }
    } catch (e) {
      // Don't update timestamp on failure — retry on next call.
      AppLog.e('[$_logTag] file metadata lookup failed: $e');
      return;
    }

    if (_pieceSize == null) {
      try {
        final torrents = await _qbt.getTorrents(hashes: [torrentHash]);
        if (torrents.isNotEmpty) {
          final t = torrents.first;
          if (t.pieceSize > 0) _pieceSize = t.pieceSize;
        }
      } catch (e) {
        AppLog.e('[$_logTag] torrent metadata lookup failed: $e');
      }
    }

    try {
      final states = await _qbt.getPieceStates(torrentHash);
      if (states != null && states.isNotEmpty) {
        _cachedPieceStates = states;
      }
    } catch (e) {
      AppLog.e('[$_logTag] piece states lookup failed: $e');
    }

    _cachedAt = now;
  }

  @visibleForTesting
  static String guessContentType(String path) {
    final ext = p.extension(path).toLowerCase();
    switch (ext) {
      case '.mkv':
        return 'video/x-matroska';
      case '.mp4':
      case '.m4v':
        return 'video/mp4';
      case '.webm':
        return 'video/webm';
      case '.mov':
        return 'video/quicktime';
      case '.avi':
        return 'video/x-msvideo';
      case '.ts':
      case '.m2ts':
        return 'video/mp2t';
      case '.mpg':
      case '.mpeg':
        return 'video/mpeg';
      default:
        return 'application/octet-stream';
    }
  }
}
