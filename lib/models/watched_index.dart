import '../utils/media_names.dart';
import 'watch_progress.dart';

/// Precomputed answer to "has this been watched?".
///
/// Every caller used to hand-roll this as a linear scan over
/// `watchProgressProvider.values` — the episodes drawer did one full scan
/// *per episode row*, so a 24-episode season cost 24 passes over the whole
/// progress map on every rebuild. Worse, the three call sites had drifted:
/// the drawer matched structurally-then-by-filename, the movie screens
/// matched on `movieId` only, and none of them agreed on what to do with an
/// entry that was missing ids.
///
/// This builds the answer once per change to the progress map and hands out
/// O(1) lookups — including the name fallback, which is indexed by title key
/// rather than scanned. It is a plain value class with no Riverpod dependency
/// so the matching rules can be unit-tested directly.
///
/// **Watched is deliberately decoupled from "the file still exists."** A
/// watched mark has to survive deleting the file and re-downloading it
/// later, so this index is built from the raw progress map rather than from
/// `continueWatchingProvider` (which excludes completed items).
class WatchedIndex {
  WatchedIndex._(
    this._episodeKeys,
    this._furthestByShow,
    this._movieIds,
    this._unkeyedByTitle,
    this.episodeCount,
  );

  /// `showId/season/episode` for every completed entry that carries a TMDB
  /// show id. This is the fast path and covers everything written since
  /// entries started persisting `showId`.
  final Set<String> _episodeKeys;

  /// The furthest watched regular episode (season 1 and up) of every show
  /// in [_episodeKeys], by season and then episode.
  final Map<int, ({int season, int episode})> _furthestByShow;

  /// TMDB movie ids for every completed movie entry.
  final Set<int> _movieIds;

  /// Completed episode entries that have **no** show id, bucketed by
  /// [titleMatchKey] of their show name.
  ///
  /// Only those: an entry that has an id is identified by it. Falling back
  /// to the name for keyed entries too is what let watching "You" S01E01
  /// mark "Young Sheldon" S01E01 — every miss on the id went looking for a
  /// name that merely contained the other.
  final Map<String, List<WatchProgress>> _unkeyedByTitle;

  /// Watched episode entries, keyed or not. For diagnostics and tests.
  final int episodeCount;

  static final WatchedIndex empty = WatchedIndex._(
    {},
    const {},
    {},
    const {},
    0,
  );

  /// The one key format for "this episode of this show". The TMDB watched
  /// reconcile keys its rating sets with this too, so the two agree on
  /// identity by construction rather than by keeping two copies in step.
  static String episodeKey(int showId, int season, int episode) =>
      '$showId/$season/$episode';

  /// Build from the raw watch-progress values.
  ///
  /// Entries that are not effectively watched (completed flag or 90%+)
  /// are skipped entirely. An entry with season+episode is treated as an
  /// episode even if it also somehow carries a `movieId`, because episode
  /// identity is the more specific claim.
  factory WatchedIndex.fromProgress(Iterable<WatchProgress> entries) {
    final episodeKeys = <String>{};
    final furthest = <int, ({int season, int episode})>{};
    final movieIds = <int>{};
    final unkeyed = <String, List<WatchProgress>>{};
    var episodes = 0;

    for (final p in entries) {
      if (!p.isEffectivelyWatched) continue;

      final season = p.seasonNumber;
      final episode = p.episodeNumber;
      if (season != null && episode != null) {
        episodes++;
        final showId = p.showId;
        if (showId != null) {
          episodeKeys.add(episodeKey(showId, season, episode));
          final here = (season: season, episode: episode);
          if (season > 0 && _isAfter(here, furthest[showId])) {
            furthest[showId] = here;
          }
          continue;
        }
        final name = p.showName;
        if (name == null) continue;
        final key = titleMatchKey(name);
        if (key.isEmpty) continue;
        (unkeyed[key] ??= []).add(p);
        continue;
      }

      final movieId = p.movieId;
      if (movieId != null) movieIds.add(movieId);
    }

    return WatchedIndex._(episodeKeys, furthest, movieIds, unkeyed, episodes);
  }

  static bool _isAfter(
    ({int season, int episode}) a,
    ({int season, int episode})? b,
  ) =>
      b == null ||
      a.season > b.season ||
      (a.season == b.season && a.episode > b.episode);

  /// Whether a specific episode is marked watched.
  ///
  /// [showName] is only consulted for entries saved without a show id —
  /// older rows, and files whose show never resolved. Those are matched on
  /// the same title rules as everywhere else ([titlesMatch]): equality after
  /// normalising, never containment, with a release year allowed on one side
  /// only — so "Severance" finds a row stored as "Severance 2022", but "You"
  /// never finds "Young Sheldon".
  bool isEpisodeWatched({
    required int showId,
    required int season,
    required int episode,
    String? showName,
  }) {
    if (_episodeKeys.contains(episodeKey(showId, season, episode))) {
      return true;
    }
    if (showName == null || _unkeyedByTitle.isEmpty) return false;

    final bucket = _unkeyedByTitle[titleMatchKey(showName)];
    if (bucket == null) return false;
    return bucket.any(
      (p) =>
          p.seasonNumber == season &&
          p.episodeNumber == episode &&
          titlesMatch(p.showName!, showName),
    );
  }

  /// The furthest episode of a show marked watched — highest season, then
  /// highest episode — or null when none is. Specials (season 0) are left
  /// out: they sit outside the running order. [showName] finds rows saved
  /// without a show id, on the same rules as [isEpisodeWatched].
  ({int season, int episode})? furthestWatchedEpisode({
    required int showId,
    String? showName,
  }) {
    var furthest = _furthestByShow[showId];
    if (showName == null || _unkeyedByTitle.isEmpty) return furthest;

    final bucket = _unkeyedByTitle[titleMatchKey(showName)] ?? const [];
    for (final p in bucket) {
      final season = p.seasonNumber!;
      if (season < 1 || !titlesMatch(p.showName!, showName)) continue;
      final here = (season: season, episode: p.episodeNumber!);
      if (_isAfter(here, furthest)) furthest = here;
    }
    return furthest;
  }

  bool isMovieWatched(int movieId) => _movieIds.contains(movieId);

  /// Every watched movie id — for screens that flag a whole grid at once
  /// rather than asking per card.
  Set<int> get watchedMovieIds => Set.unmodifiable(_movieIds);

  bool get isEmpty => episodeCount == 0 && _movieIds.isEmpty;
}
