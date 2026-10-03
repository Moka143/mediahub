import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import 'editorial/editorial.dart';
import 'media/hue_backdrop.dart';
import 'media/media_helpers.dart';
import 'media/poster_lookup.dart';

/// Cinematic backdrop hero for the Show / Movie detail screens.
///
/// Renders:
///   * a full-bleed background image (or hue gradient fallback),
///   * stacked gradient overlays (top → black bottom + left fade for
///     text legibility),
///   * an overlaid hero block with poster, big display title,
///     metadata pills, description, and a primary CTA row.
class MediaHubBackdropHero extends StatelessWidget {
  const MediaHubBackdropHero({
    super.key,
    required this.title,
    required this.year,
    required this.metaPills,
    this.statusOverlay,
    required this.posterUrl,
    required this.backdropUrl,
    required this.fallbackHue,
    required this.description,
    required this.primaryAction,
    this.posterPlaceholderIcon = Icons.movie_outlined,
  });

  final String title;
  final String? year;
  final List<MediaHubMetaPill> metaPills;

  /// Small status marker above the title — the next-episode chip, today.
  ///
  /// Part of the title block's own column, so it gets that column's width
  /// and moves with it. It used to be pinned at a fixed spot with no width
  /// limit: its ellipsis never engaged (a long episode name drew a 2000-px
  /// chip in a 600-px hero), and a two-line title growing up from the bottom
  /// slid underneath it.
  final Widget? statusOverlay;
  final String? posterUrl;
  final String? backdropUrl;
  final double fallbackHue;
  final String? description;
  final Widget primaryAction;
  final IconData posterPlaceholderIcon;

  /// Top inset of the hero block: clears the floating controls over the hero.
  static const double _blockTopInset = 96;

  /// The masthead title — larger than the type ramp's top step (40).
  static const double _titleSize = 84;

  /// How tall the hero should be for a given viewport.
  ///
  /// A fixed 480 took 77% of a 625pt window, which is why the page under it
  /// always scrolled. Tying it to the viewport keeps the hero cinematic on a
  /// large display and stops it crowding out everything else on a laptop.
  ///
  /// The floor is set by the poster: below ~360 the artwork and the title
  /// block start colliding, and a hero that cannot show its own poster is not
  /// worth keeping.
  static double resolveHeight(double viewportHeight) =>
      (viewportHeight * 0.52).clamp(360.0, 480.0);

  /// Poster height for a given hero height, leaving room for the floating
  /// controls above and the hero's own bottom inset.
  static double resolvePosterHeight(double heroHeight) =>
      (heroHeight - 180).clamp(200.0, 300.0);

  @override
  Widget build(BuildContext context) {
    final heroHeight = resolveHeight(MediaQuery.sizeOf(context).height);
    final posterHeight = resolvePosterHeight(heroHeight);
    final backdrop = tmdbResized(backdropUrl);

    // A minimum, not a fixed height: the title block below is what sizes
    // the hero, so a two-line title, a tagline and large accessibility text
    // make it taller instead of pushing its top out of the frame, under the
    // floating Back button.
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: heroHeight),
      child: Stack(
        alignment: Alignment.bottomLeft,
        children: [
          // Backdrop, or the hue gradient when TMDB has none — a list
          // endpoint's record carries no backdrop path, for one.
          Positioned.fill(
            child: backdrop != null
                ? CachedNetworkImage(
                    imageUrl: backdrop,
                    fit: BoxFit.cover,
                    memCacheWidth: 1600,
                    placeholder: (_, _) =>
                        HueBackdrop(hue: fallbackHue, dark: true),
                    errorWidget: (_, _, _) =>
                        HueBackdrop(hue: fallbackHue, dark: true),
                  )
                : HueBackdrop(hue: fallbackHue, dark: true),
          ),

          // Top → bottom fade so the page content reads cleanly under
          // the hero image
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.55, 0.85, 1.0],
                  colors: [
                    Colors.transparent,
                    AppColors.bgPage.withValues(alpha: 0.47),
                    AppColors.bgPage.withValues(alpha: 0.86),
                    AppColors.bgPage,
                  ],
                ),
              ),
            ),
          ),
          // Left fade — protects metadata legibility over busy art
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  stops: const [0.0, 0.6],
                  colors: [
                    AppColors.bgPage.withValues(alpha: 0.7),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Hero block — poster + title + meta + CTA. The only child not
          // positioned, so the one that sets the hero's height; the top
          // inset keeps it clear of the floating controls.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.huge,
              _blockTopInset,
              AppSpacing.huge,
              AppSpacing.huge,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: SizedBox(
                    width: posterHeight * 2 / 3,
                    height: posterHeight,
                    child: buildPosterImage(
                      posterAsync: AsyncValue.data(posterUrl),
                      hue: fallbackHue,
                      placeholderIcon: posterPlaceholderIcon,
                      iconSize: 64,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.xxl),

                // Title block
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (statusOverlay != null) ...[
                        statusOverlay!,
                        const SizedBox(height: AppSpacing.md),
                      ],
                      // The year leads the metadata row rather than sitting
                      // under the title: at 84pt with a 0.92 line height a
                      // descender (the italic J of "Jumanji") dropped into
                      // it. It is the same class of fact as the runtime and
                      // the rating, so it gets the same treatment.
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.sm,
                        children: [
                          if (year != null && year!.isNotEmpty)
                            EditorialBadge(
                              year!,
                              prominent: true,
                              tone: AppColors.fg1,
                            ),
                          for (final p in metaPills)
                            EditorialBadge(
                              p.label,
                              prominent: true,
                              tone: p.color,
                              icon: p.icon,
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      SerifTitle(
                        title,
                        size: _titleSize,
                        height: 0.92,
                        letterSpacing: -0.02,
                        color: AppColors.fg,
                        maxLines: 2,
                      ),
                      if (description != null && description!.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.md),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: Text(
                            description!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.ui(
                              size: AppType.sizeLead,
                              color: AppColors.fg1,
                              height: 1.6,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.lg),
                      primaryAction,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A metadata pill rendered in the hero — runtime, rating, genres.
/// Sized for the cinematic title block, not the compact row badges.
class MediaHubMetaPill {
  const MediaHubMetaPill({required this.label, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;
}
