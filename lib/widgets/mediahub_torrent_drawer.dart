import 'package:flutter/material.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../models/torrentio_stream.dart';
import '../services/torrentio_api_service.dart';
import 'common/status_badge.dart';
import 'mediahub_drawer.dart';
import 'torrentio_stream_picker_dialog.dart' show StreamPickerResult;

/// MediaHub right-side torrent picker drawer.
///
/// Drop-in replacement for the centered `TorrentioStreamPickerDialog`
/// — same `show()` API surface returning a `StreamPickerResult?` —
/// but rendered as a slide-in drawer matching the design's
/// `ShowTorrentDrawer` / `MovieTorrentDrawer` (`screen-detail.jsx`).
///
/// Layout:
///   * Header — "CHOOSE A SOURCE" kicker + big title + subtitle + ✕
///   * Quality filter row (`All (n)` / `4K` / `1080p` / `720p`) +
///     `Seeded`/`Size` sort segment
///   * Scrollable list of source rows: quality pill (with ●CACHED
///     marker for Real-Debrid hits), mono filename, codec/source/size
///     line, ●seeders + leechers, Stream + GRAB buttons; first row
///     gets a ★BEST tag.
///   * Footer — "n sources · sorted by …" + Cancel
class MediaHubTorrentDrawer extends StatefulWidget {
  const MediaHubTorrentDrawer({
    super.key,
    required this.title,
    this.subtitle,
    required this.streams,
    required this.onSelect,
  });

  final String title;
  final String? subtitle;
  final List<TorrentioStream> streams;
  final void Function(TorrentioStream stream, bool isStreaming) onSelect;

  /// Drop-in replacement for the legacy centered dialog. Backdrop blur,
  /// tap-out, drag-to-dismiss and slide animation are all owned by
  /// [MediaHubDrawer].
  static Future<StreamPickerResult?> show({
    required BuildContext context,
    required String title,
    String? subtitle,
    required List<TorrentioStream> streams,
    required void Function(TorrentioStream stream, bool isStreaming) onSelect,
  }) {
    return MediaHubDrawer.show<StreamPickerResult>(
      context: context,
      builder: (_) => MediaHubTorrentDrawer(
        title: title,
        subtitle: subtitle,
        streams: streams,
        onSelect: onSelect,
      ),
    );
  }

  @override
  State<MediaHubTorrentDrawer> createState() => _MediaHubTorrentDrawerState();
}

class _MediaHubTorrentDrawerState extends State<MediaHubTorrentDrawer> {
  String? _qualityFilter;
  bool _sortBySize = false; // false = sort by seeders

  List<TorrentioStream> get _filtered {
    var s = List<TorrentioStream>.from(widget.streams);
    if (_qualityFilter != null) {
      s = TorrentioApiService.filterByQuality(s, _qualityFilter!);
    }
    if (_sortBySize) {
      s = TorrentioApiService.sortStreams(
        s,
        sortBy: TorrentioSortOption.sizeDesc,
      );
    } else {
      s = TorrentioApiService.sortStreams(
        s,
        sortBy: TorrentioSortOption.seeders,
      );
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: MediaHubDrawer.dragGripWidth),
      child: _DrawerPanel(
        title: widget.title,
        subtitle: widget.subtitle,
        filtered: _filtered,
        total: widget.streams.length,
        qualityFilter: _qualityFilter,
        onQualityChange: (q) => setState(() => _qualityFilter = q),
        sortBySize: _sortBySize,
        onSortChange: (b) => setState(() => _sortBySize = b),
        onPick: (stream, isStreaming) {
          widget.onSelect(stream, isStreaming);
          Navigator.of(
            context,
          ).pop(StreamPickerResult(stream: stream, isStreaming: isStreaming));
        },
        onCancel: () => Navigator.of(context).pop(),
      ),
    );
  }
}

class _DrawerPanel extends StatelessWidget {
  const _DrawerPanel({
    required this.title,
    required this.subtitle,
    required this.filtered,
    required this.total,
    required this.qualityFilter,
    required this.onQualityChange,
    required this.sortBySize,
    required this.onSortChange,
    required this.onPick,
    required this.onCancel,
  });

