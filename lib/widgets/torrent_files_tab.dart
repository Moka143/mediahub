import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_tokens.dart';
import '../models/torrent_file.dart';
import '../providers/connection_provider.dart';
import '../providers/torrent_provider.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import 'common/empty_state.dart';
import 'common/loading_state.dart';

/// Tab widget for displaying torrent files with batch selection support
class TorrentFilesTab extends ConsumerStatefulWidget {
  final String torrentHash;

  const TorrentFilesTab({super.key, required this.torrentHash});

  @override
  ConsumerState<TorrentFilesTab> createState() => _TorrentFilesTabState();
}

class _TorrentFilesTabState extends ConsumerState<TorrentFilesTab> {
  final Set<int> _selectedFiles = {};
  bool _isSelectionMode = false;

  void _toggleSelection(int fileIndex) {
    setState(() {
      if (_selectedFiles.contains(fileIndex)) {
        _selectedFiles.remove(fileIndex);
        if (_selectedFiles.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedFiles.add(fileIndex);
      }
    });
  }

  void _selectAll(List<TorrentFile> files) {
    setState(() {
      _isSelectionMode = true;
      _selectedFiles.addAll(files.map((f) => f.index));
    });
  }

  void _selectVideos(List<TorrentFile> files) {
    setState(() {
      _isSelectionMode = true;
      _selectedFiles.addAll(
        files.where((f) => _isVideoFile(f.fileName)).map((f) => f.index),
      );
    });
  }

  void _clearSelection() {
    setState(() {
      _isSelectionMode = false;
      _selectedFiles.clear();
    });
  }

  bool _isVideoFile(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return ['mp4', 'mkv', 'avi', 'mov', 'wmv', 'webm', 'flv', 'm4v'].contains(ext);
  }

  Future<void> _setBatchPriority(FilePriority priority) async {
    final apiService = ref.read(qbApiServiceProvider);
    await apiService.setFilePriority(
      widget.torrentHash,
      _selectedFiles.toList(),
      priority.value,
    );
    ref.invalidate(torrentFilesProvider(widget.torrentHash));
    _clearSelection();
  }

  Future<void> _setAllPriority(List<TorrentFile> files, FilePriority priority) async {
    final apiService = ref.read(qbApiServiceProvider);
    await apiService.setFilePriority(
      widget.torrentHash,
      files.map((f) => f.index).toList(),
      priority.value,
    );
    ref.invalidate(torrentFilesProvider(widget.torrentHash));
  }

  @override
  Widget build(BuildContext context) {
    final filesAsync = ref.watch(torrentFilesProvider(widget.torrentHash));

    return filesAsync.when(
      data: (files) => _buildContent(context, files),
      loading: () => const LoadingIndicator(message: 'Loading files...'),
      error: (error, stack) => EmptyState.error(
        message: error.toString(),
        onRetry: () => ref.invalidate(torrentFilesProvider(widget.torrentHash)),
      ),
    );
  }

  Widget _buildContent(BuildContext context, List<TorrentFile> files) {
    if (files.isEmpty) {
      return EmptyState.noData(
        icon: Icons.folder_off_outlined,
        title: 'No files',
      );
    }

    return Column(
      children: [
        // Selection toolbar or quick actions
        if (_isSelectionMode)
          _buildSelectionToolbar(context, files)
        else
          _buildQuickActions(context, files),

        // File list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(AppSpacing.sm),
            itemCount: files.length,
            itemBuilder: (context, index) {
              final file = files[index];
              return _FileListItem(
                file: file,
                torrentHash: widget.torrentHash,
                isSelected: _selectedFiles.contains(file.index),
                isSelectionMode: _isSelectionMode,
                onTap: () {
                  if (_isSelectionMode) {
                    _toggleSelection(file.index);
                  }
                },
                onLongPress: () {
                  if (!_isSelectionMode) {
                    setState(() {
                      _isSelectionMode = true;
                      _selectedFiles.add(file.index);
                    });
                  }
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSelectionToolbar(BuildContext context, List<TorrentFile> files) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withAlpha(AppOpacity.medium),
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withAlpha(AppOpacity.light),
          ),
        ),
      ),
      child: Row(
        children: [
          // Selection count
          Text(
            '${_selectedFiles.length} selected',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),

          const SizedBox(width: AppSpacing.sm),

          // Select all button
          TextButton(
            onPressed: () => _selectAll(files),
            child: const Text('Select All'),
          ),

          const Spacer(),

          // Batch priority dropdown
          PopupMenuButton<FilePriority>(
            onSelected: _setBatchPriority,
            itemBuilder: (context) => FilePriority.values.map((priority) {
              return PopupMenuItem(
                value: priority,
                child: Row(
                  children: [
                    _PriorityIcon(priority: priority),
                    const SizedBox(width: AppSpacing.sm),
                    Text(priority.label),
                  ],
                ),
              );
            }).toList(),
            child: FilledButton.tonalIcon(
              onPressed: null, // Handled by PopupMenuButton
              icon: const Icon(Icons.low_priority, size: 18),
              label: const Text('Set Priority'),
            ),
          ),

          const SizedBox(width: AppSpacing.sm),

          // Cancel button
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: _clearSelection,
            tooltip: 'Cancel selection',
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(BuildContext context, List<TorrentFile> files) {
    final videoCount = files.where((f) => _isVideoFile(f.fileName)).length;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // Select all
            ActionChip(
              avatar: const Icon(Icons.check_box_outlined, size: 18),
              label: const Text('Select All'),
              onPressed: () => _selectAll(files),
            ),

            const SizedBox(width: AppSpacing.sm),

            // Select videos only
            if (videoCount > 0)
              ActionChip(
                avatar: const Icon(Icons.video_file_outlined, size: 18),
                label: Text('Videos ($videoCount)'),
                onPressed: () => _selectVideos(files),
              ),

            const SizedBox(width: AppSpacing.sm),

            // Max priority all
            ActionChip(
              avatar: Icon(
                Icons.keyboard_double_arrow_up,
                size: 18,
                color: _getPriorityColor(FilePriority.maximum),
              ),
              label: const Text('Max All'),
              onPressed: () => _setAllPriority(files, FilePriority.maximum),
            ),

            const SizedBox(width: AppSpacing.sm),

            // Normal priority all
            ActionChip(
              avatar: Icon(
                Icons.remove,
                size: 18,
                color: _getPriorityColor(FilePriority.normal),
              ),
              label: const Text('Normal All'),
              onPressed: () => _setAllPriority(files, FilePriority.normal),
            ),
          ],
        ),
      ),
    );
  }

  Color _getPriorityColor(FilePriority priority) {
    switch (priority) {
      case FilePriority.doNotDownload:
        return Colors.grey;
      case FilePriority.normal:
        return Colors.blue;
      case FilePriority.high:
        return Colors.orange;
      case FilePriority.maximum:
        return Colors.red;
    }
  }
}

class _FileListItem extends ConsumerWidget {
  final TorrentFile file;
  final String torrentHash;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _FileListItem({
    required this.file,
    required this.torrentHash,
    required this.isSelected,
    required this.isSelectionMode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // Determine icon based on file extension
    final fileIcon = _getFileIcon(file.extension);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      color: isSelected
          ? theme.colorScheme.primaryContainer.withAlpha(AppOpacity.medium)
          : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              // Selection checkbox or file icon
              if (isSelectionMode)
                Checkbox(
                  value: isSelected,
                  onChanged: (_) => onTap(),
                )
              else
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(fileIcon, color: theme.colorScheme.primary, size: 20),
                ),

              const SizedBox(width: AppSpacing.md),

              // File info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      children: [
                        Text(
                          Formatters.formatBytes(file.size),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(AppRadius.xxs),
                            child: LinearProgressIndicator(
                              value: file.progress,
                              minHeight: 4,
                              backgroundColor: theme.colorScheme.surfaceContainerHighest,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          Formatters.formatProgress(file.progress),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: AppSpacing.sm),

              // Priority indicator with dropdown
              if (!isSelectionMode) _buildPriorityButton(context, ref),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getFileIcon(String extension) {
    switch (extension.toLowerCase()) {
      case 'mp4':
      case 'mkv':
      case 'avi':
      case 'mov':
      case 'wmv':
      case 'webm':
      case 'flv':
      case 'm4v':
        return Icons.movie_outlined;
      case 'mp3':
      case 'flac':
      case 'wav':
      case 'aac':
      case 'ogg':
      case 'm4a':
        return Icons.audiotrack_outlined;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'bmp':
      case 'webp':
        return Icons.image_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return Icons.folder_zip_outlined;
      case 'exe':
      case 'msi':
      case 'dmg':
      case 'app':
        return Icons.apps_outlined;
      case 'txt':
      case 'md':
      case 'doc':
      case 'docx':
        return Icons.description_outlined;
      case 'srt':
      case 'sub':
      case 'ass':
        return Icons.subtitles_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  Widget _buildPriorityButton(BuildContext context, WidgetRef ref) {
    final priority = file.priorityEnum;

    return PopupMenuButton<FilePriority>(
      initialValue: priority,
      onSelected: (newPriority) async {
        final apiService = ref.read(qbApiServiceProvider);
        await apiService.setFilePriority(torrentHash, [file.index], newPriority.value);
        ref.invalidate(torrentFilesProvider(torrentHash));
      },
      itemBuilder: (context) => FilePriority.values.map((p) {
        return PopupMenuItem(
          value: p,
          child: Row(
            children: [
              _PriorityIcon(priority: p),
              const SizedBox(width: AppSpacing.sm),
              Text(p.label),
            ],
          ),
        );
      }).toList(),
      child: _PriorityBadge(priority: priority),
    );
  }
}

/// Visual priority indicator badge
class _PriorityBadge extends StatelessWidget {
  final FilePriority priority;

  const _PriorityBadge({required this.priority});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _getPriorityStyle(priority);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withAlpha(AppOpacity.light),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: color.withAlpha(AppOpacity.medium),
          width: AppBorderWidth.hairline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: AppSpacing.xxs),
          Text(
            priority.label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  (IconData, Color) _getPriorityStyle(FilePriority priority) {
    switch (priority) {
      case FilePriority.doNotDownload:
        return (Icons.block, Colors.grey);
      case FilePriority.normal:
        return (Icons.remove, Colors.blue);
      case FilePriority.high:
        return (Icons.arrow_upward, Colors.orange);
      case FilePriority.maximum:
        return (Icons.keyboard_double_arrow_up, Colors.red);
    }
  }
}

/// Priority icon widget
class _PriorityIcon extends StatelessWidget {
  final FilePriority priority;

  const _PriorityIcon({required this.priority});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _getPriorityStyle(priority);
    return Icon(icon, size: 18, color: color);
  }

  (IconData, Color) _getPriorityStyle(FilePriority priority) {
    switch (priority) {
      case FilePriority.doNotDownload:
        return (Icons.block, Colors.grey);
      case FilePriority.normal:
        return (Icons.remove, Colors.blue);
      case FilePriority.high:
        return (Icons.arrow_upward, Colors.orange);
      case FilePriority.maximum:
        return (Icons.keyboard_double_arrow_up, Colors.red);
    }
  }
}
