import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../editorial/editorial.dart';
import 'media_helpers.dart';

/// Action available in a [MediaPosterCard] overflow menu.
class MediaCardAction {
  final IconData icon;
  final String label;
  final VoidCallback onSelected;
  final bool destructive;

  const MediaCardAction({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.destructive = false,
  });
}

/// How the title is laid out on a [MediaPosterCard].
enum CardTitleStyle {
  /// Title rendered in a small caption block below the poster.
  /// Used in library / continue-watching contexts where readability
  /// of the title and surrounding metadata matters.
  below,

  /// Title overlaid on the poster bottom with italic serif + shadow.
  /// Used in browse contexts where the poster art is the primary
  /// signal and the title is a label on top of it.
  overlay,
}

/// Unified poster card. Two layouts:
///
/// * [CardTitleStyle.below] (default) — poster with optional badge,
///   progress bar, watched checkmark, hover-revealed overflow menu;
///   title and subtitle render in a caption block below the poster.
///   Used in the Library tab.
///
/// * [CardTitleStyle.overlay] — full-bleed poster; title rendered in
///   italic serif at the bottom of the poster with a shadow for
///   legibility; optional [overlayYear] mono text top-left and
///   [overlayRating] badge top-right. Used by Movies / Shows browse.
class MediaPosterCard extends ConsumerStatefulWidget {
  final AsyncValue<String?>? posterAsync;
  final String title;
  final String? subtitle;
  final String? badge;

  /// Visual treatment for [badge]. Defaults to neutral hairline.
  /// Only honoured in [CardTitleStyle.below] mode.
  final BadgeKind badgeKind;

  /// When non-null, overrides [badgeKind] and tints the badge with
  /// this arbitrary color (used for rating colors, quality colors).
  /// Only honoured in [CardTitleStyle.below] mode.
  final Color? badgeTone;

  final double? progress;
  final bool isWatched;
  final VoidCallback onTap;
  final List<MediaCardAction> actions;

  /// Fixed card width. Pass null inside a grid (`SliverGrid` etc.)
  /// to let the parent's constraint drive the size.
  final double? width;

  /// Which layout to use. Defaults to `below` (library style).
  final CardTitleStyle titleStyle;

  /// Year text shown top-left of the poster in [CardTitleStyle.overlay].
  final String? overlayYear;

  /// Rating text shown top-right of the poster in [CardTitleStyle.overlay]
  /// (typically `'★ 8.5'`). Renders as an [EditorialBadge] tinted with
  /// [overlayRatingTone] when supplied, otherwise [BadgeKind.neutral].
  final String? overlayRating;

  /// Optional tint for [overlayRating]; pass [AppColors.accent]-like
  /// for high ratings.
  final Color? overlayRatingTone;

  const MediaPosterCard({
    super.key,
    required this.title,
    required this.onTap,
    this.posterAsync,
    this.subtitle,
    this.badge,
    this.badgeKind = BadgeKind.neutral,
    this.badgeTone,
    this.progress,
    this.isWatched = false,
    this.actions = const [],
    this.width = 152,
    this.titleStyle = CardTitleStyle.below,
    this.overlayYear,
    this.overlayRating,
    this.overlayRatingTone,
  });

  /// Height this card needs at [width] in the default
  /// [CardTitleStyle.below] layout.
  ///
  /// A horizontal `ListView` has to be given a bounded cross axis, so its
  /// host must state a height — and a hard-coded one silently drifts out of
  /// date the moment the card's text block changes. The Continue Watching
  /// row was pinned at 190 against a card that needs ~275, which clipped
  /// 84 px off every card in it.
  ///
  /// Text is measured through the ambient [TextScaler] rather than assumed,
  /// so the row also survives a user running large accessibility text —
  /// which a fixed number never would.
  static double heightForWidth(
    BuildContext context, {
    double width = 152,
    bool hasSubtitle = true,
  }) {
    final scaler = MediaQuery.textScalerOf(context);
    // Poster is a 2:3 AspectRatio.
    final poster = width * 3 / 2;
    // _buildBelowLayout's padding: xs on top, sm on the bottom.
    const padding = AppSpacing.xs + AppSpacing.sm;
    // bodySmall / labelSmall at their default ~1.35 line height.
    final title = scaler.scale(12) * 1.35;
    final subtitle = hasSubtitle ? 3 + scaler.scale(11) * 1.35 : 0.0;
    // Round up, plus a hair, so sub-pixel rounding can't reintroduce the
    // overflow this method exists to prevent.
    return (poster + padding + title + subtitle).ceilToDouble() + 2;
  }

  @override
  ConsumerState<MediaPosterCard> createState() => _MediaPosterCardState();
}

class _MediaPosterCardState extends ConsumerState<MediaPosterCard> {
  bool _isHovered = false;
  bool _menuOpen = false;