  final String title;
  final String? subtitle;
  final List<TorrentioStream> filtered;
  final int total;
  final String? qualityFilter;
  final ValueChanged<String?> onQualityChange;
  final bool sortBySize;
  final ValueChanged<bool> onSortChange;
  final void Function(TorrentioStream, bool isStreaming) onPick;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Header(title: title, subtitle: subtitle, onClose: onCancel),
        _FilterBar(
          total: total,
          qualityFilter: qualityFilter,
          onQualityChange: onQualityChange,
          sortBySize: sortBySize,
          onSortChange: onSortChange,
        ),
        Expanded(
          child: filtered.isEmpty
              ? const Center(
                  child: Text(
                    'No sources match this filter.',
                    style: TextStyle(color: Color(0xFF7A7A92)),
                  ),
                )
              : _GroupedSourceList(filtered: filtered, onPick: onPick),
        ),
        _Footer(
          count: filtered.length,
          sortLabel: sortBySize ? 'size' : 'seeders',
          onCancel: onCancel,
        ),
      ],
    );
  }
}

/// Groups sources by quality tier (4K / 1080p / 720p / SD) with a small
/// section header per tier. Within each tier the row order is preserved
/// from the parent's filter+sort, so the existing "best" star still goes
/// on the very first item overall.
class _GroupedSourceList extends StatelessWidget {
  const _GroupedSourceList({required this.filtered, required this.onPick});

  final List<TorrentioStream> filtered;
  final void Function(TorrentioStream, bool isStreaming) onPick;

  String _tier(TorrentioStream s) {
    final q = (s.quality).toUpperCase();
    if (q.contains('2160') || q.contains('4K') || q.contains('UHD')) {
      return '4K';
    }
    if (q.contains('1080')) return '1080p';
    if (q.contains('720')) return '720p';
    if (q.contains('480') || q.contains('360') || q.contains('SD')) return 'SD';
    return 'Other';
  }

  @override
  Widget build(BuildContext context) {
    // Preserve filter ordering within each tier; the tier order itself
    // follows the canonical 4K → 1080p → 720p → SD → Other.
    const tierOrder = ['4K', '1080p', '720p', 'SD', 'Other'];
    final groups = <String, List<TorrentioStream>>{};
    for (final s in filtered) {
      groups.putIfAbsent(_tier(s), () => <TorrentioStream>[]).add(s);
    }
    final orderedTiers = tierOrder.where(groups.containsKey).toList();

    // Build a flat list of [section header, ...rows] entries so we can
    // use a single ListView (good for sticky scroll behaviour and lazy
    // construction).
    final items = <_GroupedItem>[];
    var globalIndex = 0;
    for (final tier in orderedTiers) {
      final rows = groups[tier]!;
      items.add(_GroupedItem.header(tier, rows.length));
      for (final s in rows) {
        items.add(_GroupedItem.row(s, globalIndex == 0));
        globalIndex++;
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final item = items[i];
        if (item.isHeader) {
          return _TierHeader(
            label: item.headerLabel!,
            count: item.headerCount!,
          );
        }
        return _SourceRow(
          stream: item.stream!,
          best: item.best,
          onPick: onPick,
        );
      },
    );
  }
}

class _GroupedItem {
  _GroupedItem._({
    required this.isHeader,
    this.headerLabel,
    this.headerCount,
    this.stream,
    this.best = false,
  });

  factory _GroupedItem.header(String label, int count) =>
      _GroupedItem._(isHeader: true, headerLabel: label, headerCount: count);

  factory _GroupedItem.row(TorrentioStream stream, bool best) =>
      _GroupedItem._(isHeader: false, stream: stream, best: best);

  final bool isHeader;
  final String? headerLabel;
  final int? headerCount;
  final TorrentioStream? stream;
  final bool best;
}

class _TierHeader extends StatelessWidget {
  const _TierHeader({required this.label, required this.count});

  final String label;
  final int count;

