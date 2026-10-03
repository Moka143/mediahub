import '../../models/auto_download_event.dart';
import '../../models/auto_download_state.dart';
import '../../models/torrent.dart';
import '../../services/app_logger.dart';
import '../../services/auto_download_service.dart';
import 'auto_download_ledger.dart';

/// Every download auto-download believes is running, by queue key, with the
/// torrent behind it — null for a key an older build queued without one.
/// That is the queue, plus any tracked episode still marked downloading.
Map<String, String?> activeDownloads(AutoDownloadState state) {
  final active = <String, String?>{
    for (final key in state.downloadQueue) key: state.queuedTorrents[key],
  };
  for (final t in state.lastDownloadedEpisodes.values) {
    if (t.status != EpisodeDownloadStatus.downloading) continue;
    final key = downloadQueueKey(t.showId, t.season, t.episode);
    active[key] ??= t.torrentHash;
  }
  return active;
}

/// The torrent in [torrents] with [hash], ignoring case.
Torrent? engineTorrent(List<Torrent> torrents, String hash) {
  final wanted = hash.toLowerCase();
  return torrents.where((t) => t.hash.toLowerCase() == wanted).firstOrNull;
}

/// Keeps the auto-download record in step with the engine: a download that
/// finished is marked done, and one that left the engine unfinished — the
/// user deleted a stalled one, or switched engines — is released.
///
/// Nothing else ever cleared them: the queue key and the `downloading`
/// status were only cleared by completion, so a deleted download blocked
/// that episode, and the background check skipped the show, for good —
/// across restarts too, with no way to clear it from the UI. Now a
/// download missing from two checks in a row is released, its episode
/// set back to `awaitingTorrent` (the background check then looks for
/// another source, never the same torrent), and the log says so.
class EngineReconciler {
  EngineReconciler({required this.ledger, required this.markCompleted});

  final AutoDownloadLedger ledger;

  /// Records a finished download: the notifier's `markDownloadCompleted`,
  /// which the torrent list calls too.
  final Future<void> Function(String torrentHash) markCompleted;

  /// Queue keys whose torrent was missing from the engine on the last
  /// check. A second miss releases them; one miss could be the engine
  /// restarting.
  final Set<String> _missingOnce = {};

  /// Check every active download against [torrents], the engine's list —
  /// a real answer, never the empty list of a failed request.
  Future<void> reconcile(List<Torrent> torrents) async {
    final active = activeDownloads(ledger.state);
    for (final MapEntry(key: key, value: hash) in active.entries) {
      if (hash == null) {
        // Queued by an older build with no hash recorded. Look for the
        // episode by name; without a match there is nothing to wait for.
        if (_foundByName(key, torrents)) continue;
      } else {
        final torrent = engineTorrent(torrents, hash);
        if (torrent != null) {
          _missingOnce.remove(key);
          if (torrent.isCompleted) {
            await markCompleted(torrent.hash);
            if (!ledger.mounted) return;
          }
          continue;
        }
      }

      if (_missingOnce.add(key)) continue; // first miss: wait for a second
      _missingOnce.remove(key);
      await _releaseVanished(key, hash);
      if (!ledger.mounted) return;
    }
  }

  /// Whether [torrents] holds one named like the episode [key] tracks.
  bool _foundByName(String key, List<Torrent> torrents) {
    final tracking = trackingForKey(ledger.state, key);
    return tracking != null &&
        torrents.any(
          (t) => AutoDownloadService.torrentIsEpisode(
            t,
            tracking.showName,
            tracking.season,
            tracking.episode,
          ),
        );
  }

  Future<void> _releaseVanished(String key, String? hash) async {
    AppLog.i('[AutoDownload] $key left the engine unfinished — releasing it');
    await ledger.releaseQueued(key);
    if (!ledger.mounted) return;
    final tracking = trackingForKey(ledger.state, key);
    if (tracking == null ||
        tracking.status != EpisodeDownloadStatus.downloading) {
      return;
    }
    await ledger.updateTracking(
      tracking.showId,
      tracking.copyWith(
        status: EpisodeDownloadStatus.awaitingTorrent,
        torrentHash: hash ?? tracking.torrentHash,
      ),
    );
    await ledger.log(
      AutoDownloadEventType.downloadFailed,
      showId: tracking.showId,
      showName: tracking.showName,
      season: tracking.season,
      episode: tracking.episode,
      quality: tracking.quality,
      message:
          '${tracking.showName} ${tracking.episodeCode} left Transfers before '
          'it finished — another source will be tried.',
    );
  }

  /// Record that the torrent [torrentHash] finished.
  ///
  /// Releases every queue key recorded for the torrent, not only the one
  /// the show's tracking still points at — the tracking moves on to the next
  /// episode, and the earlier key used to stay in the queue for good.
  Future<void> completeDownload(String torrentHash) async {
    final hash = torrentHash.toLowerCase();
    for (final e in ledger.state.queuedTorrents.entries.toList()) {
      if (e.value.toLowerCase() != hash) continue;
      await ledger.releaseQueued(e.key);
      if (!ledger.mounted) return;
    }

    for (final entry in ledger.state.lastDownloadedEpisodes.entries.toList()) {
      final tracking = entry.value;
      if (tracking.torrentHash?.toLowerCase() != hash ||
          tracking.status != EpisodeDownloadStatus.downloading) {
        continue;
      }
      await ledger.updateTracking(
        entry.key,
        tracking.copyWith(status: EpisodeDownloadStatus.downloaded),
      );
      if (!ledger.mounted) return;
      await ledger.releaseQueued(
        downloadQueueKey(entry.key, tracking.season, tracking.episode),
      );
      await ledger.log(
        AutoDownloadEventType.downloadCompleted,
        showId: tracking.showId,
        showName: tracking.showName,
        season: tracking.season,
        episode: tracking.episode,
        quality: tracking.quality,
        message:
            '${tracking.showName} ${tracking.episodeCode} finished downloading.',
      );
      return;
    }
  }
}
