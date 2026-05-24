import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../design/app_colors.dart';
import '../../design/app_theme.dart';
import '../../design/app_typography.dart';
import '../editorial/editorial_button.dart';
import '../editorial/editorial_led.dart';
import '../editorial/mono_label.dart';

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

/// Editorial sidebar — fixed-width navigation rail.
///
/// Layout (matches the prototype's `.sb` chrome):
///   ┌─────────────────────────┐
///   │  MediaHub  v 2.4        │  italic serif + mono
///   ├─────────────────────────┤
///   │  LIBRARY                │  mono section label
///   │  ▸ Home          5      │  active item: accent left strip
///   │    Transfers     12     │  count in tinted mono pill
///   ├─────────────────────────┤
///   │  SOURCES                │
///   │  TMDB           OK      │
///   │  EZTV           OK      │
///   ├─────────────────────────┤
///   │  ● QBITTORRENT · 4.6.5  │  status footer
///   │  ↓ 47.6 MB/s            │
///   │  moka@dev  · 2.1TB free │
///   └─────────────────────────┘
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
    this.dlSpeed,
    this.ulSpeed,
    this.freeSpace,
    this.qbitVersion,
  });

  final List<SidebarItem> items;
  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onAddTorrent;
  final bool collapsed;
  final VoidCallback onToggleCollapse;
  final String brandSubtitle;

  /// Optional live status data rendered in the footer.
  final String? dlSpeed;
  final String? ulSpeed;
  final String? freeSpace;
  final String? qbitVersion;

  @override
  State<MediaHubSidebar> createState() => _MediaHubSidebarState();
}

class _MediaHubSidebarState extends State<MediaHubSidebar> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget.collapsed ? 64.0 : 232.0;

    return SizedBox(
      width: w + 14,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: w,
              decoration: const BoxDecoration(
                color: AppColors.bgPageAlt,
                border: Border(
                  right: BorderSide(color: AppColors.line, width: 1),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Brand(
                    collapsed: widget.collapsed,
                    subtitle: widget.brandSubtitle,
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      children: [
                        if (!widget.collapsed)
                          const _SectionLabel(label: 'LIBRARY'),
                        ...List.generate(widget.items.length, (i) {
                          return _NavRow(
                            item: widget.items[i],
                            active: i == widget.currentIndex,
                            collapsed: widget.collapsed,
                            onTap: () => widget.onDestinationSelected(i),
                          );
                        }),
                        const SizedBox(height: 8),
                        if (!widget.collapsed)
                          const _SectionLabel(label: 'SOURCES'),
                        if (!widget.collapsed) ...const [
                          _SourceRow(label: 'TMDB', status: 'OK'),
                          _SourceRow(label: 'EZTV', status: 'OK'),
                          _SourceRow(label: 'Torrentio', status: 'OK'),
                          _SourceRow(label: 'OpenSubtitles', status: '—', ok: false),
                        ],
                      ],
                    ),
                  ),
                  _Footer(
                    collapsed: widget.collapsed,
                    onAddTorrent: widget.onAddTorrent,
                    dlSpeed: widget.dlSpeed,
                    ulSpeed: widget.ulSpeed,
                    freeSpace: widget.freeSpace,
                    qbitVersion: widget.qbitVersion,
                    connected: widget.brandSubtitle.toUpperCase().contains('CONNECT'),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 22,
              left: w - 12,
              child: _CollapseToggle(
                collapsed: widget.collapsed,
                hover: _hover,
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
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line, width: 1)),
      ),
      child: collapsed
          ? Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: AppColors.accentSoft,
                border: Border.all(color: AppColors.accent, width: 1),
              ),
              alignment: Alignment.center,
              child: Text(
                'M',
                style: GoogleFonts.instrumentSerif(
                  fontSize: 18,
                  fontStyle: FontStyle.italic,
                  color: AppColors.accent,
                  height: 1.0,
                ),
              ),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'MediaHub',
                  style: GoogleFonts.instrumentSerif(
                    fontSize: 26,
                    fontStyle: FontStyle.italic,
                    color: AppColors.fg,
                    height: 1.0,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: MonoLabel(
                    subtitle.contains('v') ? subtitle : 'v 2.4',
                    color: AppColors.fg3,
                    letterSpacing: 0.1,
                  ),
                ),
              ],
            ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: MonoLabel(label, letterSpacing: 0.16),
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
    final fgColor = widget.active ? AppColors.fg : AppColors.fg1;
    final iconColor = widget.active ? AppColors.accent : AppColors.fg2;
    final bg = widget.active
        ? Colors.white.withValues(alpha: 0.05)
        : (_hover ? Colors.white.withValues(alpha: 0.04) : Colors.transparent);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 1),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (widget.active)
                Positioned(
                  left: -14,
                  top: 8,
                  bottom: 8,
                  child: Container(
                    width: 2,
                    decoration: const BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.only(
                        topRight: Radius.circular(2),
                        bottomRight: Radius.circular(2),
                      ),
                    ),
                  ),
                ),
              Container(
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(6),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: widget.collapsed ? 0 : 10,
                  vertical: 7,
                ),
                child: Row(
                  mainAxisAlignment: widget.collapsed
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    Icon(
                      widget.active
                          ? widget.item.selectedIcon
                          : widget.item.icon,
                      size: 16,
                      color: iconColor,
                    ),
                    if (!widget.collapsed) ...[
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          widget.item.label,
                          style: AppType.ui(
                            size: 13,
                            color: fgColor,
                            height: 1.0,
                          ),
                        ),
                      ),
                      if (widget.item.badge > 0) _CountTag(
                            count: widget.item.badge,
                            isError: widget.item.errorBadge,
                          ),
                      if (widget.item.dot)
                        _StatusDot(pulse: widget.item.dotPulse),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CountTag extends StatelessWidget {
  const _CountTag({required this.count, this.isError = false});
  final int count;
  final bool isError;
  @override
  Widget build(BuildContext context) {
    final fg = isError ? AppColors.err : AppColors.fg3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
      ),
      constraints: const BoxConstraints(minWidth: 22),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: AppType.mono(
          size: 10,
          color: fg,
          weight: FontWeight.w500,
          letterSpacing: 0.04,
        ),
      ),
    );
  }
}

