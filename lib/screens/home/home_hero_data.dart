import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/local_media_file.dart';
import '../../models/show.dart';
import '../../models/watch_progress.dart';
import '../../providers/local_media_provider.dart';
import '../../providers/movies_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/shows_provider.dart';
import '../../providers/watch_progress_provider.dart';
import '../../screens/show_details_screen.dart';
import '../../screens/video_player_screen.dart';
import '../../services/app_logger.dart';
import '../../utils/feedback_utils.dart';
import '../../utils/platform_utils.dart';

/// Build a TMDB image URL from a poster path (e.g. `/abc.jpg`).
/// Returns null if the path is null or empty. If the input already
/// looks like an absolute URL, return it untouched so callers don't
/// double-prefix when the path was previously resolved.
String? tmdbPoster(String? p, {String size = 'w500'}) {
  if (p == null || p.isEmpty) return null;
  if (p.startsWith('http://') || p.startsWith('https://')) return p;
  final prefix = p.startsWith('/') ? '' : '/';
  return 'https://image.tmdb.org/t/p/$size$prefix$p';
}

/// Strip episode/year/quality tail from a torrent or filename so the
/// remainder is usable as a TMDB search query. Returns the cleaned
/// title (spaces, no separators), or an empty string when nothing
/// recognizable remains.
/// Open the video player for a Continue-Watching entry, seeking to
/// the saved position. Falls back to a synthetic LocalMediaFile when
/// the file isn't yet in the scanned library (e.g. a torrent that
/// completed but the scanner hasn't picked it up).
void resumePlayback(
  BuildContext context,
  WidgetRef ref,
  WatchProgress progress,
  List<LocalMediaFile> localFiles,
) {
  final file = localFiles.firstWhere(
    (f) => f.path == progress.filePath,
    orElse: () {
      final name = basenameOf(progress.filePath);
      final ext = name.contains('.') ? name.split('.').last : '';
      return LocalMediaFile(
        path: progress.filePath,
        fileName: name,
        sizeBytes: 0,
        modifiedDate: DateTime.now(),
        extension: ext,
        showName: progress.showName,
        seasonNumber: progress.seasonNumber,
        episodeNumber: progress.episodeNumber,
        progress: progress,
      );
    },
  );
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          VideoPlayerScreen(file: file, startPosition: progress.position),
    ),
  );
}

/// Build the hero's primary CTA: Resume the most recent in-progress
/// episode, or send the user to Shows browse when no progress exists.
VoidCallback heroPrimaryTap(
  BuildContext context,
  WidgetRef ref,
  List<WatchProgress> continueWatching,
  List<LocalMediaFile> localFiles,
) {
  if (continueWatching.isNotEmpty) {
    final hero = continueWatching.first;
    return () => resumePlayback(context, ref, hero, localFiles);
  }
  return () => ref.read(currentTabIndexProvider.notifier).set(2);
}

/// Build the hero's secondary CTA: "More info" — open ShowDetailsScreen
/// for the in-progress title, or for the trending fallback when there's
/// no progress yet.
VoidCallback heroSecondaryTap(
  BuildContext context,
  WidgetRef ref,
  List<WatchProgress> continueWatching,
  AsyncValue<List<Show>> trendingShows,
) {
  if (continueWatching.isNotEmpty) {
    final hero = continueWatching.first;
    return () => openHeroDetails(context, ref, hero, trendingShows);
  }
  return () {
    final fb = trendingShows.maybeWhen(
      data: (s) => s.isEmpty ? null : s.first,
      orElse: () => null,
    );
    if (fb != null) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => ShowDetailsScreen(show: fb)));
    } else {
      ref.read(currentTabIndexProvider.notifier).set(2);
    }
  };
}

