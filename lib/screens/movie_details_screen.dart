import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../models/local_media_file.dart';
import '../models/movie.dart';
import '../models/torrentio_stream.dart';
import '../providers/favorites_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/movies_provider.dart';
import '../providers/torrentio_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../providers/watchlist_provider.dart';
import '../utils/error_messages.dart';
import '../utils/feedback_utils.dart';
import '../widgets/details/detail_shell.dart';
import '../widgets/details/details_page.dart';
import '../widgets/editorial/editorial.dart';
import '../widgets/media/hue_backdrop.dart';
import '../widgets/media/local_playback.dart';
import '../widgets/media/media_poster_card.dart';
import '../widgets/mediahub_backdrop_hero.dart';
import '../widgets/mediahub_torrent_drawer.dart';
import '_details_playback_controller.dart';
import 'settings_screen.dart';
import 'video_player_screen.dart';

/// A movie: the hero with Play (when it is on disk) and its sources,
/// overview, cast and similar movies.
class MovieDetailsScreen extends ConsumerStatefulWidget {
  final Movie movie;

  /// When true, the source picker opens as soon as the full movie record
  /// (with its IMDb id) has loaded. Used by the browse spotlight's "Stream".
  final bool autoOpenTorrentPicker;

  const MovieDetailsScreen({
    super.key,
    required this.movie,
    this.autoOpenTorrentPicker = false,
  });

  @override
  ConsumerState<MovieDetailsScreen> createState() => _MovieDetailsScreenState();
}