  Color _progressColor(ThemeData theme) {
    final p = widget.progress ?? 0;
    if (p >= 0.9) return const Color(0xFF10B981);
    if (p >= 0.6) return theme.colorScheme.primary;
    return theme.colorScheme.primary.withValues(alpha: 0.8);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaleFactor = _isHovered ? 1.03 : 1.0;
    final hasProgress = widget.progress != null && widget.progress! > 0;
    final isOverlay = widget.titleStyle == CardTitleStyle.overlay;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        scale: scaleFactor,
        duration: AppDuration.fast,
        curve: Curves.easeOutCubic,
        child: Container(
          width: widget.width,
          decoration: mediaCardDecoration(context).copyWith(
            boxShadow: _isHovered
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.2),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                InkWell(
                  onTap: widget.onTap,
                  child: isOverlay
                      ? _buildOverlayLayout(theme, hasProgress)
                      : _buildBelowLayout(theme, hasProgress),
                ),

                // Overflow action menu — sibling of the InkWell so the
                // popup button captures taps independently. Stays mounted
                // regardless of hover; visibility is toggled via opacity +
                // IgnorePointer. If we conditionally remove it on hover-out,
                // opening the menu disposes the PopupMenuButton's State (the
                // modal barrier triggers MouseRegion.onExit → setState → tree
                // rebuilds without the button), and showMenu's `.then` then
                // sees `!mounted` and silently drops `onSelected` — so the
                // menu opens and closes but the action never fires.
                if (widget.actions.isNotEmpty)
                  Positioned(
                    top: AppSpacing.xs,
                    right: AppSpacing.xs,
                    child: AnimatedOpacity(
                      duration: AppDuration.fast,
                      opacity: (_isHovered || _menuOpen) ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: !(_isHovered || _menuOpen),
                        child: Material(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(AppRadius.full),
                          child: PopupMenuButton<MediaCardAction>(
                            tooltip: 'More',
                            icon: const Padding(
                              padding: EdgeInsets.all(2),
                              child: Icon(
                                Icons.more_vert_rounded,
                                size: 18,
                                color: Colors.white,
                              ),
                            ),
                            padding: EdgeInsets.zero,
                            onOpened: () => setState(() => _menuOpen = true),
                            onCanceled: () => setState(() => _menuOpen = false),
                            onSelected: (a) {
                              setState(() => _menuOpen = false);
                              a.onSelected();
                            },
                            itemBuilder: (_) => [
                              for (final a in widget.actions)
                                PopupMenuItem<MediaCardAction>(
                                  value: a,
                                  child: Row(
                                    children: [
                                      Icon(
                                        a.icon,
                                        size: 18,
                                        color: a.destructive
                                            ? theme.colorScheme.error
                                            : null,
                                      ),
                                      const SizedBox(width: AppSpacing.sm),
                                      Text(
                                        a.label,
                                        style: TextStyle(
                                          color: a.destructive
                                              ? theme.colorScheme.error
                                              : null,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
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

  /// Library layout — poster + caption block below.
  Widget _buildBelowLayout(ThemeData theme, bool hasProgress) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              buildPosterImage(theme: theme, posterAsync: widget.posterAsync),
              _bottomGradient(),
              _centeredPlayHover(theme),
              if (widget.badge != null)
                Positioned(
                  top: AppSpacing.sm,
                  left: AppSpacing.sm,
                  child: EditorialBadge(
                    widget.badge!,
                    kind: widget.badgeKind,
                    tone: widget.badgeTone,
                    compact: true,
                  ),
                ),
              if (widget.isWatched && !_isHovered) _watchedCheckmark(),
              if (hasProgress) _progressBar(theme),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sm,
            AppSpacing.xs,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (widget.subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  widget.subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.7,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Browse layout — full-bleed poster with title overlaid at bottom.
  Widget _buildOverlayLayout(ThemeData theme, bool hasProgress) {
    const textShadow = [
      Shadow(color: Color(0xB3000000), offset: Offset(0, 2), blurRadius: 14),
    ];
    return AspectRatio(
      aspectRatio: 2 / 3,
      child: Stack(
        fit: StackFit.expand,
        children: [
          buildPosterImage(theme: theme, posterAsync: widget.posterAsync),
          _bottomGradient(),
          if (widget.overlayYear != null || widget.overlayRating != null)
            _topGradient(),

          // Year (top-left mono).
          if (widget.overlayYear != null)
            Positioned(
              top: 10,
              left: 10,
              child: Text(
                widget.overlayYear!,
                style:
                    AppType.mono(
                      // Full white, not 85%: against the scrim the text is
                      // already soft enough, and the alpha was costing
                      // contrast exactly where it was scarcest.
                      size: 10,
                      color: Colors.white,
                      letterSpacing: 0.12,
                      weight: FontWeight.w600,
                    ).copyWith(
                      shadows: const [
                        // A tight shadow for the edge of a light poster the
                        // scrim does not fully cover, plus a wider soft one
                        // for overall separation.
                        Shadow(color: Color(0xCC000000), blurRadius: 3),
                        Shadow(color: Color(0x99000000), blurRadius: 8),
                      ],
                    ),
              ),
            ),

          // Rating badge (top-right).
          if (widget.overlayRating != null)
            Positioned(
              top: 10,
              right: 10,
              child: EditorialBadge(
                widget.overlayRating!,
                tone: widget.overlayRatingTone,
              ),
            ),

          // Browse / overlay layout: a diagonal corner ribbon reads
          // "watched" at a glance, even when the poster has a busy
          // background that hides the small checkmark. Hidden on hover
          // so the play prompt + rating badge stay legible.
          if (widget.isWatched && !_isHovered) _watchedRibbon(theme),

          // Title overlay bottom.
          Positioned(
            bottom: 12,
            left: 12,
            right: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.serif(
                    size: 18,
                    color: AppColors.fg,
                    height: 1.05,
                    letterSpacing: -0.01,
                  ).copyWith(shadows: textShadow),
                ),
                if (widget.subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.subtitle!.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        AppType.mono(
                          size: 10,
                          color: Colors.white.withValues(alpha: 0.7),
                          letterSpacing: 0.1,
                          weight: FontWeight.w500,
                        ).copyWith(
                          shadows: const [
                            Shadow(color: Color(0x99000000), blurRadius: 6),
                          ],
                        ),
                  ),
                ],
              ],
            ),
          ),

          if (hasProgress) _progressBar(theme),

          if (_isHovered)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.accent, width: 1),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Shared sub-pieces ────────────────────────────────────────────

  /// Scrim behind the year and rating, mirroring [_bottomGradient].
  ///
  /// The year is small white mono text and used to rely on a drop shadow
  /// alone, which disappears against a bright poster — a daylight sky or a
  /// sunlit jungle left it barely readable. A shadow adds contrast only where
  /// the background is already dark, so it cannot fix light art; a scrim can.
  ///
  /// Shallower and lighter than the bottom one, which has a two-line serif
  /// title to carry. This only has to lift two corner labels off the image.
  Widget _topGradient() {
    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.55),
                Colors.transparent,
              ],
              stops: const [0.0, 0.28],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomGradient() {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
            stops: const [0.5, 1.0],
          ),
        ),
      ),
    );
  }

  Widget _centeredPlayHover(ThemeData theme) {
    return Center(
      child: AnimatedOpacity(
        duration: AppDuration.fast,
        opacity: _isHovered ? 1.0 : 0.85,
        child: AnimatedScale(
          duration: AppDuration.fast,
          scale: _isHovered ? 1.1 : 1.0,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              Icons.play_arrow_rounded,
              color: theme.colorScheme.onPrimary,
              size: 28,
            ),
          ),
        ),
      ),
    );
  }

  Widget _watchedCheckmark() {
    return Positioned(
      top: AppSpacing.xs,
      right: AppSpacing.xs,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: const BoxDecoration(
          color: Color(0xFF10B981),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check_rounded, size: 14, color: Colors.white),
      ),
    );
  }

  /// Diagonal "WATCHED" ribbon stretched across the top-right corner.
  /// Used on the [CardTitleStyle.overlay] layout (browse posters) where
  /// a tiny checkmark gets lost against busy poster art.
  ///
  /// Implementation: a custom `ClipPath` cuts the card's stack to the
  /// rounded-rect bounds (the parent `Material.clipBehavior` would
  /// otherwise leak the ribbon's rotated overhang) and we then draw a
  /// solid green band rotated 45° in the top-right corner.
  Widget _watchedRibbon(ThemeData theme) {
    return Positioned.fill(
      child: IgnorePointer(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Stack(
            children: [
              Positioned(
                top: 18,
                right: -36,
                child: Transform.rotate(
                  angle: 0.7853981633974483, // π/4 — 45°
                  alignment: Alignment.center,
                  child: Container(
                    width: 130,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Color(0xFF10B981),
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x66000000),
                          blurRadius: 6,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Text(
                      'WATCHED',
                      style: AppType.mono(
                        size: 9,
                        color: Colors.white,
                        weight: FontWeight.w800,
                        letterSpacing: 0.16,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _progressBar(ThemeData theme) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(AppRadius.xxs),
        ),
        child: AnimatedContainer(
          duration: AppDuration.fast,
          height: _isHovered ? 5 : 4,
          child: LinearProgressIndicator(
            value: widget.progress,
            minHeight: _isHovered ? 5 : 4,
            backgroundColor: Colors.white24,
            valueColor: AlwaysStoppedAnimation<Color>(_progressColor(theme)),
          ),
        ),
      ),
    );
  }
}
