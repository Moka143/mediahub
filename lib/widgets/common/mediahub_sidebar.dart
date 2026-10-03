import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../utils/constants.dart';
import '../editorial/editorial_button.dart';
import '../editorial/editorial_led.dart';
import '../editorial/mono_label.dart';
import 'hub_pressable.dart';
import 'nav_badge.dart';

/// A single navigation entry rendered in [MediaHubSidebar].
class SidebarItem {
  const SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badge = 0,
    this.errorBadge = false,
    this.dot = false,
    this.dotPulse = false,
    this.status,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// Numeric badge (e.g. active download count). 0 hides the badge.
  final int badge;

  /// Render the badge in the error color.
  final bool errorBadge;

  /// Status dot (e.g. today's calendar episode airing).
  final bool dot;
  final bool dotPulse;

  /// What the badge or dot means, in words — "3 active", "airing today".
  /// Read out after the label, and shown in the collapsed rail's tooltip,
  /// where the label itself is hidden.
  final String? status;
}

/// Editorial sidebar — collapsible navigation rail.
///
/// Layout (matches the prototype's `.sb` chrome):
///   ┌─────────────────────────┐
///   │  MediaHub  v0.8.0       │  italic serif + mono version
///   ├─────────────────────────┤
///   │  ▸ Home                 │  active item: accent left strip
///   │    Transfers     12     │  count in tinted mono pill
///   │    Calendar       ●     │  status LED
///   ├─────────────────────────┤
///   │  [ + Add torrent ]      │
///   │  ● BUILT-IN ENGINE      │  status footer, two lines so neither
///   │    CONNECTED            │  half is ever cut off
///   └─────────────────────────┘
///
/// Collapsed, it is a 64px icon rail: every icon has a tooltip, and the
/// count badge and status dot move onto the icons instead of disappearing.
class MediaHubSidebar extends StatefulWidget {
  const MediaHubSidebar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onDestinationSelected,
    required this.onAddTorrent,
    required this.collapsed,
    required this.onToggleCollapse,
    required this.connected,
    this.engineName = 'Engine',
    this.version = AppConstants.appVersion,
  });

  final List<SidebarItem> items;
  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onAddTorrent;
  final bool collapsed;
  final VoidCallback onToggleCollapse;

  /// Whether the torrent engine is reachable — drives the footer LED.
  final bool connected;

  /// The backend named in the status footer. Passed in rather than hardcoded
  /// because it is no longer always qBittorrent, and a footer that names the
  /// wrong one is worse than a generic label — it sends the user looking for
  /// a program that is not running.
  final String engineName;

  /// Shown next to the wordmark. It was a hard-coded "v 2.4" — the old code
  /// only showed the real value if the connection label contained a "v",
  /// which "CONNECTED" and "OFFLINE" never do.
  final String version;

  static const double expandedWidth = 232;
  static const double collapsedWidth = 64;

  /// Room to the right of the rail for the collapse toggle, which straddles
  /// the rail's edge. Hit testing stops at a widget's bounds, so the half of
  /// the toggle outside the rail needs space of its own to be clickable.
  static const double toggleGutter = 14;

  static const Duration _duration = AppDuration.normal;

  /// Inset of the brand and the expanded footer: (64 − 28) / 2 centres the
  /// 28px monogram in the collapsed rail, and the wordmark and footer share
  /// that left edge.
  static const double _brandInset = 18;

  /// The rail's inner inset — around the nav list and footer, and either
  /// side of a nav row. 64 − 2 × 14 leaves the collapsed rail a 36px column,
  /// the add button's size; the active row's strip hangs out by this much to
  /// sit on the rail's edge.
  static const double _navInset = 14;

  /// Half the gap between neighbouring nav rows' fills.
  static const double _rowGap = 1;

  /// (36 − 16) / 2: the icon sits where the collapsed rail centres it, so it
  /// stays put as the rail collapses.
  static const double _rowPadH = 10;

  /// Gives the 6px footer LED an 18px target for its tooltip.
  static const double _ledHitPad = 6;

  /// Sets the 6px LED level with the middle of the engine name's first line.
  static const double _ledTopInset = 3;

  @override
  State<MediaHubSidebar> createState() => _MediaHubSidebarState();
}

