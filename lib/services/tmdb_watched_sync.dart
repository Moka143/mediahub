import '../models/local_media_file.dart';
import '../models/watch_progress.dart';
import '../models/watched_index.dart';
import '../utils/formatters.dart';
import '../utils/media_names.dart';
import '../utils/platform_utils.dart';
import 'tmdb_account_service.dart';
import 'tmdb_title_resolver.dart';

/// The TMDB item a watched mark is about.
///
/// TMDB has no "watched" flag at any level, so the app uses a rating as the
/// proxy: rated 10 ↔ watched, rating deleted ↔ not watched. Ratings exist per
/// episode, per show and per movie — hence three kinds of target.
sealed class WatchedTarget {
  const WatchedTarget();
}

/// One episode of a show.
final class EpisodeTarget extends WatchedTarget {
  const EpisodeTarget(this.showId, this.season, this.episode);

  final int showId;
  final int season;
  final int episode;

  /// The shared identity — the same key [WatchedIndex] indexes by.
  String get key => WatchedIndex.episodeKey(showId, season, episode);
}

/// A whole show: a file that is show-shaped but names no episode.
final class ShowTarget extends WatchedTarget {
  const ShowTarget(this.showId);

  final int showId;
}

/// A movie.
final class MovieTarget extends WatchedTarget {
  const MovieTarget(this.movieId);

  final int movieId;
}

/// Reads and writes the user's watched state on TMDB.
///
/// Holds what every push needs — the account service, its account id and the
/// title resolver — so the three places that push (marking from the
/// library, finishing something in the player, and the launch reconcile)
/// share one implementation instead of three that each resolved titles their
/// own way.
class TmdbWatchedSync {
  TmdbWatchedSync({
    required this.account,
    required this.resolver,
    required this.accountId,
  });

  final TmdbAccountService account;
  final TmdbTitleResolver resolver;
  final int accountId;

  /// What a watched mark refers to on TMDB, from whatever its row or file
  /// carries.
  ///
  /// Ids already known win. Otherwise the title is resolved from the file
  /// name — which keeps the year — or from [showName], and only an
  /// unambiguous match counts ([TmdbTitleResolver]). Null when the item
  /// cannot be identified; nothing should then be written to TMDB. Throws
  /// when TMDB cannot be reached, so the caller can keep the push pending.
  Future<WatchedTarget?> targetFor({
    required String path,
    String? showName,
    int? season,
    int? episode,
    int? showId,
    int? movieId,
  }) async {
    if (season != null && episode != null) {
      final id = showId ?? await _resolveShow(path, showName);
      return id == null ? null : EpisodeTarget(id, season, episode);
    }
    if (showId != null) return ShowTarget(showId);
    if (movieId != null) return MovieTarget(movieId);
    if (WatchProgress.isSyntheticPath(path)) return null;
    final query = movieQueryFromFileName(basenameOf(path));
    if (query == null) return null;
    final id = await resolver.movieId(query);
    return id == null ? null : MovieTarget(id);
  }

  Future<int?> _resolveShow(String path, String? showName) async {
    final fromFile = WatchProgress.isSyntheticPath(path)
        ? null
        : showQueryFromName(basenameOf(path));
    final query =
        fromFile ??
        (showName == null || showName.trim().isEmpty
            ? null
            : (title: showName, year: null));
    if (query == null) return null;
    return resolver.showId(query);
  }

  /// Record [target] as watched (or not) on TMDB.
  ///
  /// Watching a movie or a whole show also takes it off the watchlist — the
  /// "done" proxy. Un-watching does not put it back: that is a decision the
  /// user should make explicitly. Throws on any failure.
  Future<void> push(WatchedTarget target, {required bool watched}) async {
    const value = TmdbAccountService.watchedRatingValue;
    switch (target) {
      case EpisodeTarget(:final showId, :final season, :final episode):
        if (watched) {
          await account.rateEpisode(
            seriesId: showId,
            seasonNumber: season,
            episodeNumber: episode,
            value: value,
          );
        } else {
          await account.deleteEpisodeRating(
            seriesId: showId,
            seasonNumber: season,
            episodeNumber: episode,
          );
        }
      case ShowTarget(:final showId):
        if (watched) {
          await Future.wait([
            account.rateShow(seriesId: showId, value: value),
            account.setWatchlist(
              accountId: accountId,
              mediaType: TmdbMediaType.tv,
              mediaId: showId,
              watchlist: false,
            ),
          ]);
        } else {
          await account.deleteShowRating(seriesId: showId);
        }
      case MovieTarget(:final movieId):
        if (watched) {
          await Future.wait([
            account.rateMovie(movieId: movieId, value: value),
            account.setWatchlist(
              accountId: accountId,
              mediaType: TmdbMediaType.movie,
              mediaId: movieId,
              watchlist: false,
            ),
          ]);
        } else {
          await account.deleteMovieRating(movieId: movieId);
        }
    }
  }
}

/// What a TMDB reconcile changes locally, worked out before any of it is
/// applied.
class WatchedReconcilePlan {
  const WatchedReconcilePlan({required this.upserts, required this.unwatch});

  /// Rows to store as watched, keyed by file hash: existing rows TMDB says
  /// are watched, and new synthetic rows for things rated on another device.
  final Map<String, WatchProgress> upserts;

  /// Paths whose explicit mark follows a rating removed elsewhere.
  final Set<String> unwatch;

