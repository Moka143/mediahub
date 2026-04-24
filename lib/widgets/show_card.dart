import 'package:flutter/material.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_theme.dart';
import '../models/show.dart';
import 'common/empty_state.dart';
import 'common/loading_state.dart';

/// Modern card widget for displaying a TV show
class ShowCard extends StatefulWidget {
  final Show show;
  final VoidCallback? onTap;
  final bool showRating;
  final double? width;
  final double? height;
  final int newEpisodeCount;
  final double? watchProgress;

  const ShowCard({
    super.key,
    required this.show,
    this.onTap,
    this.showRating = true,
    this.width,
    this.height,
    this.newEpisodeCount = 0,
    this.watchProgress,
  });

  @override
  State<ShowCard> createState() => _ShowCardState();
}

class _ShowCardState extends State<ShowCard>
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

                // Gradient overlay - more subtle, deeper
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

                // Title at bottom
                Positioned(
                  bottom: AppSpacing.md,
                  left: AppSpacing.md,
                  right: AppSpacing.md,
                  child: Text(
                    widget.show.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                // Rating badge - glassmorphism style
                if (widget.showRating && widget.show.voteAverage > 0)
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
                          widget.show.voteAverage,
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
                            widget.show.voteAverage.toStringAsFixed(1),
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

                // Year badge - minimal style
                if (widget.show.year != null)
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
                        widget.show.year!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),

                // New episode badge (Stremio-inspired)
                if (widget.newEpisodeCount > 0)
                  Positioned(
                    top: AppSpacing.sm,
                    left: widget.show.year != null
                        ? AppSpacing.lg * 3
                        : AppSpacing.sm,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xxs,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        boxShadow: [
                          BoxShadow(
                            color: theme.colorScheme.primary.withAlpha(
                              AppOpacity.medium,
                            ),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.new_releases_rounded,
                            color: Colors.white,
                            size: 12,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '${widget.newEpisodeCount} new',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Watch progress bar at bottom
                if (widget.watchProgress != null && widget.watchProgress! > 0)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(AppOpacity.medium),
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(AppRadius.lg),
                          bottomRight: Radius.circular(AppRadius.lg),
                        ),
                      ),
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: widget.watchProgress!.clamp(0.0, 1.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.only(
                              bottomLeft: const Radius.circular(AppRadius.lg),
                              bottomRight: widget.watchProgress! >= 0.99
                                  ? const Radius.circular(AppRadius.lg)
                                  : Radius.zero,
                            ),
                          ),
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
    if (widget.show.posterUrl != null) {
      return Image.network(
        widget.show.posterUrl!,
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
    final appColors = context.appColors;

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
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.tv_rounded,
              size: AppIconSize.xxxl,
              color: appColors.mutedText.withAlpha(AppOpacity.semi),
            ),
            const SizedBox(height: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Text(
                widget.show.name,
                style: TextStyle(
                  color: appColors.mutedText,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingPlaceholder(BuildContext context) {
    final appColors = context.appColors;

    return Container(
      color: appColors.shimmerBase,
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation(
              Theme.of(
                context,
              ).colorScheme.primary.withAlpha(AppOpacity.strong),
            ),
          ),
        ),
      ),
    );
  }
}

/// Modern horizontal scrolling row of show cards
class ShowCardRow extends StatelessWidget {
  final String title;
  final List<Show> shows;
  final Function(Show) onShowTap;
  final VoidCallback? onSeeAllTap;
  final bool isLoading;

  const ShowCardRow({
    super.key,
    required this.title,
    required this.shows,
    required this.onShowTap,
    this.onSeeAllTap,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header - modern style
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenPadding,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              if (onSeeAllTap != null)
                TextButton.icon(
                  onPressed: onSeeAllTap,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: const Text('See All'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.xs,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),

        // Cards - larger, more prominent
        SizedBox(
          height: 220,
          child: isLoading
              ? ShimmerLoading(
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.screenPadding,
                    ),
                    itemCount: 5,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.lg),
                      child: const SkeletonShowCard(),
                    ),
                  ),
                )
              : shows.isEmpty
              ? Center(
                  child: Text(
                    'No shows found',
                    style: TextStyle(color: appColors.mutedText),
                  ),
                )
              : ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.screenPadding,
                  ),
                  clipBehavior: Clip.none,
                  itemCount: shows.length,
                  itemBuilder: (context, index) {
                    final show = shows[index];
                    return Padding(
                      padding: EdgeInsets.only(
                        right: index < shows.length - 1 ? AppSpacing.lg : 0,
                      ),
                      child: ShowCard(
                        show: show,
                        width: 140,
                        height: 210,
                        onTap: () => onShowTap(show),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Modern grid view of show cards with adaptive column count
class ShowCardGrid extends StatelessWidget {
  final List<Show> shows;
  final Function(Show) onShowTap;
  final bool isLoading;
  final int? crossAxisCount; // If null, will be calculated based on width
  final EdgeInsets? padding;
  final ScrollController? controller;

  const ShowCardGrid({
    super.key,
    required this.shows,
    required this.onShowTap,
    this.isLoading = false,
    this.crossAxisCount,
    this.padding,
    this.controller,
  });

  /// Calculate adaptive column count based on available width
  int _getAdaptiveColumnCount(double width) {
    // Each card should be at least 130px wide, ideally ~160px
    // We account for padding and spacing
    const minCardWidth = 130.0;
    const idealCardWidth = 160.0;
    final availableWidth = width - (AppSpacing.screenPadding * 2);

    // Calculate columns based on ideal width
    var columns = (availableWidth / (idealCardWidth + AppSpacing.lg)).floor();

    // Ensure at least 2 columns and at most 8
    return columns.clamp(2, 8);
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const LoadingState(message: 'Loading shows...');
    }

    if (shows.isEmpty) {
      return EmptyState.noResults(
        title: 'No shows found',
        subtitle: 'Try a different search term',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            crossAxisCount ?? _getAdaptiveColumnCount(constraints.maxWidth);

        return GridView.builder(
          controller: controller,
          padding: padding ?? const EdgeInsets.all(AppSpacing.screenPadding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            childAspectRatio: 0.62,
            crossAxisSpacing: AppSpacing.lg,
            mainAxisSpacing: AppSpacing.lg,
          ),
          itemCount: shows.length,
          itemBuilder: (context, index) {
            final show = shows[index];
            return ShowCard(show: show, onTap: () => onShowTap(show));
          },
        );
      },
    );
  }
}
