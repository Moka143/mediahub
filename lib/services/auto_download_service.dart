import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../models/episode.dart';
import '../models/eztv_torrent.dart';
import '../models/local_media_file.dart';
import '../models/torrent.dart';
import '../models/torrent_file.dart';
import '../models/torrentio_stream.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import '../utils/media_names.dart';
import '../utils/media_quality.dart';
import 'app_logger.dart';
import 'eztv_api_service.dart';
import 'json_prefs_store.dart';
import 'tmdb_api_service.dart';
import 'torrent_engine.dart';
import 'torrentio_api_service.dart';

/// Represents the status of an episode for auto-download tracking.
///
/// Persisted by index: append new values at the end, never reorder or remove
/// one, or every stored tracking entry changes meaning.
enum EpisodeDownloadStatus {
  /// Episode is not yet available according to TMDB
  notAired,

  /// Aired, but no download of it is in Transfers — none was found yet, or
  /// the one that was started left Transfers before it finished. The
  /// periodic check retries these.
  awaitingTorrent,

  /// Reserved. Never written; kept so the indices after it stay put.
  available,

  /// Currently downloading
  downloading,

  /// Downloaded and ready to watch
  downloaded,

  /// Episode watched
  watched,
}

/// Tracks episode information for auto-download
class EpisodeTrackingInfo {
  final int showId;
  final String? imdbId;
  final String showName;
  final int season;
  final int episode;
  final EpisodeDownloadStatus status;
  final String? quality;

  /// The torrent fetching (or that fetched) this episode. Kept with
  /// [EpisodeDownloadStatus.awaitingTorrent] too, as the one *not* to pick
  /// again: it is the download that just failed.
  final String? torrentHash;

  EpisodeTrackingInfo({
    required this.showId,
    this.imdbId,
    required this.showName,
    required this.season,
    required this.episode,
    required this.status,
    this.quality,
    this.torrentHash,
  });

  String get episodeCode => Formatters.episodeCode(season, episode);

  EpisodeTrackingInfo copyWith({
    int? showId,
    String? imdbId,
    String? showName,
    int? season,
    int? episode,
    EpisodeDownloadStatus? status,
    String? quality,
    String? torrentHash,
  }) {
    return EpisodeTrackingInfo(
      showId: showId ?? this.showId,
      imdbId: imdbId ?? this.imdbId,
      showName: showName ?? this.showName,
      season: season ?? this.season,
      episode: episode ?? this.episode,
      status: status ?? this.status,
      quality: quality ?? this.quality,
      torrentHash: torrentHash ?? this.torrentHash,
    );
  }

  Map<String, dynamic> toJson() => {
    'show_id': showId,
    'imdb_id': imdbId,
    'show_name': showName,
    'season': season,
    'episode': episode,
    'status': status.index,
    'quality': quality,
    'torrent_hash': torrentHash,
  };

  /// Throws on a malformed entry — including a status index this build does
  /// not know — so the loader drops this one entry, not every show's.
  factory EpisodeTrackingInfo.fromJson(Map<String, dynamic> json) {
    return EpisodeTrackingInfo(
      showId: json['show_id'] as int,
      imdbId: json['imdb_id'] as String?,
      showName: json['show_name'] as String,
      season: json['season'] as int,
      episode: json['episode'] as int,
      // Entries written before `status` existed have none: the first state.
      status: enumFromJson(
        EpisodeDownloadStatus.values,
        json['status'],
        EpisodeDownloadStatus.notAired,
      ),
      quality: json['quality'] as String?,
      torrentHash: json['torrent_hash'] as String?,
    );
  }
}

/// Result of next episode lookup
class NextEpisodeResult {
  /// The episode after the one asked about — aired or not; see [hasAired].
  final Episode? nextEpisode;

  /// Whether [nextEpisode] has aired ([airDateHasPassed]). Anything that
  /// would look for a torrent must check this: next week's episode has
  /// none, and searching for it is a guaranteed "No torrent found".
  final bool hasAired;

