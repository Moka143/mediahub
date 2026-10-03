import 'dart:io';

import '../models/peer.dart';
import '../models/torrent.dart';
import '../models/torrent_file.dart';
import '../models/tracker.dart';

/// What a given [TorrentEngine] can actually do.
///
/// The app was written against qBittorrent, whose Web API answers everything.
/// A purpose-built streaming engine does not: it has no tracker table and no
/// delta-sync endpoint. Rather than have the UI discover that through empty
/// lists, it asks here.
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

  /// Speed limits that can be changed without restarting the engine.
  final bool liveSpeedLimits;

  /// Sequential-download control the caller has to drive itself.
  ///
  /// False means the engine orders pieces for streaming on its own — see
  /// [TorrentEngine.streamUrl].
  final bool pieceLevelControl;

  /// Force-recheck and tracker reannounce.
  final bool maintenanceActions;

  /// Files can be *ranked* — qBittorrent's Maximum / High / Normal — as well
  /// as skipped. False means include or exclude only: such an engine reports
  /// every included file as priority 1, so offering High would be accepted
  /// and then snap back to Normal on the next refresh.
  final bool rankedFilePriorities;

  /// A torrent's connected peers come split into seeds (`Torrent.numSeeds`)
  /// and leechers (`Torrent.numLeeches`), with swarm totals in `numComplete`
  /// / `numIncomplete`. False means one count of connected peers, which the
  /// engine reports in `numSeeds`.
  final bool seedsAndPeersSplit;

  /// Each `Peer` carries its client name, its own progress and live
  /// download and upload rates. False means only its address, connection
  /// state and byte counters are real; the rest read as zero.
  final bool peerDetails;

  const EngineCapabilities({
    this.trackers = true,
    this.peers = true,
    this.deltaSync = true,
    this.liveSpeedLimits = true,
    this.pieceLevelControl = true,
    this.maintenanceActions = true,
    this.rankedFilePriorities = true,
    this.seedsAndPeersSplit = true,
    this.peerDetails = true,
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

  // ---------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------

  /// Establish a session. Engines with no auth step return true if
  /// reachable, false if not.
  ///
  /// May throw a transport error (`DioException`) for an engine that has an
  /// auth step, so the caller can tell "wrong password" from "nothing is
  /// listening" — the two need different advice.
  Future<bool> login();

  /// Cheap reachability probe. Must not throw.
  Future<bool> testConnection();

  /// Engine version string, for the connection panel.
  Future<String?> getVersion();

  // ---------------------------------------------------------------------
  // Listing and detail
  // ---------------------------------------------------------------------

  /// The torrents the engine holds — all of them, or those among [hashes].
  ///
  /// **Null means the engine could not be asked**: it is not running, it
  /// refused us, or it answered something unreadable. An empty list means it
  /// answered and holds nothing. The streaming state machine needs the
  /// difference: treating one failed poll as "the torrent is gone" used to
  /// fail healthy sessions with a metadata timeout.
  Future<List<Torrent>?> tryGetTorrents({List<String>? hashes});

  /// [tryGetTorrents], with "could not ask" folded into an empty list — for
  /// callers that render a list and have nothing better to do on failure.
  Future<List<Torrent>> getTorrents({List<String>? hashes}) async =>
      await tryGetTorrents(hashes: hashes) ?? <Torrent>[];

  /// Files inside a torrent, with per-file progress and priority, in torrent
  /// order. Null when the engine could not be asked; empty while the engine
  /// does not have the torrent's metadata yet.
  Future<List<TorrentFile>?> tryGetTorrentFiles(String hash);

  /// [tryGetTorrentFiles], with "could not ask" folded into an empty list.
  Future<List<TorrentFile>> getTorrentFiles(String hash) async =>
      await tryGetTorrentFiles(hash) ?? <TorrentFile>[];

  // ---------------------------------------------------------------------
  // Mutation
  // ---------------------------------------------------------------------

  /// Add a torrent from a magnet link or a `.torrent` file.
  ///
  /// [sequentialDownload] is a hint an engine with no
  /// [EngineCapabilities.pieceLevelControl] may ignore — it is expected to
  /// order pieces correctly on its own.
  Future<bool> addTorrent({
    String? magnetLink,
    File? torrentFile,
    String? savePath,
    bool? paused,
    bool? sequentialDownload,
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

  /// Sequential download on, first/last-piece priority off, so the piece
  /// picker works forward from the first wanted piece. [resetPicker] turns it
  /// off and on again, to move a picker that a previous session left parked
  /// elsewhere.
  ///
  /// The only ordering control any engine offers: qBittorrent's Web API has
  /// no per-piece priority at all. An engine without
  /// [EngineCapabilities.pieceLevelControl] orders pieces itself, so this
  /// answers true — "the engine already delivers in order" — rather than
  /// false, which callers read as a broken session.
  Future<bool> ensureInOrderDownload(
    String hash, {
    bool resetPicker = false,
  }) async => true;

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

  // ---------------------------------------------------------------------
  // Optional: global state
  // ---------------------------------------------------------------------

  /// Delta since the last poll, keyed by the engine's own convention.
  ///
  /// Null means "no delta endpoint" and the caller must do a full
  /// [getTorrents]. See [EngineCapabilities.deltaSync].
  Future<Map<String, dynamic>?> getMainData({bool fullUpdate = false}) async =>
      null;

  /// Bytes per second; 0 means unlimited.
  Future<bool> setDownloadLimit(int limit) async => false;

  /// Bytes per second; 0 means unlimited.
  Future<bool> setUploadLimit(int limit) async => false;

  // ---------------------------------------------------------------------

  /// Release transport resources. The engine *process*, if any, is managed
  /// separately and outlives this.
  void dispose();
}
