import 'package:flutter/material.dart';

import '../design/app_tokens.dart';
import '../models/torrentio_stream.dart';
import '../services/torrentio_api_service.dart';
import '../services/streaming_service.dart';

/// Result from the stream picker dialog
class StreamPickerResult {
  final TorrentioStream stream;
  final bool isStreaming;

  StreamPickerResult({required this.stream, required this.isStreaming});
}

/// Sort options extended for streaming
enum StreamPickerSortOption {
  streaming, // Single-file first, then by seeders
  seeders,
  quality,
  size,
  sizeDesc,
}

/// Dialog for picking a Torrentio stream to download or stream
class TorrentioStreamPickerDialog extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<TorrentioStream> streams;
  final Function(TorrentioStream, bool isStreaming) onSelect;

  const TorrentioStreamPickerDialog({
    super.key,
    required this.title,
    this.subtitle,
    required this.streams,
    required this.onSelect,
  });

  @override
  State<TorrentioStreamPickerDialog> createState() => _TorrentioStreamPickerDialogState();

  /// Show the dialog and return the selected stream result (or null if cancelled)
  static Future<StreamPickerResult?> show({
    required BuildContext context,
    required String title,
    String? subtitle,
    required List<TorrentioStream> streams,
    required Function(TorrentioStream, bool isStreaming) onSelect,
  }) {
    return showDialog<StreamPickerResult>(
      context: context,
      builder: (context) => TorrentioStreamPickerDialog(
        title: title,
        subtitle: subtitle,
        streams: streams,
        onSelect: onSelect,
      ),
    );
  }
}

class _TorrentioStreamPickerDialogState extends State<TorrentioStreamPickerDialog> {
  StreamPickerSortOption _sortBy = StreamPickerSortOption.streaming; // Default to streaming-optimized sort
  String? _qualityFilter;
  bool _singleFileOnly = false; // Filter to show only single-file torrents

  List<TorrentioStream> get _sortedStreams {
    var streams = List<TorrentioStream>.from(widget.streams);

    // Apply quality filter
    if (_qualityFilter != null) {
      streams = TorrentioApiService.filterByQuality(streams, _qualityFilter!);
    }
    
    // Apply single-file filter
    if (_singleFileOnly) {
      streams = streams.singleFileOnly();
    }

    // Apply sorting
    switch (_sortBy) {
      case StreamPickerSortOption.streaming:
        // Sort by streaming score (single-file first, then quality + seeders)
        return streams.sortForStreaming();
      case StreamPickerSortOption.seeders:
        return TorrentioApiService.sortStreams(streams, sortBy: TorrentioSortOption.seeders);
      case StreamPickerSortOption.quality:
        return TorrentioApiService.sortStreams(streams, sortBy: TorrentioSortOption.quality);
      case StreamPickerSortOption.size:
        return TorrentioApiService.sortStreams(streams, sortBy: TorrentioSortOption.size);
      case StreamPickerSortOption.sizeDesc:
        return TorrentioApiService.sortStreams(streams, sortBy: TorrentioSortOption.sizeDesc);
    }
  }

  Set<String> get _availableQualities {
    return TorrentioApiService.getAvailableQualities(widget.streams);
  }
  