  /// The show has no seasons after this one.
  final bool isSeriesEnd;

  /// TMDB could not be asked — "no next episode" means nothing then.
  final bool lookupFailed;

  /// What happened, in a sentence for the activity log.
  final String? message;

  NextEpisodeResult({
    this.nextEpisode,
    this.hasAired = false,
    this.isSeriesEnd = false,
    this.lookupFailed = false,
    this.message,
  });

  bool get hasNextEpisode => nextEpisode != null;
}

/// Service for managing auto-download of next episodes
class AutoDownloadService {
  final TmdbApiService _tmdbService;
  final EztvApiService _eztvService;
  final TorrentEngine _engine;
  final TorrentioApiService _torrentioService;
  final DateTime Function() _clock;

  /// How long to wait for a season pack's file list before giving up on
  /// picking one episode out of it.
  final Duration metadataTimeout;

  /// How often to ask for it meanwhile.
  final Duration metadataPollInterval;

  AutoDownloadService({
    required TmdbApiService tmdbService,
    required EztvApiService eztvService,
    required TorrentEngine engine,
    required TorrentioApiService torrentioService,
    DateTime Function()? clock,
    this.metadataTimeout = const Duration(minutes: 2),
    this.metadataPollInterval = const Duration(seconds: 2),
  }) : _tmdbService = tmdbService,
       _eztvService = eztvService,
       _engine = engine,
       _torrentioService = torrentioService,
       _clock = clock ?? DateTime.now;

  /// Get the next episode for a show after the given season/episode.
  ///
  /// Returns the next episode whether or not it has aired, flagged with
  /// [NextEpisodeResult.hasAired]; callers that fetch must check it.
  Future<NextEpisodeResult> getNextEpisode({
    required int showId,
    required int currentSeason,
    required int currentEpisode,
  }) async {
    try {
      final show = await _tmdbService.getShowDetails(showId);
      final totalSeasons = show.numberOfSeasons ?? 0;

      final currentSeasonEpisodes = await _tmdbService.getSeasonEpisodes(
        showId,
        currentSeason,
      );

      final nextInSeason = currentSeasonEpisodes
          .where((e) => e.episodeNumber == currentEpisode + 1)
          .firstOrNull;
      if (nextInSeason != null) {
        final aired = _aired(nextInSeason);
        return NextEpisodeResult(
          nextEpisode: nextInSeason,
          hasAired: aired,
          message: aired ? null : _airsOn(nextInSeason),
        );
      }

      if (currentSeason >= totalSeasons) {
        return NextEpisodeResult(
          isSeriesEnd: true,
          message: 'The series has ended — there are no more seasons.',
        );
      }

      final nextSeason = currentSeason + 1;
      try {
        final nextSeasonEpisodes = await _tmdbService.getSeasonEpisodes(
          showId,
          nextSeason,
        );
        if (nextSeasonEpisodes.isNotEmpty) {
          final firstEp = nextSeasonEpisodes.first;
          final aired = _aired(firstEp);
          return NextEpisodeResult(
            nextEpisode: firstEp,
            hasAired: aired,
            message: aired ? 'Moving to season $nextSeason.' : _airsOn(firstEp),
          );
        }
      } catch (e) {
        // TMDB lists a season before it has any episode records.
        AppLog.d('[AutoDownload] season $nextSeason of $showId not out: $e');
      }

      return NextEpisodeResult(message: 'Season $nextSeason is not out yet.');
    } catch (e) {
      AppLog.w('[AutoDownload] next-episode lookup for $showId failed: $e');
      return NextEpisodeResult(
        lookupFailed: true,
        message: "Couldn't check TMDB for the next episode.",
      );
    }
  }

  bool _aired(Episode e) => airDateHasPassed(e.airDate, now: _clock());

