import 'package:flutter/material.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import 'common/status_badge.dart';

/// Cinematic backdrop hero for the Show / Movie detail screens.
///
/// Renders:
///   * a full-bleed background image (or hue gradient fallback) at
///     480–520px tall,
///   * stacked gradient overlays (top → black bottom + left fade for
///     text legibility),
///   * an overlaid hero block with poster, big display title,
///     metadata pills, description, and a primary CTA row.
///
/// Matches the structure of the design's `ShowDetailScreen` /
/// `MovieDetailScreen` backdrop heroes.
class MediaHubBackdropHero extends StatelessWidget {
  const MediaHubBackdropHero({
    super.key,
    required this.title,
    required this.year,
    required this.metaPills,
    required this.posterUrl,
    required this.backdropUrl,
    required this.fallbackHue,
    required this.description,
    required this.primaryAction,
    this.posterPlaceholderIcon = Icons.movie_outlined,
    this.height = 480,
  });

  final String title;
  final String? year;
  final List<MediaHubMetaPill> metaPills;
  final String? posterUrl;
  final String? backdropUrl;
  final double fallbackHue;
  final String? description;
  final Widget primaryAction;
  final IconData posterPlaceholderIcon;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Backdrop image or hue gradient fallback. We log when TMDB
          // didn't ship a backdrop OR the network image errored — that's
          // typically a stale `Show`/`Movie` instance loaded from a list
          // endpoint that doesn't include `backdrop_path`. The fallback
          // hue gradient is intentional, not a "mockup" — just be aware
          // it kicks in whenever the URL is missing.
          if (backdropUrl != null)
            Image.network(
              backdropUrl!,
              fit: BoxFit.cover,
              loadingBuilder: (_, child, progress) =>
                  progress == null ? child : _backdropFallback(),
              errorBuilder: (_, e, __) {
                debugPrint(
                  '[Hero] backdrop load failed for "$title": $backdropUrl ($e)',
                );
                return _backdropFallback();
              },
            )
          else ...[
            Builder(builder: (_) {
              debugPrint(
                '[Hero] no backdrop URL for "$title" (TMDB had no backdrop_path)',
              );
              return _backdropFallback();
            }),
          ],

          // Top → bottom fade so the page content reads cleanly under
          // the hero image
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.55, 0.85, 1.0],
                colors: [
                  Colors.transparent,
                  AppColors.bgPage.withAlpha(120),
                  AppColors.bgPage.withAlpha(220),
                  AppColors.bgPage,
                ],
              ),
            ),
          ),
          // Left fade — protects metadata legibility over busy art
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                stops: const [0.0, 0.6],
                colors: [
                  AppColors.bgPage.withAlpha(178),
                  Colors.transparent,
                ],
              ),
            ),
          ),

          // Hero block — poster + title + meta + CTA
          Positioned(
            left: AppSpacing.huge,
            right: AppSpacing.huge,
            bottom: AppSpacing.huge,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Poster — same diagnostic story as the backdrop above.
                if (posterUrl != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    child: Image.network(
                      posterUrl!,
                      width: 200,
                      height: 300,
                      fit: BoxFit.cover,
                      loadingBuilder: (_, child, progress) =>
                          progress == null ? child : _posterFallback(),
                      errorBuilder: (_, e, __) {
                        debugPrint(
                          '[Hero] poster load failed for "$title": $posterUrl ($e)',
                        );
                        return _posterFallback();
                      },
                    ),
                  )
                else ...[
                  Builder(builder: (_) {
                    debugPrint(
                      '[Hero] no poster URL for "$title" (TMDB had no poster_path)',
                    );
                    return _posterFallback();
                  }),
                ],
                const SizedBox(width: AppSpacing.xxl),

                // Title block
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: AppSpacing.xs,
                        children: [
                          for (final p in metaPills)
                            StatusBadge(
                              label: p.label,
                              textColor: p.color,
                              size: StatusBadgeSize.small,
                              icon: p.icon,
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 52,
                          fontWeight: FontWeight.w800,
                          height: 0.95,
                          letterSpacing: -1.6,
                          color: Colors.white,
                          shadows: [
                            Shadow(
                              color: Colors.black.withAlpha(102),
                              blurRadius: 24,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                      ),
                      if (year != null) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          year!.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF7A7A92),
                            letterSpacing: 0.5,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                      if (description != null && description!.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.md),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: Text(
                            description!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 14,
                              height: 1.6,
                              color: const Color(0xFFB4B4C8),
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

  Widget _backdropFallback() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, fallbackHue, 0.5, 0.18).toColor(),
            HSLColor.fromAHSL(1, (fallbackHue + 30) % 360, 0.5, 0.08).toColor(),
          ],
        ),
      ),
    );
  }

  Widget _posterFallback() {
    return Container(
      width: 200,
      height: 300,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            HSLColor.fromAHSL(1, fallbackHue, 0.6, 0.4).toColor(),
            HSLColor.fromAHSL(1, fallbackHue, 0.5, 0.18).toColor(),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Colors.white.withAlpha(20)),
      ),
      child: Center(
        child: Icon(
          posterPlaceholderIcon,
          size: 64,
          color: Colors.white.withAlpha(102),
        ),
      ),
    );
  }
}

/// A metadata pill rendered in the hero — small mono uppercase pill,
/// auto-tinted from `color` (foreground) with a soft alpha background.
class MediaHubMetaPill {
  const MediaHubMetaPill({required this.label, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;
}
