import '../../models/auto_download_event.dart';
import '../../models/episode_grab_result.dart';
import '../../models/eztv_torrent.dart';
import '../../models/local_media_file.dart';
import '../../services/app_logger.dart';
import '../../services/auto_download_service.dart';
import '../../utils/formatters.dart';
import '../../utils/media_quality.dart';
import 'auto_download_ledger.dart';

/// The answer when a grab could not be started.
const EpisodeGrabResult grabFailed = EpisodeGrabResult(
  EpisodeGrabOutcome.failed,
  "Couldn't start the download. Check that the torrent engine is running.",
);

/// One episode for [EpisodeGrabber] to fetch, and how.
class EpisodeGrabRequest {
  const EpisodeGrabRequest({
    required this.showId,
    required this.imdbId,
    required this.showName,
    required this.season,
    required this.episode,
    required this.quality,
    required this.announce,
    this.excludeHashes = const {},
    this.waitForFileSelection = true,
  });

  final int showId;

  /// What both indexers search by.
  final String imdbId;

  final String showName;
  final int season;
  final int episode;

  /// The quality asked for: the show's preference.
  final String quality;

  /// Whether finding no source goes in the activity log. The background
  /// check, which asks every few minutes, passes false.
  final bool announce;

  /// Torrents never to pick: a download of this episode that failed.
  final Set<String> excludeHashes;

  /// Whether to wait for a season pack to be trimmed to this episode.
  /// False when someone is waiting on the answer.
  final bool waitForFileSelection;

  /// The episode's key in the download queue.
  String get key => downloadQueueKey(showId, season, episode);

  /// "Show S01E01", for messages.
  String get label => '$showName ${Formatters.episodeCode(season, episode)}';

  /// A tracking entry for this episode.
  EpisodeTrackingInfo tracking(
    EpisodeDownloadStatus status, {
    required String? quality,
    String? torrentHash,
  }) => EpisodeTrackingInfo(
    showId: showId,
    imdbId: imdbId,
    showName: showName,
    season: season,
    episode: episode,
    status: status,
    quality: quality,
    torrentHash: torrentHash,
  );
}

/// Fetches one episode: checks what is already here, chooses a source, adds
/// it to the engine and records what came of it.
///
/// Made per grab, with what it needs read at that moment — the engine, the
/// settings and the library can all change between two grabs. Run it under
/// the show's lock.
class EpisodeGrabber {
  EpisodeGrabber({
    required this.service,
    required this.ledger,
    required this.savePath,
    required this.library,
    required this.quietUntil,
  });

  final AutoDownloadService service;
  final AutoDownloadLedger ledger;

  /// Where downloads are saved.
  final String savePath;

  /// The local library — read only once the episode is known not to be
  /// queued already.
  final List<LocalMediaFile> Function() library;

  /// When the background check may next ask about each show. Finding no
  /// source pushes a show's out by [missBackoff].
  final Map<int, DateTime> quietUntil;

  /// How long after finding no source the background check asks again.
  static const Duration missBackoff = Duration(minutes: 30);

  /// Fetch [request]'s episode now.
  ///
  /// The queue key is written *before* the first await of the fetch, so
  /// nothing else can queue the same episode meanwhile; it is released
  /// again if the fetch does not happen.
  Future<EpisodeGrabResult> grab(EpisodeGrabRequest request) async {
    // Only an episode at or past the show's tracked one moves the tracking.
    final advances = movesTracking(
      ledger.state.lastDownloadedEpisodes[request.showId],
      request.season,
      request.episode,
    );
    final here = _alreadyHere(request);
    if (here != null) return here;

    await ledger.setQueued(request.key, null);
    var keepKey = false;
    try {
      // Already in the engine — queued by an earlier run whose entry was
      // lost, or added by hand.
      if (await _inTransfers(request)) {
        return EpisodeGrabResult(
          EpisodeGrabOutcome.alreadyQueued,
          '${request.label} is already in Transfers.',
        );
      }
      if (!ledger.mounted) return grabFailed;

      final torrent = await _chooseSource(request);
      if (!ledger.mounted) return grabFailed;
      if (torrent == null) return await _noSource(request, advances: advances);

      final added = await _addToEngine(request, torrent);
      if (!ledger.mounted) {
        return added
            ? EpisodeGrabResult(
                EpisodeGrabOutcome.started,
                'Downloading ${request.label}.',
              )
            : grabFailed;
      }
      if (!added) return await _addFailed(request, torrent);

      keepKey = true;
      return await _recordStarted(request, torrent, advances: advances);
    } catch (e) {
      AppLog.e('[AutoDownload] fetching ${request.label} failed: $e');
      return grabFailed;
    } finally {
      if (!keepKey && ledger.mounted) await ledger.releaseQueued(request.key);
    }
  }

