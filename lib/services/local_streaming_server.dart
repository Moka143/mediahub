import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'torrent_engine.dart';

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

/// A contiguous, inclusive run of file-relative byte offsets.
///
/// Produced by [LocalStreamingServer.availableRanges] to describe *where*
/// a partially-downloaded file actually has data. A single `progress`
/// fraction cannot express this: once sequential download is off (which is
/// what we do after the user seeks) pieces land scattered, so "60%
/// downloaded" says nothing about which 60%.
@immutable
class ByteRange {
  const ByteRange(this.start, this.end);

  /// First byte of the run, file-relative.
  final int start;

  /// Last byte of the run, inclusive.
  final int end;

  int get length => end - start + 1;

  bool contains(int offset) => offset >= start && offset <= end;

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'ByteRange($start-$end)';
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
  final TorrentEngine _qbt;
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
  ///
  /// Sized to the index, not to a safety margin. This was 64 MB, which on a
  /// 500 MB episode swallowed the last ~12% of the runtime: seeking there
  /// answered 416, mpv treated the seek as failed, and playback fell back to
  /// the spinner. Cues/moov live in the final few MB, so 8 MB covers the
  /// probe with room to spare while leaving the rest of the file seekable.
  static const int _tailProbeWindow = 8 * 1024 * 1024; // 8 MB

  /// Below this size the tail window would cover a large fraction of the
  /// file — for a 20 MB sample every offset would count as a probe and a
  /// read of any not-yet-downloaded byte would 416 instead of waiting, so
  /// the file could never stream at all. Small files skip the rule entirely
  /// and use the blocking path, which is cheap at these sizes.
  static const int _minTailProbeFileSize = 4 * _tailProbeWindow; // 32 MB

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

  /// How long the initial `bytes=0-` open may wait for a real prefix before
  /// we 503 rather than advertising the whole file and stalling in the body.
  /// Kept under mpv's network timeout (~60 s).
  static const Duration _openPrefixWait = Duration(seconds: 20);

  /// How long a mid-file open-ended read (a seek) may wait for its available
  /// run to reach [minClampedChunk] before we answer with the shorter run we
  /// already have. Deliberately brief: the whole point of the seek path is
  /// that the bytes are there, so responding fast matters more than
  /// responding in big slices.
  static const Duration _seekRunWait = Duration(seconds: 2);

