import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/movie.dart';
import '../../models/show.dart';
import '../common/hub_pressable.dart';
import '../common/mediahub_popup_menu.dart';
import '../editorial/editorial.dart';
import 'hue_backdrop.dart';
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

/// Fewest TMDB votes a rating needs before a card shows it. A "★ 10.0" from
/// three votes says nothing, and discover feeds sorted by rating are full of
/// them.
const int minRatingVotes = 20;

/// The "★ 8.4" badge text for a TMDB rating, or null when there is no
/// rating worth showing.
///
/// [voteCount] of 0 means "not reported" — a non-zero average needs at least
/// one vote — so the rating is shown as before.
String? ratingLabel(double average, {int voteCount = 0}) {
  if (average <= 0) return null;
  if (voteCount > 0 && voteCount < minRatingVotes) return null;
  return '★ ${average.toStringAsFixed(1)}';
}

/// Unified poster card. Two layouts:
///
/// * [CardTitleStyle.below] (default) — poster with optional badge,
///   progress bar, watched checkmark, overflow menu; title and subtitle in a
///   caption block below the poster. Used in the Library.
///
/// * [CardTitleStyle.overlay] — full-bleed poster; title in italic serif at
///   the bottom of the poster; optional [overlayYear] top-left and
///   [overlayRating] top-right. Used for TMDB titles — see
///   [MediaPosterCard.movie] and [MediaPosterCard.show].
///
/// Keyboard and right-click reach everything a hover does: the card takes
/// focus, Enter opens it, and focus or a right click reveals the overflow
/// menu, which used to appear only under the mouse.
class MediaPosterCard extends StatefulWidget {
  final AsyncValue<String?>? posterAsync;
  final String title;
  final String? subtitle;
  final String? badge;

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
  /// (typically `'★ 8.5'`, see [ratingLabel]).
  final String? overlayRating;

  /// Optional tint for [overlayRating].
  final Color? overlayRatingTone;

  /// Glyph on the placeholder shown while there is no poster.
  final IconData placeholderIcon;

  const MediaPosterCard({
    super.key,
    required this.title,
    required this.onTap,
    this.posterAsync,
    this.subtitle,
    this.badge,
    this.progress,
    this.isWatched = false,
    this.actions = const [],
    this.width = 152,
    this.titleStyle = CardTitleStyle.below,
    this.overlayYear,
    this.overlayRating,
    this.overlayRatingTone,
    this.placeholderIcon = Icons.movie_rounded,
  });

  /// A TMDB movie as a browse card.
  ///
  /// Browse, Favorites, Home and the details pages' "More like this" rows
  /// each mapped a movie onto a card by hand — eight copies of the same
  /// rating string among them.
  factory MediaPosterCard.movie(
    Movie movie, {
    Key? key,
    required VoidCallback onTap,
    bool isWatched = false,
    double? width,
    String? subtitle,
    List<MediaCardAction> actions = const [],
  }) => MediaPosterCard(
    key: key,
    title: movie.title,
    onTap: onTap,
    posterAsync: AsyncValue.data(movie.posterUrl),
    titleStyle: CardTitleStyle.overlay,
    overlayYear: movie.year,
    overlayRating: ratingLabel(movie.voteAverage, voteCount: movie.voteCount),
    overlayRatingTone: movie.voteAverage >= 8 ? AppColors.accent : null,
    isWatched: isWatched,
    width: width,
    subtitle: subtitle,
    actions: actions,
  );

  /// A TMDB show as a browse card. See [MediaPosterCard.movie].
  factory MediaPosterCard.show(
    Show show, {
    Key? key,
    required VoidCallback onTap,
    double? width,
    String? subtitle,
    List<MediaCardAction> actions = const [],
  }) => MediaPosterCard(
    key: key,
    title: show.name,
    onTap: onTap,
    posterAsync: AsyncValue.data(show.posterUrl),
    titleStyle: CardTitleStyle.overlay,
    overlayYear: show.year,
    overlayRating: ratingLabel(show.voteAverage, voteCount: show.voteCount),
    overlayRatingTone: show.voteAverage >= 8 ? AppColors.accent : null,
    width: width,
    subtitle: subtitle,
    placeholderIcon: Icons.live_tv_rounded,
    actions: actions,
  );

  // The caption block's text, set explicitly so [heightForWidth] measures
  // the same thing that is drawn — it used to assume a 1.35 line height the
  // theme's 1.4 did not have.
  static const double _titleSize = AppType.sizeCaption;
  static const double _subtitleSize = AppType.sizeSmall;
  static const double _lineHeight = 1.35;