class _MovieDetailsScreenState extends ConsumerState<MovieDetailsScreen>
    with DetailsPlaybackController<MovieDetailsScreen> {
  bool _loadingSources = false;
  bool _isStreaming = false;
  bool _autoPickerFired = false;

  @override
  void dispose() {
    disposePlaybackController();
    super.dispose();
  }

  void _openSettings() => unawaited(
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
  );

  /// The copy on disk is matched on title *and* year: "Dune" (2021) must not
  /// play `Dune.1984.mkv`.
  static ({String title, int? year}) _onDisk(Movie movie) =>
      (title: movie.title, year: int.tryParse(movie.year ?? ''));

  /// Look up the movie's sources and open the picker.
  Future<void> _openSources(Movie movie) async {
    final imdbId = movie.imdbId;
    if (imdbId == null) {
      AppSnackBar.showError(
        context,
        message:
            "Sources can't be looked up for this movie — TMDB doesn't link "
            'it to IMDb.',
      );
      return;
    }
    if (_loadingSources) return;
    setState(() => _loadingSources = true);

    // Straight to the service: the cached provider retries a failure for
    // ~40 s before reporting it, which read as a button that did nothing.
    final torrentio = ref.read(torrentioApiServiceProvider);
    List<TorrentioStream>? streams;
    Object? failure;
    try {
      streams = (await torrentio.getMovieStreams(imdbId)).streams;
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    setState(() => _loadingSources = false);

    if (failure != null) {
      AppSnackBar.showError(
        context,
        message: friendlyErrorMessage(failure, subject: 'sources'),
      );
      return;
    }
    if (streams == null || streams.isEmpty) {
      AppSnackBar.showInfo(
        context,
        message: 'No sources found for this movie yet.',
      );
      return;
    }

    await MediaHubTorrentDrawer.show(
      context: context,
      title: movie.title,
      subtitle: movie.year,
      streams: streams,
      onSelect: (stream, isStreaming) {
        if (mounted) unawaited(_play(stream, movie, isStreaming: isStreaming));
      },
    );
  }

  /// What the picker's choice does — stream or download — through the flow
  /// the show page shares ([startDetailsDownload]).
  Future<void> _play(
    TorrentioStream stream,
    Movie movie, {
    required bool isStreaming,
  }) {
    // The Play button stands in for the copy on disk while a stream of it
    // starts.
    if (isStreaming) setState(() => _isStreaming = true);
    return startDetailsDownload(
      stream: stream,
      isStreaming: isStreaming,
      // Nothing has checked the copy on disk on the way here: a finished
      // one plays instead of re-adding the torrent.
      localFile: ref.read(localMovieFileProvider(_onDisk(movie))),
      movieImdbId: movie.imdbId,
      target: DetailsStreamTarget(
        label: '"${movie.title}"',
        onSettled: () {
          if (mounted) setState(() => _isStreaming = false);
        },
        onTryAnotherSource: () => unawaited(_openSources(movie)),
        openPlayer: (file, session) => VideoPlayerScreen.fromSession(
          file: file,
          session: session,
          movieImdbId: movie.imdbId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final movieAsync = ref.watch(movieDetailsProvider(widget.movie.id));

    // From the browse spotlight: open the picker once the full record —
    // with its IMDb id — is in.
    final loaded = movieAsync.value;
    if (widget.autoOpenTorrentPicker && !_autoPickerFired && loaded != null) {
      _autoPickerFired = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openSources(loaded));
      });
    }

    return DetailsPageScaffold<Movie>(
      value: movieAsync,
      subject: 'this movie',
      onRetry: () => ref.invalidate(movieDetailsProvider(widget.movie.id)),
      onOpenSettings: _openSettings,
      headerActions: (movie) => Consumer(
        builder: (context, ref, _) => DetailsHeaderActions(
          isFavorite: ref.watch(isMovieFavoriteProvider(movie.id)),
          onToggleFavorite: () => unawaited(
            ref
                .read(favoritesProvider.notifier)
                .toggleMovieFavorite(movie.id, movie: movie),
          ),
          isOnWatchlist: ref.watch(isMovieOnWatchlistProvider(movie.id)),
          onToggleWatchlist: () => unawaited(
            ref.read(watchlistProvider.notifier).toggleMovie(movie.id),
          ),
          onOpenSettings: _openSettings,
        ),
      ),
      builder: (context, movie) => _content(movie),
    );
  }

  Widget _content(Movie movie) {
    final similar =
        ref.watch(similarMoviesProvider(movie.id)).value ?? const <Movie>[];
    // Not "on disk" while a stream of it is starting.
    final localFile = _isStreaming
        ? null
        : ref.watch(localMovieFileProvider(_onDisk(movie)));
    final isWatched = ref.watch(isMovieWatchedProvider(movie.id));
    final rating = ratingLabel(movie.voteAverage, voteCount: movie.voteCount);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: MediaHubBackdropHero(
            title: movie.title,
            year: movie.year,
            posterUrl: movie.posterUrl,
            backdropUrl: movie.backdropUrl,
            fallbackHue: hueForId(movie.id),
            description: (movie.tagline != null && movie.tagline!.isNotEmpty)
                ? movie.tagline
                : movie.overview,
            metaPills: [
              if (isWatched)
                const MediaHubMetaPill(
                  label: 'Watched',
                  color: AppColors.ok,
                  icon: Icons.check_circle_rounded,
                ),
              if (movie.runtimeFormatted != null)
                MediaHubMetaPill(
                  label: movie.runtimeFormatted!,
                  color: AppColors.fg1,
                ),
              if (rating != null)
                MediaHubMetaPill(
                  label: rating,
                  color: getRatingColor(movie.voteAverage),
                ),
              ...movie.genres
                  .take(3)
                  .map(
                    (g) => MediaHubMetaPill(label: g, color: AppColors.accent),
                  ),
            ],
            primaryAction: _actions(movie, localFile),
          ),
        ),
        DetailsOverviewSliver(overview: movie.overview),
        DetailsCastSliver(cast: movie.cast),
        DetailsSimilarSliver(
          itemCount: similar.length,
          itemBuilder: (context, index) {
            final other = similar[index];
            return Consumer(
              builder: (context, ref, _) => MediaPosterCard.movie(
                other,
                width: DetailsSimilarSliver.cardWidth,
                isWatched: ref.watch(isMovieWatchedProvider(other.id)),
                onTap: () => unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MovieDetailsScreen(movie: other),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
      ],
    );
  }

  /// Play (when the movie is on disk), its sources, and the trailer.
  Widget _actions(Movie movie, LocalMediaFile? localFile) {
    final sourcesLabel = _loadingSources
        ? 'Finding sources…'
        : (localFile == null ? 'Stream' : 'Sources');
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        if (localFile != null) _playButton(movie, localFile),
        EditorialButton(
          label: sourcesLabel,
          icon: localFile == null
              ? Icons.play_arrow_rounded
              : Icons.list_rounded,
          kind: localFile == null
              ? EditorialButtonKind.accent
              : EditorialButtonKind.ghost,
          large: true,
          onPressed: _loadingSources
              ? null
              : () => unawaited(_openSources(movie)),
        ),
        if (bestTrailer(movie.videos) != null)
          TrailerButton(videos: movie.videos),
      ],
    );
  }

  /// Play / Continue / Rewatch for the copy on disk.
  ///
  /// It said "Resume" for a file never opened, and for a finished one it
  /// passed the saved position — 90%+ in — dropping the viewer into the
  /// credits. A finished movie now starts from the top; one in progress
  /// opens on the player's own resume prompt.
  Widget _playButton(Movie movie, LocalMediaFile localFile) {
    final watched = localFile.isWatched;
    final inProgress = localFile.hasProgress && !watched;
    final label = watched ? 'Rewatch' : (inProgress ? 'Continue' : 'Play');
    return EditorialButton(
      label: label,
      icon: watched ? Icons.replay_rounded : Icons.play_arrow_rounded,
      kind: EditorialButtonKind.accent,
      large: true,
      onPressed: () => unawaited(
        openLocalFile(
          context,
          ref,
          localFile,
          // Zero skips the resume prompt; null lets the player offer it.
          startPosition: watched ? Duration.zero : null,
          movieImdbId: movie.imdbId,
        ),
      ),
    );
  }
}