  /// Count of single-episode releases available (including video+subs)
  int get _singleFileCount {
    var streams = List<TorrentioStream>.from(widget.streams);
    if (_qualityFilter != null) {
      streams = TorrentioApiService.filterByQuality(streams, _qualityFilter!);
    }
    return streams.where((s) => s.isSingleEpisodeRelease).length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sortedStreams = _sortedStreams;

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Container(
        width: 550,
        constraints: const BoxConstraints(maxHeight: 650),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              padding: EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withAlpha(AppOpacity.light),
                borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withAlpha(AppOpacity.light),
                          borderRadius: BorderRadius.circular(AppRadius.md),
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
                              widget.title,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (widget.subtitle != null)
                              Text(
                                widget.subtitle!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(context).pop(),
                        tooltip: 'Close',
                      ),
                    ],
                  ),
                  SizedBox(height: AppSpacing.md),
                  // Filter and sort controls
                  Row(
                    children: [
                      // Quality filter
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _qualityFilter,
                          decoration: InputDecoration(
                            labelText: 'Quality',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: AppSpacing.md,
                              vertical: AppSpacing.sm,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(AppRadius.md),
                            ),
                          ),
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
                      // Sort options
                      Expanded(
                        child: DropdownButtonFormField<StreamPickerSortOption>(
                          value: _sortBy,
                          decoration: InputDecoration(
                            labelText: 'Sort by',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: AppSpacing.md,
                              vertical: AppSpacing.sm,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(AppRadius.md),
                            ),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: StreamPickerSortOption.streaming,
                              child: Text('Best for Streaming'),
                            ),
                            DropdownMenuItem(
                              value: StreamPickerSortOption.seeders,
                              child: Text('Seeders'),
                            ),
                            DropdownMenuItem(
                              value: StreamPickerSortOption.quality,
                              child: Text('Quality'),
                            ),
                            DropdownMenuItem(
                              value: StreamPickerSortOption.size,
                              child: Text('Size (asc)'),
                            ),
                            DropdownMenuItem(
                              value: StreamPickerSortOption.sizeDesc,
                              child: Text('Size (desc)'),
                            ),
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
                  // Single-file filter toggle
                  if (_singleFileCount > 0 && _singleFileCount < widget.streams.length) ...[
                    SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        Checkbox(
                          value: _singleFileOnly,
                          onChanged: (value) {
                            setState(() => _singleFileOnly = value ?? false);
                          },
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        SizedBox(width: AppSpacing.xs),
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              setState(() => _singleFileOnly = !_singleFileOnly);
                            },
                            child: Text(
                              'Single-file torrents only ($_singleFileCount available)',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                        Tooltip(
                          message: 'Single-episode releases (including those with subtitles) are faster to stream.\n'
                              'Season packs require selecting a specific file from the pack.',
                          child: Icon(
                            Icons.info_outline_rounded,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // Results count
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Text(
                '${sortedStreams.length} streams available',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),

            // Stream list
            Flexible(
              child: sortedStreams.isEmpty
                  ? Center(
                      child: Padding(
                        padding: EdgeInsets.all(AppSpacing.xl),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search_off_rounded,
                              size: 48,
                              color: theme.colorScheme.onSurfaceVariant.withAlpha(AppOpacity.medium),
                            ),
                            SizedBox(height: AppSpacing.md),
                            Text(
                              'No streams match the current filter',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                      itemCount: sortedStreams.length,
                      itemBuilder: (context, index) {
                        final stream = sortedStreams[index];
                        return _StreamListItem(
                          stream: stream,
                          onDownload: () {
                            widget.onSelect(stream, false);
                            Navigator.of(context).pop(StreamPickerResult(stream: stream, isStreaming: false));
                          },
                          onStream: () {
                            widget.onSelect(stream, true);
                            Navigator.of(context).pop(StreamPickerResult(stream: stream, isStreaming: true));
                          },
                        );
                      },
                    ),
            ),

            // Footer
            Container(
              padding: EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: theme.colorScheme.outlineVariant.withAlpha(AppOpacity.medium),
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
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

/// Individual stream list item
class _StreamListItem extends StatelessWidget {
  final TorrentioStream stream;
  final VoidCallback onDownload;
  final VoidCallback onStream;

  const _StreamListItem({
    required this.stream,
    required this.onDownload,
    required this.onStream,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: InkWell(
        onTap: onDownload,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: Quality badge, source, seeders
              Row(
                children: [
                  // Quality badge
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xxs,
                    ),
                    decoration: BoxDecoration(
                      color: _getQualityColor(stream.quality).withAlpha(AppOpacity.light),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      border: Border.all(
                        color: _getQualityColor(stream.quality).withAlpha(AppOpacity.medium),
                      ),
                    ),
                    child: Text(
                      stream.quality,
                      style: TextStyle(
                        color: _getQualityColor(stream.quality),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SizedBox(width: AppSpacing.sm),
                  // Single-file vs Season pack indicator
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xxs,
                    ),
                    decoration: BoxDecoration(
                      color: stream.isSingleEpisodeRelease 
                          ? Colors.green.withAlpha(AppOpacity.light) 
                          : Colors.orange.withAlpha(AppOpacity.light),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      border: Border.all(
                        color: stream.isSingleEpisodeRelease 
                            ? Colors.green.withAlpha(AppOpacity.medium) 
                            : Colors.orange.withAlpha(AppOpacity.medium),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          stream.isSingleEpisodeRelease ? Icons.file_present_rounded : Icons.folder_rounded,
                          size: 10,
                          color: stream.isSingleEpisodeRelease ? Colors.green : Colors.orange,
                        ),
                        SizedBox(width: 2),
                        Text(
                          stream.isSingleFile 
                              ? 'Single' 
                              : (stream.isSingleEpisodeRelease ? 'w/Subs' : 'Pack'),
                          style: TextStyle(
                            color: stream.isSingleEpisodeRelease ? Colors.green : Colors.orange,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: AppSpacing.sm),
                  // Source site
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xxs,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      stream.sourceSite,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Seeders
                  Row(
                    children: [
                      Icon(
                        Icons.person_rounded,
                        size: 14,
                        color: _getSeedersColor(stream.seeders),
                      ),
                      SizedBox(width: 2),
                      Text(
                        '${stream.seeders}',
                        style: TextStyle(
                          color: _getSeedersColor(stream.seeders),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(width: AppSpacing.md),
                  // Size
                  Row(
                    children: [
                      Icon(
                        Icons.storage_rounded,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      SizedBox(width: 2),
                      Text(
                        stream.sizeFormatted,
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              SizedBox(height: AppSpacing.sm),
              // Release name
              Text(
                stream.releaseName,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (stream.filename != null) ...[
                SizedBox(height: AppSpacing.xxs),
                Text(
                  stream.filename!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              // Health bar and action buttons
              SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                      child: LinearProgressIndicator(
                        value: stream.healthScore / 100,
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation(
                          _getHealthColor(stream.healthScore),
                        ),
                        minHeight: 3,
                      ),
                    ),
                  ),
                  SizedBox(width: AppSpacing.sm),
                  // Stream button
                  OutlinedButton.icon(
                    onPressed: onStream,
                    icon: const Icon(Icons.play_circle_outline_rounded, size: 16),
                    label: const Text('Stream'),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xs,
                      ),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                  SizedBox(width: AppSpacing.xs),
                  // Download button
                  FilledButton.icon(
                    onPressed: onDownload,
                    icon: const Icon(Icons.download_rounded, size: 16),
                    label: const Text('Download'),
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xs,
                      ),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
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
      case 'BluRay':
        return Colors.indigo;
      default:
        return Colors.grey;
    }
  }

  Color _getSeedersColor(int seeders) {
    if (seeders >= 50) return Colors.green;
    if (seeders >= 10) return Colors.orange;
    if (seeders > 0) return Colors.red.shade300;
    return Colors.grey;
  }

  Color _getHealthColor(int health) {
    if (health >= 80) return Colors.green;
    if (health >= 50) return Colors.orange;
    if (health >= 20) return Colors.red.shade300;
    return Colors.grey;
  }
}
