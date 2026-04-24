import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_tokens.dart';
import '../providers/settings_provider.dart';
import '../providers/torrent_provider.dart';

/// Dialog for adding a new torrent
class AddTorrentDialog extends ConsumerStatefulWidget {
  const AddTorrentDialog({super.key});

  @override
  ConsumerState<AddTorrentDialog> createState() => _AddTorrentDialogState();
}

class _AddTorrentDialogState extends ConsumerState<AddTorrentDialog> {
  final _magnetController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String? _selectedFilePath;
  String? _savePath;
  bool _startImmediately = true;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _savePath = settings.defaultSavePath;
  }

  @override
  void dispose() {
    _magnetController.dispose();
    super.dispose();
  }

  Future<void> _pickTorrentFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['torrent'],
      );

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _selectedFilePath = result.files.first.path;
          _magnetController.clear();
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to pick file: $e';
      });
    }
  }

  Future<void> _pickSavePath() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath();

      if (result != null) {
        setState(() {
          _savePath = result;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to pick directory: $e';
      });
    }
  }

  Future<void> _addTorrent() async {
    if (_isLoading) return;

    // Validate
    final hasMagnet = _magnetController.text.isNotEmpty;
    final hasFile = _selectedFilePath != null;

    if (!hasMagnet && !hasFile) {
      setState(() {
        _error = 'Please enter a magnet link or select a torrent file';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final notifier = ref.read(torrentListProvider.notifier);
      bool success;

      if (hasMagnet) {
        success = await notifier.addMagnet(
          _magnetController.text,
          savePath: _savePath,
          startNow: _startImmediately,
        );
      } else {
        success = await notifier.addTorrentFile(
          File(_selectedFilePath!),
          savePath: _savePath,
          startNow: _startImmediately,
        );
      }

      if (success) {
        if (mounted) {
          Navigator.of(context).pop(true);
        }
      } else {
        setState(() {
          _error = 'Failed to add torrent';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(
              Icons.add_rounded,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          const Text('Add Torrent'),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Magnet link input
              TextField(
                controller: _magnetController,
                decoration: InputDecoration(
                  labelText: 'Magnet Link',
                  hintText: 'magnet:?xt=urn:btih:...',
                  prefixIcon: const Icon(Icons.link_rounded),
                  enabled: _selectedFilePath == null,
                ),
                maxLines: 3,
                minLines: 1,
                onChanged: (_) {
                  if (_selectedFilePath != null) {
                    setState(() {
                      _selectedFilePath = null;
                    });
                  }
                },
              ),
              SizedBox(height: AppSpacing.lg),

              // OR divider
              Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xs,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(AppRadius.full),
                      ),
                      child: Text(
                        'OR',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
              SizedBox(height: AppSpacing.lg),

              // File picker
              OutlinedButton.icon(
                onPressed: _pickTorrentFile,
                icon: const Icon(Icons.folder_open_rounded),
                label: Text(
                  _selectedFilePath != null
                      ? _selectedFilePath!.split('/').last
                      : 'Select .torrent file',
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  ),
                ),
              ),
              SizedBox(height: AppSpacing.xl),

              // Save path
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(
                          color: theme.colorScheme.outline.withAlpha(64),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.folder_rounded,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Save to',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                Text(
                                  _savePath ?? 'Default',
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(width: AppSpacing.sm),
                  FilledButton.tonalIcon(
                    onPressed: _pickSavePath,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('Browse'),
                  ),
                ],
              ),
              SizedBox(height: AppSpacing.lg),

              // Start immediately toggle
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withAlpha(
                    128,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _startImmediately
                            ? theme.colorScheme.primary.withAlpha(32)
                            : theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: _startImmediately
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        'Start immediately',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Switch(
                      value: _startImmediately,
                      onChanged: (value) {
                        setState(() {
                          _startImmediately = value;
                        });
                      },
                    ),
                  ],
                ),
              ),

              // Error message
              if (_error != null) ...[
                SizedBox(height: AppSpacing.lg),
                Container(
                  padding: EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        color: theme.colorScheme.error,
                        size: AppIconSize.md,
                      ),
                      SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _isLoading ? null : _addTorrent,
          icon: _isLoading
              ? SizedBox(
                  width: AppIconSize.sm,
                  height: AppIconSize.sm,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_rounded),
          label: Text(_isLoading ? 'Adding...' : 'Add'),
        ),
      ],
    );
  }
}

/// Show the add torrent dialog
Future<bool?> showAddTorrentDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (context) => const AddTorrentDialog(),
  );
}