  /// Height this card needs at [width] in the [CardTitleStyle.below] layout.
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
    final title = scaler.scale(_titleSize) * _lineHeight;
    final subtitle = hasSubtitle
        ? 3 + scaler.scale(_subtitleSize) * _lineHeight
        : 0.0;
    // Round up, plus a hair, so sub-pixel rounding can't reintroduce the
    // overflow this method exists to prevent.
    return (poster + padding + title + subtitle).ceilToDouble() + 2;
  }

  @override
  State<MediaPosterCard> createState() => _MediaPosterCardState();
}

class _MediaPosterCardState extends State<MediaPosterCard> {
  final _menuKey = GlobalKey<PopupMenuButtonState<MediaCardAction>>();
  bool _hovered = false;
  bool _focused = false;
  bool _menuFocused = false;
  bool _menuOpen = false;

  bool get _menuVisible => _hovered || _focused || _menuFocused || _menuOpen;

  void _openMenu() => _menuKey.currentState?.showButtonMenu();

  @override
  Widget build(BuildContext context) {
    final hasProgress = widget.progress != null && widget.progress! > 0;
    final isOverlay = widget.titleStyle == CardTitleStyle.overlay;
    final lifted = _hovered || _focused;

    return HubPressable(
      onTap: widget.onTap,
      onSecondaryTap: widget.actions.isEmpty ? null : _openMenu,
      onHoverChanged: (h) => setState(() => _hovered = h),
      onFocusChanged: (f) => setState(() => _focused = f),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: AnimatedScale(
        scale: lifted ? 1.03 : 1.0,
        duration: AppDuration.fast,
        curve: Curves.easeOutCubic,
        child: Container(
          width: widget.width,
          decoration: mediaCardDecoration().copyWith(
            boxShadow: lifted
                ? [
                    BoxShadow(
                      color: AppColors.accent.withAlpha(AppOpacity.medium),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              isOverlay
                  ? _buildOverlayLayout(hasProgress)
                  : _buildBelowLayout(hasProgress),
              if (widget.actions.isNotEmpty) _menu(),
            ],
          ),
        ),
      ),
    );
  }

  /// Overflow menu. Stays mounted regardless of hover; visibility is toggled
  /// via opacity + IgnorePointer. Removing it on hover-out disposed the
  /// PopupMenuButton's State the moment the menu's modal barrier triggered
  /// onExit, and `showMenu`'s `.then` then saw `!mounted` and silently
  /// dropped `onSelected` — the menu opened and closed but the action never
  /// fired.
  ///
  /// Hidden, it is also out of the focus order: Tab must not land on an
  /// invisible button. Focusing the card reveals it, so Tab reaches it next.
  Widget _menu() {
    final visible = _menuVisible;
    return Positioned(
      top: AppSpacing.xs,
      right: AppSpacing.xs,
      child: AnimatedOpacity(
        duration: AppDuration.fast,
        opacity: visible ? 1.0 : 0.0,
        child: IgnorePointer(
          ignoring: !visible,
          child: ExcludeFocus(
            excluding: !visible,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: (f) => setState(() => _menuFocused = f),
              child: Material(
                color: AppColors.scrimStrong,
                borderRadius: BorderRadius.circular(AppRadius.full),
                child: PopupMenuButton<MediaCardAction>(
                  key: _menuKey,
                  tooltip: 'More actions',
                  color: kMediaHubPopupColor,
                  shape: kMediaHubPopupShape,
                  icon: const Padding(
                    padding: EdgeInsets.all(AppSpacing.xxs),
                    child: Icon(
                      Icons.more_vert_rounded,
                      size: 18,
                      color: AppColors.fg,
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
                        child: mediaHubMenuLabel(
                          icon: a.icon,
                          label: a.label,
                          destructive: a.destructive,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _poster() => buildPosterImage(
    posterAsync: widget.posterAsync,
    hue: hueForText(widget.title),
    placeholderIcon: widget.placeholderIcon,
  );

  /// Library layout — poster + caption block below.
  Widget _buildBelowLayout(bool hasProgress) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _poster(),
              _bottomGradient(),
              _centeredPlayHover(),
              if (widget.badge != null)
                Positioned(
                  top: AppSpacing.sm,
                  left: AppSpacing.sm,
                  child: EditorialBadge(widget.badge!, compact: true),
                ),
              if (widget.isWatched && !_menuVisible) _watchedCheckmark(),
              if (hasProgress) _progressBar(),
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
                style: AppType.ui(
                  size: MediaPosterCard._titleSize,
                  color: AppColors.fg,
                  weight: FontWeight.w600,
                  height: MediaPosterCard._lineHeight,
                ),
              ),
              if (widget.subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  widget.subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(
                    size: MediaPosterCard._subtitleSize,
                    color: AppColors.fg2,
                    height: MediaPosterCard._lineHeight,
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
  Widget _buildOverlayLayout(bool hasProgress) {
    final textShadow = [
      Shadow(
        color: AppColors.mediaBlack.withValues(alpha: 0.7),
        offset: const Offset(0, 2),
        blurRadius: 14,
      ),
    ];
    return AspectRatio(
      aspectRatio: 2 / 3,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _poster(),
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
                      size: AppType.sizeLabel,
                      color: AppColors.onMedia,
                      letterSpacing: 0.12,
                      weight: FontWeight.w600,
                    ).copyWith(
                      shadows: [
                        // A tight shadow for the edge of a light poster the
                        // scrim does not fully cover, plus a wider soft one
                        // for overall separation.
                        Shadow(
                          color: AppColors.mediaBlack.withAlpha(
                            AppOpacity.heavy,
                          ),
                          blurRadius: 3,
                        ),
                        Shadow(
                          color: AppColors.mediaBlack.withValues(alpha: 0.6),
                          blurRadius: 8,
                        ),
                      ],
                    ),
              ),
            ),

          // Rating badge (top-right). Hidden while the overflow menu, which
          // sits in the same corner, is showing.
          if (widget.overlayRating != null &&
              !(widget.actions.isNotEmpty && _menuVisible))
            Positioned(
              top: 10,
              right: 10,
              child: EditorialBadge(
                widget.overlayRating!,
                tone: widget.overlayRatingTone,
              ),
            ),

          // A diagonal corner ribbon reads "watched" at a glance, even on a
          // busy poster that would hide a small checkmark. Hidden on hover
          // so the rating badge stays legible.
          if (widget.isWatched && !_menuVisible) _watchedRibbon(),

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
                    size: AppType.sizeHeading,
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
                          size: AppType.sizeLabel,
                          color: AppColors.fg1,
                          letterSpacing: 0.1,
                          weight: FontWeight.w500,
                        ).copyWith(
                          shadows: [
                            Shadow(
                              color: AppColors.mediaBlack.withValues(
                                alpha: 0.6,
                              ),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                  ),
                ],
              ],
            ),
          ),

          if (hasProgress) _progressBar(),

          if (_hovered || _focused)
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

  /// Scrim behind the year and rating, mirroring [_bottomGradient].
  ///
  /// The year is small white mono text and used to rely on a drop shadow
  /// alone, which disappears against a bright poster. A shadow adds contrast
  /// only where the background is already dark, so it cannot fix light art;
  /// a scrim can. Shallower than the bottom one, which has a two-line serif
  /// title to carry.
  Widget _topGradient() {
    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.mediaBlack.withValues(alpha: 0.55),
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
            colors: [
              Colors.transparent,
              AppColors.mediaBlack.withValues(alpha: 0.7),
            ],
            stops: const [0.5, 1.0],
          ),
        ),
      ),
    );
  }

  Widget _centeredPlayHover() {
    final active = _hovered || _focused;
    return Center(
      child: AnimatedOpacity(
        duration: AppDuration.fast,
        opacity: active ? 1.0 : 0.85,
        child: AnimatedScale(
          duration: AppDuration.fast,
          scale: active ? 1.1 : 1.0,
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: const BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.scrimSoft,
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: AppColors.onAccent,
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
        padding: const EdgeInsets.all(AppSpacing.xs),
        decoration: const BoxDecoration(
          color: AppColors.ok,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.check_rounded,
          size: 14,
          color: AppColors.onAccent,
        ),
      ),
    );
  }

  /// Diagonal "WATCHED" ribbon stretched across the top-right corner, for
  /// the overlay layout where a small checkmark gets lost in busy art.
  ///
  /// The ClipRRect cuts the stack to the card's rounded corners — the card's
  /// own clip would otherwise leak the rotated band's overhang.
  Widget _watchedRibbon() {
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
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xs,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.ok,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.mediaBlack.withAlpha(
                            AppOpacity.semi,
                          ),
                          blurRadius: 6,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Text(
                      'WATCHED',
                      style: AppType.mono(
                        size: AppType.sizeLabel,
                        color: AppColors.onAccent,
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

  Widget _progressBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: EditorialProgress(value: widget.progress!),
    );
  }
}