/// Resolve a WatchProgress entry to a full Show and push ShowDetailsScreen.
/// Tries (1) TMDB id from the progress, (2) trending-shows cache by name,
/// (3) TMDB search by name. Falls back to the Shows tab + snackbar if
/// nothing resolves.
Future<void> openHeroDetails(
  BuildContext context,
  WidgetRef ref,
  WatchProgress hero,
  AsyncValue<List<Show>> trendingShows,
) async {
  Show? found;
  if (hero.showId != null) {
    try {
      found = await ref.read(showDetailsProvider(hero.showId!).future);
    } catch (e) {
      // Fall through to the trending-cache and search strategies below.
      AppLog.w('[Home] hero show ${hero.showId} lookup failed: $e');
    }
  }
  if (found == null) {
    final name = hero.showName?.toLowerCase();
    if (name != null && name.isNotEmpty) {
      final cached = trendingShows.value ?? const <Show>[];
      for (final s in cached) {
        if (s.name.toLowerCase() == name) {
          found = s;
          break;
        }
      }
    }
  }
  if (found == null && (hero.showName?.isNotEmpty ?? false)) {
    try {
      final tmdb = ref.read(tmdbApiServiceProvider);
      final results = await tmdb.searchShows(hero.showName!);
      if (results.isNotEmpty) found = results.first;
    } catch (e) {
      AppLog.w('[Home] hero search for "${hero.showName}" failed: $e');
    }
  }

  if (!context.mounted) return;
  if (found != null) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ShowDetailsScreen(show: found!)));
  } else {
    AppSnackBar.showInfo(
      context,
      message: "Couldn't find details for ${hero.showName ?? 'this title'}",
    );
    ref.read(currentTabIndexProvider.notifier).set(2);
  }
}

/// Backdrop + poster for the Home hero, always for the Continue
/// Watching title itself. Never a different trending show.
class HeroArt {
  const HeroArt({this.backdropUrl, this.posterUrl});

  final String? backdropUrl;
  final String? posterUrl;
}

final homeContinueHeroArtProvider = FutureProvider<HeroArt?>((ref) async {
  final list = ref.watch(continueWatchingProvider);
  if (list.isEmpty) return null;
  final hero = list.first;
  final localFiles = ref
      .watch(localMediaFilesProvider)
      .maybeWhen(data: (f) => f, orElse: () => const <LocalMediaFile>[]);

  String? localPosterUrl() {
    if (hero.posterPath != null && hero.posterPath!.isNotEmpty) {
      return tmdbPoster(hero.posterPath, size: 'w500');
    }
    final name = hero.showName?.toLowerCase() ?? '';
    if (name.isEmpty) return null;
    for (final f in localFiles) {
      if (f.posterPath != null && f.showName?.toLowerCase() == name) {
        return tmdbPoster(f.posterPath, size: 'w500');
      }
    }
    return null;
  }

  final fallbackPoster = localPosterUrl();

  if (hero.showId != null) {
    try {
      final show = await ref.watch(showDetailsProvider(hero.showId!).future);
      return HeroArt(
        backdropUrl: show.backdropUrl,
        posterUrl: show.posterUrl ?? fallbackPoster,
      );
    } catch (e) {
      // Fall through to the name-search strategy; art is optional.
      AppLog.w('[Home] hero art for show ${hero.showId} failed: $e');
    }
  }
  if (hero.movieId != null) {
    try {
      final movie = await ref.watch(movieDetailsProvider(hero.movieId!).future);
      return HeroArt(
        backdropUrl: movie.backdropUrl,
        posterUrl: movie.posterUrl ?? fallbackPoster,
      );
    } catch (e) {
      AppLog.w('[Home] hero art for movie ${hero.movieId} failed: $e');
    }
  }

  final name = hero.showName;
  if (name != null && name.isNotEmpty) {
    final tmdb = ref.read(tmdbApiServiceProvider);
    try {
      final isEpisode = hero.seasonNumber != null || hero.episodeNumber != null;
      if (isEpisode) {
        final shows = await tmdb.searchShows(name);
        if (shows.isNotEmpty) {
          final show = shows.first;
          return HeroArt(
            backdropUrl: show.backdropUrl,
            posterUrl: show.posterUrl ?? fallbackPoster,
          );
        }
      } else {
        final movies = await tmdb.searchMovies(name);
        if (movies.isNotEmpty) {
          final movie = movies.first;
          return HeroArt(
            backdropUrl: movie.backdropUrl,
            posterUrl: movie.posterUrl ?? fallbackPoster,
          );
        }
        final shows = await tmdb.searchShows(name);
        if (shows.isNotEmpty) {
          final show = shows.first;
          return HeroArt(
            backdropUrl: show.backdropUrl,
            posterUrl: show.posterUrl ?? fallbackPoster,
          );
        }
      }
    } catch (e) {
      AppLog.w('[Home] hero art search failed: $e');
    }
  }

  return HeroArt(posterUrl: fallbackPoster);
});

/// Procedural fallback when no real artwork is available — keeps the
/// dark cinematic feel even before TMDB poster paths come back.
Widget hueBackdrop(int hue) {
  return DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          HSLColor.fromAHSL(1, hue.toDouble(), 0.5, 0.22).toColor(),
          HSLColor.fromAHSL(1, hue.toDouble(), 0.5, 0.08).toColor(),
        ],
      ),
    ),
  );
}
