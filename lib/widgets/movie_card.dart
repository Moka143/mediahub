import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../models/movie.dart';

/// Modern card widget for displaying a movie
class MovieCard extends StatefulWidget {
  final Movie movie;
  final VoidCallback? onTap;
  final bool showRating;
  final double? width;
  final double? height;

  const MovieCard({
    super.key,
    required this.movie,
    this.onTap,
    this.showRating = true,
    this.width,
    this.height,
  });

  @override
  State<MovieCard> createState() => _MovieCardState();
}

class _MovieCardState extends State<MovieCard>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppDuration.fast,
          curve: Curves.easeOutCubic,
          width: widget.width,
          height: widget.height,
          transform: Matrix4.identity()..scale(_isHovered ? 1.03 : 1.0),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            boxShadow: [
              BoxShadow(
                color: (isDark ? Colors.black : AppColors.seedColor).withAlpha(
                  _isHovered ? AppOpacity.medium : AppOpacity.light,
                ),
                blurRadius: _isHovered ? 20 : 12,
                offset: Offset(0, _isHovered ? 8 : 4),
                spreadRadius: _isHovered ? 2 : 0,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Poster image
                _buildPoster(context),

                // Gradient overlay
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0.0, 0.5, 1.0],
                        colors: [
                          Colors.transparent,
                          Colors.transparent,
                          Colors.black.withAlpha(AppOpacity.almostOpaque),
                        ],
                      ),
                    ),
                  ),
                ),

                // Title and runtime at bottom
                Positioned(
                  bottom: AppSpacing.md,
                  left: AppSpacing.md,
                  right: AppSpacing.md,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.movie.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (widget.movie.runtimeFormatted != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          widget.movie.runtimeFormatted!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                // Rating badge
                if (widget.showRating && widget.movie.voteAverage > 0)
                  Positioned(
                    top: AppSpacing.sm,
                    right: AppSpacing.sm,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xxs,
                      ),
                      decoration: BoxDecoration(
                        color: getRatingColor(
                          widget.movie.voteAverage,
                        ).withAlpha(AppOpacity.almostOpaque),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(
                          color: Colors.white.withAlpha(AppOpacity.light),
                          width: AppBorderWidth.hairline,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.star_rounded,
                            color: Colors.white,
                            size: AppIconSize.xs,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            widget.movie.voteAverage.toStringAsFixed(1),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Year badge
                if (widget.movie.year != null)
                  Positioned(
                    top: AppSpacing.sm,
                    left: AppSpacing.sm,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xxs,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(AppOpacity.medium),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text(
                        widget.movie.year!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),

                // Hover overlay
                if (_isHovered)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: theme.colorScheme.primary.withAlpha(
                            AppOpacity.strong,
                          ),
                          width: AppBorderWidth.thick,
                        ),
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPoster(BuildContext context) {
    if (widget.movie.posterUrl != null) {
      return Image.network(
        widget.movie.posterUrl!,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            _buildPlaceholder(context),
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return _buildLoadingPlaceholder(context);
        },
      );
    }
    return _buildPlaceholder(context);
  }

  Widget _buildPlaceholder(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.surfaceContainerHighest,
            theme.colorScheme.surfaceContainerHigh,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          size: 48,
          color: theme.colorScheme.onSurfaceVariant.withAlpha(
            AppOpacity.medium,
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingPlaceholder(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: theme.colorScheme.primary.withAlpha(AppOpacity.medium),
          ),
        ),
      ),
    );
  }
}

/// Grid of movie cards with responsive layout
class MovieCardGrid extends StatelessWidget {
  final List<Movie> movies;
  final ValueChanged<Movie>? onMovieTap;
  final ScrollController? controller;
  final EdgeInsets? padding;
  final bool shrinkWrap;

  const MovieCardGrid({
    super.key,
    required this.movies,
    this.onMovieTap,
    this.controller,
    this.padding,
    this.shrinkWrap = false,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = _calculateCrossAxisCount(screenWidth);

    return GridView.builder(
      controller: controller,
      padding: padding ?? EdgeInsets.all(AppSpacing.screenPadding),
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap
          ? const NeverScrollableScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 0.67,
        crossAxisSpacing: AppSpacing.md,
        mainAxisSpacing: AppSpacing.md,
      ),
      itemCount: movies.length,
      itemBuilder: (context, index) {
        final movie = movies[index];
        return MovieCard(movie: movie, onTap: () => onMovieTap?.call(movie));
      },
    );
  }

  int _calculateCrossAxisCount(double width) {
    if (width > 1400) return 7;
    if (width > 1200) return 6;
    if (width > 1000) return 5;
    if (width > 800) return 4;
    if (width > 600) return 3;
    return 2;
  }
}

/// Horizontal scrolling row of movie cards
class MovieCardRow extends StatelessWidget {
  final List<Movie> movies;
  final ValueChanged<Movie>? onMovieTap;
  final double cardWidth;
  final double cardHeight;
  final EdgeInsets? padding;

  const MovieCardRow({
    super.key,
    required this.movies,
    this.onMovieTap,
    this.cardWidth = 140,
    this.cardHeight = 210,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: cardHeight,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding:
            padding ??
            EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
        itemCount: movies.length,
        itemBuilder: (context, index) {
          final movie = movies[index];
          return Padding(
            padding: EdgeInsets.only(right: AppSpacing.md),
            child: MovieCard(
              movie: movie,
              width: cardWidth,
              height: cardHeight,
              onTap: () => onMovieTap?.call(movie),
            ),
          );
        },
      ),
    );
  }
}

/// Section header with title and optional "See All" button
class MovieSectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onSeeAll;

  const MovieSectionHeader({super.key, required this.title, this.onSeeAll});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (onSeeAll != null)
            TextButton(onPressed: onSeeAll, child: const Text('See All')),
        ],
      ),
    );
  }
}

/// Async movie row with loading and error states
class AsyncMovieRow extends StatelessWidget {
  final AsyncValue<List<Movie>> movies;
  final String title;
  final ValueChanged<Movie>? onMovieTap;
  final VoidCallback? onSeeAll;
  final VoidCallback? onRetry;

  const AsyncMovieRow({
    super.key,
    required this.movies,
    required this.title,
    this.onMovieTap,
    this.onSeeAll,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MovieSectionHeader(title: title, onSeeAll: onSeeAll),
        SizedBox(height: AppSpacing.sm),
        movies.when(
          data: (movieList) => movieList.isEmpty
              ? SizedBox(
                  height: 210,
                  child: Center(
                    child: Text(
                      'No movies found',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : MovieCardRow(movies: movieList, onMovieTap: onMovieTap),
          loading: () => const SizedBox(
            height: 210,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => SizedBox(
            height: 210,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  SizedBox(height: AppSpacing.sm),
                  Text(
                    'Failed to load',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (onRetry != null)
                    TextButton(onPressed: onRetry, child: const Text('Retry')),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