  /// Contiguous prefix mpv's lavf demuxer needs to identify the file.
  /// Matches `demuxer-lavf-probesize` in the player.
  static const int prefixProbeBytes = 8 * 1024 * 1024; // 8 MB

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
    required TorrentEngine qbt,
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
    } catch (e) {
      // Teardown is best-effort; the socket is going away regardless.
      AppLog.d('[$_logTag] server close during stop failed: $e');
    }
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
  ///   * an available run shorter than [minRun], which would otherwise turn
  ///     one stalled request into a storm of tiny ones. Notably this covers
  ///     a seek past the download edge, where nothing at [start] is
  ///     available yet — that case still blocks, so the seek-past-head
  ///     indicator and the piece prioritiser behave as before.
  ///
  /// [minRun] exists so the caller can lower the bar *after* it has already
  /// waited for the run to grow (see [_waitForRunAt]). At that point a short
  /// run is real information and serving it beats promising the rest of the
  /// file and stalling mid-body — the exact hang this function was written
  /// to avoid. Only a run of zero (nothing at [start]) still falls through
  /// to the blocking path.
  @visibleForTesting
  static int clampOpenEndedEnd({
    required int start,
    required int requestedEnd,
    required int firstUnavailableByte,
    required bool openEnded,
    int minRun = minClampedChunk,
  }) {
    if (!openEnded) return requestedEnd;
    final availableEnd = firstUnavailableByte - 1;
    // Everything asked for is already on disk — nothing to shorten.
    if (availableEnd >= requestedEnd) return requestedEnd;
    // Too little to be worth a round trip; let the caller block instead.
    if (availableEnd - start + 1 < minRun) return requestedEnd;
    return availableEnd;
  }

  /// Whether the leading bytes of a media file are a real container, not
  /// qBittorrent's sparse-zero padding.
  ///
  /// Season-pack file progress can sit at 10% while piece 0 of *this* file
  /// is still empty. Serving those zeros makes mpv fail with
  /// `EBML header parsing failed` / `Failed to recognize file format`,
  /// after which it never recovers even when the real header lands.
  @visibleForTesting
  static bool looksLikeContainerHeader(List<int> bytes) {
    if (bytes.length < 4) return false;
    if (bytes[0] == 0x1A &&
        bytes[1] == 0x45 &&
        bytes[2] == 0xDF &&
        bytes[3] == 0xA3) {
      return true; // MKV / WebM EBML
    }
    if (bytes[0] == 0x47) return true; // MPEG-TS
    if (bytes.length >= 8) {
      final tag = String.fromCharCodes(bytes.sublist(4, 8));
      if (tag == 'ftyp' || tag == 'moov' || tag == 'mdat') return true;
    }
    if (bytes.length >= 4) {
      final riff = String.fromCharCodes(bytes.sublist(0, 4));
      if (riff == 'RIFF' || riff == 'AVI ') return true;
    }
    return false;
  }

  /// Piece indices covering a contiguous prefix of [minBytes] from the
  /// start of a file. Used to bump those pieces to max priority.
  static List<int> prefixPieceIds({
    required int firstPiece,
    required int lastPiece,
    required int pieceSize,
    int minBytes = prefixProbeBytes,
  }) {
    if (firstPiece < 0 || lastPiece < firstPiece) {
      return const [];
    }
    final filePieces = lastPiece - firstPiece + 1;
    // `/torrents/info` does not include piece_size, so callers often pass 0.
    // Fall back to a handful of leading pieces — enough for mpv to probe.
    if (pieceSize <= 0) {
      final need = filePieces < 4 ? filePieces : 4;
      return [for (var i = 0; i < need; i++) firstPiece + i];
    }
    final need = (minBytes / pieceSize).ceil().clamp(1, filePieces).toInt();
    return [for (var i = 0; i < need; i++) firstPiece + i];
  }

  /// True when the first piece of this file is fully downloaded (state 2).
  ///
  /// One complete leading piece is enough to open; the HTTP proxy waits on
  /// the rest. Requiring an 8 MB run blocked real streams: sequential had
  /// finished piece 1613 while 1614 never completed, so we sat until 99%.
  ///
  /// Took `pieceSize` and `minBytes` until callers were audited and neither
  /// was ever read — the doc promised a contiguous `minBytes` prefix while
  /// the body checked one piece, and `StreamingService` was resolving the
  /// piece size purely to hand it over. The behaviour was right; the
  /// signature was describing a different function.
  static bool prefixPiecesReady({
    required List<int> pieceStates,
    required int firstPiece,
    required int lastPiece,
  }) {
    if (firstPiece < 0 || firstPiece > lastPiece) return false;
    if (firstPiece >= pieceStates.length) return false;
    return pieceStates[firstPiece] == 2;
  }

  /// True when [path] starts with a real container header, not zeros.
  static Future<bool> fileHasPlayableHeader(String path) async {
    RandomAccessFile? raf;
    try {
      raf = await File(path).open();
      final bytes = await raf.read(16);
      return looksLikeContainerHeader(bytes);
    } catch (_) {
      return false;
    } finally {
      await raf?.close();
    }
  }

  /// Map a file in a multi-file torrent onto piece indices.
  ///
  /// qBittorrent's `piece_range` is missing on some WebUI versions; we
  /// reconstruct it from file sizes + piece size so we don't fall back to
  /// the "0..progress×size is contiguous" lie.
  static (int first, int last)? pieceRangeForFile({
    required List<int> fileSizes,
    required int fileIndex,
    required int pieceSize,
  }) {
    if (pieceSize <= 0 || fileIndex < 0 || fileIndex >= fileSizes.length) {
      return null;
    }
    var offset = 0;
    for (var i = 0; i < fileSizes.length; i++) {
      final size = fileSizes[i];
      if (size <= 0) {
        if (i == fileIndex) return null;
        continue;
      }
      if (i == fileIndex) {
        return (offset ~/ pieceSize, (offset + size - 1) ~/ pieceSize);
      }
      offset += size;
    }
    return null;
  }

  /// Contiguous downloaded runs of a file, in file-relative byte offsets.
  ///
  /// The inverse of [_firstUnavailableByteFrom]: instead of "where does the
  /// data stop", this answers "which parts do we have" in one pass, which is
  /// what the seek bar needs to draw an honest buffered track and what the
  /// health monitor needs to tell a seek-into-a-hole from a seek-past-head.
  ///
  /// Shares [_firstUnavailableByteFrom]'s simplification that the file's
  /// first byte aligns with the start of [firstPiece] — off by at most one
  /// piece at the file boundary, and in the conservative direction (a
  /// boundary piece we mislabel as missing is simply not drawn).
  ///
  /// Returns an empty list when the piece map is unusable; callers should
  /// fall back to the scalar progress fraction.
  static List<ByteRange> availableRanges({
    required List<int> pieceStates,
    required int firstPiece,
    required int lastPiece,
    required int pieceSize,
    required int fileSize,
  }) {
    if (pieceSize <= 0 ||
        fileSize <= 0 ||
        firstPiece < 0 ||
        lastPiece < firstPiece ||
        pieceStates.isEmpty) {
      return const [];
    }

    final ranges = <ByteRange>[];
    int? runStartPiece;

    void closeRun(int endPieceExclusive) {
      if (runStartPiece == null) return;
      final start = (runStartPiece! - firstPiece) * pieceSize;
      final end = (endPieceExclusive - firstPiece) * pieceSize - 1;
      runStartPiece = null;
      if (start >= fileSize) return;
      final clampedEnd = end >= fileSize ? fileSize - 1 : end;
      if (clampedEnd < start) return;
      ranges.add(ByteRange(start, clampedEnd));
    }

    final last = lastPiece < pieceStates.length - 1
        ? lastPiece
        : pieceStates.length - 1;
    for (var i = firstPiece; i <= last; i++) {
      if (pieceStates[i] == 2) {
        runStartPiece ??= i;
      } else {
        closeRun(i);
      }
    }
    closeRun(last + 1);
    return ranges;
  }

  /// Whether a read at [start] lands in the container-index tail window
  /// described on [_tailProbeWindow].
  ///
  /// Always false for a file below [_minTailProbeFileSize] — see that
  /// constant for why a small file must not fast-fail.
  @visibleForTesting
  static bool isTailProbeStart(int start, int size) =>
      size >= _minTailProbeFileSize && start >= size - _tailProbeWindow;

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

      // Tail-probe fast-fail. If the request lands in the last
      // [_tailProbeWindow] of the file AND those bytes haven't been
      // downloaded yet, return 416 so
      // mpv's demuxer skips the probe instead of blocking. User seeks into
      // the middle of the file fall outside the tail window and drop into
      // the blocking-read path below.
      final isTailProbe = isTailProbeStart(start, size);
      var firstMissing = await _firstUnavailableByteFrom(start);
      var startByteAvailable = firstMissing > start;
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

      // Initial open (`bytes=0-`): wait for a real prefix, then advertise
      // only that run. Promising the whole file while byte 0 is still
      // missing hangs mpv until network-timeout (duration stays 00:00).
      int end;
      if (range.openEnded && start == 0) {
        firstMissing = await _waitForRunAt(0, size, limit: _openPrefixWait);
        startByteAvailable = firstMissing > 0;
        if (!startByteAvailable) {
          AppLog.w(
            '[$_logTag] 503 — file start still not downloaded after '
            '${_openPrefixWait.inSeconds}s',
          );
          res.statusCode = HttpStatus.serviceUnavailable;
          await res.close();
          return;
        }
        end = firstMissing - 1;
        if (end > range.end) end = range.end;
      } else if (range.openEnded && startByteAvailable) {
        // A mid-file `bytes=N-` with data at N is what a *seek into the
        // buffered region* looks like. Answering with the whole remaining
        // file promises a Content-Length we cannot deliver, and libav
        // abandons the open rather than asking again — the seek then never
        // completes and the player falls back to the spinner even though the
        // bytes at N were on disk all along.
        //
        // Give the run a short chance to reach [minClampedChunk] so a healthy
        // download still answers in large slices, then serve whatever is
        // genuinely there. `minRun: 1` is the point: after waiting, a short
        // run is served short instead of over-promised.
        firstMissing = await _waitForRunAt(start, size, limit: _seekRunWait);
        end = clampOpenEndedEnd(
          start: start,
          requestedEnd: range.end,
          firstUnavailableByte: firstMissing,
          openEnded: true,
          minRun: 1,
        );
      } else {
        end = clampOpenEndedEnd(
          start: start,
          requestedEnd: range.end,
          firstUnavailableByte: firstMissing,
          openEnded: range.openEnded,
        );
      }
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
      } catch (_) {
        // The original error above is the useful one; a failure to close a
        // response we already gave up on adds nothing.
      }
    } finally {
      _activeRequests.remove(req);
    }
  }

  /// Poll until [start] has a contiguous run of at least [minClampedChunk]
  /// (or reaches end-of-file), or [limit] elapses. Returns the first
  /// unavailable file offset — equal to [start] when nothing landed at all.
  Future<int> _waitForRunAt(
    int start,
    int size, {
    required Duration limit,
  }) async {
    final deadline = DateTime.now().add(limit);
    var firstMissing = await _firstUnavailableByteFrom(start);
    while (!_stopped && DateTime.now().isBefore(deadline)) {
      if (firstMissing > start &&
          (firstMissing - start >= minClampedChunk || firstMissing >= size)) {
        return firstMissing;
      }
      await Future<void>.delayed(_waitInterval);
      firstMissing = await _firstUnavailableByteFrom(start);
    }
    return firstMissing;
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
        // Sparse zeros at byte 0 must never reach mpv — it treats them as
        // a broken container and gives up on the stream for good.
        if (position == 0 && !looksLikeContainerHeader(bytes)) {
          AppLog.d('[$_logTag] first bytes are still sparse zeros — waiting');
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

  /// Linear fallback when piece metadata isn't available.
  ///
  /// We used to pretend `0..progress×size` was a contiguous downloaded
  /// prefix. That's only true for a single-file sequential torrent; a
  /// season-pack episode can be 10% "downloaded" while its first piece is
  /// still zeros. Claiming those bytes are ready is what made mpv parse
  /// `0x00 at pos 0` and die.
  ///
  /// Without piece mapping we only trust the file when it's essentially
  /// complete. Otherwise we block at [fromOffset] until piece states land.
  int _linearFirstUnavailable(int fromOffset, int size) {
    if (_cachedProgress >= 0.999) return size;
    return fromOffset;
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

      if (_pieceSize == null) {
        try {
          final torrents = await _qbt.getTorrents(hashes: [torrentHash]);
          if (torrents.isNotEmpty && torrents.first.pieceSize > 0) {
            _pieceSize = torrents.first.pieceSize;
          }
        } catch (e) {
          AppLog.e('[$_logTag] torrent metadata lookup failed: $e');
        }
      }
      // `/torrents/info` does not include piece_size on current qBit.
      if (_pieceSize == null) {
        try {
          final size = await _qbt.getPieceSize(torrentHash);
          if (size > 0) _pieceSize = size;
        } catch (e) {
          AppLog.e('[$_logTag] piece size lookup failed: $e');
        }
      }

      if ((_pieceFirst == null || _pieceLast == null) &&
          _pieceSize != null &&
          fileIndex >= 0 &&
          fileIndex < files.length) {
        final computed = pieceRangeForFile(
          fileSizes: files.map((f) => f.size.round()).toList(),
          fileIndex: fileIndex,
          pieceSize: _pieceSize!,
        );
        if (computed != null) {
          _pieceFirst = computed.$1;
          _pieceLast = computed.$2;
        }
      }
    } catch (e) {
      // Don't update timestamp on failure — retry on next call.
      AppLog.e('[$_logTag] file metadata lookup failed: $e');
      return;
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
