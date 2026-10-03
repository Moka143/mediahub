import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../design/torrent_tone.dart';
import '../models/torrent.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import '../utils/media_quality.dart';
import 'common/hub_pressable.dart';
import 'common/mediahub_popup_menu.dart';
import 'editorial/editorial.dart';
import 'transfers/transfer_labels.dart';
import 'transfers/transfer_menu.dart';

/// The data columns of the Transfers table, after the flexible name column.
///
/// The header and the rows used to repeat these widths independently; both
/// now lay out from this one list, so a label always sits over its column.
enum TransferColumn {
  // Wide enough for "999.99 MB" in the mono face: at 64 the unit was
  // clipped and sizes read as bare numbers.
  size(76),
  progress(120),
  download(70),
  upload(70),
  eta(60),
  actions(60);

  const TransferColumn(this.width);

  final double width;

  /// Space between columns.
  static const double gap = AppSpacing.md;

  /// The narrow list beside the details pane keeps only what fits.
  static List<TransferColumn> forLayout({required bool compact}) =>
      compact ? const [size, download, actions] : values;

  /// Left and right inset of the header and every row. Tighter beside the
  /// details pane, where the name column needs every pixel.
  static double inset({required bool compact}) =>
      compact ? AppSpacing.lg : AppSpacing.xxl;
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
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgPage,
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: TransferColumn.inset(compact: compact),
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(child: _sortCell(TorrentSort.name, 'Name', 'name')),
          for (final column in TransferColumn.forLayout(compact: compact)) ...[
            const SizedBox(width: TransferColumn.gap),
            SizedBox(width: column.width, child: _cellFor(column)),
          ],
        ],
      ),
    );
  }

  Widget _cellFor(TransferColumn column) => switch (column) {
    TransferColumn.size => _sortCell(TorrentSort.size, 'Size', 'size'),
    TransferColumn.progress => _sortCell(
      TorrentSort.progress,
      'Progress',
      'progress',
    ),
    TransferColumn.download => _sortCell(
      TorrentSort.dlspeed,
      '↓',
      'download speed',
    ),
    TransferColumn.upload => _sortCell(
      TorrentSort.upspeed,
      '↑',
      'upload speed',
    ),
    TransferColumn.eta => _sortCell(TorrentSort.eta, 'ETA', 'time left'),
    TransferColumn.actions => const SizedBox.shrink(),
  };

  Widget _sortCell(TorrentSort key, String label, String spoken) {
    final active = key == sortKey;
    final color = active ? AppColors.accent : AppColors.fg2;
    final direction = ascending ? 'ascending' : 'descending';
    return HubPressable(
      onTap: () => onSortKeyTap(key),
      selected: active,
      // The arrow columns have no words to read; say what they sort.
      tooltip: label.length == 1 ? 'Sort by $spoken' : null,
      semanticLabel: active ? 'Sort by $spoken, $direction' : 'Sort by $spoken',
      excludeChildSemantics: true,
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: AppType.mono(
              size: AppType.sizeLabel,
              color: color,
              weight: FontWeight.w700,
              letterSpacing: 0.1,
            ),
          ),
          if (active) ...[
            const SizedBox(width: AppSpacing.xs),
            AnimatedRotation(
              turns: ascending ? 0.5 : 0,
              duration: AppDuration.fast,
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
  }
}

/// Dense single-line torrent row — status dot + quality pill + mono
/// release name, then mono columns for size / progress / dl / ul / eta
/// / actions. Matches the `TorrentRow` component in the design.
///
/// Click (or Enter / Space while focused) runs [onTap]; right click, the
/// context-menu key or Shift+F10 opens the row's menu; Delete deletes. The
/// action buttons, dimmed until the pointer is over the row, light up for
/// keyboard focus anywhere inside it as well.
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
    this.onOpen,
    this.checked = false,
    this.compact = false,
  });

  final Torrent torrent;

  /// Highlighted: in the multi-selection, or the one shown in the details
  /// pane.
  final bool selected;

  /// In the multi-selection — words the menu's Select / Deselect.
  final bool checked;

  final VoidCallback? onTap;

  /// Also what the menu's Select / Deselect runs.
  final VoidCallback? onLongPress;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onDelete;

  /// Show the details. Offered in the menu when given.
  final VoidCallback? onOpen;
  final bool compact;

  @override
  State<MediaHubTorrentRow> createState() => _MediaHubTorrentRowState();
}

enum _RowAction { open, pauseResume, select, delete }