  /// The answer when there is nothing to fetch — the episode is queued
  /// already, or in the library — or null to go on.
  EpisodeGrabResult? _alreadyHere(EpisodeGrabRequest r) {
    if (ledger.state.downloadQueue.contains(r.key)) {
      return EpisodeGrabResult(
        EpisodeGrabOutcome.alreadyQueued,
        '${r.label} is already downloading.',
      );
    }
    if (service.isEpisodeDownloaded(
      downloadedFiles: library(),
      showName: r.showName,
      season: r.season,
      episode: r.episode,
      showId: r.showId,
    )) {
      return EpisodeGrabResult(
        EpisodeGrabOutcome.alreadyDownloaded,
        '${r.label} is already in your library.',
      );
    }
    return null;
  }

  /// Whether the engine already holds a torrent named like the episode.
  Future<bool> _inTransfers(EpisodeGrabRequest r) =>
      service.isEpisodeCurrentlyDownloading(
        showName: r.showName,
        season: r.season,
        episode: r.episode,
      );

  /// The best source for the episode, or null when there is none.
  ///
  /// A download is kept, so no streaming size cap: it would throw away the
  /// quality preference for anything over 900 MB.
  Future<EztvTorrent?> _chooseSource(EpisodeGrabRequest r) =>
      service.findTorrentForEpisode(
        imdbId: r.imdbId,
        season: r.season,
        episode: r.episode,
        preferredQuality: r.quality,
        forStreaming: false,
        excludeHashes: r.excludeHashes,
      );

  /// No source yet: back off, keep the episode wanted, and say so.
  Future<EpisodeGrabResult> _noSource(
    EpisodeGrabRequest r, {
    required bool advances,
  }) async {
    quietUntil[r.showId] = DateTime.now().add(missBackoff);
    if (advances) {
      await ledger.updateTracking(
        r.showId,
        r.tracking(
          EpisodeDownloadStatus.awaitingTorrent,
          quality: r.quality,
          torrentHash: r.excludeHashes.isEmpty ? null : r.excludeHashes.first,
        ),
      );
    }
    final message = 'No source found for ${r.label} yet.';
    if (r.announce) {
      await _log(
        r,
        AutoDownloadEventType.torrentNotFound,
        quality: r.quality,
        message: message,
      );
    }
    return EpisodeGrabResult(EpisodeGrabOutcome.noTorrent, message);
  }

  /// Add [torrent] to the engine. When it is a season pack
  /// ([EztvTorrent.fileIdx]) the service also has it fetch only this
  /// episode — waited for unless [EpisodeGrabRequest.waitForFileSelection]
  /// is false.
  Future<bool> _addToEngine(EpisodeGrabRequest r, EztvTorrent torrent) =>
      service.downloadNextEpisode(
        magnetLink: torrent.magnetUrl,
        savePath: savePath,
        infoHash: torrent.hash,
        fileIdx: torrent.fileIdx,
        waitForFileSelection: r.waitForFileSelection,
      );

  /// The engine did not take [torrent].
  Future<EpisodeGrabResult> _addFailed(
    EpisodeGrabRequest r,
    EztvTorrent torrent,
  ) async {
    await _log(
      r,
      AutoDownloadEventType.downloadFailed,
      quality: torrent.quality,
      message: "Couldn't add ${r.label} to Transfers.",
    );
    return grabFailed;
  }

  /// [torrent] is downloading: queue it under its hash, move the tracking
  /// on to it, and log it.
  Future<EpisodeGrabResult> _recordStarted(
    EpisodeGrabRequest r,
    EztvTorrent torrent, {
    required bool advances,
  }) async {
    final hash = torrent.hash.toLowerCase();
    final inQuality = torrent.quality == MediaQuality.unknown.label
        ? ''
        : ' in ${torrent.quality}';
    final started = EpisodeGrabResult(
      EpisodeGrabOutcome.started,
      'Downloading ${r.label}$inQuality.',
    );

    await ledger.setQueued(r.key, hash);
    if (!ledger.mounted) return started;
    if (advances) {
      await ledger.updateTracking(
        r.showId,
        r.tracking(
          EpisodeDownloadStatus.downloading,
          // What was actually found, not what was asked for.
          quality: torrent.quality,
          torrentHash: hash,
        ),
      );
    }
    await _log(
      r,
      AutoDownloadEventType.downloadStarted,
      quality: torrent.quality,
      message: 'Started downloading ${r.label}$inQuality.',
    );
    return started;
  }

  Future<void> _log(
    EpisodeGrabRequest r,
    AutoDownloadEventType type, {
    required String? quality,
    required String message,
  }) => ledger.log(
    type,
    showId: r.showId,
    showName: r.showName,
    season: r.season,
    episode: r.episode,
    quality: quality,
    message: message,
  );
}