  static String _airsOn(Episode e) {
    final date = parseAirDate(e.airDate);
    return date == null
        ? '${e.episodeCode} has no air date yet.'
        : '${e.episodeCode} airs ${formatAirDate(date)}.';
  }

  /// A TMDB air date as "Oct 10" (or "Oct 10, 2027" when not this year).
  static String formatAirDate(DateTime date) => date.year == DateTime.now().year
      ? DateFormat.MMMd().format(date)
      : DateFormat.yMMMd().format(date);

  /// Whether the library already holds [season]x[episode] of [showName].
  ///
  /// The same show, not one whose name contains the other — "Dark Matter"
  /// S01E01 on disk used to count as "Dark" S01E01, and the real one was
  /// never fetched. When both sides know the TMDB [showId], that decides.
  bool isEpisodeDownloaded({
    required List<LocalMediaFile> downloadedFiles,
    required String showName,
    required int season,
    required int episode,
    int? showId,
  }) {
    return downloadedFiles.any((file) {
      if (file.seasonNumber != season || file.episodeNumber != episode) {
        return false;
      }
      final fileShowId = file.showId;
      if (showId != null && fileShowId != null) return fileShowId == showId;
      final fileShow = file.showName;
      return fileShow != null && titlesMatch(fileShow, showName);
    });
  }

  /// Upper bound on a *candidate* torrent's size when picking a source to
  /// stream. Smaller files reach the play threshold sooner.
  ///
  /// Streaming only: a download is meant to be kept, and capping it threw
  /// away the per-show quality preference — a 2.1 GB 1080p release lost to
  /// an 800 MB 720p one for every show.
  ///
  /// Unrelated to `StreamingService`'s buffer model (80–500 MB, or 10% of the
  /// file), which decides when playback may start once a source is chosen.
  static const int maxStreamingSizeBytes = 900 * 1024 * 1024; // 900 MB

  /// Find a torrent for [season]x[episode] of the show [imdbId].
  ///
  /// EZTV and Torrentio are asked **at the same time**: EZTV first meant a
  /// blocked EZTV domain held every lookup for its full timeout before
  /// Torrentio was even asked. The choice between them is
  /// [pickEpisodeTorrent]'s.
  ///
  /// [forStreaming] caps the size ([maxStreamingSizeBytes]); downloads pass
  /// false. [excludeHashes] are never picked — a download that failed and
  /// should not be retried with the same torrent.
  Future<EztvTorrent?> findTorrentForEpisode({
    required String imdbId,
    required int season,
    required int episode,
    String? preferredQuality,
    bool forStreaming = true,
    Set<String> excludeHashes = const {},
  }) async {
    final code = Formatters.episodeCode(season, episode);
    final (eztv, torrentio) = await (
      _eztvService
          .getTorrentsForEpisode(imdbId, season: season, episode: episode)
          .then<List<EztvTorrent>>(
            (list) => list,
            onError: (Object e) {
              AppLog.w('[AutoDownload] EZTV lookup for $code failed: $e');
              return <EztvTorrent>[];
            },
          ),
      _torrentioService
          .getSeriesStreams(imdbId, season: season, episode: episode)
          .then<List<TorrentioStream>>(
            (response) => response.streams,
            onError: (Object e) {
              AppLog.w('[AutoDownload] Torrentio lookup for $code failed: $e');
              return <TorrentioStream>[];
            },
          ),
    ).wait;

    final pick = pickEpisodeTorrent(
      eztv: eztv,
      torrentio: torrentio,
      season: season,
      episode: episode,
      preferredQuality: preferredQuality,
      maxSizeBytes: forStreaming ? maxStreamingSizeBytes : null,
      excludeHashes: excludeHashes,
    );
    AppLog.d(
      '[AutoDownload] $code ($imdbId): ${eztv.length} EZTV, '
      '${torrentio.length} Torrentio → '
      '${pick == null ? "nothing" : "${pick.title} (${pick.seeds} seeds)"}',
    );
    return pick;
  }