class _MediaHubTorrentRowState extends State<MediaHubTorrentRow>
    with SingleTickerProviderStateMixin {
  bool _hover = false;
  bool _focusWithin = false;

  /// Where the last secondary-button press landed, so the right-click menu
  /// opens under the pointer. `onSecondaryTap` itself carries no position.
  Offset? _secondaryAt;

  /// The status dot's breathing. Runs only while data is arriving
  /// ([isTransferring]): a Transfers list of paused, seeding or stalled
  /// torrents used to repeat this forever on every row, so the app never
  /// reached an idle frame while the screen was open.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: AppDuration.pulse,
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  @override
  void didUpdateWidget(MediaHubTorrentRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _syncPulse() {
    if (isTransferring(widget.torrent)) {
      if (!_pulse.isAnimating) unawaited(_pulse.repeat(reverse: true));
    } else if (_pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 1;
    }
  }

  VoidCallback? get _pauseOrResume =>
      widget.torrent.isPaused ? widget.onResume : widget.onPause;

  List<PopupMenuEntry<_RowAction>> _menuItems() {
    final paused = widget.torrent.isPaused;
    return [
      if (widget.onOpen != null)
        PopupMenuItem(
          value: _RowAction.open,
          child: mediaHubMenuLabel(
            icon: Icons.info_outline_rounded,
            label: 'Details',
          ),
        ),
      PopupMenuItem(
        value: _RowAction.pauseResume,
        enabled: _pauseOrResume != null,
        child: mediaHubMenuLabel(
          icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          label: paused ? 'Resume' : 'Pause',
        ),
      ),
      PopupMenuItem(
        value: _RowAction.select,
        enabled: widget.onLongPress != null,
        child: mediaHubMenuLabel(
          icon: widget.checked
              ? Icons.check_box_rounded
              : Icons.check_box_outline_blank_rounded,
          label: widget.checked ? 'Deselect' : 'Select',
        ),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: _RowAction.delete,
        enabled: widget.onDelete != null,
        child: mediaHubMenuLabel(
          icon: Icons.delete_outline_rounded,
          label: 'Delete…',
          destructive: true,
        ),
      ),
    ];
  }

  /// [at] is a pointer position (right click); otherwise the menu opens
  /// below [anchor], or below the row.
  Future<void> _openMenu({Offset? at, BuildContext? anchor}) async {
    final action = await showTransfersMenu<_RowAction>(
      context: anchor ?? context,
      items: _menuItems(),
      position: at,
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _RowAction.open:
        widget.onOpen?.call();
      case _RowAction.pauseResume:
        _pauseOrResume?.call();
      case _RowAction.select:
        widget.onLongPress?.call();
      case _RowAction.delete:
        widget.onDelete?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final torrent = widget.torrent;
    final tone = torrentStateTone(torrent);
    final onDelete = widget.onDelete;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.contextMenu): () =>
            unawaited(_openMenu()),
        const SingleActivator(LogicalKeyboardKey.f10, shift: true): () =>
            unawaited(_openMenu()),
        const SingleActivator(LogicalKeyboardKey.delete): ?onDelete,
      },
      // Focus *within* the row — the row itself or either action button —
      // keeps the actions lit while the keyboard moves between them.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => setState(() => _focusWithin = focused),
        child: Listener(
          onPointerDown: (event) {
            if (event.buttons & kSecondaryMouseButton != 0) {
              _secondaryAt = event.position;
            }
          },
          child: HubPressable(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            onSecondaryTap: () => unawaited(_openMenu(at: _secondaryAt)),
            onHoverChanged: (hovering) => setState(() => _hover = hovering),
            selected: widget.selected,
            borderRadius: BorderRadius.zero,
            child: Stack(
              children: [
                _rowBody(torrent, tone),
                if (widget.selected)
                  const Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: _SelectedEdge(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _rowBody(Torrent torrent, Color tone) {
    final Color background;
    if (widget.selected) {
      background = AppColors.accentSoft;
    } else if (_hover) {
      background = AppColors.bgSurface;
    } else {
      background = Colors.transparent;
    }
    return AnimatedContainer(
      duration: AppDuration.fast,
      decoration: BoxDecoration(
        color: background,
        border: const Border(bottom: BorderSide(color: AppColors.line)),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: TransferColumn.inset(compact: widget.compact),
        vertical: AppSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: _NameCell(torrent: torrent, tone: tone, pulse: _pulse),
              ),
              for (final column in TransferColumn.forLayout(
                compact: widget.compact,
              )) ...[
                const SizedBox(width: TransferColumn.gap),
                SizedBox(
                  width: column.width,
                  child: _cell(column, torrent, tone),
                ),
              ],
            ],
          ),
          // The list beside the details pane has no room for the Progress
          // column, which left it with no sign of how far each transfer had
          // got. A hairline under the row says it instead.
          if (widget.compact && torrent.progress < 1) ...[
            const SizedBox(height: AppSpacing.sm),
            EditorialProgress(
              value: torrent.progress,
              color: tone,
              height: 2,
              glow: false,
            ),
          ],
        ],
      ),
    );
  }

  Widget _cell(TransferColumn column, Torrent torrent, Color tone) {
    switch (column) {
      case TransferColumn.size:
        return _MonoCell(Formatters.formatBytes(torrent.size));
      case TransferColumn.progress:
        return _ProgressCell(torrent: torrent, tone: tone);
      case TransferColumn.download:
        return _SpeedCell(
          bytesPerSecond: torrent.dlspeed,
          tone: AppColors.downloading,
        );
      case TransferColumn.upload:
        return _SpeedCell(
          bytesPerSecond: torrent.upspeed,
          tone: AppColors.seeding,
        );
      case TransferColumn.eta:
        return _MonoCell(transferEtaLabel(torrent));
      case TransferColumn.actions:
        return AnimatedOpacity(
          duration: AppDuration.fast,
          opacity: _hover || _focusWithin || widget.selected ? 1.0 : 0.3,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _RowIconButton(
                icon: torrent.isPaused
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded,
                tooltip: torrent.isPaused ? 'Resume' : 'Pause',
                onPressed: _pauseOrResume,
              ),
              const SizedBox(width: AppSpacing.xxs),
              Builder(
                builder: (buttonContext) => _RowIconButton(
                  icon: Icons.more_horiz_rounded,
                  tooltip: 'More actions',
                  onPressed: () => unawaited(_openMenu(anchor: buttonContext)),
                ),
              ),
            ],
          ),
        );
    }
  }
}

