import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import 'editorial/editorial.dart';
import 'media/hue_backdrop.dart';
import 'media/media_helpers.dart';
import 'media/poster_lookup.dart';

/// Cinematic spotlight card at the top of the Shows / Movies browse
/// screens: the feed's first title, over its backdrop, with its poster on
/// the right and the same two actions the Home hero uses — "Stream" and
/// "Details".
class MediaHubSpotlight extends StatelessWidget {
  const MediaHubSpotlight({
    super.key,
    required this.title,
    required this.year,
    required this.genre,
    required this.rating,
    required this.hue,
    required this.metaSuffix,
    required this.feedLabel,
    required this.onPrimaryTap,
    required this.onSecondaryTap,
    this.backdropUrl,
    this.posterUrl,
  });

  final String title;
  final String? year;

  /// The title's genre, or null when it is not known. Never a guess: the
  /// spotlight used to print "DRAMA" for anything without one.
  final String? genre;

  /// "★ 8.4", or null to show none — see `ratingLabel`.
  final String? rating;
  final double hue;
  final String metaSuffix; // e.g. "TV SERIES" or "2H 26M"

  /// Which feed this is the top of — "Trending", "Top rated · Horror". It
  /// always said "▲ Trending", including on Popular, Top Rated, New Releases
  /// and every genre filter.
  final String feedLabel;
  final VoidCallback onPrimaryTap;
  final VoidCallback onSecondaryTap;

  /// TMDB backdrop URL. Rendered full-bleed behind the gradient overlays;
  /// without one the card falls back to a hue gradient.
  final String? backdropUrl;

  /// TMDB poster URL, shown tall on the right of the card.
  final String? posterUrl;

  /// The headline title — larger than the type ramp's top step (40).
  static const double _titleSize = 56;

  @override
  Widget build(BuildContext context) {
    final backdrop = tmdbResized(backdropUrl);
    // 220 is a *minimum*, not a fixed height. A two-line title needs ~234px
    // with the badges, meta row and CTAs; as a fixed SizedBox this clipped
    // the CTA row of any title long enough to wrap. The body is the only
    // non-positioned child, so it sizes the Stack; every decorative layer is
    // Positioned.fill behind it.
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 220),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            // The backdrop provides texture and mood, not detail — it sits
            // behind the gradients and poster.
            Positioned.fill(
              child: backdrop != null
                  ? CachedNetworkImage(
                      imageUrl: backdrop,
                      fit: BoxFit.cover,
                      memCacheWidth: 1600,
                      placeholder: (_, _) => HueBackdrop(hue: hue, dark: true),
                      errorWidget: (_, _, _) =>
                          HueBackdrop(hue: hue, dark: true),
                    )
                  : HueBackdrop(hue: hue, dark: true),
            ),
            // Light hue tint over the photo so it harmonises with the page
            // palette; stronger over the bare gradient.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.7, 0),
                    radius: 0.9,
                    colors: [
                      HSLColor.fromAHSL(
                        backdrop == null ? 0.65 : 0.25,
                        (hue + 40) % 360,
                        0.6,
                        0.3,
                      ).toColor(),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            // Poster on the right, fading in from the left.
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 360,
              child: ClipRect(
                child: ShaderMask(
                  shaderCallback: (b) => const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Colors.transparent, AppColors.mediaBlack],
                    stops: [0.0, 0.45],
                  ).createShader(b),
                  blendMode: BlendMode.dstIn,
                  child: _HeroPoster(url: posterUrl, hue: hue),
                ),
              ),
            ),
            // Strong fade from the left for text legibility — heavier over a
            // real backdrop so the title doesn't fight bright artwork.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    stops: const [0.0, 0.45, 0.75],
                    colors: [
                      backdrop == null
                          ? AppColors.bgPage.withValues(alpha: 0.95)
                          : AppColors.bgPage.withAlpha(AppOpacity.almostOpaque),
                      AppColors.bgPage.withValues(
                        alpha: backdrop == null ? 0.5 : 0.66,
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xxl,
                  vertical: AppSpacing.lg,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: [
                        EditorialBadge(feedLabel, tone: AppColors.warn),
                        if (rating != null)
                          EditorialBadge(rating!, tone: AppColors.warn),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 540),
                      child: SerifTitle(
                        title,
                        size: _titleSize,
                        height: 0.95,
                        letterSpacing: -0.02,
                        color: AppColors.fg,
                        maxLines: 2,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    MonoLabel(
                      [?year, ?genre?.toUpperCase(), metaSuffix].join(' · '),
                      color: AppColors.fg1,
                      letterSpacing: 0.06,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        EditorialButton(
                          label: 'Stream',
                          icon: Icons.play_arrow_rounded,
                          kind: EditorialButtonKind.accent,
                          onPressed: onPrimaryTap,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        EditorialButton(
                          label: 'Details',
                          kind: EditorialButtonKind.ghost,
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
}

/// The tall poster anchored to the card's right edge, or a hue stand-in
/// when there is none.
class _HeroPoster extends StatelessWidget {
  const _HeroPoster({required this.url, required this.hue});

  final String? url;
  final double hue;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          right: AppSpacing.lg,
          top: 16,
          bottom: 16,
          child: AspectRatio(
            aspectRatio: 2 / 3,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.lineStrong),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.shadow.withValues(alpha: 0.47),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: buildPosterImage(
                  posterAsync: AsyncValue.data(url),
                  hue: hue,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
