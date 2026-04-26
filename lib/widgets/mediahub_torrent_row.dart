import 'package:flutter/material.dart';

import '../design/app_colors.dart';
import '../design/app_theme.dart';
import '../design/app_tokens.dart';
import '../models/torrent.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import 'common/status_badge.dart';

/// Pull a short display quality token (`4K` / `1080p` / `720p` / `SD`)
/// out of a release name. The full name is what we want to render
/// elsewhere — but the quality badge needs a tiny label.
String _qualityFromName(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('2160') || lower.contains('uhd') || lower.contains('4k')) {
    return '4K';
  }
  if (lower.contains('1080')) return '1080p';
  if (lower.contains('720')) return '720p';
  return 'SD';
}

/// Sortable column-header strip matching the design's Transfers screen.
///
/// Renders a horizontal track of column labels in mono uppercase. The
/// active sort key shows an arrow that flips on direction change.
class MediaHubTorrentHeader extends StatelessWidget {
  const MediaHubTorrentHeader({
    super.key,
    required this.sortKey,
    required this.ascending,
    required this.onSortKeyTap,
    this.compact = false,
  });

  final TorrentSort sortKey;
  final bool ascending;
  final ValueChanged<TorrentSort> onSortKeyTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final headers = <_HeaderCol>[
      _HeaderCol('Name', TorrentSort.name, flex: 1),
      _HeaderCol('Size', TorrentSort.size, width: 64),
      if (!compact) _HeaderCol('Progress', TorrentSort.progress, width: 120),
      _HeaderCol('↓', TorrentSort.dlspeed, width: 70),
      if (!compact) _HeaderCol('↑', TorrentSort.upspeed, width: 70),
      if (!compact) _HeaderCol('ETA', TorrentSort.eta, width: 60),
      _HeaderCol('', null, width: 60, alignRight: true),
    ];

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgPage,
        border: Border(bottom: BorderSide(color: Color(0x0FFFFFFF), width: 1)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxl,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          for (var i = 0; i < headers.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.md),
            _buildCell(headers[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildCell(_HeaderCol col) {
    final active = col.key != null && col.key == sortKey;
    final color = active ? AppColors.seedColor : const Color(0xFF7A7A92);
    final child = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: col.key == null ? null : () => onSortKeyTap(col.key!),
      child: Row(
        mainAxisAlignment: col.alignRight
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Text(
            col.label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 1.0,
              fontFamily: 'monospace',
            ),
          ),
          if (active) ...[
            const SizedBox(width: 4),
            AnimatedRotation(
              turns: ascending ? 0.5 : 0,
              duration: const Duration(milliseconds: 180),
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 12,
                color: color,
              ),
            ),
          ],
        ],
      ),
    );
    if (col.flex != null) {
      return Expanded(flex: col.flex!, child: child);
    }
    return SizedBox(width: col.width, child: child);
  }
}

class _HeaderCol {
  const _HeaderCol(
    this.label,
    this.key, {
    this.width,
    this.flex,
    this.alignRight = false,
  });

  final String label;
  final TorrentSort? key;
  final double? width;
  final int? flex;
  final bool alignRight;
}

/// Dense single-line torrent row — status dot + quality pill + mono
/// release name, then mono columns for size / progress / dl / ul / eta
/// / actions. Matches the `TorrentRow` component in the design.
class MediaHubTorrentRow extends StatefulWidget {
  const MediaHubTorrentRow({
    super.key,
    required this.torrent,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onPause,
    required this.onResume,
    required this.onDelete,
    this.compact = false,
  });

  final Torrent torrent;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onDelete;
  final bool compact;

  @override
  State<MediaHubTorrentRow> createState() => _MediaHubTorrentRowState();
}