  /// Choose a source for an episode — pure, so the ranking is testable.
  ///
  /// In order of preference:
  ///  1. EZTV releases **with seeds**, preferred quality first, then quality,
  ///     then seeds. A 0-seed 720p used to beat a 40-seed HDTV here and the
  ///     stream never started, while Torrentio had healthy sources.
  ///  2. Torrentio's best seeded release (one episode over a season pack).
  ///  3. Releases with no seeds reported, EZTV first — a brand-new release
  ///     often lists 0 seeds until the indexer catches up.
  ///  4. With [maxSizeBytes], releases over it, as a last resort.
  ///
  /// [maxSizeBytes] prefers releases of known size within it, then those of
  /// unknown size.
  @visibleForTesting
  static EztvTorrent? pickEpisodeTorrent({
    required List<EztvTorrent> eztv,
    required List<TorrentioStream> torrentio,
    required int season,
    required int episode,
    String? preferredQuality,
    int? maxSizeBytes,
    Set<String> excludeHashes = const {},
  }) {
    final excluded = {for (final h in excludeHashes) h.toLowerCase()};
    final eztvAll = [
      for (final t in eztv)
        if (t.magnetUrl.isNotEmpty && !excluded.contains(t.hash.toLowerCase()))
          t,
    ];
    final tioAll = [
      for (final s in torrentio)
        if (s.infoHash.isNotEmpty &&
            !excluded.contains(s.infoHash.toLowerCase()))
          s,
    ];

    List<T> sized<T>(List<T> all, int Function(T) size) {
      if (maxSizeBytes == null) return all;
      final within = all
          .where((t) => size(t) > 0 && size(t) <= maxSizeBytes)
          .toList();
      return within.isNotEmpty
          ? within
          : all.where((t) => size(t) == 0).toList();
    }

    final eztvPool = sized(eztvAll, (t) => t.sizeBytes);
    final tioPool = sized(tioAll, (s) => s.sizeBytes);

    final eztvSeeded = eztvPool.where((t) => t.seeds > 0).toList();
    if (eztvSeeded.isNotEmpty) {
      return rankEztv(eztvSeeded, preferredQuality).first;
    }
    final tioBest = tioPool.isEmpty
        ? null
        : rankTorrentio(tioPool, preferredQuality).first;
    if (tioBest != null && tioBest.seeders > 0) {
      return _fromTorrentio(tioBest, season, episode);
    }
    if (eztvPool.isNotEmpty) return rankEztv(eztvPool, preferredQuality).first;
    if (tioBest != null) return _fromTorrentio(tioBest, season, episode);
    if (maxSizeBytes != null && tioAll.isNotEmpty) {
      return _fromTorrentio(
        rankTorrentio(tioAll, preferredQuality).first,
        season,
        episode,
      );
    }
    return null;
  }

  /// EZTV releases best first: preferred quality, then quality, then seeds.
  ///
  /// [qualityMatches], not `==`: the preference arrives as whatever an older
  /// build stored (`1080P`, `4K`) and must still match `1080p` / `2160p`.
  @visibleForTesting
  static List<EztvTorrent> rankEztv(
    List<EztvTorrent> torrents,
    String? preferredQuality,
  ) {
    return [...torrents]..sort((a, b) {
      if (preferredQuality != null) {
        final aMatches = qualityMatches(a.quality, preferredQuality);
        final bMatches = qualityMatches(b.quality, preferredQuality);
        if (aMatches != bMatches) return aMatches ? -1 : 1;
      }
      final byQuality = b.qualityPriority.compareTo(a.qualityPriority);
      if (byQuality != 0) return byQuality;
      return b.seeds.compareTo(a.seeds);
    });
  }

