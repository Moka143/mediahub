import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/peer.dart';
import '../models/torrent.dart';
import '../models/torrent_file.dart';
import '../utils/constants.dart';
import 'app_logger.dart';
import 'torrent_engine.dart';

/// The built-in torrent engine: [rqbit](https://github.com/ikatson/rqbit),
/// driven over its local HTTP API.
///
/// **Why this exists.** qBittorrent is a downloader. It pre-allocates files
/// and leaves the not-yet-downloaded regions reading back as zeros, which the
/// demuxer decodes as corrupt video — so the app grew `LocalStreamingServer`
/// and `PlaybackHealthMonitor` to serve only the bytes that are really there.
/// rqbit serves a file *while it downloads*, prioritising the pieces at the
/// read head, which is what [streamUrl] returns and what lets that whole
/// layer go away.
///
/// **Addressing.** rqbit routes accept `{id_or_infohash}`, and a 40-character
/// hex string is parsed as an info hash. So the app's existing vocabulary —
/// everything keyed by `Torrent.hash` — carries over unchanged, with no id
/// table to keep in sync. Hashes are lower-cased on the way in because rqbit
/// emits lower-case and indexers do not always.
///
/// **What it cannot do**, declared in [capabilities] rather than discovered
/// through empty lists: no tracker table, no delta-sync endpoint, no live
/// speed limits (they are launch flags — see `RqbitProcessService`), and no
/// download ordering for the caller to drive, because ordering pieces is the
/// engine's own job.
///
/// Always on loopback: the app only ever talks to the sidecar it launched.
class RqbitEngine extends TorrentEngine {
  late final Dio _dio;
  final int _port;

  /// The folder the sidecar was launched with, i.e. its session default.
  ///
  /// Needed by [addTorrent] to tell "save where you normally would" apart from
  /// "save somewhere specific" — the two take different paths through rqbit
  /// and produce different directory layouts.
  final String _defaultSavePath;

  /// Piece length per hash. Never changes for a given torrent, and the only
  /// source for it is the details call, so it is worth not repeating.
  final Map<String, int> _pieceSizeCache = {};

  RqbitEngine({
    int port = AppConstants.defaultRqbitPort,
    String defaultSavePath = '',
  }) : _port = port,
       _defaultSavePath = defaultSavePath {
    _dio = Dio(
      BaseOptions(
        baseUrl: 'http://${AppConstants.rqbitHost}:$port',
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
        // rqbit answers 404 for an unknown torrent and 412 for one that is
        // not live yet. Both are ordinary answers here, so read them rather
        // than throwing through every call site.
        validateStatus: (code) => code != null && code < 500,
      ),
    );
  }

  @override
  EngineCapabilities get capabilities => const EngineCapabilities(
    // No per-torrent tracker table in the API.
    trackers: false,
    // `/peer_stats` exists, but reports far less than qBittorrent's table.
    peers: true,
    // No sync/maindata equivalent; `?with_stats=true` makes a full list cheap
    // enough that there is nothing to delta against.
    deltaSync: false,
    // `--ratelimit-download` / `--ratelimit-upload` are process launch flags.
    liveSpeedLimits: false,
    // The engine orders pieces itself. That is the entire point of it.
    pieceLevelControl: false,
    maintenanceActions: false,
    // `update_only_files` takes the set of files to download — nothing finer.
    rankedFilePriorities: false,
    // `peer_stats` counts live peers without telling seeds from leechers, and
    // gives a peer byte counters but no client, progress or rates.
    seedsAndPeersSplit: false,
    peerDetails: false,
  );

  @override
  String get baseUrl => 'http://${AppConstants.rqbitHost}:$_port';

  // ---------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------

  /// rqbit on loopback has no auth step: a session is simply the engine
  /// answering. False therefore means "not running", never "wrong password".
  @override
  Future<bool> login() => testConnection();