class _MediaHubSidebarState extends State<MediaHubSidebar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: MediaHubSidebar._duration,
    value: widget.collapsed ? 0 : 1,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOutCubic,
  );
  bool _hover = false;

  @override
  void didUpdateWidget(covariant MediaHubSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.collapsed != oldWidget.collapsed) {
      if (widget.collapsed) {
        _ctrl.reverse();
      } else {
        _ctrl.forward();
      }
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, _) {
        final width = lerpDouble(
          MediaHubSidebar.collapsedWidth,
          MediaHubSidebar.expandedWidth,
          _curve.value,
        )!;
        // The rail keeps its expanded layout for as long as any of it is
        // showing, laid out at full width and clipped to the animating one;
        // only a fully collapsed rail switches to the icon layout. The outer
        // width and the rail now move together (the outer box used to jump
        // straight to its final size), and the content never sees a width
        // between the two layouts — which is what overflowed three Rows on
        // every expand and made the collapse snap.
        final expandedLayout = _ctrl.value > 0;
        final layoutWidth = expandedLayout
            ? MediaHubSidebar.expandedWidth
            : MediaHubSidebar.collapsedWidth;

        return SizedBox(
          width: width + MediaHubSidebar.toggleGutter,
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                SizedBox(
                  width: width,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: AppColors.bgPageAlt,
                      border: Border(
                        right: BorderSide(color: AppColors.line, width: 1),
                      ),
                    ),
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: layoutWidth,
                        maxWidth: layoutWidth,
                        child: _rail(collapsed: !expandedLayout),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 22,
                  left: width - 12,
                  child: _CollapseToggle(
                    collapsed: widget.collapsed,
                    emphasised: _hover,
                    onTap: widget.onToggleCollapse,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _rail({required bool collapsed}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Brand(collapsed: collapsed, version: widget.version),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(
              vertical: MediaHubSidebar._navInset,
            ),
            children: [
              for (var i = 0; i < widget.items.length; i++)
                _NavRow(
                  item: widget.items[i],
                  active: i == widget.currentIndex,
                  collapsed: collapsed,
                  onTap: () => widget.onDestinationSelected(i),
                ),
            ],
          ),
        ),
        _Footer(
          collapsed: collapsed,
          onAddTorrent: widget.onAddTorrent,
          engineName: widget.engineName,
          connected: widget.connected,
        ),
      ],
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.collapsed, required this.version});

  final bool collapsed;
  final String version;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(MediaHubSidebar._brandInset),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line, width: 1)),
      ),
      child: collapsed
          ? Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  color: AppColors.accentSoft,
                  border: Border.all(color: AppColors.accent, width: 1),
                ),
                alignment: Alignment.center,
                child: Text(
                  'M',
                  style: AppType.serif(
                    size: AppType.sizeHeading,
                    color: AppColors.accent,
                    height: 1.0,
                  ),
                ),
              ),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  AppConstants.appName,
                  style: AppType.serif(
                    size: AppType.sizeTitle,
                    height: 1.0,
                    letterSpacing: -0.02,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: MonoLabel(
                      'v$version',
                      letterSpacing: 0.1,
                      uppercase: false,
                      maxLines: 1,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _NavRow extends StatefulWidget {
  const _NavRow({
    required this.item,
    required this.active,
    required this.collapsed,
    required this.onTap,
  });

  final SidebarItem item;
  final bool active;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  State<_NavRow> createState() => _NavRowState();
}

class _NavRowState extends State<_NavRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final fgColor = widget.active ? AppColors.fg : AppColors.fg1;
    final iconColor = widget.active ? AppColors.accent : AppColors.fg2;
    final bg = widget.active || _hover ? AppColors.line : Colors.transparent;
    final described = item.status == null
        ? item.label
        : '${item.label}, ${item.status}';

    Widget icon = Icon(
      widget.active ? item.selectedIcon : item.icon,
      size: 16,
      color: iconColor,
    );
    if (widget.collapsed) {
      // No room for the label, so the badge and the dot sit on the icon
      // rather than vanishing — an errored transfer or an episode airing
      // today should not depend on how wide the rail is.
      icon = NavDot(
        isVisible: item.dot,
        pulse: item.dotPulse,
        child: NavBadge(
          count: item.badge,
          isError: item.errorBadge,
          child: icon,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MediaHubSidebar._navInset,
        vertical: MediaHubSidebar._rowGap,
      ),
      child: HubPressable(
        onTap: widget.onTap,
        selected: widget.active,
        // The label is on screen when expanded; collapsed, the tooltip is
        // the only place it appears.
        tooltip: widget.collapsed ? described.replaceFirst(', ', ' · ') : null,
        semanticLabel: described,
        excludeChildSemantics: true,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        onHoverChanged: (h) => setState(() => _hover = h),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (widget.active)
              Positioned(
                left: -MediaHubSidebar._navInset,
                top: 8,
                bottom: 8,
                child: Container(
                  width: 2,
                  decoration: const BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.only(
                      topRight: Radius.circular(AppRadius.full),
                      bottomRight: Radius.circular(AppRadius.full),
                    ),
                  ),
                ),
              ),
            Container(
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(AppRadius.xs),
              ),
              padding: widget.collapsed
                  ? const EdgeInsets.symmetric(vertical: AppSpacing.sm)
                  : const EdgeInsets.symmetric(
                      horizontal: MediaHubSidebar._rowPadH,
                      vertical: AppSpacing.sm,
                    ),
              child: Row(
                mainAxisAlignment: widget.collapsed
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  icon,
                  if (!widget.collapsed) ...[
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.ui(
                          size: AppType.sizeBody,
                          color: fgColor,
                          height: 1.0,
                        ),
                      ),
                    ),
                    if (item.badge > 0)
                      NavCountTag(count: item.badge, isError: item.errorBadge),
                    if (item.dot) ...[
                      const SizedBox(width: 6),
                      NavStatusDot(pulse: item.dotPulse),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.collapsed,
    required this.onAddTorrent,
    required this.engineName,
    required this.connected,
  });

  final bool collapsed;
  final VoidCallback onAddTorrent;
  final String engineName;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final statusWord = connected ? 'Connected' : 'Offline';
    final led = EditorialLed(
      color: connected ? AppColors.ok : AppColors.fg3,
      size: 6,
    );

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: collapsed
            ? MediaHubSidebar._navInset
            : MediaHubSidebar._brandInset,
        vertical: MediaHubSidebar._navInset,
      ),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.line, width: 1)),
      ),
      child: collapsed
          ? Column(
              children: [
                EditorialIconButton(
                  icon: Icons.add_rounded,
                  onPressed: onAddTorrent,
                  tooltip: 'Add torrent',
                  iconSize: 16,
                  size: 36,
                  color: AppColors.accent,
                ),
                const SizedBox(height: 12),
                Tooltip(
                  message: '$engineName · $statusWord',
                  child: Semantics(
                    label: '$engineName, $statusWord',
                    child: Padding(
                      padding: const EdgeInsets.all(MediaHubSidebar._ledHitPad),
                      child: led,
                    ),
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                EditorialButton(
                  label: 'Add torrent',
                  icon: Icons.add_rounded,
                  kind: EditorialButtonKind.accent,
                  onPressed: onAddTorrent,
                  expand: true,
                ),
                const SizedBox(height: 12),
                // Two lines rather than "BUILT-IN ENGINE · CONNECTED" on one:
                // that did not fit the rail and was cut to "CONNECT…", the
                // half of the line the user actually needed.
                Semantics(
                  label: '$engineName, $statusWord',
                  excludeSemantics: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(
                          top: MediaHubSidebar._ledTopInset,
                        ),
                        child: led,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            MonoLabel(
                              engineName,
                              color: AppColors.fg1,
                              letterSpacing: 0.08,
                              maxLines: 1,
                            ),
                            const SizedBox(height: 2),
                            MonoLabel(
                              statusWord,
                              color: connected ? AppColors.ok : AppColors.fg2,
                              letterSpacing: 0.08,
                              maxLines: 1,
                            ),
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

class _CollapseToggle extends StatelessWidget {
  const _CollapseToggle({
    required this.collapsed,
    required this.emphasised,
    required this.onTap,
  });

  final bool collapsed;

  /// Pointer is over the rail: brighten the glyph so the toggle is easy to
  /// find. It is always visible — it used to sit at 40% opacity.
  final bool emphasised;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HubPressable(
      onTap: onTap,
      tooltip: collapsed ? 'Expand sidebar' : 'Collapse sidebar',
      borderRadius: BorderRadius.circular(AppRadius.md),
      // 24×24: the WCAG minimum target. It was 22×22.
      child: Container(
        width: 24,
        height: 24,
        decoration: const BoxDecoration(
          color: AppColors.bgSurfaceHi,
          shape: BoxShape.circle,
          border: Border.fromBorderSide(
            BorderSide(color: AppColors.lineStrong),
          ),
        ),
        child: Center(
          child: AnimatedRotation(
            duration: MediaHubSidebar._duration,
            turns: collapsed ? 0 : 0.5,
            child: Icon(
              Icons.chevron_right_rounded,
              size: 14,
              color: emphasised ? AppColors.fg : AppColors.fg2,
            ),
          ),
        ),
      ),
    );
  }
}