  Color _accent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (label) {
      case '4K':
        return scheme.tertiary;
      case '1080p':
        return scheme.primary;
      case '720p':
        return scheme.secondary;
      default:
        return scheme.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 14,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: accent,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '· $count',
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF7A7A92),
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onClose,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.lg,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x0FFFFFFF), width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 64,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.seedColor, AppColors.accentTertiary],
              ),
              borderRadius: BorderRadius.circular(2),
              boxShadow: [
                BoxShadow(
                  color: AppColors.seedColor.withAlpha(120),
                  blurRadius: 12,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CHOOSE A SOURCE',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.seedColor,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.88,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 22,
                    color: Color(0xFFF4F4F8),
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.44,
                    height: 1.2,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF7A7A92),
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: onClose,
            tooltip: 'Close (Esc)',
            icon: const Icon(Icons.close_rounded, size: 16),
            style: IconButton.styleFrom(
              foregroundColor: const Color(0xFF7A7A92),
              backgroundColor: AppColors.bgSurface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                side: const BorderSide(color: Color(0x0FFFFFFF)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.total,
    required this.qualityFilter,
    required this.onQualityChange,
    required this.sortBySize,
    required this.onSortChange,
  });

  final int total;
  final String? qualityFilter;
  final ValueChanged<String?> onQualityChange;
  final bool sortBySize;
  final ValueChanged<bool> onSortChange;

  @override
  Widget build(BuildContext context) {
    Widget pill({
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.seedColor.withAlpha(36)
                : Colors.transparent,
            border: Border.all(
              color: selected
                  ? AppColors.seedColor.withAlpha(0x66)
                  : Colors.transparent,
            ),
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: selected ? AppColors.seedColor : const Color(0xFFB4B4C8),
            ),
          ),
        ),
      );
    }

    Widget seg({
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm + 2,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: selected ? AppColors.bgSurfaceHi : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: selected
                  ? const Color(0xFFF4F4F8)
                  : const Color(0xFF7A7A92),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xl,
        vertical: AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x0FFFFFFF), width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  pill(
                    label: 'All ($total)',
                    selected: qualityFilter == null,
                    onTap: () => onQualityChange(null),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  pill(
                    label: '4K',
                    selected: qualityFilter == '4K',
                    onTap: () => onQualityChange('4K'),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  pill(
                    label: '1080p',
                    selected: qualityFilter == '1080p',
                    onTap: () => onQualityChange('1080p'),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  pill(
                    label: '720p',
                    selected: qualityFilter == '720p',
                    onTap: () => onQualityChange('720p'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: AppColors.bgSurface,
              border: Border.all(color: const Color(0x0FFFFFFF)),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                seg(
                  label: 'Seeded',
                  selected: !sortBySize,
                  onTap: () => onSortChange(false),
                ),
                seg(
                  label: 'Size',
                  selected: sortBySize,
                  onTap: () => onSortChange(true),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatefulWidget {
  const _SourceRow({
    required this.stream,
    required this.best,
    required this.onPick,
  });

  final TorrentioStream stream;
  final bool best;
  final void Function(TorrentioStream, bool isStreaming) onPick;

  @override
  State<_SourceRow> createState() => _SourceRowState();
}

class _SourceRowState extends State<_SourceRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.stream;
    final quality = s.quality.isEmpty ? 'SD' : s.quality;
    final source = s.sourceSite;
    final size = s.sizeFormatted;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: _hover ? AppColors.bgSurfaceHi : Colors.transparent,
          border: Border.all(
            color: widget.best
                ? AppColors.seedColor.withAlpha(0x66)
                : Colors.transparent,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (widget.best)
              Positioned(
                top: -1,
                left: AppSpacing.md,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.seedColor,
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(4),
                      bottomRight: Radius.circular(4),
                    ),
                  ),
                  child: const Text(
                    '★ BEST',
                    style: TextStyle(
                      fontSize: 8,
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.md,
                widget.best ? AppSpacing.md + 4 : AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Quality + cached column
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      StatusBadge.quality(
                        quality: quality,
                        size: StatusBadgeSize.small,
                      ),
                      // ●CACHED green badge — Real-Debrid hits surface
                      // through the source name; we use a heuristic.
                      if (s.name.toLowerCase().contains('cached') ||
                          s.name.toLowerCase().contains('rd+'))
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            '● CACHED',
                            style: TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.w700,
                              color: AppColors.seeding,
                              letterSpacing: 0.5,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          s.title.split('\n').first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFF4F4F8),
                            fontWeight: FontWeight.w500,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (source.isNotEmpty)
                              _MetaBit(text: source.toUpperCase()),
                            if (size.isNotEmpty) ...[
                              const _Dot(),
                              _MetaBit(text: size, brighter: true),
                            ],
                            if (s.isSeasonPack) ...[
                              const _Dot(),
                              const Text(
                                'FULL SEASON',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.accentPrimary,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '● ${s.seeders}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.seeding,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(height: 2),
                      _StreamabilityChip(seeders: s.seeders),
                      const SizedBox(height: 2),
                      Text(
                        s.isSeasonPack
                            ? 'pack'
                            : (s.isSingleFile ? 'single' : 'multi'),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF7A7A92),
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: AppSpacing.md),
                  // Stream button
                  IconButton(
                    onPressed: () => widget.onPick(s, true),
                    tooltip: 'Stream now',
                    icon: const Icon(Icons.play_arrow_rounded, size: 14),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      foregroundColor: const Color(0xFFB4B4C8),
                      side: const BorderSide(color: Color(0x1AFFFFFF)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      padding: const EdgeInsets.all(8),
                      minimumSize: const Size(32, 32),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // GRAB button
                  GestureDetector(
                    onTap: () => widget.onPick(s, false),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm,
                      ),
                      decoration: BoxDecoration(
                        color: widget.best || _hover
                            ? AppColors.seedColor
                            : AppColors.seedColor.withAlpha(36),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(
                          color: AppColors.seedColor.withAlpha(0x66),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.download_rounded,
                            size: 11,
                            color: widget.best || _hover
                                ? Colors.white
                                : AppColors.seedColor,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'GRAB',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'monospace',
                              letterSpacing: 0.5,
                              color: widget.best || _hover
                                  ? Colors.white
                                  : AppColors.seedColor,
                            ),
                          ),
                        ],
                      ),
                    ),
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

class _MetaBit extends StatelessWidget {
  const _MetaBit({required this.text, this.brighter = false});

  final String text;
  final bool brighter;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 10,
        fontFamily: 'monospace',
        color: brighter ? const Color(0xFFB4B4C8) : const Color(0xFF7A7A92),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        '·',
        style: TextStyle(color: Color(0xFF54546A), fontSize: 10),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.count,
    required this.sortLabel,
    required this.onCancel,
  });

  final int count;
  final String sortLabel;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xl,
        vertical: AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        color: AppColors.bgPage,
        border: Border(top: BorderSide(color: Color(0x0FFFFFFF), width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$count sources · sorted by $sortLabel',
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF7A7A92),
                fontFamily: 'monospace',
              ),
            ),
          ),
          OutlinedButton(
            onPressed: onCancel,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFB4B4C8),
              side: const BorderSide(color: Color(0x1AFFFFFF)),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
            ),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

/// Compact "fast / good / slow" hint based on the seeder count. The
/// thresholds are intentionally loose — torrent health varies too much
/// to be precise. The goal is just to give the user one glanceable
/// hint about whether a row is going to play or struggle.
class _StreamabilityChip extends StatelessWidget {
  const _StreamabilityChip({required this.seeders});

  final int seeders;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final String label;
    final Color color;
    if (seeders >= 50) {
      label = 'fast';
      color = scheme.tertiary;
    } else if (seeders >= 10) {
      label = 'good';
      color = scheme.primary;
    } else if (seeders >= 1) {
      label = 'slow';
      color = scheme.secondary;
    } else {
      label = 'dead';
      color = scheme.error;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: AppOpacity.medium / 255.0),
        border: Border.all(
          color: color.withValues(alpha: AppOpacity.semi / 255.0),
          width: AppBorderWidth.thin,
        ),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: color,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