  @override
  Future<bool> testConnection() async {
    try {
      final response = await _dio.get('/');
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> getVersion() async {
    // rqbit's root document lists its routes but does not carry a version, so
    // the connection panel gets the engine's name instead of a blank.
    return testConnection().then((ok) => ok ? 'rqbit' : null);
  }

  // ---------------------------------------------------------------------
  // Listing
  // ---------------------------------------------------------------------

  /// rqbit's states, mapped onto the qBittorrent vocabulary the rest of the
  /// app already speaks (`TorrentState`, the filter enum, `Torrent.stateText`).
  ///
  /// Translating here rather than teaching every screen a second vocabulary
  /// keeps `isDownloading` / `isSeeding` / `isPaused` / `isCompleted` /
  /// `hasError` answering correctly for both engines.
  static String mapState({
    required String state,
    required bool finished,
    required bool initializingPaused,
    required bool hasPeers,
  }) {
    switch (state) {
      case 'initializing':
        // Metadata fetch. Paused-while-initializing is a real rqbit state and
        // is not the same as `paused`.
        return initializingPaused ? TorrentState.pausedDL : TorrentState.metaDL;
      case 'paused':
        return finished ? TorrentState.pausedUP : TorrentState.pausedDL;
      case 'error':
        return TorrentState.error;
      case 'live':
        if (finished) return TorrentState.uploading;
        // "stalled" is not an rqbit state; it is qBittorrent's word for a
        // live torrent with nothing coming in, and the Transfers screen's
        // filters and colours depend on the distinction.
        return hasPeers ? TorrentState.downloading : TorrentState.stalledDL;
      default:
        return TorrentState.unknown;
    }
  }

  /// qBittorrent's sentinel for "no meaningful ETA" (100 days). The UI already
  /// renders it as `∞`, so reusing it avoids a second convention.
  static const int _unknownEta = 8640000;

  /// rqbit reports speeds in MiB/s; everything downstream is bytes/s.
  static int mibPerSecondToBytes(num? mbps) =>
      mbps == null ? 0 : (mbps * 1024 * 1024).round();

  /// Build a [Torrent] from one entry of `GET /torrents?with_stats=true`.
  ///
  /// Static and pure so the mapping — which is where an engine swap actually
  /// goes wrong — is testable without a server.
  static Torrent torrentFromJson(Map<String, dynamic> json) {
    final stats = (json['stats'] as Map?)?.cast<String, dynamic>() ?? const {};
    final live = (stats['live'] as Map?)?.cast<String, dynamic>();
    final snapshot = (live?['snapshot'] as Map?)?.cast<String, dynamic>();
    final peerStats = (snapshot?['peer_stats'] as Map?)
        ?.cast<String, dynamic>();

    final total = (stats['total_bytes'] as num?)?.toInt() ?? 0;
    final done = (stats['progress_bytes'] as num?)?.toInt() ?? 0;
    final finished = stats['finished'] as bool? ?? false;
    final livePeers = (peerStats?['live'] as num?)?.toInt() ?? 0;

    final dlSpeed = mibPerSecondToBytes(
      (live?['download_speed'] as Map?)?['mbps'] as num?,
    );
    final upSpeed = mibPerSecondToBytes(
      (live?['upload_speed'] as Map?)?['mbps'] as num?,
    );

    // serde writes a Rust Duration as {secs, nanos}.
    final remaining = (live?['time_remaining'] as Map?)?['duration'] as Map?;
    final eta = (remaining?['secs'] as num?)?.toInt() ?? _unknownEta;

    final outputFolder = json['output_folder'] as String? ?? '';
    final name = json['name'] as String? ?? '';

    return Torrent(
      hash: (json['info_hash'] as String? ?? '').toLowerCase(),
      name: name,
      size: total,
      totalSize: total,
      progress: total == 0 ? 0 : (done / total).clamp(0.0, 1.0),
      dlspeed: dlSpeed,
      upspeed: upSpeed,
      eta: eta,
      state: mapState(
        state: stats['state'] as String? ?? 'initializing',
        finished: finished,
        initializingPaused: stats['initializing_paused'] as bool? ?? false,
        hasPeers: livePeers > 0,
      ),
      // rqbit does not separate seeds from leechers among connected peers, so
      // the connected count goes to `numSeeds` and swarm size is reported as
      // what we have *seen* rather than invented.
      numSeeds: livePeers,
      numLeeches: 0,
      numComplete: (peerStats?['seen'] as num?)?.toInt() ?? 0,
      numIncomplete: 0,
      ratio: done == 0
          ? 0
          : ((stats['uploaded_bytes'] as num?)?.toInt() ?? 0) / done,
      // rqbit tracks neither an add time nor a completion time. Zero is what
      // the formatters already render as "—".
      addedOn: 0,
      completionOn: 0,
      savePath: outputFolder,
      // Unlike qBittorrent's, rqbit's `output_folder` is already this
      // torrent's own folder (see [addTorrent]), so it *is* the content root:
      // the folder for a multi-file torrent, the folder holding the file for a
      // single-file one. Both are what `_openFromContentPath` expects — it
      // stats the path and recurses if it is a directory.
      contentPath: outputFolder,
      downloaded: done,
      uploaded: (stats['uploaded_bytes'] as num?)?.toInt() ?? 0,
      amountLeft: (total - done).clamp(0, total),
      category: '',
      tags: '',
      priority: 0,
      tracker: '',
      seenComplete: 0,
      lastActivity: 0,
      pieceSize: 0,
      piecesNum: (json['total_pieces'] as num?)?.toInt() ?? 0,
      piecesHave: 0,
      // The engine streams in order by construction, so the flag the app reads
      // to decide whether a torrent is stream-ready is true, always.
      sequentialDownload: true,
      firstLastPiecePriority: false,
    );
  }

  @override
  Future<List<Torrent>?> tryGetTorrents({List<String>? hashes}) async {
    try {
      // rqbit pushes none of the filtering down, but `with_stats` folds what
      // would otherwise be one stats call per torrent into this one request.
      final response = await _dio.get(
        '/torrents',
        queryParameters: const {'with_stats': 'true'},
      );
      if (response.statusCode != 200) return null;

      final raw = (response.data as Map?)?['torrents'];
      if (raw is! List) return null;

      var torrents = raw
          .whereType<Map>()
          .map((e) => torrentFromJson(e.cast<String, dynamic>()))
          .toList();

      if (hashes != null && hashes.isNotEmpty) {
        final wanted = hashes.map((h) => h.toLowerCase()).toSet();
        torrents = torrents.where((t) => wanted.contains(t.hash)).toList();
      }
      return torrents;
    } catch (e) {
      _log('List torrents error: $e');
      return null;
    }
  }

  /// `GET /torrents/{hash}`: the details document, an empty map when rqbit
  /// does not know the torrent, or null when it could not be asked.
  Future<Map<String, dynamic>?> _details(String hash) async {
    try {
      final response = await _dio.get('/torrents/${hash.toLowerCase()}');
      if (response.statusCode == 404) return const {};
      if (response.statusCode != 200) return null;
      return (response.data as Map?)?.cast<String, dynamic>();
    } catch (e) {
      _log('Torrent details error: $e');
      return null;
    }
  }

  @override
  Future<List<TorrentFile>?> tryGetTorrentFiles(String hash) async {
    final details = await _details(hash);
    if (details == null) return null;
    final rawFiles = details['files'];
    if (rawFiles is! List) return <TorrentFile>[];

    // Per-file byte progress rides on the stats object, not on the file list.
    final progress = await _fileProgress(hash);
    if (progress == null) return null;

    return rawFiles.indexed.map((entry) {
      final (index, raw) = entry;
      final file = (raw as Map).cast<String, dynamic>();
      final length = (file['length'] as num?)?.toInt() ?? 0;
      final included = file['included'] as bool? ?? true;
      final done = index < progress.length ? progress[index] : 0;

      // rqbit's `components` is the path split into segments; qBittorrent
      // hands back a single path with forward slashes, and the file tree and
      // the episode-matching regexes both expect that shape.
      final components = (file['components'] as List?)?.cast<String>();
      final name = (components == null || components.isEmpty)
          ? (file['name'] as String? ?? '')
          : components.join('/');

      return TorrentFile(
        index: index,
        name: name,
        size: length,
        progress: length == 0 ? 0 : (done / length).clamp(0.0, 1.0),
        // rqbit's model is inclusion, not a 0-7 scale. Map onto the two
        // values the app actually acts on: 0 = skip, 1 = download.
        priority: included ? 1 : 0,
        isSeed: false,
        pieceRange: null,
        availability: 0,
      );
    }).toList();
  }

  /// Bytes downloaded per file. Empty when rqbit has no stats for the
  /// torrent yet (it answers 4xx while initialising); null when it could not
  /// be asked — reporting zero progress then would read as a restart.
  Future<List<int>?> _fileProgress(String hash) async {
    try {
      final response = await _dio.get(
        '/torrents/${hash.toLowerCase()}/stats/v1',
      );
      if (response.statusCode != 200) return const [];
      final raw = (response.data as Map?)?['file_progress'];
      if (raw is! List) return const [];
      return raw.map((e) => (e as num).toInt()).toList();
    } catch (e) {
      _log('File progress error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Mutation
  // ---------------------------------------------------------------------

  /// Whether an add should override rqbit's own choice of folder.
  ///
  /// Static and pure because the consequence of getting it wrong is not an
  /// error but a quietly wrong directory layout.
  static bool wantsCustomOutputFolder(String? savePath, String defaultPath) {
    if (savePath == null || savePath.isEmpty) return false;
    if (defaultPath.isEmpty) return true;
    return p.canonicalize(savePath) != p.canonicalize(defaultPath);
  }

  @override
  Future<bool> addTorrent({
    String? magnetLink,
    File? torrentFile,
    String? savePath,
    bool? paused,
    bool? sequentialDownload,
  }) async {
    // `sequentialDownload` is deliberately ignored: this engine orders pieces
    // for streaming itself, which is what
    // EngineCapabilities.pieceLevelControl = false announces.
    try {
      final Object body;
      if (magnetLink != null) {
        body = magnetLink;
      } else if (torrentFile != null) {
        body = await torrentFile.readAsBytes();
      } else {
        _log('Add torrent called with neither a magnet nor a file');
        return false;
      }

      // Only send `output_folder` when the caller genuinely wants a different
      // location. rqbit treats an explicit output_folder as literal and writes
      // straight into it, with no per-torrent subfolder — so passing the
      // session default on every add would flatten every torrent into one
      // directory and let two season packs overwrite each other's files.
      // Omitting it lets rqbit join its default folder with a subfolder named
      // for the torrent, which is the layout the rest of the app assumes.
      final response = await _dio.post(
        '/torrents',
        data: body,
        queryParameters: {
          if (wantsCustomOutputFolder(savePath, _defaultSavePath))
            'output_folder': savePath,
          // Re-adding a torrent whose files are already on disk should resume
          // it, not fail. The streaming path relies on this: a second play of
          // the same episode must not error out as a duplicate.
          'overwrite': 'true',
          if (magnetLink != null) 'is_url': 'true',
        },
        options: Options(
          contentType: magnetLink != null
              ? Headers.textPlainContentType
              : 'application/octet-stream',
        ),
      );

      if (response.statusCode != 200) {
        _log('Add torrent failed: ${response.statusCode} ${response.data}');
        return false;
      }

      // rqbit has no "add paused" parameter, so a paused add is an add
      // followed by a pause.
      if (paused == true) {
        final added = (response.data as Map?)?['details'] as Map?;
        final hash = added?['info_hash'] as String?;
        if (hash != null) await pauseTorrents([hash]);
      }
      return true;
    } catch (e) {
      _log('Add torrent error: $e');
      return false;
    }
  }

  /// Apply a POST action to each hash, succeeding only if all of them did.
  ///
  /// rqbit's actions are per-torrent; qBittorrent's take a list. The list form
  /// is what the app's call sites expect, so the fan-out lives here.
  Future<bool> _forEachHash(
    List<String> hashes,
    String action, {
    Map<String, dynamic>? queryParameters,
  }) async {
    if (hashes.isEmpty) return true;
    var allOk = true;
    for (final hash in hashes) {
      try {
        final response = await _dio.post(
          '/torrents/${hash.toLowerCase()}/$action',
          queryParameters: queryParameters,
        );
        final ok = response.statusCode == 200;
        if (!ok) {
          _log('$action failed for $hash: ${response.statusCode}');
          allOk = false;
        }
      } catch (e) {
        _log('$action error for $hash: $e');
        allOk = false;
      }
    }
    return allOk;
  }

  @override
  Future<bool> pauseTorrents(List<String> hashes) =>
      _forEachHash(hashes, 'pause');

  @override
  Future<bool> resumeTorrents(List<String> hashes) =>
      _forEachHash(hashes, 'start');

  @override
  Future<bool> deleteTorrents(List<String> hashes, {bool deleteFiles = false}) {
    // rqbit splits what qBittorrent expresses as a flag: `delete` removes the
    // files, `forget` keeps them.
    return _forEachHash(hashes, deleteFiles ? 'delete' : 'forget');
  }

  @override
  Future<bool> setFilePriority(
    String hash,
    List<int> fileIds,
    int priority,
  ) async {
    // qBittorrent takes an incremental instruction ("these files are now
    // priority N"); rqbit takes the absolute set of files to download. So the
    // current selection has to be read back and edited, rather than sent.
    final files = await getTorrentFiles(hash);
    if (files.isEmpty) return false;

    final included = <int>{
      for (final f in files)
        if (f.priority > 0) f.index,
    };
    if (priority > 0) {
      included.addAll(fileIds);
    } else {
      included.removeAll(fileIds);
    }

    // rqbit rejects an empty selection outright. Deselecting everything is
    // never what a caller means — season-pack trimming always keeps one file —
    // so treat it as a no-op rather than sending a request that must fail.
    if (included.isEmpty) {
      _log('Refusing to deselect every file of $hash');
      return false;
    }

    try {
      final response = await _dio.post(
        '/torrents/${hash.toLowerCase()}/update_only_files',
        data: {'only_files': included.toList()..sort()},
      );
      return response.statusCode == 200;
    } catch (e) {
      _log('Set file priority error: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // Streaming
  // ---------------------------------------------------------------------

  /// The whole reason for this engine.
  ///
  /// rqbit serves the file over HTTP while it downloads: it honours `Range`,
  /// prioritises the pieces at the read position, and holds the response open
  /// until they arrive instead of answering zeros. The player opens this URL
  /// directly — no proxy, no piece priming, no stall recovery.
  @override
  String? streamUrl(String hash, int fileIndex) =>
      '$baseUrl/torrents/${hash.toLowerCase()}/stream/$fileIndex';

  /// Expand rqbit's `haves` bitfield into the 0/1/2 vector the app uses.
  ///
  /// Sent as `Accept: application/octet-stream`, the endpoint answers the raw
  /// bitfield plus an `x-bitfield-len` header giving the piece count; without
  /// that header it renders an SVG for its own web UI, which is no use here.
  /// Bits are most-significant-first within each byte, as in the BitTorrent
  /// wire protocol.
  ///
  /// There is no "downloading" state to report, so pieces are only ever 2
  /// (have) or 0 (missing) — which is all any caller distinguishes.
  static List<int> expandBitfield(List<int> bytes, int pieceCount) {
    final states = List<int>.filled(pieceCount, 0);
    for (var i = 0; i < pieceCount; i++) {
      final byte = i ~/ 8;
      if (byte >= bytes.length) break;
      final bit = 7 - (i % 8);
      if ((bytes[byte] >> bit) & 1 == 1) states[i] = 2;
    }
    return states;
  }

  @override
  Future<List<int>?> getPieceStates(String hash) async {
    try {
      final response = await _dio.get<List<int>>(
        '/torrents/${hash.toLowerCase()}/haves',
        options: Options(
          responseType: ResponseType.bytes,
          headers: const {'Accept': 'application/octet-stream'},
        ),
      );
      if (response.statusCode != 200) return null;

      final bytes = response.data;
      if (bytes == null) return null;

      final header = response.headers.value('x-bitfield-len');
      final pieceCount = int.tryParse(header ?? '') ?? bytes.length * 8;
      return expandBitfield(bytes, pieceCount);
    } catch (e) {
      _log('Get piece states error: $e');
      return null;
    }
  }

  /// Recover the piece length from the total size and the piece count.
  ///
  /// rqbit reports `total_pieces` but not the piece length, and the byte-range
  /// maths downstream needs the length.
  ///
  /// Dividing does **not** work. With total = `s*(p-1) + r`, `ceil(total / p)`
  /// only lands back on `s` when `s - r < p`; a torrent whose final piece is
  /// nearly empty divides to something well below the real piece size, and
  /// every piece-to-offset conversion after that is silently wrong.
  ///
  /// So invert the relation instead of guessing it: piece lengths are powers
  /// of two, and for the right one `ceil(total / size)` reproduces the piece
  /// count exactly. Test each candidate and accept only an unambiguous match —
  /// 0 means "unknown", which callers already handle.
  static int derivePieceSize({required int totalBytes, required int pieces}) {
    if (totalBytes <= 0 || pieces <= 0) return 0;

    // 16 KiB to 64 MiB covers every piece length in practice; BEP 3 gives no
    // hard bounds, but no client picks outside this.
    var matches = 0;
    var found = 0;
    for (var exponent = 14; exponent <= 26; exponent++) {
      final size = 1 << exponent;
      if ((totalBytes + size - 1) ~/ size == pieces) {
        matches++;
        found = size;
      }
    }
    // More than one candidate fits only for a tiny single-piece torrent, where
    // the answer is genuinely ambiguous. Say so rather than picking.
    return matches == 1 ? found : 0;
  }

  @override
  Future<int> getPieceSize(String hash) async {
    final key = hash.toLowerCase();
    final cached = _pieceSizeCache[key];
    if (cached != null) return cached;

    final details = await _details(key);
    final pieces = (details?['total_pieces'] as num?)?.toInt() ?? 0;
    final files = (details?['files'] as List?)?.whereType<Map>() ?? const [];
    final total = files.fold<int>(
      0,
      (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0),
    );

    final size = derivePieceSize(totalBytes: total, pieces: pieces);
    if (size > 0) _pieceSizeCache[key] = size;
    return size;
  }

  // ---------------------------------------------------------------------
  // Peers
  // ---------------------------------------------------------------------

  @override
  Future<List<Peer>> getTorrentPeers(String hash) async {
    try {
      final response = await _dio.get(
        '/torrents/${hash.toLowerCase()}/peer_stats',
      );
      if (response.statusCode != 200) return const [];

      final peers = (response.data as Map?)?['peers'];
      if (peers is! Map) return const [];

      // Keys are `ip:port`; the value carries connection state and counters,
      // but none of qBittorrent's client name, flags, country or relevance.
      // Those fields stay empty rather than being invented.
      return peers.entries.map((entry) {
        final address = entry.key.toString();
        final split = address.lastIndexOf(':');
        final counters =
            ((entry.value as Map?)?['counters'] as Map?)
                ?.cast<String, dynamic>() ??
            const {};
        return Peer(
          ip: split > 0 ? address.substring(0, split) : address,
          port: split > 0 ? int.tryParse(address.substring(split + 1)) ?? 0 : 0,
          client: '',
          progress: 0,
          dlSpeed: 0,
          upSpeed: 0,
          downloaded: (counters['fetched_bytes'] as num?)?.toInt() ?? 0,
          uploaded: (counters['uploaded_bytes'] as num?)?.toInt() ?? 0,
          connection: (entry.value as Map?)?['state']?.toString() ?? '',
          flags: '',
          flagsDesc: '',
          relevance: 0,
          country: '',
          countryCode: '',
        );
      }).toList();
    } catch (e) {
      _log('Get peers error: $e');
      return const [];
    }
  }

  void _log(String message) => AppLog.d('[RqbitEngine] $message');

  @override
  void dispose() {
    _dio.close();
  }
}
