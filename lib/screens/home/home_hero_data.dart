import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/movie.dart';
import '../../models/show.dart';
import '../../models/watch_progress.dart';
import '../../providers/shows_provider.dart';
import '../../providers/watch_progress_provider.dart';
import '../../services/app_logger.dart';
import '../../utils/error_messages.dart';
import '../../utils/feedback_utils.dart';
import '../../utils/media_names.dart';
import '../../utils/platform_utils.dart';
import '../../widgets/media/poster_lookup.dart';
import '../movie_details_screen.dart';
import '../show_details_screen.dart';

/// Backdrop, poster and — for a movie — TMDB's title for the Home hero.
/// Always the Continue Watching title's own art, never a different trending
/// show's (which is how Lioness once ended up on another show's still).
@immutable
class HeroArt {
  const HeroArt({this.backdropUrl, this.posterUrl, this.title});

  final String? backdropUrl;
  final String? posterUrl;

  /// TMDB's name for a movie — a movie's own record has only a filename.
  final String? title;
}

/// Art for the first Continue Watching entry.
///
/// `select`s the entry itself — WatchProgress compares by file — so the
/// progress writes made every few seconds during playback don't refetch it.
final homeContinueHeroArtProvider = FutureProvider<HeroArt?>((ref) async {
  final hero = ref.watch(
    continueWatchingProvider.select((list) => list.isEmpty ? null : list.first),
  );
  if (hero == null) return null;
  final ownPoster = tmdbImageUrl(hero.posterPath);
  final tmdb = ref.watch(tmdbApiServiceProvider);
  final resolver = ref.watch(tmdbTitleResolverProvider);

  try {
    var showId = hero.showId;
    var movieId = hero.movieId;
    if (showId == null && movieId == null) {
      final ids = await _resolveIds(resolver.showId, resolver.movieId, hero);
      showId = ids.showId;
      movieId = ids.movieId;
    }
    if (showId != null) {
      final show = await tmdb.getShowDetails(showId);
      return HeroArt(
        backdropUrl: show.backdropUrl,
        posterUrl: show.posterUrl ?? ownPoster,
      );
    }
    if (movieId != null) {
      final movie = await tmdb.getMovieDetails(movieId);
      return HeroArt(
        backdropUrl: movie.backdropUrl,
        posterUrl: movie.posterUrl ?? ownPoster,
        title: movie.title,
      );
    }
  } catch (e) {
    // Art is optional: the hero falls back to its hue gradient.
    AppLog.w('[Home] hero art for "${watchProgressTitle(hero)}" failed: $e');
  }
  return HeroArt(posterUrl: ownPoster);
}, retry: (_, _) => null);

/// TMDB ids for an entry that carries none, through the resolver that only
/// answers when exactly one title matches — never "the first search hit".
Future<({int? showId, int? movieId})> _resolveIds(
  Future<int?> Function(TitleQuery) showId,
  Future<int?> Function(TitleQuery) movieId,
  WatchProgress progress,
) async {
  if (isEpisodeProgress(progress)) {
    final name = progress.showName;
    if (name == null || name.isEmpty) return (showId: null, movieId: null);
    return (showId: await showId((title: name, year: null)), movieId: null);
  }
  final query =
      movieQueryFromFileName(basenameOf(progress.filePath)) ??
      (title: watchProgressTitle(progress), year: null);
  return (showId: null, movieId: await movieId(query));
}

/// Open the details page a Continue Watching entry belongs to — the
/// movie's, when it is a movie.
///
/// "More info" used to search only TV shows, so a movie in Continue
/// Watching ended on "Couldn't find details" and a jump to the TV tab.
Future<void> openProgressDetails(
  BuildContext context,
  WidgetRef ref,
  WatchProgress progress,
) async {
  final title = watchProgressTitle(progress);
  final resolver = ref.read(tmdbTitleResolverProvider);

  var showId = progress.showId;
  var movieId = progress.movieId;
  Object? failure;
  if (showId == null && movieId == null) {
    try {
      final ids = await _resolveIds(
        resolver.showId,
        resolver.movieId,
        progress,
      );
      showId = ids.showId;
      movieId = ids.movieId;
    } catch (e) {
      failure = e;
    }
  }
  if (!context.mounted) return;

  // The details pages load the full record themselves — and show their own
  // error, with Back, if it fails — so they open straight away.
  final Widget? page = movieId != null
      ? MovieDetailsScreen(
          movie: Movie(id: movieId, title: title),
        )
      : showId != null
      ? ShowDetailsScreen(
          show: Show(id: showId, name: progress.showName ?? title),
        )
      : null;
  if (page == null) {
    AppSnackBar.showInfo(
      context,
      message: failure != null
          ? friendlyErrorMessage(failure, subject: 'its details')
          : 'TMDB has no single match for "$title".',
    );
    return;
  }
  unawaited(
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
  );
}
