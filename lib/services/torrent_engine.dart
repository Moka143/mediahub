import 'dart:io';

import '../models/peer.dart';
import '../models/torrent.dart';
import '../models/torrent_file.dart';
import '../models/tracker.dart';

/// What a given [TorrentEngine] can actually do.
///
/// The app was written against qBittorrent, whose Web API answers everything.
/// A purpose-built streaming engine does not: it has no global preferences
/// dialog to read, no tracker table, no delta-sync endpoint. Rather than have
/// the UI discover that through empty lists, it asks here.
///
/// Every flag defaults to the qBittorrent answer, so an engine only declares
/// what it *lacks*.
class EngineCapabilities {
  /// Per-torrent tracker table with live status — `torrent_trackers_tab`.
  final bool trackers;

  /// Per-torrent peer list — `torrent_peers_tab`.
  final bool peers;

  /// A delta-sync endpoint, so list polling need not refetch everything.
  final bool deltaSync;

  /// Readable/writable global engine preferences.
  final bool globalPreferences;

  /// Speed limits that can be changed without restarting the engine.
  final bool liveSpeedLimits;

  /// Piece priorities and sequential-download toggles the caller can drive.
  ///
  /// False means the engine orders pieces itself — see [streamUrl].
  final bool pieceLevelControl;

  /// Force-recheck and tracker reannounce.
  final bool maintenanceActions;

  const EngineCapabilities({
    this.trackers = true,
    this.peers = true,
    this.deltaSync = true,
    this.globalPreferences = true,
    this.liveSpeedLimits = true,
    this.pieceLevelControl = true,
    this.maintenanceActions = true,
  });
}

/// The torrent backend, as the rest of the app sees it.
///
/// Extracted so the backend can be swapped without touching the ~98 call
/// sites that used to name `QBittorrentApiService` directly. Two shapes of
/// backend are in view:
///
///  * **A downloader** (qBittorrent). Writes files to disk and exposes piece
///    state; making it *stream* is the caller's problem, which is what
///    `LocalStreamingServer` and `PlaybackHealthMonitor` exist for.
///  * **A streaming engine** (rqbit). Serves a file over HTTP while it
///    downloads, prioritising the pieces at the read head itself. It answers
///    [streamUrl] and the caller skips the proxy entirely.
///
/// Members split into three groups:
///
///  1. **Abstract** — every engine must implement them. Nothing works without.
///  2. **Overridable with a degraded default** — an engine that cannot do it
///     inherits an honest "no", and [capabilities] says so in advance.
///  3. **[streamUrl]** — the hinge between the two shapes above.
abstract class TorrentEngine {
  TorrentEngine();

  // ---------------------------------------------------------------------
  // Identity and capabilities
  // ---------------------------------------------------------------------

  /// What this engine supports. Read it before showing a UI affordance that
  /// depends on an optional member below.
  EngineCapabilities get capabilities => const EngineCapabilities();

  /// Root URL of the engine's HTTP API, e.g. `http://localhost:8080`.
  String get baseUrl;

  /// Whether a session is currently established. Engines with no auth step
  /// report true once reachable.
  bool get isAuthenticated;

  // ---------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------

  /// Establish a session. Engines with no auth step return true if reachable.
  Future<bool> login();

  /// Tear down the session. A no-op where there is nothing to tear down.
  Future<void> logout();

  /// Cheap reachability probe. Must not throw.
  Future<bool> testConnection();

  /// Engine version string, for the connection panel.
  Future<String?> getVersion();

  /// API version string, for the connection panel. Null when the engine does
  /// not version its API separately.
  Future<String?> getApiVersion();

  // ---------------------------------------------------------------------
  // Listing and detail
  // ---------------------------------------------------------------------

  /// List torrents. Filtering/sorting arguments are hints: an engine that
  /// cannot push them down may answer the full list and let the caller sort.
  Future<List<Torrent>> getTorrents({
    String? filter,
    String? category,
    String? tag,
    String? sort,
    bool? reverse,
    int? limit,
    int? offset,
    List<String>? hashes,
  });

  /// Engine-specific extended properties for one torrent. Shape is not
  /// normalised — only the info tab reads it, defensively.
  Future<Map<String, dynamic>?> getTorrentProperties(String hash);

  /// Files inside a torrent, with per-file progress and priority.
  Future<List<TorrentFile>> getTorrentFiles(String hash);

  // ---------------------------------------------------------------------
  // Mutation
  // ---------------------------------------------------------------------

  /// Add a torrent from a magnet link or a `.torrent` file.
  ///
  /// [sequentialDownload] and [firstLastPiecePrio] are hints an engine with
  /// no [EngineCapabilities.pieceLevelControl] may ignore — it is expected to
  /// order pieces correctly on its own.
  Future<bool> addTorrent({
    String? magnetLink,
    File? torrentFile,
    String? savePath,
    String? category,
    bool? paused,
    bool? skipChecking,
    bool? sequentialDownload,
    bool? firstLastPiecePrio,
  });

