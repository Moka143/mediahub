import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/cast_member.dart';
import '../../utils/error_messages.dart';
import '../common/back_shortcuts.dart';
import '../common/empty_state.dart';
import '../common/floating_header_action.dart';
import '../common/loading_state.dart';
import '../editorial/editorial.dart';
import '../media/cast_row.dart';
import '../mediahub_backdrop_hero.dart';
import 'detail_shell.dart';
import 'show_detail_sections.dart';

/// What a details page already knows about its title before the full
/// record has loaded — what the card that opened it showed.
@immutable
class DetailsPreview {
  const DetailsPreview({
    required this.title,
    required this.year,
    required this.posterUrl,
    required this.backdropUrl,
    required this.hue,
    this.placeholderIcon = Icons.movie_outlined,
  });

  final String title;
  final String? year;
  final String? posterUrl;
  final String? backdropUrl;
  final double hue;
  final IconData placeholderIcon;
}

/// A pushed details page — movie or show.
///
/// Back is on screen in every state and Esc / ⌘[ / Alt+← leave the page.
/// Both pages used to draw Back only once the data had loaded, so a page
/// that was still loading, or had failed to load, was a dead end — and the
/// show page's failure state was a bare `Error: TmdbApiException: …`.
class DetailsPageScaffold<T> extends StatelessWidget {
  const DetailsPageScaffold({
    super.key,
    required this.value,
    required this.subject,
    required this.onRetry,
    required this.builder,
    this.headerActions,
    this.onOpenSettings,
    this.preview,
  });

  final AsyncValue<T> value;

  /// Drawn while [value] loads, in place of a bare spinner: the page opened
  /// from a card that already showed the poster and title.
  final DetailsPreview? preview;

  /// What failed to load, for the error message — "this movie".
  final String subject;
  final VoidCallback onRetry;
  final Widget Function(BuildContext context, T data) builder;

  /// Controls for the top-right corner, once there is data to act on.
  final Widget Function(T data)? headerActions;

  /// Where to send someone whose TMDB token was rejected.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    // Data first, then the error, then loading. While Riverpod retries a
    // failed request in the background the value is "loading" with the error
    // attached; reading it as loading kept an offline page spinning for the
    // ~40 s of retries before admitting anything was wrong.
    final data = value.value;
    final Widget body;
    if (data != null) {
      body = builder(context, data);
    } else if (value.hasError) {
      final error = value.error!;
      final needsSettings =
          failureNeedsSettings(error) && onOpenSettings != null;
      body = EmptyState.error(
        title: "Couldn't load $subject",
        message: friendlyErrorMessage(error, subject: subject),
        onRetry: onRetry,
        secondaryLabel: needsSettings ? 'Open Settings' : null,
        onSecondary: needsSettings ? onOpenSettings : null,
      );
    } else if (preview case final known?) {
      body = _LoadingPreview(preview: known);
    } else {
      body = const LoadingIndicator();
    }

    return BackShortcuts(
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(child: body),
            Positioned(
              top: AppSpacing.lg,
              left: AppSpacing.xxl,
              child: SafeArea(
                child: FloatingHeaderAction(
                  icon: Icons.arrow_back_rounded,
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
            if (data != null && headerActions != null)
              Positioned(
                top: AppSpacing.lg,
                right: AppSpacing.xxl,
                child: SafeArea(child: headerActions!(data)),
              ),
          ],
        ),
      ),
    );
  }
}

/// The details hero for a [DetailsPreview], with its actions held back
/// until the record they need (an IMDb id, the seasons) has loaded.
class _LoadingPreview extends StatelessWidget {
  const _LoadingPreview({required this.preview});

  final DetailsPreview preview;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: MediaHubBackdropHero(
            title: preview.title,
            year: preview.year,
            metaPills: const [],
            posterUrl: preview.posterUrl,
            backdropUrl: preview.backdropUrl,
            fallbackHue: preview.hue,
            description: null,
            posterPlaceholderIcon: preview.placeholderIcon,
            primaryAction: const EditorialButton(
              label: 'Loading…',
              icon: Icons.hourglass_empty_rounded,
              large: true,
            ),
          ),
        ),
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.detailPadding),
            child: ThinProgressLine(),
          ),
        ),
      ],
    );
  }
}

