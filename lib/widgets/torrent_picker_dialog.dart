import 'package:flutter/material.dart';

import '../design/app_tokens.dart';
import '../design/app_theme.dart';
import '../models/eztv_torrent.dart';

/// Dialog for picking a torrent to download
class TorrentPickerDialog extends StatefulWidget {
  final String showName;
  final String episodeCode;
  final List<EztvTorrent> torrents;
  final Function(EztvTorrent) onDownload;

  const TorrentPickerDialog({
    super.key,
    required this.showName,
    required this.episodeCode,
    required this.torrents,
    required this.onDownload,
  });

  @override
  State<TorrentPickerDialog> createState() => _TorrentPickerDialogState();

  /// Show the dialog and return the selected torrent (or null if cancelled)
  static Future<EztvTorrent?> show({
    required BuildContext context,
    required String showName,
    required String episodeCode,
    required List<EztvTorrent> torrents,
    required Function(EztvTorrent) onDownload,
  }) {
    return showDialog<EztvTorrent>(
      context: context,
      builder: (context) => TorrentPickerDialog(
        showName: showName,
        episodeCode: episodeCode,
        torrents: torrents,
        onDownload: onDownload,
      ),
    );
  }
}

class _TorrentPickerDialogState extends State<TorrentPickerDialog> {
  String _sortBy = 'seeds';
  String? _qualityFilter;

  List<EztvTorrent> get _sortedTorrents {
    var torrents = List<EztvTorrent>.from(widget.torrents);

    // Apply quality filter
    if (_qualityFilter != null) {
      torrents = torrents.where((t) => t.quality == _qualityFilter).toList();
    }

    // Apply sorting
    switch (_sortBy) {
      case 'seeds':
        torrents.sort((a, b) => b.seeds.compareTo(a.seeds));
        break;
      case 'quality':
        torrents.sort((a, b) => b.qualityPriority.compareTo(a.qualityPriority));
        break;
      case 'size':
        torrents.sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
        break;
    }

    return torrents;
  }

