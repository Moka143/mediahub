import '../../models/auto_download_event.dart';
import '../../models/episode.dart';
import '../../models/episode_grab_result.dart';
import '../../services/app_logger.dart';
import '../../services/auto_download_service.dart';
import '../../utils/formatters.dart';
import 'auto_download_ledger.dart';
import 'engine_reconciler.dart';
import 'episode_grabber.dart';

/// Decides whether an episode can be fetched yet, and hands it to the grab.
///
/// Two ways in: the episode after the one a show is at, once it has aired
/// ([fetchNextAfter]), and one asked for by hand ([fetchNow]). The grab
/// itself is [EpisodeGrabber]'s, reached through [grab] so that it sees the
/// engine and the settings as they are by then. Run both under the show's
/// lock.
///
/// Long-lived: it remembers, in memory, which waits it has announced.
class EpisodeFetcher {
  EpisodeFetcher({
    required this.ledger,
    required this.quietUntil,
    required this.grab,
    required this.qualityFor,
  });

  final AutoDownloadLedger ledger;

  /// Shows the background check should not ask TMDB about again before the
  /// given time. Written here for a show waiting on an episode to air or
  /// with nothing left to fetch.
  final Map<int, DateTime> quietUntil;

  /// Fetch an episode that can be fetched.
  final Future<EpisodeGrabResult> Function(EpisodeGrabRequest request) grab;

  /// The quality to ask for, for a show.
  final String Function(int showId) qualityFor;

  /// How long a show with nothing to fetch (series over, season not
  /// announced) is left alone by the background check.
  static const Duration idleBackoff = Duration(hours: 24);

  /// Episodes already announced as waiting to air, so the log says it once.
  final Set<String> _announcedWaits = {};

  /// Fetch the episode after [season]x[episode], if it has aired.
  Future<void> fetchNextAfter(
    AutoDownloadService service, {
    required int showId,
    required String imdbId,
    required String showName,
    required int season,
    required int episode,
    required String quality,
    required bool announce,
  }) async {
    final next = await service.getNextEpisode(
      showId: showId,
      currentSeason: season,
      currentEpisode: episode,
    );
    if (!ledger.mounted) return;

    final nextEp = next.nextEpisode;
    if (nextEp == null) {
      // A finished series, or a season not announced: nothing to ask TMDB
      // again for a while. A failed lookup is retried on the next pass.
      if (!next.lookupFailed) {
        quietUntil[showId] = DateTime.now().add(idleBackoff);
      }
      if (announce) {
        await ledger.log(
          AutoDownloadEventType.checked,
          showId: showId,
          showName: showName,
          season: season,
          episode: episode,
          message: next.message ?? 'No next episode yet.',
        );
      }
      return;
    }

    if (!next.hasAired) {
      // Not yet: nothing to search for, and nothing to ask TMDB again until
      // it airs. This used to search the indexers anyway, every time.
      quietUntil[showId] =
          service.airsAt(nextEp) ?? DateTime.now().add(idleBackoff);
      final key = downloadQueueKey(
        showId,
        nextEp.seasonNumber,
        nextEp.episodeNumber,
      );
      if (announce && _announcedWaits.add(key)) {
        await ledger.log(
          AutoDownloadEventType.episodeQueued,
          showId: showId,
          showName: showName,
          season: nextEp.seasonNumber,
          episode: nextEp.episodeNumber,
          message:
              '$showName ${nextEp.episodeCode} will download once it airs'
              '${_airDateSuffix(nextEp)}.',
        );
      }
      return;
    }

    await grab(
      EpisodeGrabRequest(
        showId: showId,
        imdbId: imdbId,
        showName: showName,
        season: nextEp.seasonNumber,
        episode: nextEp.episodeNumber,
        quality: quality,
        announce: announce,
      ),
    );
  }

  static String _airDateSuffix(Episode episode) {
    final date = parseAirDate(episode.airDate);
    return date == null ? '' : ' (${AutoDownloadService.formatAirDate(date)})';
  }

  /// Fetch [season]x[episode] now, for someone waiting on the answer.
  ///
  /// An episode TMDB says has not aired is not searched for. Resolves the
  /// IMDB id itself (from TMDB's external ids) when [imdbId] is null.
  Future<EpisodeGrabResult> fetchNow(
    AutoDownloadService service, {
    required int showId,
    required String showName,
    String? imdbId,
    required int season,
    required int episode,
  }) async {
    final label = '$showName ${Formatters.episodeCode(season, episode)}';
    final notAired = await _notAiredYet(
      service,
      showId: showId,
      season: season,
      episode: episode,
      label: label,
    );
    if (notAired != null) return notAired;
    if (!ledger.mounted) return grabFailed;

    var imdb = imdbId;
    if (imdb == null || imdb.isEmpty) {
      try {
        imdb = await service.imdbIdForShow(showId);
      } catch (e) {
        AppLog.w('[AutoDownload] IMDB id for $showName unavailable: $e');
        return const EpisodeGrabResult(
          EpisodeGrabOutcome.failed,
          "Couldn't reach TMDB. Check your connection and try again.",
        );
      }
    }
    if (imdb == null || imdb.isEmpty) {
      return EpisodeGrabResult(
        EpisodeGrabOutcome.failed,
        "Couldn't search for $label: TMDB has no IMDb id for $showName.",
      );
    }
    if (!ledger.mounted) return grabFailed;

    final key = downloadQueueKey(showId, season, episode);
    if (ledger.state.downloadQueue.contains(key)) {
      await _releaseIfGone(service, key);
      if (!ledger.mounted) return grabFailed;
    }

    return grab(
      EpisodeGrabRequest(
        showId: showId,
        imdbId: imdb,
        showName: showName,
        season: season,
        episode: episode,
        quality: qualityFor(showId),
        announce: true,
        // Someone is waiting on the answer; trimming a season pack to this
        // episode can carry on without them.
        waitForFileSelection: false,
      ),
    );
  }

  /// A [EpisodeGrabOutcome.notAired] answer when TMDB says [season]x[episode]
  /// has not aired yet, or null to go on.
  ///
  /// Also null without the date (TMDB unreachable): try anyway — a release
  /// existing is its own proof.
  Future<EpisodeGrabResult?> _notAiredYet(
    AutoDownloadService service, {
    required int showId,
    required int season,
    required int episode,
    required String label,
  }) async {
    try {
      final details = await service.episodeDetails(showId, season, episode);
      if (details != null && !service.hasAired(details)) {
        final date = parseAirDate(details.airDate);
        return EpisodeGrabResult(
          EpisodeGrabOutcome.notAired,
          date == null
              ? "$label hasn't aired yet."
              : '$label airs ${AutoDownloadService.formatAirDate(date)}.',
        );
      }
    } catch (e) {
      AppLog.w('[AutoDownload] air date of $label unavailable: $e');
    }
    return null;
  }

  /// Release the queued [key] when its torrent is no longer in the engine.
  ///
  /// A queued key whose torrent is gone from Transfers is stale — the user
  /// is asking again, so look now rather than waiting for the background
  /// check to notice.
  Future<void> _releaseIfGone(AutoDownloadService service, String key) async {
    final torrents = await service.engineTorrents();
    if (torrents == null || !ledger.mounted) return;
    final hash = ledger.state.queuedTorrents[key];
    if (hash != null && engineTorrent(torrents, hash) == null) {
      await ledger.releaseQueued(key);
    }
  }
}