  bool get isEmpty => upserts.isEmpty && unwatch.isEmpty;
}

/// Compare local watched state with TMDB's ratings and decide what to
/// change locally — TMDB wins, with three exceptions that keep local data
/// from being clobbered:
///
///  * a row whose own change has not reached TMDB yet
///    ([WatchProgress.tmdbPushPending]) is left alone — "not rated" is only
///    the old state;
///  * a title actually played to the credits is never un-marked
///    ([WatchProgress.followsRemoteUnwatch]);
///  * an item that cannot be identified is left alone.
///
/// Every library file and every progress row is considered, synthetic rows
/// included — `tmdb:rated-movie:` rows used to be skipped, so a movie
/// un-rated elsewhere stayed watched here forever, and was re-marked (with a
/// full rewrite of the history) on every launch. Rows that would not change
/// produce nothing, so a pass with nothing new writes nothing.
///
/// [resolvedShowIds] / [resolvedMovieIds] carry TMDB ids, by path, for rows
/// and files that do not store one.
WatchedReconcilePlan planWatchedReconcile({
  required Map<String, WatchProgress> progress,
  required List<LocalMediaFile> files,
  required List<({int showId, int season, int episode})> ratedEpisodes,
  required Set<int> ratedMovieIds,
  Map<String, int> resolvedShowIds = const {},
  Map<String, int> resolvedMovieIds = const {},
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final ratedKeys = {
    for (final e in ratedEpisodes)
      WatchedIndex.episodeKey(e.showId, e.season, e.episode),
  };
  final filesByPath = {for (final f in files) f.path: f};
  final paths = <String>{
    ...filesByPath.keys,
    for (final p in progress.values) p.filePath,
  };

  final upserts = <String, WatchProgress>{};
  final unwatch = <String>{};
  final coveredEpisodes = <String>{};
  final coveredMovies = <int>{};

  void follow(String path, WatchProgress? row, bool rated, WatchProgress mark) {
    final watched = row?.isEffectivelyWatched ?? false;
    if (rated && !watched) {
      upserts[mark.fileHash] = mark;
    } else if (!rated && watched && row!.followsRemoteUnwatch) {
      unwatch.add(path);
    }
  }

  for (final path in paths) {
    final file = filesByPath[path];
    final hash = WatchProgress.generateHash(path);
    final row = progress[hash];
    if (row != null && row.tmdbPushPending) continue;

    final season = file?.seasonNumber ?? row?.seasonNumber;
    final episode = file?.episodeNumber ?? row?.episodeNumber;
    if (season != null && episode != null) {
      final showId = file?.showId ?? row?.showId ?? resolvedShowIds[path];
      if (showId == null) continue;
      final key = WatchedIndex.episodeKey(showId, season, episode);
      coveredEpisodes.add(key);
      follow(
        path,
        row,
        ratedKeys.contains(key),
        _watchedRow(
          path,
          row,
          file,
          now: at,
          showId: showId,
          season: season,
          episode: episode,
        ),
      );
      continue;
    }

    final movieId = row?.movieId ?? resolvedMovieIds[path];
    if (movieId == null) continue;
    coveredMovies.add(movieId);
    follow(
      path,
      row,
      ratedMovieIds.contains(movieId),
      _watchedRow(path, row, file, now: at, movieId: movieId),
    );
  }

  // Rated on TMDB with nothing here to carry the mark — watched on another
  // device and never downloaded on this one. A synthetic row gives the mark
  // somewhere to live; the episodes drawer matches on (show, season,
  // episode), not on the path.
  for (final e in ratedEpisodes) {
    final key = WatchedIndex.episodeKey(e.showId, e.season, e.episode);
    if (!coveredEpisodes.add(key)) continue;
    final path = 'tmdb:rated:${e.showId}/${e.season}/${e.episode}';
    upserts[WatchProgress.generateHash(path)] = _watchedRow(
      path,
      null,
      null,
      now: at,
      showId: e.showId,
      season: e.season,
      episode: e.episode,
    );
  }
  for (final id in ratedMovieIds) {
    if (!coveredMovies.add(id)) continue;
    final path = 'tmdb:rated-movie:$id';
    upserts[WatchProgress.generateHash(path)] = _watchedRow(
      path,
      null,
      null,
      now: at,
      movieId: id,
    );
  }

  return WatchedReconcilePlan(upserts: upserts, unwatch: unwatch);
}

/// [row] (or a new row for [path]) marked watched, with the ids learned.
WatchProgress _watchedRow(
  String path,
  WatchProgress? row,
  LocalMediaFile? file, {
  required DateTime now,
  int? showId,
  int? season,
  int? episode,
  int? movieId,
}) {
  if (row != null) {
    return row.copyWith(
      isCompleted: true,
      lastWatched: now,
      showId: row.showId ?? showId,
      movieId: row.movieId ?? movieId,
    );
  }
  return WatchProgress(
    fileHash: WatchProgress.generateHash(path),
    filePath: path,
    showName: file?.showName,
    showId: showId,
    seasonNumber: season,
    episodeNumber: episode,
    episodeCode: Formatters.episodeCodeOrNull(season, episode),
    movieId: movieId,
    posterPath: file?.posterPath,
    position: Duration.zero,
    duration: Duration.zero,
    lastWatched: now,
    isCompleted: true,
  );
}
