import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/show.dart';
import '../../models/watch_progress.dart';
import '../../widgets/editorial/editorial.dart';
import 'home_hero_data.dart';

class HeroCard extends ConsumerWidget {
  const HeroCard({
    super.key,
    required this.continueWatching,
    this.fallbackShow,
    this.onPrimaryTap,
    this.onSecondaryTap,
  });

  final List<WatchProgress> continueWatching;

  /// When the user has no continue-watching items yet, the hero
  /// pulls art + title from this trending show so the page never
  /// shows an empty gradient on first run.
  final Show? fallbackShow;

  final VoidCallback? onPrimaryTap;
  final VoidCallback? onSecondaryTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hero = continueWatching.isNotEmpty ? continueWatching.first : null;
    final fb = fallbackShow;
    final hue = hero != null
        ? (hero.showName?.codeUnits.fold<int>(0, (a, b) => a + b) ?? 220) % 360
        : (fb != null ? (fb.id * 37) % 360 : 220);

    // Continue Watching uses that title's own backdrop + poster.
    // Trending art is only for the empty-library welcome hero — mixing
    // it in here is how Lioness ended up on another show's still.
    final cwArt = hero == null
        ? null
        : ref.watch(homeContinueHeroArtProvider).asData?.value;
    final backdropUrl = hero != null
        ? cwArt?.backdropUrl
        : (fb?.backdropUrl ?? fb?.posterUrl);
    final posterUrl = hero != null ? cwArt?.posterUrl : fb?.posterUrl;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: SizedBox(
        height: 360,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (backdropUrl != null)
              CachedNetworkImage(
                imageUrl: backdropUrl,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => hueBackdrop(hue),
                placeholder: (_, _) => hueBackdrop(hue),
              )
            else
              hueBackdrop(hue),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.6, -0.4),
                  radius: 1.0,
                  colors: [
                    HSLColor.fromAHSL(0.5, hue.toDouble(), 0.7, 0.3).toColor(),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            if (posterUrl != null)
              Positioned(
                right: AppSpacing.xxl,
                top: 40,
                bottom: 40,
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(color: Colors.white.withAlpha(28)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(140),
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
                        errorWidget: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  stops: const [0.0, 0.55, 0.82],
                  colors: [
                    AppColors.bgPage.withAlpha(200),
                    AppColors.bgPage.withAlpha(90),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.huge),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      EditorialBadge(
                        hero != null
                            ? 'Continue Watching'
                            : (fb != null ? '▲ Trending' : 'Welcome'),
                        compact: true,
                        tone: hero != null
                            ? AppColors.seedColor
                            : AppColors.accentAmber,
                      ),
                      if (hero?.episodeCode != null)
                        EditorialBadge(
                          hero!.episodeCode!,
                          compact: true,
                          tone: AppColors.fg2,
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SerifTitle(
                    hero?.showName ??
                        hero?.episodeTitle ??
                        fb?.name ??
                        'MediaHub',
                    size: 64,
                    height: 0.95,
                    letterSpacing: -0.02,
                    color: AppColors.fg,
                    maxLines: 2,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 540),
                    child: Text(
                      hero != null
                          ? 'Pick up where you left off — '
                                '${_progressLabel(hero)} remaining.'
                          : (fb?.overview != null && fb!.overview!.isNotEmpty
                                ? fb.overview!
                                : 'Browse Shows or Movies, queue a torrent, '
                                      'and start watching the moment it\'s ready.'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.ui(
                        size: 14,
                        color: AppColors.fg1,
                        height: 1.6,
                      ),
                    ),
                  ),
                  if (hero != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    SizedBox(
                      width: 320,
                      child: HomeProgressBar(
                        progress:
                            hero.position.inSeconds /
                            (hero.duration.inSeconds == 0
                                ? 1
                                : hero.duration.inSeconds),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      EditorialButton(
                        label: hero != null ? 'Resume' : 'Browse',
                        icon: Icons.play_arrow_rounded,
                        kind: EditorialButtonKind.accent,
                        large: true,
                        onPressed: onPrimaryTap ?? () {},
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      EditorialButton(
                        label: 'More info',
                        kind: EditorialButtonKind.ghost,
                        large: true,
                        onPressed: onSecondaryTap ?? () {},
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _progressLabel(WatchProgress p) {
    final remaining = p.duration - p.position;
    final m = remaining.inMinutes;
    if (m < 1) return '< 1 min';
    if (m < 60) return '$m min';
    return '${m ~/ 60}h ${m % 60}m';
  }
}

class HomeProgressBar extends StatelessWidget {
  const HomeProgressBar({super.key, required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 4,
        child: Stack(
          children: [
            Container(color: AppColors.glassBorder),
            FractionallySizedBox(
              widthFactor: progress.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.seedColor,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.seedColor.withAlpha(120),
                      blurRadius: 8,
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
}

class HomeSectionHeader extends StatelessWidget {
  const HomeSectionHeader({super.key, required this.title, this.onSeeAll});

  final String title;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        SerifTitle(title, size: 24, height: 1.0),
        const Spacer(),
        if (onSeeAll != null)
          InkWell(
            onTap: onSeeAll,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                'see all →',
                style: AppType.mono(
                  size: 11,
                  color: AppColors.fg2,
                  letterSpacing: 0.06,
                  weight: FontWeight.w500,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
