import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../providers/settings_provider.dart';
import '../providers/torrent_provider.dart';
import 'editorial/editorial.dart';

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
    return Dialog(
      backgroundColor: AppColors.bgSurface,
      elevation: 0,
      insetPadding: const EdgeInsets.all(AppSpacing.xxl),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: AppColors.line, width: 1),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xxl,
            AppSpacing.xl,
            AppSpacing.xxl,
            AppSpacing.lg,
          ),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.add_rounded,
                      color: AppColors.accent,
                      size: AppIconSize.lg,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    const SerifTitle('Add torrent', size: 22, height: 1.05),
                  ],
                ),
                const SizedBox(height: AppSpacing.xl),

                // Magnet link input
                TextField(
                  controller: _magnetController,
                  style: AppType.ui(size: 13, color: AppColors.fg),
                  cursorColor: AppColors.accent,
                  decoration: InputDecoration(
                    labelText: 'Magnet link',
                    labelStyle: AppType.mono(
                      size: 11,
                      color: AppColors.fg2,
                      letterSpacing: 0.06,
                    ),
                    hintText: 'magnet:?xt=urn:btih:…',
                    hintStyle: AppType.ui(size: 13, color: AppColors.fg3),
                    prefixIcon: const Icon(
                      Icons.link_rounded,
                      color: AppColors.fg2,
                      size: AppIconSize.sm,
                    ),
                    enabled: _selectedFilePath == null,
                    filled: true,
                    fillColor: AppColors.bgPage,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      borderSide: BorderSide(color: AppColors.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      borderSide: BorderSide(color: AppColors.line),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      borderSide: BorderSide(color: AppColors.accent),
                    ),
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
                const SizedBox(height: AppSpacing.lg),

                // OR divider (mono tag between hairlines)
                Row(
                  children: [
                    const Expanded(
                      child: Divider(color: AppColors.line, height: 1),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                      ),
                      child: MonoLabel(
                        'OR',
                        color: AppColors.fg3,
                        letterSpacing: 0.12,
                      ),
                    ),
                    const Expanded(
                      child: Divider(color: AppColors.line, height: 1),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),

                // File picker
                EditorialButton(
                  label: _selectedFilePath != null
                      ? _selectedFilePath!.split(Platform.pathSeparator).last
                      : 'Select .torrent file',
                  icon: Icons.folder_open_rounded,
                  kind: EditorialButtonKind.ghost,
                  expand: true,
                  onPressed: _pickTorrentFile,
                ),
                const SizedBox(height: AppSpacing.xl),

                // Save path row
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.bgPage,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          border: Border.all(color: AppColors.line),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.folder_rounded,
                              size: AppIconSize.sm,
                              color: AppColors.fg2,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  MonoLabel(
                                    'SAVE TO',
                                    color: AppColors.fg3,
                                    letterSpacing: 0.08,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _savePath ?? 'Default',
                                    overflow: TextOverflow.ellipsis,
                                    style: AppType.ui(
                                      size: 13,
                                      color: AppColors.fg,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    EditorialButton(
                      label: 'Browse',
                      icon: Icons.folder_open_rounded,
                      kind: EditorialButtonKind.subtle,
                      onPressed: _pickSavePath,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),

                // Start immediately toggle
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.bgPage,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.play_arrow_rounded,
                        color: AppColors.fg1,
                        size: AppIconSize.sm,
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Text(
                          'Start immediately',
                          style: AppType.ui(size: 13, color: AppColors.fg),
                        ),
                      ),
                      Switch.adaptive(
                        value: _startImmediately,
                        activeThumbColor: AppColors.accent,
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
                  const SizedBox(height: AppSpacing.lg),
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: AppColors.err.withValues(alpha: 0.12),
                      border: Border.all(
                        color: AppColors.err.withValues(alpha: 0.5),
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          color: AppColors.err,
                          size: AppIconSize.sm,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            _error!,
                            style: AppType.ui(size: 12, color: AppColors.err),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: AppSpacing.xl),

                // Actions
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    EditorialButton(
                      label: 'Cancel',
                      kind: EditorialButtonKind.ghost,
                      onPressed: _isLoading
                          ? null
                          : () => Navigator.of(context).pop(false),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    EditorialButton(
                      label: _isLoading ? 'Adding…' : 'Add',
                      icon: _isLoading ? null : Icons.add_rounded,
                      kind: EditorialButtonKind.accent,
                      onPressed: _isLoading ? null : _addTorrent,
                    ),
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

/// Show the add torrent dialog
Future<bool?> showAddTorrentDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (context) => const AddTorrentDialog(),
  );
}