  Future<bool> pauseTorrents(List<String> hashes);

  Future<bool> resumeTorrents(List<String> hashes);

  Future<bool> deleteTorrents(List<String> hashes, {bool deleteFiles = false});

  /// Deselect the files we do not want, so a season pack does not pull 40 GB
  /// to watch one episode. Priority 0 means "do not download".
  Future<bool> setFilePriority(String hash, List<int> fileIds, int priority);

  // ---------------------------------------------------------------------
  // Streaming
  // ---------------------------------------------------------------------

  /// A URL the player can open directly for [fileIndex] of [hash], served by
  /// the engine while the torrent is still downloading.
  ///
  /// Null means the engine has no such endpoint and the caller must front the
  /// partially-downloaded file itself. That is the qBittorrent path, and the
  /// entire reason `LocalStreamingServer` exists: qBittorrent pre-allocates
  /// files and the not-yet-downloaded regions read back as zeros, which the
  /// demuxer treats as corrupt video.
  ///
  /// An engine that answers a URL here is expected to honour `Range`, to
  /// prioritise the pieces at the read position, and to hold the response
  /// open rather than serving zeros — i.e. to do natively what the proxy
  /// approximates.
  String? streamUrl(String hash, int fileIndex) => null;

  /// Per-piece download state: 0 = missing, 1 = downloading, 2 = downloaded.
  ///
  /// Null when the engine cannot report it. Drives both the streaming proxy's
  /// available-byte-range maths and the seek bar's buffered track — the
  /// latter survives even for an engine that answers [streamUrl], because a
  /// single `progress` fraction cannot say *which* bytes are on disk.
  Future<List<int>?> getPieceStates(String hash);

  /// Piece length in bytes, needed to turn [getPieceStates] into byte ranges.
  /// Zero when unknown.
  Future<int> getPieceSize(String hash) async => 0;

  // ---------------------------------------------------------------------
  // Optional: piece-level control
  //
  // An engine without EngineCapabilities.pieceLevelControl orders pieces for
  // streaming itself, so these are no-ops rather than failures.
  // ---------------------------------------------------------------------

  /// Sequential on, first/last piece priority off, so the piece picker starts
  /// at the first wanted piece of the selected file.
  ///
  /// Defaults to true — "the engine already delivers in order" — rather than
  /// false, because a false here reads to callers as a broken session.
  Future<bool> ensureInOrderDownload(
    String hash, {
    bool resetPicker = false,
  }) async => true;

  Future<bool> toggleSequentialDownload(String hash) async => false;

  Future<bool> toggleFirstLastPiecePrio(String hash) async => false;

  /// Raise (or lower) the priority of specific pieces, to pull the head of
  /// the selected file first.
  Future<bool> setPiecePriority(
    String hash,
    List<int> pieceIds,
    int priority,
  ) async => false;

  // ---------------------------------------------------------------------
  // Optional: detail tabs
  // ---------------------------------------------------------------------

  /// Empty when [EngineCapabilities.trackers] is false.
  Future<List<Tracker>> getTorrentTrackers(String hash) async => const [];

  /// Empty when [EngineCapabilities.peers] is false.
  Future<List<Peer>> getTorrentPeers(String hash) async => const [];

  // ---------------------------------------------------------------------
  // Optional: maintenance
  // ---------------------------------------------------------------------

  Future<bool> recheckTorrents(List<String> hashes) async => false;

  Future<bool> reannounceTorrents(List<String> hashes) async => false;

  Future<bool> setTorrentPriority(List<String> hashes, String priority) async =>
      false;

  // ---------------------------------------------------------------------
  // Optional: global state
  // ---------------------------------------------------------------------

  /// Delta since the last poll, keyed by the engine's own convention.
  ///
  /// Null means "no delta endpoint" and the caller must do a full
  /// [getTorrents]. See [EngineCapabilities.deltaSync].
  Future<Map<String, dynamic>?> getMainData({bool fullUpdate = false}) async =>
      null;

  Future<Map<String, dynamic>?> getPreferences() async => null;

  Future<bool> setPreferences(Map<String, dynamic> prefs) async => false;

  /// Global transfer counters — speeds, session totals.
  Future<Map<String, dynamic>?> getTransferInfo() async => null;

  /// Bytes per second; 0 means unlimited.
  Future<bool> setDownloadLimit(int limit) async => false;

  /// Bytes per second; 0 means unlimited.
  Future<bool> setUploadLimit(int limit) async => false;

  // ---------------------------------------------------------------------

  /// Release transport resources. The engine *process*, if any, is managed
  /// separately and outlives this.
  void dispose();
}
