import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/show.dart';
import '../../models/watch_progress.dart';
import '../../widgets/common/loading_state.dart';
import '../../widgets/editorial/editorial.dart';
import '../../widgets/media/hue_backdrop.dart';
import '../../widgets/media/poster_lookup.dart';
import 'home_hero_data.dart';

/// The Home hero: the title in progress, or — before anything has been
/// watched — the week's top trending show.
///
/// Its actions use the browse spotlight's words for the same thing:
/// "Stream" to watch, "Details" for the page. The hero said "Browse" and
/// "More info" where the spotlight, for the same title, said "Get torrent"
/// and "Details".
class HeroCard extends StatelessWidget {
  const HeroCard({
    super.key,
    required this.progress,
    required this.art,
    required this.fallbackShow,
    required this.onPrimaryTap,
    this.onSecondaryTap,
  });

  /// The most recent Continue Watching entry, if any.
  final WatchProgress? progress;
  final HeroArt? art;

  /// Shown when there is nothing in progress.
  final Show? fallbackShow;

  final VoidCallback onPrimaryTap;
  final VoidCallback? onSecondaryTap;

  /// The largest type on Home — above the type ramp's top step,
  /// [AppType.sizeDisplay].
  static const double _titleSize = 64;

  /// A *minimum*, as on the browse spotlight. A two-line title over a
  /// three-line overview needs ~410 px; at a fixed 360 the Stream and
  /// Details buttons were clipped off the bottom.
  static const double _minHeight = 360;

  /// Fixed rather than stretched to the card: the text keeps a gutter this
  /// wide clear for it, and a poster that grew with a taller card would grow
  /// back over the text.
  static const double _posterHeight = _minHeight - 80;
  static const double _posterWidth = _posterHeight * 2 / 3;

  @override
  Widget build(BuildContext context) {
    final hero = progress;
    final fb = hero == null ? fallbackShow : null;
    final title = hero != null
        ? (art?.title ?? watchProgressTitle(hero))
        : (fb?.name ?? 'MediaHub');
    final hue = hero != null
        ? hueForText(title)
        : (fb != null ? hueForId(fb.id) : 220.0);
    final backdropUrl = tmdbResized(
      hero != null ? art?.backdropUrl : (fb?.backdropUrl ?? fb?.posterUrl),
    );
    final posterUrl = hero != null ? art?.posterUrl : fb?.posterUrl;

    final String badge;
    final String body;
    final String primaryLabel;
    final IconData primaryIcon;
    if (hero != null) {
      badge = 'Continue watching';
      body = 'Pick up where you left off — ${_remaining(hero)} left.';
      primaryLabel = 'Resume';
      primaryIcon = Icons.play_arrow_rounded;
    } else if (fb != null) {
      badge = '▲ Trending';
      body = (fb.overview != null && fb.overview!.isNotEmpty)
          ? fb.overview!
          : 'This week\'s most-watched show.';
      primaryLabel = 'Stream';
      primaryIcon = Icons.play_arrow_rounded;
    } else {
      badge = 'Welcome';
      body =
          'Browse shows or movies, pick a source, and start watching while '
          'it downloads.';
      primaryLabel = 'Browse shows';
      primaryIcon = Icons.explore_rounded;
    }

    // The text is the only non-positioned child, so it sizes the Stack;
    // every other layer is positioned behind or beside it.
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _minHeight),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Positioned.fill(
              child: backdropUrl != null
                  ? CachedNetworkImage(
                      imageUrl: backdropUrl,
                      fit: BoxFit.cover,
                      memCacheWidth: 1600,
                      errorWidget: (_, _, _) =>
                          HueBackdrop(hue: hue, dark: true),
                      placeholder: (_, _) => HueBackdrop(hue: hue, dark: true),
                    )
                  : HueBackdrop(hue: hue, dark: true),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.6, -0.4),
                    radius: 1.0,
                    colors: [
                      HSLColor.fromAHSL(0.5, hue % 360, 0.7, 0.3).toColor(),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            if (posterUrl != null)
              Positioned(
                right: AppSpacing.xxl,
                top: 0,
                bottom: 0,
                child: Center(
                  child: SizedBox(
                    width: _posterWidth,
                    height: _posterHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(
                          color: AppColors.onMedia.withAlpha(AppOpacity.light),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.shadow.withValues(alpha: 0.55),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        child: CachedNetworkImage(
                          imageUrl: posterUrl,
                          fit: BoxFit.cover,
                          memCacheWidth: 400,
                          errorWidget: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    stops: const [0.0, 0.55, 0.82],
                    colors: [
                      AppColors.bgPage.withAlpha(AppOpacity.heavy),
                      AppColors.bgPage.withValues(alpha: 0.35),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: Padding(
                // The right side keeps the poster's column clear: the title
                // and overview ran on underneath it.
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.huge,
                  AppSpacing.huge,
                  posterUrl == null
                      ? AppSpacing.huge
                      : AppSpacing.xxl + _posterWidth + AppSpacing.xxl,
                  AppSpacing.huge,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: [
                        EditorialBadge(
                          badge,
                          tone: hero != null
                              ? AppColors.accent
                              : AppColors.warn,
                        ),
                        if (hero?.episodeCode != null)
                          EditorialBadge(
                            hero!.episodeCode!,
                            tone: AppColors.fg1,
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SerifTitle(
                      title,
                      size: _titleSize,
                      height: 0.95,
                      letterSpacing: -0.02,
                      color: AppColors.fg,
                      maxLines: 2,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 540),
                      child: Text(
                        body,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.ui(
                          size: AppType.sizeLead,
                          color: AppColors.fg1,
                          height: 1.6,
                        ),
                      ),
                    ),
                    if (hero != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      SizedBox(
                        width: 320,
                        child: EditorialProgress(value: hero.progress),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        EditorialButton(
                          label: primaryLabel,
                          icon: primaryIcon,
                          kind: EditorialButtonKind.accent,
                          large: true,
                          onPressed: onPrimaryTap,
                        ),
                        if (onSecondaryTap != null)
                          EditorialButton(
                            label: 'Details',
                            kind: EditorialButtonKind.ghost,
                            large: true,
                            onPressed: onSecondaryTap,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _remaining(WatchProgress p) {
    final m = (p.duration - p.position).inMinutes;
    if (m < 1) return 'under a minute';
    if (m < 60) return '$m min';
    return '${m ~/ 60}h ${m % 60}m';
  }
}

/// The hero's place while Home does not yet know what to put in it.
///
/// [HeroCard] with nothing to show says "Welcome — Browse shows", which is
/// right for a first run with no network but wrong for the second it takes
/// trending to load: the card then swapped to a show, and its main button
/// changed under the pointer.
class HeroSkeleton extends StatelessWidget {
  const HeroSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: HeroCard._minHeight),
      padding: const EdgeInsets.all(AppSpacing.huge),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      child: Semantics(
        label: 'Loading',
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonBox(width: 96, height: 20),
            SizedBox(height: AppSpacing.lg),
            SkeletonBox(width: 380, height: 48),
            SizedBox(height: AppSpacing.lg),
            SkeletonBox(width: 520, height: 14),
            SizedBox(height: AppSpacing.sm),
            SkeletonBox(width: 440, height: 14),
          ],
        ),
      ),
    );
  }
}