class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.pulse});
  final bool pulse;
  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
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
  void didUpdateWidget(covariant _StatusDot oldWidget) {
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
        final t = widget.pulse ? (0.55 + 0.45 * _ctrl.value) : 1.0;
        return EditorialLed(
          color: AppColors.accent.withValues(alpha: t),
          size: 6,
        );
      },
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.label, required this.status, this.ok = true});
  final String label;
  final String status;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 5),
      child: Row(
        children: [
          Icon(
            ok ? Icons.public_rounded : Icons.cloud_off_rounded,
            size: 14,
            color: AppColors.fg2,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              label,
              style: AppType.ui(size: 12, color: AppColors.fg1, height: 1.0),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: ok
                  ? AppColors.okSoft
                  : Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              status,
              style: AppType.mono(
                size: 9,
                color: ok ? AppColors.ok : AppColors.fg3,
                letterSpacing: 0.04,
                weight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.collapsed,
    required this.onAddTorrent,
    required this.dlSpeed,
    required this.ulSpeed,
    required this.freeSpace,
    required this.qbitVersion,
    required this.connected,
  });

  final bool collapsed;
  final VoidCallback onAddTorrent;
  final String? dlSpeed;
  final String? ulSpeed;
  final String? freeSpace;
  final String? qbitVersion;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        collapsed ? 8 : 18,
        14,
        collapsed ? 8 : 18,
        14,
      ),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.line, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (collapsed) ...[
            EditorialIconButton(
              icon: Icons.add_rounded,
              onPressed: onAddTorrent,
              tooltip: 'Add torrent',
              iconSize: 16,
              size: 36,
              color: AppColors.accent,
            ),
          ] else ...[
            EditorialButton(
              label: 'Add torrent',
              icon: Icons.add_rounded,
              kind: EditorialButtonKind.accent,
              onPressed: onAddTorrent,
              expand: true,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                EditorialLed(
                  color: connected ? AppColors.ok : AppColors.fg3,
                  size: 6,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: MonoLabel(
                    qbitVersion != null
                        ? 'QBITTORRENT · ${qbitVersion!.toUpperCase()}'
                        : (connected
                            ? 'QBITTORRENT · CONNECTED'
                            : 'QBITTORRENT · OFFLINE'),
                    color: AppColors.fg2,
                    letterSpacing: 0.08,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
            if (dlSpeed != null || ulSpeed != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  MonoLabel(
                    '↓ ${dlSpeed ?? '—'}',
                    color: AppColors.fg3,
                    letterSpacing: 0.06,
                    uppercase: false,
                  ),
                  const Spacer(),
                  MonoLabel(
                    '↑ ${ulSpeed ?? '—'}',
                    color: AppColors.fg3,
                    letterSpacing: 0.06,
                    uppercase: false,
                  ),
                ],
              ),
            ],
            if (freeSpace != null) ...[
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Row(
                children: [
                  MonoLabel(
                    'STORAGE',
                    color: AppColors.fg3,
                  ),
                  const Spacer(),
                  MonoLabel(
                    freeSpace!,
                    color: AppColors.fg2,
                    uppercase: false,
                    letterSpacing: 0.06,
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _CollapseToggle extends StatelessWidget {
  const _CollapseToggle({
    required this.collapsed,
    required this.hover,
    required this.onTap,
  });

  final bool collapsed;
  final bool hover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: hover ? 1.0 : 0.4,
      child: Material(
        color: AppColors.bgSurfaceHi,
        shape: const CircleBorder(
          side: BorderSide(color: AppColors.lineStrong),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 22,
            height: 22,
            child: Center(
              child: AnimatedRotation(
                duration: const Duration(milliseconds: 220),
                turns: collapsed ? 0 : 0.5,
                child: const Icon(
                  Icons.chevron_right_rounded,
                  size: 12,
                  color: AppColors.fg2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Re-export — preserved for call sites that import the palette
/// extension via the sidebar barrel.
extension MediaHubSidebarPalette on BuildContext {
  AppColorsExtension get mediaHubColors => appColors;
}