class _MediaHubTorrentRowState extends State<MediaHubTorrentRow>
    with SingleTickerProviderStateMixin {
  bool _hover = false;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Color _stateColor() {
    final ac = context.appColors;
    if (widget.torrent.hasError) return ac.errorState;
    if (widget.torrent.isPaused) return ac.paused;
    if (widget.torrent.isDownloading) return ac.downloading;
    if (widget.torrent.isSeeding) return ac.seeding;
    return ac.queued;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.torrent;
    final accent = AppColors.seedColor;
    final stateColor = _stateColor();
    final ac = context.appColors;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                color: widget.selected
                    ? accent.withAlpha(0x24)
                    : (_hover
                          ? Colors.white.withAlpha(10)
                          : Colors.transparent),
                border: const Border(
                  bottom: BorderSide(color: Color(0x0FFFFFFF), width: 1),
                ),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xxl,
                vertical: AppSpacing.md,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Name column — status dot + quality pill + mono name
                  Expanded(
                    child: Row(
                      children: [
                        AnimatedBuilder(
                          animation: _pulse,
                          builder: (context, _) {
                            final pulse = t.isDownloading
                                ? (0.55 + 0.45 * _pulse.value)
                                : 1.0;
                            return Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: stateColor.withAlpha(
                                  (255 * pulse).round(),
                                ),
                                shape: BoxShape.circle,
                                boxShadow: t.isDownloading
                                    ? [
                                        BoxShadow(
                                          color: stateColor.withAlpha(140),
                                          blurRadius: 8,
                                        ),
                                      ]
                                    : null,
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        StatusBadge.quality(
                          quality: _qualityFromName(t.name),
                          size: StatusBadgeSize.small,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w500,
                              color: Color(0xFFF4F4F8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  // Size
                  SizedBox(
                    width: 64,
                    child: Text(
                      Formatters.formatBytes(t.size),
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: Color(0xFFB4B4C8),
                      ),
                    ),
                  ),
                  if (!widget.compact) ...[
                    const SizedBox(width: AppSpacing.md),
                    SizedBox(
                      width: 120,
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 4,
                              decoration: BoxDecoration(
                                color: AppColors.bgSurfaceHi,
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: t.progress.clamp(0.0, 1.0),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: stateColor,
                                    borderRadius: BorderRadius.circular(2),
                                    boxShadow: t.isDownloading
                                        ? [
                                            BoxShadow(
                                              color: stateColor.withAlpha(120),
                                              blurRadius: 6,
                                            ),
                                          ]
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          SizedBox(
                            width: 36,
                            child: Text(
                              '${(t.progress * 100).toStringAsFixed(0)}%',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w700,
                                color: stateColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(width: AppSpacing.md),
                  // DL speed
                  SizedBox(
                    width: 70,
                    child: Text(
                      t.dlspeed > 0 ? Formatters.formatSpeed(t.dlspeed) : '—',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: t.dlspeed > 0
                            ? ac.downloading
                            : const Color(0xFF54546A),
                      ),
                    ),
                  ),
                  if (!widget.compact) ...[
                    const SizedBox(width: AppSpacing.md),
                    SizedBox(
                      width: 70,
                      child: Text(
                        t.upspeed > 0 ? Formatters.formatSpeed(t.upspeed) : '—',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: t.upspeed > 0
                              ? ac.seeding
                              : const Color(0xFF54546A),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    SizedBox(
                      width: 60,
                      child: Text(
                        (t.eta > 0 && t.eta < 8640000)
                            ? Formatters.formatDuration(t.eta)
                            : '—',
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: Color(0xFFB4B4C8),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: AppSpacing.md),
                  // Actions
                  SizedBox(
                    width: 60,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 120),
                      opacity: _hover || widget.selected ? 1.0 : 0.3,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _RowIconButton(
                            icon: t.isPaused
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                            tooltip: t.isPaused ? 'Resume' : 'Pause',
                            onPressed: t.isPaused
                                ? widget.onResume
                                : widget.onPause,
                          ),
                          const SizedBox(width: 2),
                          _RowIconButton(
                            icon: Icons.more_horiz_rounded,
                            tooltip: 'More',
                            onPressed: widget.onLongPress,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Selected indicator bar on the left edge
            if (widget.selected)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Container(
                  width: 3,
                  decoration: BoxDecoration(
                    color: accent,
                    boxShadow: [
                      BoxShadow(color: accent.withAlpha(120), blurRadius: 8),
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

class _RowIconButton extends StatefulWidget {
  const _RowIconButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  State<_RowIconButton> createState() => _RowIconButtonState();
}

class _RowIconButtonState extends State<_RowIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: _hover ? Colors.white.withAlpha(10) : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Center(
              child: Icon(
                widget.icon,
                size: 14,
                color: const Color(0xFFB4B4C8),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
