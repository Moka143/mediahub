import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/torrent_file.dart';
import 'app_logger.dart';
import 'piece_geometry.dart';
import 'torrent_engine.dart';

export 'piece_geometry.dart' show ByteRange;

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
/// best-effort hint, not a guarantee, and a torrent that was downloading
/// before streaming began has pieces all over the file. Either way,
/// "downloaded bytes" cannot be modelled as a single contiguous front. We
/// query the piece map and serve each request only up to the first missing
/// piece on or after the read position — mapped through the file's real
/// offset in the torrent, see [FilePieceMap] — and missing pieces block (with
/// a stall ceiling) until they land. mpv's cache-pause-wait absorbs the gaps.
///
/// This is the same pattern peerflix / WebTorrent / Stremio use.
class LocalStreamingServer {
  final TorrentEngine _engine;
  final String filePath;
  final String torrentHash;
  final int fileIndex;

  /// Optional prefix appended to the `[LocalStreamingServer]` tag in logs —
  /// lets callers distinguish concurrent instances (e.g. the next-episode
  /// prefetch proxy vs. the main session's).
  final String _logTag;

  /// How long to wait between piece-state polls when the requested byte is
  /// past a missing piece. Short enough that mpv doesn't time out, long
  /// enough not to hammer the engine's API.
  static const Duration _waitInterval = Duration(milliseconds: 400);

  /// How long to wait before asking for the piece size again while the
  /// engine cannot say yet — it only knows once the torrent's metadata is in.
  static const Duration _geometryRetry = Duration(seconds: 5);

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

  /// If we're blocking on a missing piece and the file's overall download
  /// progress doesn't advance at all for this long, give up and close the
  /// connection. Without this, a hopeless seek (e.g. way past the head while
  /// the torrent is paused or stuck on rare pieces) would tie up an HTTP
  /// socket forever.
  static const Duration _stallTimeout = Duration(minutes: 5);

  /// How long the first bytes of the file may keep reading back as zeros,
  /// with the piece map saying they are there, before the request is given
  /// up. The piece map and the disk disagreeing is not something more
  /// download progress fixes, so this does not reset on progress.
  static const Duration _headerWaitLimit = Duration(minutes: 2);

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

  // File metadata — resolved on the first requests, then cached for the
  // server's lifetime (immutable once the torrent's metadata is in).
  int? _fileSize;
  int _pieceSize = 0;
  FilePieceMap? _pieceMap;
  DateTime _pieceSizeAskedAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Mutable: piece states + per-file progress, refreshed per TTL.
  List<int>? _cachedPieceStates;
  TorrentFile? _cachedFile;
  DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _stopped = false;

  /// [_openPrefixWait] and [_headerWaitLimit], unless a test shortened them.
  final Duration _openPrefixWaitLimit;
  final Duration _headerWaitLimitValue;

  double get _cachedProgress => _cachedFile?.progress ?? 0;

  LocalStreamingServer({
    required TorrentEngine engine,
    required this.filePath,
    required this.torrentHash,
    required this.fileIndex,
    String? logTag,
    @visibleForTesting Duration openPrefixWait = _openPrefixWait,
    @visibleForTesting Duration headerWaitLimit = _headerWaitLimit,
  }) : _engine = engine,
       _openPrefixWaitLimit = openPrefixWait,
       _headerWaitLimitValue = headerWaitLimit,
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

  /// Whether [bytes] — the first bytes of a file — start like a media
  /// container this app plays.
  ///
  /// Season-pack file progress can sit at 10% while the first piece of
  /// *this* file is still empty, and those zeros make mpv fail with
  /// `EBML header parsing failed` / `Failed to recognize file format`, after
  /// which it never recovers even when the real header lands. The proxy holds
  /// byte 0 back until it looks like one of these — or, failing a match, at
  /// least not like padding; see [looksLikeRealData].
  ///
  /// This used to accept MKV, MPEG-TS, `ftyp`/`moov`/`mdat` and RIFF only,
  /// so MPEG-PS, Blu-ray M2TS, WMV, FLV and QuickTime files that open with a
  /// `wide` or `free` atom re-read their first bytes every 400 ms for good —
  /// and its AVI check looked for the `AVI ` marker at offset 0, where it
  /// never is.
  @visibleForTesting
  static bool looksLikeContainerHeader(List<int> bytes) {
    bool at(int offset, List<int> signature) {
      if (bytes.length < offset + signature.length) return false;
      for (var i = 0; i < signature.length; i++) {
        if (bytes[offset + i] != signature[i]) return false;
      }
      return true;
    }

    bool ascii(int offset, String text) => at(offset, text.codeUnits);

    // Matroska / WebM: EBML magic.
    if (at(0, const [0x1A, 0x45, 0xDF, 0xA3])) return true;
    // MPEG transport stream: sync byte on every 188-byte packet.
    if (at(0, const [0x47])) return true;
    // Blu-ray M2TS: the same packets behind a 4-byte timestamp (192 bytes).
    if (at(4, const [0x47])) return true;
    // MPEG program stream pack header, or a bare MPEG-1/2 video sequence.
    if (at(0, const [0x00, 0x00, 0x01, 0xBA])) return true;
    if (at(0, const [0x00, 0x00, 0x01, 0xB3])) return true;
    // ASF — WMV / WMA.
    if (at(0, const [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11])) {
      return true;
    }
    // Flash video.
    if (ascii(0, 'FLV')) return true;
    // RIFF (AVI says so at offset 8, after the chunk size).
    if (ascii(0, 'RIFF')) return true;
    // Ogg.
    if (ascii(0, 'OggS')) return true;
    // ISO base media / QuickTime: a 4-byte size, then the first atom's type.
    for (final atom in const ['ftyp', 'moov', 'mdat', 'wide', 'free', 'skip']) {
      if (ascii(4, atom)) return true;
    }
    return false;
  }