  /// Torrentio streams best first: seeded over dead, one episode over a
  /// season pack, preferred quality, then the streaming score.
  @visibleForTesting
  static List<TorrentioStream> rankTorrentio(
    List<TorrentioStream> streams,
    String? preferredQuality,
  ) {
    var pool = streams;
    final seeded = pool.where((s) => s.seeders > 0).toList();
    if (seeded.isNotEmpty) pool = seeded;
    final singles = pool.where((s) => s.isSingleEpisodeRelease).toList();
    if (singles.isNotEmpty) pool = singles;
    return [...pool]..sort((a, b) {
      if (preferredQuality != null) {
        final aMatches = qualityMatches(a.quality, preferredQuality);
        final bMatches = qualityMatches(b.quality, preferredQuality);
        if (aMatches != bMatches) return aMatches ? -1 : 1;
      }
      return b.streamingScore.compareTo(a.streamingScore);
    });
  }

  /// A Torrentio stream in the shape the download paths take. `fileIdx`
  /// rides along: it is what picks the episode out of a season pack.
  static EztvTorrent _fromTorrentio(
    TorrentioStream stream,
    int season,
    int episode,
  ) => EztvTorrent(
    id: 0,
    hash: stream.infoHash,
    filename: stream.filename ?? stream.title,
    title: stream.title,
    magnetUrl: stream.magnetUri,
    sizeBytes: stream.sizeBytes,
    seeds: stream.seeders,
    season: season,
    episode: episode,
    fileIdx: stream.fileIdx,
  );

  /// Add a torrent for download and, when it is a season pack ([fileIdx]),
  /// make it fetch only that episode.
  ///
  /// Returns whether the torrent was added. The pack trimming waits for the
  /// torrent's file list ([selectEpisodeFile]); with
  /// [waitForFileSelection] false it carries on in the background, for a
  /// caller with a person waiting on the answer.
  Future<bool> downloadNextEpisode({
    required String magnetLink,
    String? savePath,
    String? infoHash,
    int? fileIdx,
    bool waitForFileSelection = true,
  }) async {
    final bool added;
    try {
      // Sequential, like StreamingService: an episode queued for later is
      // often opened before it finishes, and in-order pieces make the
      // finished part playable.
      added = await _engine.addTorrent(
        magnetLink: magnetLink,
        savePath: savePath,
        sequentialDownload: true,
      );
    } catch (e) {
      AppLog.e('[AutoDownload] adding the torrent failed: $e');
      return false;
    }
    if (!added) return false;

    if (fileIdx != null && infoHash != null && infoHash.isNotEmpty) {
      final selection = selectEpisodeFile(infoHash, fileIdx);
      if (waitForFileSelection) {
        await selection;
      } else {
        unawaited(selection);
      }
    }
    return true;
  }

  /// Make the season pack [hash] fetch only file [fileIdx].
  ///
  /// Waits for the file list to exist — up to [metadataTimeout]. A magnet
  /// has no file list until its metadata arrives, which on qBittorrent is
  /// rarely within the fixed two seconds this used to wait, so nothing was
  /// deselected and the whole pack downloaded. Every engine answer is
  /// checked; a refusal is reported (false), not logged as done.
  ///
  /// Only *incomplete* extras are skipped: deselecting a finished file can
  /// send qBittorrent into a recheck that parks sequential download.
  Future<bool> selectEpisodeFile(String hash, int fileIdx) async {
    final waited = Stopwatch()..start();
    var files = <TorrentFile>[];
    while (true) {
      try {
        files = await _engine.getTorrentFiles(hash);
      } catch (e) {
        AppLog.d('[AutoDownload] file list for $hash not ready: $e');
      }
      if (files.isNotEmpty) break;
      if (waited.elapsed >= metadataTimeout) {
        AppLog.w(
          '[AutoDownload] no file list for $hash after '
          '${metadataTimeout.inSeconds}s — the whole pack will download',
        );
        return false;
      }
      await Future<void>.delayed(metadataPollInterval);
    }

    if (!files.any((f) => f.index == fileIdx)) {
      AppLog.w(
        '[AutoDownload] $hash has no file $fileIdx (${files.length} files)',
      );
      return false;
    }

    final skip = [
      for (final f in files)
        if (f.index != fileIdx && !f.isNearlyComplete) f.index,
    ];
    final skipped =
        skip.isEmpty ||
        await _setPriority(hash, skip, FilePriority.doNotDownload);
    // Top priority where the engine has priorities; an include/exclude-only
    // engine reads any non-zero value as "download it".
    final selected = await _setPriority(hash, [fileIdx], FilePriority.maximum);

    if (skipped && selected) {
      AppLog.d(
        '[AutoDownload] $hash: fetching file $fileIdx only '
        '(${skip.length} of ${files.length} skipped)',
      );
    } else {
      AppLog.w(
        '[AutoDownload] $hash: the engine refused the file selection '
        '(skip ok: $skipped, select ok: $selected)',
      );
    }
    return skipped && selected;
  }

