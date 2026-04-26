import 'package:flutter/material.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import 'common/status_badge.dart';

/// Cinematic spotlight hero card used at the top of the Shows /
/// Movies browse screens. Matches the `Spotlight` component from
/// `screen-browse.jsx`: gradient backdrop tinted by the title's
/// dominant hue, scattered miniature posters drifting on the right,
/// rich metadata pills + big display title + Get / Details CTAs.
class MediaHubSpotlight extends StatelessWidget {
  const MediaHubSpotlight({
    super.key,
    required this.title,
    required this.year,
    required this.genre,
    required this.rating,
    required this.quality,
    required this.hue,
    required this.metaSuffix,
    required this.onPrimaryTap,
    required this.onSecondaryTap,
    this.backdropUrl,
    this.posterUrl,
    this.scatteredHues = const [200, 35, 280, 130, 10],
    this.trending = true,
  });

  final String title;
  final String? year;
  final String? genre;
  final double rating;
  final String quality;
  final double hue;
  final String metaSuffix; // e.g. "2 SEASONS" or "2H 26M"
  final VoidCallback onPrimaryTap;
  final VoidCallback onSecondaryTap;

  /// TMDB backdrop URL (`/t/p/original/<path>`). Renders full-bleed
  /// behind the gradient overlays. If null we fall back to the
  /// hue-tinted procedural gradient.
  final String? backdropUrl;

  /// TMDB poster URL (`/t/p/w500/<path>`). Renders as a single tall
  /// hero poster on the right of the card (replaces the procedural
  /// mini-posters when supplied).
  final String? posterUrl;
  final List<int> scatteredHues;
  final bool trending;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: SizedBox(
        height: 220,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Backdrop image when available; otherwise a hue-tinted
            // gradient. The image is intentionally rendered "behind"
            // the gradient + poster overlays — it provides texture and
            // mood, not detail (which would compete with the title).
            if (backdropUrl != null)
              Image.network(
                backdropUrl!,
                fit: BoxFit.cover,
                alignment: Alignment.center,
                loadingBuilder: (_, child, p) =>
                    p == null ? child : _hueGradient(),
                errorBuilder: (_, __, ___) => _hueGradient(),
              )
            else
              _hueGradient(),
            // Light hue tint over the photo so it harmonises with the
            // page palette. Lower opacity than the procedural fallback
            // so the actual artwork still reads.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.7, 0),
                  radius: 0.9,
                  colors: [
                    HSLColor.fromAHSL(
                      backdropUrl == null ? 0.65 : 0.25,
                      (hue + 40) % 360,
                      0.6,
                      0.3,
                    ).toColor(),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            // Right-side hero poster — actual TMDB poster when
            // available, otherwise the legacy scattered mini-posters.
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
                    colors: [Colors.transparent, Colors.black],
                    stops: [0.0, 0.45],
                  ).createShader(b),
                  blendMode: BlendMode.dstIn,
                  child: posterUrl != null
                      ? _HeroPoster(url: posterUrl!, fallbackHue: hue)
                      : _ScatteredPosters(scatteredHues: scatteredHues),
                ),
              ),
            ),
            // Strong fade from left for text legibility — slightly
            // heavier when a real backdrop is in play so the title
            // doesn't fight bright artwork.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  stops: const [0.0, 0.45, 0.75],
                  colors: [
                    AppColors.bgPage.withAlpha(backdropUrl == null ? 243 : 235),
                    AppColors.bgPage.withAlpha(backdropUrl == null ? 128 : 168),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            // Body — pills, title, meta, CTAs
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xxl,
                vertical: AppSpacing.lg,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      if (trending)
                        StatusBadge(
                          label: '▲ Trending',
                          textColor: AppColors.accentTertiary,
                          size: StatusBadgeSize.small,
                        ),
                      StatusBadge.quality(
                        quality: quality,
                        size: StatusBadgeSize.small,
                      ),
                      if (rating > 0)
                        StatusBadge(
                          label: '★ ${rating.toStringAsFixed(1)}',
                          textColor: AppColors.warning,
                          size: StatusBadgeSize.small,
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        height: 1.05,
                        letterSpacing: -0.6,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    [
                      if (year != null) year,
                      if (genre != null) genre!.toUpperCase(),
                      metaSuffix,
                    ].whereType<String>().join(' · '),
                    style: const TextStyle(
                      fontSize: 12,
                      letterSpacing: 0.5,
                      color: Color(0xFF7A7A92),
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _CtaButton(
                        label: 'Get torrent',
                        icon: Icons.download_rounded,
                        onTap: onPrimaryTap,
                        primary: true,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      _CtaButton(
                        label: 'Details',
                        icon: null,
                        onTap: onSecondaryTap,
                        primary: false,
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
}

class _MiniPoster extends StatelessWidget {
  const _MiniPoster({required this.hue});

  final double hue;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 92,
      height: 138,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue, 0.6, 0.4).toColor(),
            HSLColor.fromAHSL(1, (hue + 30) % 360, 0.55, 0.18).toColor(),
          ],
        ),
        border: Border.all(color: Colors.white.withAlpha(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(64),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
    );
  }
}

/// Hue-tinted procedural gradient — used as the spotlight background
/// when no backdrop image is available, and during image load/error.
extension on MediaHubSpotlight {
  Widget _hueGradient() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            HSLColor.fromAHSL(1, hue, 0.45, 0.14).toColor(),
            HSLColor.fromAHSL(1, hue, 0.45, 0.08).toColor(),
          ],
        ),
      ),
    );
  }
}

/// Single tall poster anchored to the right edge — replaces the
/// procedural mini-posters when we have a real TMDB poster URL for
/// the trending title.
class _HeroPoster extends StatelessWidget {
  const _HeroPoster({required this.url, required this.fallbackHue});

  final String url;
  final double fallbackHue;

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
                border: Border.all(color: Colors.white.withAlpha(28)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(120),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  loadingBuilder: (_, child, p) =>
                      p == null ? child : _MiniPoster(hue: fallbackHue),
                  errorBuilder: (_, __, ___) => _MiniPoster(hue: fallbackHue),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Legacy decorative cluster of colored placeholder posters — kept as
/// the fallback when no real poster URL is supplied.
class _ScatteredPosters extends StatelessWidget {
  const _ScatteredPosters({required this.scatteredHues});

  final List<int> scatteredHues;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (var i = 0; i < scatteredHues.length; i++)
          Positioned(
            right: AppSpacing.md + i * (92.0 + AppSpacing.sm),
            top: i.isEven ? 24 : 40,
            child: _MiniPoster(hue: scatteredHues[i].toDouble()),
          ),
      ],
    );
  }
}

class _CtaButton extends StatefulWidget {
  const _CtaButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.primary,
  });

  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool primary;

  @override
  State<_CtaButton> createState() => _CtaButtonState();
}

class _CtaButtonState extends State<_CtaButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.seedColor;
    final bg = widget.primary
        ? (_hover ? accent : accent.withAlpha(0xE6))
        : (_hover ? Colors.white.withAlpha(28) : Colors.transparent);
    final fg = widget.primary ? Colors.white : Colors.white;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: widget.primary
                ? null
                : Border.all(color: const Color(0x1AFFFFFF)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 14, color: fg),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