  /// Whether [bytes] can be served as the start of the file: a recognised
  /// container, or at least not the zero-fill an unwritten region of a
  /// pre-allocated file reads back as.
  ///
  /// The second half is the one that matters. A container this list does
  /// not know is still a container; only all-zeros means "not written yet".
  @visibleForTesting
  static bool looksLikeRealData(List<int> bytes) {
    if (looksLikeContainerHeader(bytes)) return true;
    final head = bytes.length < 16 ? bytes : bytes.sublist(0, 16);
    return head.any((b) => b != 0);
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
      final plan = await _planResponse(range, size);
      if (plan.refuseWith != null) {
        res.statusCode = plan.refuseWith!;
        if (plan.refuseWith == HttpStatus.requestedRangeNotSatisfiable) {
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          res.headers.removeAll(HttpHeaders.contentLengthHeader);
        }
        await res.close();
        return;
      }
      final end = plan.end;
      final startByteAvailable = plan.startAvailable;
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

      final sent = await _streamRange(req, res, start, end);
      if (sent == 0) {
        // Gave up before the first byte: say so, rather than a 206 promising
        // bytes and then a connection that closes without them.
        res.statusCode = HttpStatus.serviceUnavailable;
        res.headers.contentLength = 0;
      }
      try {
        await res.close();
      } on HttpException catch (e) {
        // Gave up part-way through the body. The client sees a short read
        // and asks again; nothing more to report than that.
        AppLog.d('[$_logTag] response ended short: $e');
      }
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

  /// How much of [range] to answer with right now — or which status to
  /// refuse it with.
  ///
  /// Three request shapes get three answers:
  ///  * a probe of the container index near the end of the file, while those
  ///    bytes are not down: 416, so the demuxer skips the optional read
  ///    instead of blocking on it;
  ///  * the initial open (`bytes=0-`): wait for a real prefix, then advertise
  ///    only that run — promising the whole file while byte 0 is still
  ///    missing hangs mpv until its network timeout. 503 if none arrives;
  ///  * anything else: see [clampOpenEndedEnd].
  Future<({int end, bool startAvailable, int? refuseWith})> _planResponse(
    ParsedByteRange range,
    int size,
  ) async {
    final start = range.start;
    var firstMissing = await _firstUnavailableByteFrom(start);
    final startAvailable = firstMissing > start;

    if (isTailProbeStart(start, size) && !startAvailable) {
      AppLog.d(
        '[$_logTag] 416 tail-probe — start=$start not yet downloaded '
        '(range $start-${range.end} of $size)',
      );
      return (
        end: start,
        startAvailable: false,
        refuseWith: HttpStatus.requestedRangeNotSatisfiable,
      );
    }

    if (range.openEnded && start == 0) {
      firstMissing = await _waitForRunAt(0, size, limit: _openPrefixWaitLimit);
      if (firstMissing <= 0) {
        AppLog.w(
          '[$_logTag] 503 — file start still not downloaded after '
          '${_openPrefixWaitLimit.inSeconds}s',
        );
        return (
          end: start,
          startAvailable: false,
          refuseWith: HttpStatus.serviceUnavailable,
        );
      }
      final end = firstMissing - 1;
      return (
        end: end > range.end ? range.end : end,
        startAvailable: true,
        refuseWith: null,
      );
    }

    if (range.openEnded && startAvailable) {
      // A mid-file `bytes=N-` with data at N is what a *seek into the
      // buffered region* looks like. Answering with the whole remaining
      // file promises a Content-Length we cannot deliver, and libav abandons
      // the open rather than asking again — the seek then never completes
      // and the player falls back to the spinner even though the bytes at N
      // were on disk all along.
      //
      // Give the run a short chance to reach [minClampedChunk] so a healthy
      // download still answers in large slices, then serve whatever is
      // genuinely there. `minRun: 1` is the point: after waiting, a short
      // run is served short instead of over-promised.
      firstMissing = await _waitForRunAt(start, size, limit: _seekRunWait);
      return (
        end: clampOpenEndedEnd(
          start: start,
          requestedEnd: range.end,
          firstUnavailableByte: firstMissing,
          openEnded: true,
          minRun: 1,
        ),
        startAvailable: true,
        refuseWith: null,
      );
    }

    return (
      end: clampOpenEndedEnd(
        start: start,
        requestedEnd: range.end,
        firstUnavailableByte: firstMissing,
        openEnded: range.openEnded,
      ),
      startAvailable: startAvailable,
      refuseWith: null,
    );
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
  /// never feed mpv pre-allocated zeros from un-downloaded regions. Returns
  /// how many bytes went out.
  ///
  /// If the file's download progress fails to advance for [_stallTimeout]
  /// (paused, peers gone, requested range unreachable) we close the
  /// connection so a hopeless seek doesn't pin a socket forever. Any
  /// observed download progress resets the stall timer.
  Future<int> _streamRange(
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
    DateTime? headerWaitSince;

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
        if (position == 0 && !looksLikeRealData(bytes)) {
          final since = headerWaitSince ??= DateTime.now();
          if (DateTime.now().difference(since) > _headerWaitLimitValue) {
            AppLog.w(
              '[$_logTag] giving up — the start of the file still reads as '
              'zeros after ${_headerWaitLimitValue.inSeconds}s',
            );
            break;
          }
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
    return position - start;
  }

  /// The file-relative offset of the first byte at or after [fromOffset]
  /// that is *not* yet downloaded, or the file size when everything from
  /// there on is.
  ///
  /// With a piece map, an exact answer — see [FilePieceMap.firstUnavailableFrom].
  /// Without one (no piece size yet, or the piece states could not be read)
  /// only a *finished* file is trusted: pretending `0..progress×size` was a
  /// contiguous prefix is what fed mpv zeros from season-pack episodes whose
  /// first piece was still missing at 10%.
  Future<int> _firstUnavailableByteFrom(int fromOffset) async {
    final size = await _resolveFileSize();
    if (size <= 0) return 0;
    if (fromOffset >= size) return size;

    await _refreshState();

    final map = _pieceMap;
    final pieces = _cachedPieceStates;
    if (map != null && pieces != null && pieces.isNotEmpty) {
      return map.firstUnavailableFrom(fromOffset, pieces);
    }
    return (_cachedFile?.isComplete ?? false) ? size : fromOffset;
  }

  Future<int> _resolveFileSize() async {
    if (_fileSize != null && _fileSize! > 0) return _fileSize!;
    await _refreshState(force: true);
    return _fileSize ?? 0;
  }

  /// Refresh the file's progress and the torrent's piece states, at most
  /// once per [_pieceStateCacheTtl] (concurrent reads share one fetch).
  /// Works out the file's [FilePieceMap] once the piece size is known.
  Future<void> _refreshState({bool force = false}) async {
    final now = DateTime.now();
    if (!force && now.difference(_cachedAt) < _pieceStateCacheTtl) return;

    final files = await _engine.tryGetTorrentFiles(torrentHash);
    if (files == null) {
      // Engine did not answer. Keep what we have and try again next call.
      return;
    }
    if (fileIndex >= 0 && fileIndex < files.length) {
      final file = files[fileIndex];
      _cachedFile = file;
      if (file.size > 0) _fileSize = file.size;
    }

    if (_pieceSize <= 0 &&
        now.difference(_pieceSizeAskedAt) >= _geometryRetry) {
      _pieceSizeAskedAt = now;
      _pieceSize = await _engine.getPieceSize(torrentHash);
    }
    if (_pieceMap == null && _pieceSize > 0) {
      _pieceMap = PieceGeometry.forFile(
        files: files,
        fileIndex: fileIndex,
        pieceSize: _pieceSize,
      );
      if (_pieceMap != null) AppLog.d('[$_logTag] $_pieceMap');
    }

    final states = await _engine.getPieceStates(torrentHash);
    if (states != null && states.isNotEmpty) _cachedPieceStates = states;

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
