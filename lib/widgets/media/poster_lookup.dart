import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/local_media_file.dart';
import '../../models/watch_progress.dart';
import '../../providers/local_media_provider.dart';
import '../../utils/media_names.dart';
import '../../utils/platform_utils.dart';

/// A TMDB image URL for [path] (`/abc.jpg`), or null when there is none.
///
/// An absolute URL comes back untouched, so a value that was already
/// resolved is never double-prefixed.
String? tmdbImageUrl(String? path, {String size = 'w500'}) {
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('http://') || path.startsWith('https://')) return path;
  final slash = path.startsWith('/') ? '' : '/';
  return 'https://image.tmdb.org/t/p/$size$slash$path';
}

/// What to ask TMDB for when an item carries no poster of its own.
///
/// One rule for every card. Home's Continue Watching card, the Library card
/// and the Library's Continue Watching card each built this query with a
/// different title cleaner, so the same file triggered two different TMDB
/// searches — and could get two different posters — depending on the screen.
@immutable
class PosterQuery {
  const PosterQuery.show(this.title) : isShow = true;
  const PosterQuery.movie(this.title) : isShow = false;

  /// Cleaned title to search for.
  final String title;
  final bool isShow;

  @override
  bool operator ==(Object other) =>
      other is PosterQuery && other.title == title && other.isShow == isShow;

  @override
  int get hashCode => Object.hash(title, isShow);

  @override
  String toString() => 'PosterQuery(${isShow ? 'show' : 'movie'}: $title)';
}

/// An episode searches by its show's name; anything else is a movie,
/// searched by its parsed name or, failing that, its cleaned filename.
PosterQuery? _query({
  required String? showName,
  required bool isEpisode,
  required String fileName,
}) {
  final named = showName?.trim();
  if (isEpisode && named != null && named.isNotEmpty) {
    return PosterQuery.show(named);
  }
  final title = (named != null && named.isNotEmpty)
      ? named
      : cleanMediaTitle(fileName);
  return title.isEmpty ? null : PosterQuery.movie(title);
}

/// The poster query for a scanned library file.
PosterQuery? posterQueryForFile(LocalMediaFile file) => _query(
  showName: file.showName,
  isEpisode: file.seasonNumber != null || file.episodeNumber != null,
  fileName: file.fileName,
);

/// The poster query for a watch-progress entry — the same query its file
/// would produce, so Home and Library share one lookup.
PosterQuery? posterQueryForProgress(WatchProgress progress) => _query(
  showName: progress.showName,
  isEpisode:
      progress.seasonNumber != null ||
      progress.episodeNumber != null ||
      progress.episodeCode != null,
  fileName: basenameOf(progress.filePath),
);

/// The poster query for a torrent name. Torrent names carry far more
/// trailing metadata than filenames, hence the different cleaner — see
/// [searchTitleFromTorrentName].
PosterQuery? posterQueryForTorrent(String torrentName) {
  final title = searchTitleFromTorrentName(torrentName);
  if (title.isEmpty) return null;
  return parseEpisodeCode(torrentName) != null
      ? PosterQuery.show(title)
      : PosterQuery.movie(title);
}

/// Watch the poster URL for [query] through the shared, session-long TMDB
/// lookups (one request per title however many cards ask).
AsyncValue<String?>? watchPoster(WidgetRef ref, PosterQuery? query) {
  if (query == null) return null;
  return query.isShow
      ? ref.watch(showPosterProvider(query.title))
      : ref.watch(moviePosterProvider(query.title));
}

/// A poster for a watch-progress entry: the TMDB path it saved, else a
/// lookup by title.
AsyncValue<String?>? watchProgressPoster(WidgetRef ref, WatchProgress p) {
  final own = tmdbImageUrl(p.posterPath);
  if (own != null) return AsyncValue.data(own);
  return watchPoster(ref, posterQueryForProgress(p));
}

/// A poster for a library file: its own TMDB path when it has one, else a
/// lookup by title.
AsyncValue<String?>? watchFilePoster(WidgetRef ref, LocalMediaFile file) {
  final own = tmdbImageUrl(file.posterPath);
  if (own != null) return AsyncValue.data(own);
  return watchPoster(ref, posterQueryForFile(file));
}

/// What to call a watch-progress entry on a card or hero.
///
/// Never "Untitled": a movie has no show name and, usually, no episode
/// title, so it falls back to its cleaned filename — and only when even
/// that is empty to [WatchProgress.displayTitle].
String watchProgressTitle(WatchProgress progress) {
  final show = progress.showName?.trim();
  if (show != null && show.isNotEmpty) return show;
  final episodeTitle = progress.episodeTitle?.trim();
  if (episodeTitle != null && episodeTitle.isNotEmpty) return episodeTitle;
  final cleaned = cleanMediaTitle(basenameOf(progress.filePath));
  return cleaned.isNotEmpty ? cleaned : progress.displayTitle;
}

/// Whether [progress] is for an episode rather than a movie.
bool isEpisodeProgress(WatchProgress progress) =>
    progress.seasonNumber != null ||
    progress.episodeNumber != null ||
    progress.episodeCode != null;

/// [url] re-sized to TMDB's [size] variant when it is a TMDB `original`.
///
/// The models build backdrops at `/original` — a 4K image that decodes to
/// ~33 MB, a third of the whole image cache, to fill a hero at most a couple
/// of thousand pixels wide. `w1280` is TMDB's largest pre-scaled backdrop.
String? tmdbResized(String? url, {String size = 'w1280'}) {
  if (url == null) return null;
  return url.replaceFirst('/t/p/original/', '/t/p/$size/');
}