  Future<bool> _setPriority(
    String hash,
    List<int> ids,
    FilePriority priority,
  ) async {
    try {
      return await _engine.setFilePriority(hash, ids, priority.value);
    } catch (e) {
      AppLog.w('[AutoDownload] setFilePriority failed for $hash: $e');
      return false;
    }
  }

  /// Whether a torrent for [season]x[episode] of [showName] is already in the
  /// engine — queued by an earlier run, or added by hand.
  ///
  /// Same title matching as everywhere else: mapping spaces to dots turned
  /// "Mr. Robot" into `mr..robot`, which never matched `Mr.Robot.S04E01`,
  /// and a duplicate was queued.
  Future<bool> isEpisodeCurrentlyDownloading({
    required String showName,
    required int season,
    required int episode,
  }) async {
    try {
      final torrents = await _engine.getTorrents();
      return torrents.any(
        (t) => torrentIsEpisode(t, showName, season, episode),
      );
    } catch (e) {
      return false;
    }
  }

  /// Whether [torrent] is [season]x[episode] of [showName], by its name.
  static bool torrentIsEpisode(
    Torrent torrent,
    String showName,
    int season,
    int episode,
  ) {
    if (!nameHasEpisode(torrent.name, season, episode)) return false;
    final show = showQueryFromName(torrent.name);
    return show != null && titlesMatch(show.title, showName);
  }

  /// The engine's torrents — or null when the engine cannot be trusted to
  /// have answered.
  ///
  /// Both engines answer a failed list request with an empty list, which
  /// reads exactly like "the user deleted everything". Anything that clears
  /// state for torrents that have gone must not act on that, so the engine
  /// has to be reachable on both sides of the request.
  Future<List<Torrent>?> engineTorrents() async {
    try {
      if (!await _engine.testConnection()) return null;
      final torrents = await _engine.getTorrents();
      if (torrents.isEmpty && !await _engine.testConnection()) return null;
      return torrents;
    } catch (e) {
      AppLog.d('[AutoDownload] engine list unavailable: $e');
      return null;
    }
  }

  /// The show's IMDB id, which both indexers search by — from TMDB's external
  /// ids. Null when TMDB has none for it. Throws when TMDB is unreachable.
  Future<String?> imdbIdForShow(int showId) =>
      _tmdbService.getShowImdbId(showId);

  /// TMDB's record of one episode, or null when TMDB does not list it.
  /// Throws when TMDB is unreachable.
  Future<Episode?> episodeDetails(int showId, int season, int episode) async {
    final episodes = await _tmdbService.getSeasonEpisodes(showId, season);
    return episodes.where((e) => e.episodeNumber == episode).firstOrNull;
  }

  /// Whether [episode] has aired by now. See [airDateHasPassed].
  bool hasAired(Episode episode) => _aired(episode);

  /// When [episode] counts as aired — the moment to look again.
  DateTime? airsAt(Episode episode) =>
      parseAirDate(episode.airDate)?.add(airDateGrace);
}