/// The 3px accent bar on a highlighted row's left edge.
class _SelectedEdge extends StatelessWidget {
  const _SelectedEdge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      decoration: BoxDecoration(
        color: AppColors.accent,
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withAlpha(AppOpacity.semi),
            blurRadius: 8,
          ),
        ],
      ),
    );
  }
}

/// Status dot, quality badge and the release name.
class _NameCell extends StatelessWidget {
  const _NameCell({
    required this.torrent,
    required this.tone,
    required this.pulse,
  });

  final Torrent torrent;
  final Color tone;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final quality = qualityBadgeLabel(torrent.name);
    return Row(
      children: [
        _StatusDot(tone: tone, pulse: pulse, live: isTransferring(torrent)),
        const SizedBox(width: AppSpacing.sm),
        EditorialBadge(
          quality,
          compact: true,
          tone: qualityTone(MediaQuality.fromText(torrent.name)),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            torrent.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.mono(
              size: AppType.sizeCaption,
              color: AppColors.fg,
              weight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

/// The state-coloured dot. Breathes only while [live]; otherwise it is a
/// plain dot with no animation listener at all.
class _StatusDot extends StatelessWidget {
  const _StatusDot({
    required this.tone,
    required this.pulse,
    required this.live,
  });

  final Color tone;
  final Animation<double> pulse;
  final bool live;

  @override
  Widget build(BuildContext context) {
    if (!live) return _dot(1);
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) => _dot(0.55 + 0.45 * pulse.value),
    );
  }

  Widget _dot(double opacity) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: opacity),
        shape: BoxShape.circle,
        boxShadow: live
            ? [BoxShadow(color: tone.withAlpha(AppOpacity.semi), blurRadius: 8)]
            : null,
      ),
    );
  }
}

class _MonoCell extends StatelessWidget {
  const _MonoCell(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.clip,
      style: AppType.mono(size: AppType.sizeSmall, color: AppColors.fg1),
    );
  }
}

class _SpeedCell extends StatelessWidget {
  const _SpeedCell({required this.bytesPerSecond, required this.tone});

  final int bytesPerSecond;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final moving = bytesPerSecond > 0;
    return Text(
      moving ? Formatters.formatSpeed(bytesPerSecond) : '—',
      maxLines: 1,
      overflow: TextOverflow.clip,
      style: AppType.mono(
        size: AppType.sizeSmall,
        color: moving ? tone : AppColors.fg2,
      ),
    );
  }
}

class _ProgressCell extends StatelessWidget {
  const _ProgressCell({required this.torrent, required this.tone});

  final Torrent torrent;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: EditorialProgress(
            value: torrent.progress,
            color: tone,
            height: 4,
            glow: isTransferring(torrent),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        SizedBox(
          width: 36,
          child: Text(
            Formatters.formatProgress(torrent.progress, decimals: 0),
            textAlign: TextAlign.right,
            style: AppType.mono(
              size: AppType.sizeSmall,
              color: tone,
              weight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// 26×26 icon button in the actions column.
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
    return HubPressable(
      tooltip: widget.tooltip,
      onTap: widget.onPressed,
      onHoverChanged: (hovering) => setState(() => _hover = hovering),
      child: AnimatedContainer(
        duration: AppDuration.fast,
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: _hover ? AppColors.bgSurfaceHi : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Center(child: Icon(widget.icon, size: 14, color: AppColors.fg1)),
      ),
    );
  }
}