/// Favourite, watchlist and settings over a details hero — one cluster for
/// both pages.
class DetailsHeaderActions extends StatelessWidget {
  const DetailsHeaderActions({
    super.key,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.isOnWatchlist,
    required this.onToggleWatchlist,
    required this.onOpenSettings,
  });

  final bool isFavorite;
  final VoidCallback onToggleFavorite;
  final bool isOnWatchlist;
  final VoidCallback onToggleWatchlist;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingHeaderAction(
          icon: isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_outline_rounded,
          iconColor: isFavorite ? AppColors.err : AppColors.fg,
          tooltip: isFavorite ? 'Remove from favorites' : 'Add to favorites',
          onPressed: onToggleFavorite,
        ),
        const SizedBox(width: AppSpacing.xs),
        FloatingHeaderAction(
          icon: isOnWatchlist
              ? Icons.bookmark_rounded
              : Icons.bookmark_outline_rounded,
          iconColor: isOnWatchlist ? AppColors.warn : AppColors.fg,
          tooltip: isOnWatchlist ? 'Remove from watchlist' : 'Add to watchlist',
          onPressed: onToggleWatchlist,
        ),
        const SizedBox(width: AppSpacing.xs),
        FloatingHeaderAction(
          icon: Icons.settings_outlined,
          iconColor: AppColors.fg,
          tooltip: 'Settings',
          onPressed: onOpenSettings,
        ),
      ],
    );
  }
}

/// Section padding shared by everything under the hero, so the page has
/// one left edge.
const EdgeInsets _sectionPadding = EdgeInsets.fromLTRB(
  AppSpacing.detailPadding,
  AppSpacing.xl,
  AppSpacing.detailPadding,
  0,
);

/// The synopsis, as "Overview" on both pages — the show page called the
/// same thing "Storyline".
class DetailsOverviewSliver extends StatelessWidget {
  const DetailsOverviewSliver({super.key, required this.overview});

  final String? overview;

  @override
  Widget build(BuildContext context) {
    final text = overview;
    if (text == null || text.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverToBoxAdapter(
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: Padding(
            padding: _sectionPadding,
            child: InfoSection(
              title: 'Overview',
              child: Text(
                text,
                // 0.25 is the tracking this inherited from the theme's body
                // style, kept so the paragraph sets as it did.
                style: AppType.ui(
                  size: AppType.sizeLead,
                  color: AppColors.fg1,
                  height: 1.6,
                  letterSpacing: 0.25,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Cast, folded away by default.
class DetailsCastSliver extends StatelessWidget {
  const DetailsCastSliver({super.key, required this.cast});

  final List<CastMember> cast;

  @override
  Widget build(BuildContext context) {
    if (cast.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final count = cast.length > 12 ? '12+' : '${cast.length}';
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: FoldableSection(
          title: 'Cast',
          count: '$count CREDITS',
          child: CastRow(cast: cast),
        ),
      ),
    );
  }
}

/// "More like this" — at the bottom and deliberately quiet: a little dimmed
/// until pointed at, because the reader came for this title, not the next
/// one. Its arrows show without hover, though: hidden ones left a row cut
/// off at the window edge that a mouse wheel could not scroll.
class DetailsSimilarSliver extends StatelessWidget {
  const DetailsSimilarSliver({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
  });

  /// Width of each card in the row.
  static const double cardWidth = 124;

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    if (itemCount == 0) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(
                left: AppSpacing.detailPadding,
                right: AppSpacing.detailPadding,
                bottom: AppSpacing.md,
              ),
              child: SerifTitle(
                'More like this',
                size: AppType.sizeTitle,
                height: 1.0,
              ),
            ),
            HoverScrollRow(
              // The overlay card is a bare 2:3 poster.
              height: cardWidth * 3 / 2,
              restingOpacity: 0.8,
              alwaysShowArrows: true,
              fadeEdges: true,
              itemCount: itemCount,
              itemBuilder: itemBuilder,
            ),
          ],
        ),
      ),
    );
  }
}