  Set<String> get _availableQualities {
    return widget.torrents.map((t) => t.quality).toSet();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sortedTorrents = _sortedTorrents;
    final appColors = context.appColors;

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Container(
        width: 500,
        constraints: const BoxConstraints(maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              padding: EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withAlpha(AppOpacity.light),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Icon(
                      Icons.download_rounded,
                      color: theme.colorScheme.primary,
                      size: 24,
                    ),
                  ),
                  SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Download Torrent',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: AppSpacing.xxs),
                        Text(
                          '${widget.showName} - ${widget.episodeCode}',
                          style: TextStyle(color: appColors.mutedText),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                    style: IconButton.styleFrom(
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                ],
              ),
            ),

            // Filter and sort options
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  // Quality filter
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      value: _qualityFilter,
                      decoration: InputDecoration(
                        labelText: 'Quality',
                        contentPadding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                        prefixIcon: Icon(Icons.hd_rounded, color: appColors.mutedText),
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('All'),
                        ),
                        ..._availableQualities.map((q) => DropdownMenuItem(
                              value: q,
                              child: Text(q),
                            )),
                      ],
                      onChanged: (value) {
                        setState(() => _qualityFilter = value);
                      },
                    ),
                  ),
                  SizedBox(width: AppSpacing.md),
                  // Sort option
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _sortBy,
                      decoration: InputDecoration(
                        labelText: 'Sort by',
                        contentPadding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                        prefixIcon: Icon(Icons.sort_rounded, color: appColors.mutedText),
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      items: const [
                        DropdownMenuItem(value: 'seeds', child: Text('Seeds')),
                        DropdownMenuItem(value: 'quality', child: Text('Quality')),
                        DropdownMenuItem(value: 'size', child: Text('Size')),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _sortBy = value);
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),

            const Divider(),

            // Torrent list
            Flexible(
              child: sortedTorrents.isEmpty
                  ? Center(
                      child: Padding(
                        padding: EdgeInsets.all(AppSpacing.xl),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(AppSpacing.lg),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.search_off_rounded,
                                size: AppIconSize.xl,
                                color: appColors.mutedText,
                              ),
                            ),
                            SizedBox(height: AppSpacing.lg),
                            Text(
                              'No torrents found',
                              style: TextStyle(
                                color: appColors.mutedText,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: sortedTorrents.length,
                      itemBuilder: (context, index) {
                        final torrent = sortedTorrents[index];
                        return _TorrentListItem(
                          torrent: torrent,
                          onDownload: () {
                            widget.onDownload(torrent);
                            Navigator.of(context).pop(torrent);
                          },
                        );
                      },
                    ),
            ),

            const Divider(),

            // Actions
            Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Text(
                '${sortedTorrents.length} torrents available',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.extension<AppColorsExtension>()!.mutedText,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TorrentListItem extends StatelessWidget {
  final EztvTorrent torrent;
  final VoidCallback onDownload;

  const _TorrentListItem({
    required this.torrent,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onDownload,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              // Quality badge
              Container(
                width: 60,
                padding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: _getQualityColor(torrent.quality).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  border: Border.all(
                    color: _getQualityColor(torrent.quality).withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  torrent.quality,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _getQualityColor(torrent.quality),
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
              ),
              SizedBox(width: AppSpacing.md),

              // File info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      torrent.filename,
                      style: theme.textTheme.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: AppSpacing.xs),
                    Row(
                      children: [
                        // Size
                        Icon(
                          Icons.storage_rounded,
                          size: AppIconSize.xs,
                          color: appColors.mutedText,
                        ),
                        SizedBox(width: AppSpacing.xs),
                        Text(
                          torrent.sizeFormatted,
                          style: TextStyle(
                            fontSize: 12,
                            color: appColors.mutedText,
                          ),
                        ),
                        SizedBox(width: AppSpacing.lg),
                        // Seeds
                        Icon(
                          Icons.arrow_upward_rounded,
                          size: AppIconSize.xs,
                          color: _getSeedsColor(torrent.seeds),
                        ),
                        SizedBox(width: AppSpacing.xs),
                        Text(
                          '${torrent.seeds}',
                          style: TextStyle(
                            fontSize: 12,
                            color: _getSeedsColor(torrent.seeds),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        SizedBox(width: AppSpacing.sm),
                        // Peers
                        Icon(
                          Icons.arrow_downward_rounded,
                          size: AppIconSize.xs,
                          color: appColors.mutedText,
                        ),
                        SizedBox(width: AppSpacing.xs),
                        Text(
                          '${torrent.peers}',
                          style: TextStyle(
                            fontSize: 12,
                            color: appColors.mutedText,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Health indicator
              _buildHealthIndicator(torrent.healthScore),
              SizedBox(width: AppSpacing.sm),

              // Download button
              FilledButton.tonalIcon(
                onPressed: onDownload,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Get'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHealthIndicator(int score) {
    final color = score >= 60
        ? Colors.green
        : score >= 30
            ? Colors.orange
            : Colors.red;

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Icon(
          score >= 60
              ? Icons.signal_cellular_4_bar_rounded
              : score >= 30
                  ? Icons.signal_cellular_alt_2_bar_rounded
                  : Icons.signal_cellular_alt_1_bar_rounded,
          size: 16,
          color: color,
        ),
      ),
    );
  }

  Color _getQualityColor(String quality) {
    switch (quality) {
      case '4K':
        return Colors.purple;
      case '1080p':
        return Colors.blue;
      case '720p':
        return Colors.green;
      case 'WEB-DL':
        return Colors.teal;
      case 'WEBRip':
        return Colors.cyan;
      case 'HDTV':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  Color _getSeedsColor(int seeds) {
    if (seeds >= 50) return Colors.green;
    if (seeds >= 20) return Colors.lightGreen;
    if (seeds >= 10) return Colors.orange;
    if (seeds > 0) return Colors.deepOrange;
    return Colors.red;
  }
}
