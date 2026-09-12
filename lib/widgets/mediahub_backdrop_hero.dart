import 'package:flutter/material.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../services/app_logger.dart';
import 'editorial/editorial.dart';

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
    this.statusOverlay,
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

  /// Small status marker pinned to the hero's top-left — the next-episode
  /// chip, today.
  ///
  /// It lived in its own full-width band between the hero and Trailers, which
  /// put a single narrow chip alone in ~100px of empty page. Worse, that band
  /// shrink-wrapped under a `Center`, so the chip drifted to the middle of the
  /// window while every other block stayed on the left margin — it read as a
  /// stray toast rather than as part of the layout. Over the backdrop it is
  /// next to the thing it describes, and costs no vertical space at all.
  final Widget? statusOverlay;
  final String? posterUrl;
  final String? backdropUrl;
  final double fallbackHue;
  final String? description;
  final Widget primaryAction;
  final IconData posterPlaceholderIcon;
  final double height;

  @override
  Widget build(BuildContext context) {
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
              errorBuilder: (_, e, _) {
                AppLog.e(
                  '[Hero] backdrop load failed for "$title": $backdropUrl ($e)',
                );
                return _backdropFallback();
              },
            )
          else ...[
            Builder(
              builder: (_) {
                AppLog.d(
                  '[Hero] no backdrop URL for "$title" (TMDB had no backdrop_path)',
                );
                return _backdropFallback();
              },
            ),
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
                colors: [AppColors.bgPage.withAlpha(178), Colors.transparent],
              ),
            ),
          ),

          // Status overlay — top-left, clear of the floating back button
          // and of the poster below it.
          if (statusOverlay != null)
            Positioned(
              left: AppSpacing.huge,
              top: AppSpacing.huge + 44,
              child: statusOverlay!,
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
                      errorBuilder: (_, e, _) {
                        AppLog.e(
                          '[Hero] poster load failed for "$title": $posterUrl ($e)',
                        );
                        return _posterFallback();
                      },
                    ),
                  )
                else ...[
                  Builder(
                    builder: (_) {
                      AppLog.d(
                        '[Hero] no poster URL for "$title" (TMDB had no poster_path)',
                      );
                      return _posterFallback();
                    },
                  ),
                ],
                const SizedBox(width: AppSpacing.xxl),

                // Title block
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The year leads the metadata row rather than sitting
                      // under the title.
                      //
                      // It used to be a small mono label below an 84pt serif
                      // title set at 0.92 line height — so a descender (the
                      // italic J of "Jumanji") dropped straight into it, and
                      // at that size next to that title it read as an
                      // artefact rather than as a fact. It is the same class
                      // of metadata as the runtime and the rating, so it
                      // belongs in the same row, at the same size, with the
                      // same contrast.
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
                        size: 84,
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
                              size: 14,
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

/// A metadata pill rendered in the hero — runtime, rating, genres.
/// Sized for the cinematic title block, not the compact row badges.
class MediaHubMetaPill {
  const MediaHubMetaPill({required this.label, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;
}
