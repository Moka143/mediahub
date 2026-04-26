import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';

/// A single navigation entry rendered in [MediaHubSidebar].
class SidebarItem {
  const SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badge = 0,
    this.dot = false,
    this.dotPulse = false,
    this.errorBadge = false,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// Numeric badge (e.g. active download count). 0 hides the badge.
  final int badge;

  /// Status dot (e.g. today's calendar episode airing).
  final bool dot;
  final bool dotPulse;

  /// Render the badge in the error color.
  final bool errorBadge;
}

/// A cinematic, collapsible navigation rail styled to match the
/// MediaHub design: gradient brand mark, gradient "Add torrent" CTA,
/// soft accent active state, indicator bar, badge counts, and a
/// storage panel pinned to the bottom.
class MediaHubSidebar extends StatefulWidget {
  const MediaHubSidebar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onDestinationSelected,
    required this.onAddTorrent,
    required this.collapsed,
    required this.onToggleCollapse,
    this.brandSubtitle = 'CONNECTED',
  });

  final List<SidebarItem> items;
  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onAddTorrent;
  final bool collapsed;
  final VoidCallback onToggleCollapse;
  final String brandSubtitle;

  @override
  State<MediaHubSidebar> createState() => _MediaHubSidebarState();
}

class _MediaHubSidebarState extends State<MediaHubSidebar> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.seedColor;
    final accentDeep = AppColors.seedDeep;
    final w = widget.collapsed ? 72.0 : 240.0;
    final hPad = widget.collapsed ? AppSpacing.sm : AppSpacing.md;

    // Outer SizedBox is wide enough to host both the rail and the
    // overhanging collapse toggle. Without it the toggle, sitting at
    // `left: w - 12`, is rendered (Stack.clipBehavior = none) but
    // unhittable because the parent Row constrains its bounds.
    return SizedBox(
      width: w + 14,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              width: w,
              decoration: const BoxDecoration(
                color: AppColors.bgPageAlt,
                border: Border(
                  right: BorderSide(color: Color(0x0FFFFFFF), width: 1),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  hPad,
                  AppSpacing.lg,
                  hPad,
                  AppSpacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Brand(
                      collapsed: widget.collapsed,
                      subtitle: widget.brandSubtitle,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    _AddTorrentButton(
                      collapsed: widget.collapsed,
                      onPressed: widget.onAddTorrent,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (!widget.collapsed)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(
                          AppSpacing.md,
                          AppSpacing.sm,
                          AppSpacing.md,
                          AppSpacing.xs,
                        ),
                        child: Text(
                          'BROWSE',
                          style: TextStyle(
                            fontSize: 10,
                            color: Color(0xFF54546A),
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.4,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    Expanded(
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        itemCount: widget.items.length,
                        itemBuilder: (context, i) => _NavRow(
                          item: widget.items[i],
                          active: i == widget.currentIndex,
                          collapsed: widget.collapsed,
                          accent: accent,
                          onTap: () => widget.onDestinationSelected(i),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Collapse/expand toggle — sibling to the rail container
            // (not nested) so its hit-rect lives inside the outer
            // SizedBox and clicks actually land.
            Positioned(
              top: 24,
              left: w - 12,
              child: _CollapseToggle(
                collapsed: widget.collapsed,
                hover: _hover,
                accent: accent,
                accentDeep: accentDeep,
                onTap: widget.onToggleCollapse,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.collapsed, required this.subtitle});

  final bool collapsed;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.seedColor;

    final logo = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [
          BoxShadow(
            color: accent.withAlpha(90),
            blurRadius: 20,
            spreadRadius: 0,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/icon.png',
        width: 32,
        height: 32,
        fit: BoxFit.cover,
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Row(
        // `mainAxisSize.max` is required when an `Expanded` child is
        // present — otherwise Row's intrinsic-shrinking conflicts
        // with Expanded's flex factor and we get spurious overflow.
        mainAxisSize: MainAxisSize.max,
        children: [
          logo,
          if (!collapsed) ...[
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'MediaHub',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.32,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    'v2.0 · $subtitle',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF7A7A92),
                      letterSpacing: 0.8,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AddTorrentButton extends StatefulWidget {
  const _AddTorrentButton({required this.collapsed, required this.onPressed});

  final bool collapsed;
  final VoidCallback onPressed;

  @override
  State<_AddTorrentButton> createState() => _AddTorrentButtonState();
}

class _AddTorrentButtonState extends State<_AddTorrentButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.seedColor;
    final accentDeep = AppColors.seedDeep;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        transform: Matrix4.translationValues(0, _hover ? -1 : 0, 0),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [accent, accentDeep],
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
          boxShadow: [
            BoxShadow(
              color: accent.withAlpha(90),
              blurRadius: 20,
              offset: const Offset(0, 6),
              spreadRadius: -6,
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: widget.collapsed ? 0 : AppSpacing.md,
                vertical: AppSpacing.md,
              ),
              child: Row(
                mainAxisAlignment: widget.collapsed
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.add_rounded, size: 18, color: Colors.white),
                  if (!widget.collapsed) ...[
                    const SizedBox(width: AppSpacing.sm),
                    const Text(
                      'Add torrent',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavRow extends StatefulWidget {
  const _NavRow({
    required this.item,
    required this.active,
    required this.collapsed,
    required this.accent,
    required this.onTap,
  });

  final SidebarItem item;
  final bool active;
  final bool collapsed;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_NavRow> createState() => _NavRowState();
}

class _NavRowState extends State<_NavRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    final activeBg = accent.withAlpha(36); // ~14%
    final secondaryText = const Color(0xFFB4B4C8);

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: widget.active
                  ? activeBg
                  : (_hover ? Colors.white.withAlpha(10) : Colors.transparent),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            padding: EdgeInsets.symmetric(
              horizontal: widget.collapsed ? 0 : AppSpacing.md,
              vertical: 10,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (widget.active && !widget.collapsed)
                  Positioned(
                    left: -AppSpacing.md - 1,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Container(
                        width: 3,
                        height: 20,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(2),
                          boxShadow: [
                            BoxShadow(
                              color: accent.withAlpha(90),
                              blurRadius: 12,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Row(
                  mainAxisAlignment: widget.collapsed
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Icon(
                          widget.active
                              ? widget.item.selectedIcon
                              : widget.item.icon,
                          size: 18,
                          color: widget.active ? accent : secondaryText,
                        ),
                        if (widget.item.dot)
                          Positioned(
                            top: -2,
                            right: -2,
                            child: _PulseDot(
                              pulse: widget.item.dotPulse,
                              color: AppColors.accentTertiary,
                            ),
                          ),
                      ],
                    ),
                    if (!widget.collapsed) ...[
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Text(
                          widget.item.label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: widget.active
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: widget.active ? accent : secondaryText,
                          ),
                        ),
                      ),
                      if (widget.item.badge > 0)
                        _BadgePill(
                          count: widget.item.badge,
                          accent: accent,
                          active: widget.active,
                          isError: widget.item.errorBadge,
                        ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BadgePill extends StatelessWidget {
  const _BadgePill({
    required this.count,
    required this.accent,
    required this.active,
    required this.isError,
  });

  final int count;
  final Color accent;
  final bool active;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final base = isError
        ? AppColors.errorState
        : (active ? accent : AppColors.bgSurfaceHi);
    final fg = active || isError ? Colors.white : const Color(0xFFB4B4C8);
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: base,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: fg,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.pulse, required this.color});

  final bool pulse;
  final Color color;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    if (widget.pulse) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _PulseDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulse && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.pulse && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 1;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = widget.pulse ? (0.5 + 0.5 * _ctrl.value) : 1.0;
        return Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: widget.color.withAlpha((255 * t).round()),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: widget.color.withAlpha(140), blurRadius: 8),
            ],
          ),
        );
      },
    );
  }
}

class _CollapseToggle extends StatelessWidget {
  const _CollapseToggle({
    required this.collapsed,
    required this.hover,
    required this.accent,
    required this.accentDeep,
    required this.onTap,
  });

  final bool collapsed;
  final bool hover;
  final Color accent;
  final Color accentDeep;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: hover ? 1.0 : 0.55,
      child: Material(
        color: AppColors.bgSurfaceHi,
        shape: const CircleBorder(side: BorderSide(color: Color(0x1AFFFFFF))),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 24,
            height: 24,
            child: Center(
              child: AnimatedRotation(
                duration: const Duration(milliseconds: 240),
                turns: collapsed ? 0 : 0.5,
                child: const Icon(
                  Icons.chevron_right_rounded,
                  size: 14,
                  color: Color(0xFFB4B4C8),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Re-export for callers that want to access `appColors` style without
/// having to import the theme module separately.
extension MediaHubSidebarPalette on BuildContext {
  AppColorsExtension get mediaHubColors => appColors;
}
