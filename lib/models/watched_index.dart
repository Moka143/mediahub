import '../utils/formatters.dart';
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
/// O(1) lookups. It is a plain value class with no Riverpod dependency so
/// the matching rules can be unit-tested directly.
///
/// **Watched is deliberately decoupled from "the file still exists."** A
/// watched mark has to survive deleting the file and re-downloading it
/// later, so this index is built from the raw progress map rather than from
/// `watchedItemsProvider` (which filters on file existence) or
/// `continueWatchingProvider` (which excludes completed items).
class WatchedIndex {
  WatchedIndex._(this._episodeKeys, this._movieIds, this._unkeyedEpisodes);

  /// `showId/season/episode` for every completed entry that carries a TMDB
  /// show id. This is the fast path and covers everything written since
  /// entries started persisting `showId`.
  final Set<String> _episodeKeys;

  /// TMDB movie ids for every completed movie entry.
  final Set<int> _movieIds;

  /// Episode entries kept for fuzzy name matching. Includes keyed
  /// entries too — a stale/wrong TMDB id on the progress row would
  /// otherwise hide a watched episode in the season browser.
  final List<WatchProgress> _unkeyedEpisodes;

  static final WatchedIndex empty = WatchedIndex._({}, {}, const []);

  /// Key format shared with `library_actions.dart`'s reconcile pass so the
  /// two agree on identity.
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
    final movieIds = <int>{};
    final unkeyed = <WatchProgress>[];

    for (final p in entries) {
      if (!p.isEffectivelyWatched) continue;

      final season = p.seasonNumber;
      final episode = p.episodeNumber;
      if (season != null && episode != null) {
        final showId = p.showId;
        if (showId != null) {
          episodeKeys.add(episodeKey(showId, season, episode));
        }
        // Always keep a name fallback. A stale/wrong TMDB id on the
        // progress entry would otherwise hide a watched episode in the
        // season browser (Lioness is 113962; some saves still carry
        // another id).
        unkeyed.add(p);
        continue;
      }

      final movieId = p.movieId;
      if (movieId != null) movieIds.add(movieId);
    }

    return WatchedIndex._(episodeKeys, movieIds, unkeyed);
  }

  /// Whether a specific episode is marked watched.
  ///
  /// [showName] is only consulted for the unkeyed fallback. The match there
  /// is intentionally loose in one direction — the stored name must
  /// *contain* the queried name — because unkeyed entries get their name
  /// parsed out of a torrent filename, so "Severance" needs to match an
  /// entry stored as "Severance 2022".
  bool isEpisodeWatched({
    required int showId,
    required int season,
    required int episode,
    String? showName,
  }) {
    if (_episodeKeys.contains(episodeKey(showId, season, episode))) {
      return true;
    }
    if (_unkeyedEpisodes.isEmpty) return false;

    final code = Formatters.episodeCode(season, episode).toLowerCase();
    final target = showName?.toLowerCase();
    if (target == null || target.isEmpty) return false;
    return _unkeyedEpisodes.any((p) {
      final sameEp =
          (p.seasonNumber == season && p.episodeNumber == episode) ||
          p.episodeCode?.toLowerCase() == code;
      if (!sameEp) return false;
      final stored = p.showName?.toLowerCase();
      if (stored == null || stored.isEmpty) return false;
      return stored.contains(target) || target.contains(stored);
    });
  }

  bool isMovieWatched(int movieId) => _movieIds.contains(movieId);

  /// Every watched movie id — for screens that flag a whole grid at once
  /// rather than asking per card.
  Set<int> get watchedMovieIds => Set.unmodifiable(_movieIds);

  /// Counts, for diagnostics and tests.
  int get episodeCount => _unkeyedEpisodes.length;
  int get movieCount => _movieIds.length;
  bool get isEmpty => episodeCount == 0 && movieCount == 0;
}
