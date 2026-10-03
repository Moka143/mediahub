import 'package:flutter/material.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../design/torrent_tone.dart';
import '../models/torrentio_stream.dart';
import '../services/torrentio_api_service.dart';
import '../utils/media_quality.dart';
import 'common/hub_pressable.dart';
import 'common/mediahub_chip.dart';
import 'common/mediahub_drawer_header.dart';
import 'editorial/editorial.dart';
import 'mediahub_drawer.dart';

/// The source most likely to play well, or null when there are none.
///
/// Ranked by [TorrentioStream.streamingScore] — single-episode releases over
/// packs, then quality, then peers — among sources anyone is sharing. The
/// star used to go on the first row of the first quality tier: with tiers
/// ordered 2160p first, a 3-peer 4K source outranked a 1080p one with 800.
TorrentioStream? bestSource(List<TorrentioStream> streams) {
  if (streams.isEmpty) return null;
  final alive = streams.where((s) => s.seeders > 0).toList();
  final pool = alive.isEmpty ? streams : alive;
  return pool.reduce((a, b) => b.streamingScore > a.streamingScore ? b : a);
}

/// Right-side source picker: every source for a movie or an episode, grouped
/// by quality.
///
/// Watching is the point, so **Stream** is the primary action — the row
/// itself streams — and **Download** is the secondary one beside it.
///
/// Layout:
///   * Header — "CHOOSE A SOURCE" kicker + title + subtitle + ✕
///   * Quality filter row (`All` / `2160p` / `1080p` / `720p`) + sort
///   * Source rows grouped by quality tier; the best one carries ★ Best
///   * Footer — source count + sort + Cancel
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

  /// Called with the chosen source and whether to stream it (true) or
  /// download it (false). The drawer closes first.
  final void Function(TorrentioStream stream, bool isStreaming) onSelect;

  /// Slide the picker in. Backdrop blur, tap-out, drag-to-dismiss and the
  /// slide animation are [MediaHubDrawer]'s.
  static Future<void> show({
    required BuildContext context,
    required String title,
    String? subtitle,
    required List<TorrentioStream> streams,
    required void Function(TorrentioStream stream, bool isStreaming) onSelect,
  }) {
    return MediaHubDrawer.show<void>(
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
  bool _sortBySize = false; // false = most peers first

  List<TorrentioStream> get _filtered {
    var s = List<TorrentioStream>.from(widget.streams);
    if (_qualityFilter != null) {
      s = TorrentioApiService.filterByQuality(s, _qualityFilter!);
    }
    return TorrentioApiService.sortStreams(
      s,
      sortBy: _sortBySize
          ? TorrentioSortOption.sizeDesc
          : TorrentioSortOption.seeders,
    );
  }

  int _countFor(String quality) =>
      TorrentioApiService.filterByQuality(widget.streams, quality).length;

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Padding(
      padding: const EdgeInsets.only(left: MediaHubDrawer.dragGripWidth),
      child: Column(
        children: [
          MediaHubDrawerHeader(
            kicker: 'CHOOSE A SOURCE',
            title: widget.title,
            subtitle: widget.subtitle,
            onClose: () => Navigator.of(context).pop(),
          ),
          _FilterBar(
            total: widget.streams.length,
            countFor: _countFor,
            qualityFilter: _qualityFilter,
            onQualityChange: (q) => setState(() => _qualityFilter = q),
            sortBySize: _sortBySize,
            onSortChange: (b) => setState(() => _sortBySize = b),
          ),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      'No sources match this filter.',
                      style: AppType.ui(
                        size: AppType.sizeBody,
                        color: AppColors.fg2,
                      ),
                    ),
                  )
                : _GroupedSourceList(
                    filtered: filtered,
                    best: bestSource(filtered),
                    onPick: (stream, isStreaming) {
                      // Close first, so whatever the pick opens next (the
                      // streaming overlay, a snackbar) lands on the page.
                      Navigator.of(context).pop();
                      widget.onSelect(stream, isStreaming);
                    },
                  ),
          ),
          _Footer(
            count: filtered.length,
            sortLabel: _sortBySize ? 'largest first' : 'most peers first',
            onCancel: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// Sources grouped by quality tier (2160p / 1080p / 720p / 480p / Other)
/// under a small header per tier. Within a tier the parent's sort order is
/// kept.
class _GroupedSourceList extends StatelessWidget {
  const _GroupedSourceList({
    required this.filtered,
    required this.best,
    required this.onPick,
  });

  final List<TorrentioStream> filtered;
  final TorrentioStream? best;
  final void Function(TorrentioStream, bool isStreaming) onPick;

  /// Resolution tier, or "Other" for source-only tags (BluRay, WEB-DL…)
  /// and anything unrecognised — the same rules the sorter ranks by.
  String _tier(TorrentioStream s) =>
      s.mediaQuality.isResolution ? s.mediaQuality.label : 'Other';

  @override
  Widget build(BuildContext context) {
    const tierOrder = ['2160p', '1080p', '720p', '480p', 'Other'];
    final groups = <String, List<TorrentioStream>>{};
    for (final s in filtered) {
      groups.putIfAbsent(_tier(s), () => <TorrentioStream>[]).add(s);
    }

    // One flat list of headers and rows, so a single lazy ListView serves.
    final items = <Object>[];
    for (final tier in tierOrder.where(groups.containsKey)) {
      final rows = groups[tier]!;
      items.add((tier: tier, count: rows.length));
      items.addAll(rows);
    }

    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final item = items[i];
        if (item is TorrentioStream) {
          return _SourceRow(
            stream: item,
            best: identical(item, best),
            onPick: onPick,
          );
        }
        final header = item as ({String tier, int count});
        return _TierHeader(label: header.tier, count: header.count);
      },
    );
  }
}

class _TierHeader extends StatelessWidget {
  const _TierHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    // The same colour as the quality badges on the rows below it — the
    // header used to take a Material scheme colour of its own, so a green
    // "2160p" header sat over orange 2160p badges.
    final accent = qualityTone(MediaQuality.fromText(label));
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
            style: AppType.mono(
              size: AppType.sizeSmall,
              color: accent,
              weight: FontWeight.w700,
              letterSpacing: 0.05,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '· $count',
            style: AppType.mono(size: AppType.sizeSmall, color: AppColors.fg2),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.total,
    required this.countFor,
    required this.qualityFilter,
    required this.onQualityChange,
    required this.sortBySize,
    required this.onSortChange,
  });

  final int total;
  final int Function(String quality) countFor;
  final String? qualityFilter;
  final ValueChanged<String?> onQualityChange;
  final bool sortBySize;
  final ValueChanged<bool> onSortChange;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xl,
        vertical: AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  MediaHubFilterChip(
                    label: 'All',
                    count: total,
                    selected: qualityFilter == null,
                    onTap: () => onQualityChange(null),
                  ),
                  for (final q in const ['2160p', '1080p', '720p']) ...[
                    const SizedBox(width: AppSpacing.xs),
                    MediaHubFilterChip(
                      label: q,
                      count: countFor(q),
                      selected: qualityFilter == q,
                      onTap: () => onQualityChange(q),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Container(
            padding: const EdgeInsets.all(AppSpacing.xxs),
            decoration: BoxDecoration(
              color: AppColors.bgSurface,
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SortSegment(
                  label: 'Most peers',
                  selected: !sortBySize,
                  onTap: () => onSortChange(false),
                ),
                _SortSegment(
                  label: 'Largest',
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

class _SortSegment extends StatelessWidget {
  const _SortSegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HubPressable(
      onTap: onTap,
      selected: selected,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: selected ? AppColors.bgSurfaceHi : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Text(
          label,
          style: AppType.ui(
            size: AppType.sizeSmall,
            weight: FontWeight.w600,
            color: selected ? AppColors.fg : AppColors.fg2,
          ),
        ),
      ),
    );
  }
}

/// One source. The row itself streams it; the buttons on the right stream
/// or download it explicitly.
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
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.stream;
    final quality = qualityBadgeLabel(s.name);
    final source = s.sourceSite;
    final size = s.sizeFormatted;
    final active = _hover || _focus;
    final releaseName = s.title.split('\n').first;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: HubPressable(
        onTap: () => widget.onPick(s, true),
        onHoverChanged: (h) => setState(() => _hover = h),
        onFocusChanged: (f) => setState(() => _focus = f),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AnimatedContainer(
          duration: AppDuration.fast,
          decoration: BoxDecoration(
            color: active ? AppColors.bgSurfaceHi : Colors.transparent,
            border: Border.all(
              color: widget.best
                  ? AppColors.accent.withAlpha(AppOpacity.semi)
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
                      horizontal: AppSpacing.xs,
                      vertical: AppSpacing.xxs,
                    ),
                    decoration: const BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.only(
                        bottomLeft: Radius.circular(AppRadius.xxs),
                        bottomRight: Radius.circular(AppRadius.xxs),
                      ),
                    ),
                    child: Text(
                      '★ Best',
                      style: AppType.mono(
                        size: AppType.sizeLabel,
                        color: AppColors.onAccent,
                        weight: FontWeight.w800,
                        letterSpacing: 0.05,
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  // Clears the "★ Best" tab hanging from the top edge.
                  widget.best ? AppSpacing.xl : AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md,
                ),
                child: Row(
                  children: [
                    EditorialBadge(
                      quality,
                      tone: qualityTone(MediaQuality.fromText(quality)),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            releaseName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.mono(
                              size: AppType.sizeCaption,
                              color: AppColors.fg,
                              weight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            [
                              if (source.isNotEmpty) source,
                              if (size.isNotEmpty) size,
                              if (s.isSeasonPack) 'Full season',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.mono(
                              size: AppType.sizeLabel,
                              color: AppColors.fg1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    _SourceHealth(peers: s.seeders),
                    const SizedBox(width: AppSpacing.md),
                    _RowButton(
                      label: 'Stream',
                      icon: Icons.play_arrow_rounded,
                      tooltip: 'Watch now while it downloads',
                      filled: widget.best || active,
                      onTap: () => widget.onPick(s, true),
                    ),
                    const SizedBox(width: 4),
                    _RowButton(
                      label: 'Download',
                      icon: Icons.download_rounded,
                      tooltip: 'Download to keep — watch later',
                      filled: false,
                      onTap: () => widget.onPick(s, false),
                    ),
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

/// A compact row button. Filled means the primary action: the accent with
/// dark text, which reads (white on this orange is 2.7:1).
class _RowButton extends StatelessWidget {
  const _RowButton({
    required this.label,
    required this.icon,
    required this.tooltip,
    required this.filled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final String tooltip;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? AppColors.onAccent : AppColors.fg1;
    return HubPressable(
      onTap: onTap,
      tooltip: tooltip,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: filled ? AppColors.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: filled ? AppColors.accent : AppColors.lineStrong,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 4),
            Text(
              label,
              style: AppType.ui(
                size: AppType.sizeCaption,
                color: fg,
                weight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How healthy a source is, in plain words: how many peers share it, and
/// what that means for playback. The thresholds are deliberately loose —
/// swarm health varies too much to be precise; the point is one glanceable
/// hint about whether a source will play or struggle.
class _SourceHealth extends StatelessWidget {
  const _SourceHealth({required this.peers});

  final int peers;

  @override
  Widget build(BuildContext context) {
    final (String hint, Color color) = switch (peers) {
      >= 50 => ('Plays fast', AppColors.ok),
      >= 10 => ('Plays well', AppColors.accent),
      >= 1 => ('May buffer', AppColors.warn),
      _ => ('No peers', AppColors.err),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          peers == 1 ? '1 peer' : '$peers peers',
          style: AppType.mono(size: AppType.sizeSmall, color: AppColors.fg1),
        ),
        const SizedBox(height: 2),
        Text(
          hint,
          style: AppType.ui(
            size: AppType.sizeSmall,
            color: color,
            weight: FontWeight.w600,
          ),
        ),
      ],
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
        border: Border(top: BorderSide(color: AppColors.line, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${count == 1 ? '1 source' : '$count sources'} · $sortLabel',
              style: AppType.mono(
                size: AppType.sizeSmall,
                color: AppColors.fg2,
              ),
            ),
          ),
          EditorialButton(
            label: 'Cancel',
            kind: EditorialButtonKind.ghost,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}
