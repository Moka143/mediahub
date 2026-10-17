import '../../models/season.dart';
import '../../models/show.dart';
import '../../models/watch_progress.dart';
import '../../models/watched_index.dart';
import '../../utils/formatters.dart';
import '../../utils/media_names.dart';

/// Where someone left off in a show: the episode the show page offers to
/// continue, and the one the episodes drawer opens on.
///
/// Chosen by [pick]:
///   1. the episode of this show watched most recently and not finished —
///      "Continue S03E05";
///   2. otherwise, the episode after the furthest one watched (highest
///      season, then episode) — "Next: S03E06". The furthest rather than
///      the most recent: rows the TMDB sync writes all carry the sync's
///      time, so "most recent" among them is arbitrary.
///   3. otherwise nothing: a show never started, or one watched to its
///      last listed episode. The drawer then opens on the first season —
///      the start of a rewatch — and the page offers no Continue action.
///
/// Specials (season 0) are never a resume point; they sit outside the
/// running order.
class ResumePoint {
  const ResumePoint({
    required this.season,
    required this.episode,
    required this.inProgress,
  });

  final int season;
  final int episode;

  /// Started and not finished, as opposed to the next one up.
  final bool inProgress;

  String get code => Formatters.episodeCode(season, episode);

  /// The show page's action: "Continue S03E05" or "Next: S03E06".
  String get label => inProgress ? 'Continue $code' : 'Next: $code';

  /// See the class comment. [inProgress] is Continue Watching's list —
  /// unfinished, still playable, most recent first — for every title, not
  /// just [show]'s.
  static ResumePoint? pick({
    required Show show,
    required List<Season> seasons,
    required Iterable<WatchProgress> inProgress,
    required WatchedIndex watched,
  }) {
    final regular = [
      for (final s in seasons)
        if (s.seasonNumber > 0) s,
    ]..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    if (regular.isEmpty) return null;
    bool listed(int season) => regular.any((s) => s.seasonNumber == season);

    for (final p in inProgress) {
      final season = p.seasonNumber;
      final episode = p.episodeNumber;
      if (season == null || episode == null || !listed(season)) continue;
      if (!_isShow(p, show)) continue;
      return ResumePoint(season: season, episode: episode, inProgress: true);
    }

    final last = watched.furthestWatchedEpisode(
      showId: show.id,
      showName: show.name,
    );
    if (last == null) return null;
    for (final s in regular) {
      if (s.seasonNumber < last.season) continue;
      if (s.seasonNumber == last.season) {
        if (last.episode < s.episodeCount) {
          return ResumePoint(
            season: s.seasonNumber,
            episode: last.episode + 1,
            inProgress: false,
          );
        }
        continue;
      }
      if (s.episodeCount > 0) {
        return ResumePoint(
          season: s.seasonNumber,
          episode: 1,
          inProgress: false,
        );
      }
    }
    return null;
  }

  /// A row with a show id is identified by it; only one without falls back
  /// to the name — the rule [WatchedIndex] follows.
  static bool _isShow(WatchProgress p, Show show) {
    final id = p.showId;
    if (id != null) return id == show.id;
    final name = p.showName;
    return name != null && titlesMatch(name, show.name);
  }

  @override
  bool operator ==(Object other) =>
      other is ResumePoint &&
      other.season == season &&
      other.episode == episode &&
      other.inProgress == inProgress;

  @override
  int get hashCode => Object.hash(season, episode, inProgress);

  @override
  String toString() => 'ResumePoint($label)';
}
