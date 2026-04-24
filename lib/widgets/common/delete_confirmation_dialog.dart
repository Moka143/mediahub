import 'package:flutter/material.dart';

import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';

/// A reusable delete confirmation dialog with consistent styling
class DeleteConfirmationDialog extends StatelessWidget {
  const DeleteConfirmationDialog({
    super.key,
    required this.title,
    required this.message,
    this.deleteButtonText = 'Delete',
    this.cancelButtonText = 'Cancel',
    this.deleteWithFiles = false,
    this.showDeleteFilesOption = false,
    this.onDeleteWithFilesChanged,
    this.icon = Icons.delete_outline,
  });

  final String title;
  final String message;
  final String deleteButtonText;
  final String cancelButtonText;
  final bool deleteWithFiles;
  final bool showDeleteFilesOption;
  final ValueChanged<bool>? onDeleteWithFilesChanged;
  final IconData icon;

  /// Show the dialog and return true if user confirms deletion
  static Future<bool?> show({
    required BuildContext context,
    required String title,
    required String message,
    String deleteButtonText = 'Delete',
    String cancelButtonText = 'Cancel',
    bool showDeleteFilesOption = false,
    IconData icon = Icons.delete_outline,
  }) async {
    bool deleteWithFiles = false;

    return showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => DeleteConfirmationDialog(
          title: title,
          message: message,
          deleteButtonText: deleteButtonText,
          cancelButtonText: cancelButtonText,
          deleteWithFiles: deleteWithFiles,
          showDeleteFilesOption: showDeleteFilesOption,
          icon: icon,
          onDeleteWithFilesChanged: showDeleteFilesOption
              ? (value) => setState(() => deleteWithFiles = value)
              : null,
        ),
      ),
    );
  }

  /// Show the dialog for torrent deletion specifically
  static Future<({bool confirmed, bool deleteFiles})?> showForTorrent({
    required BuildContext context,
    required String torrentName,
  }) async {
    bool deleteWithFiles = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => DeleteConfirmationDialog(
          title: 'Delete Torrent',
          message: 'Are you sure you want to delete "$torrentName"?',
          deleteWithFiles: deleteWithFiles,
          showDeleteFilesOption: true,
          icon: Icons.delete_outline,
          onDeleteWithFilesChanged: (value) =>
              setState(() => deleteWithFiles = value),
        ),
      ),
    );

    if (confirmed == true) {
      return (confirmed: true, deleteFiles: deleteWithFiles);
    }
    return null;
  }

  /// Show the dialog for deleting multiple torrents
  static Future<({bool confirmed, bool deleteFiles})?> showForTorrents({
    required BuildContext context,
    required int torrentCount,
  }) async {
    bool deleteWithFiles = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => DeleteConfirmationDialog(
          title: 'Delete Torrents',
          message: 'Are you sure you want to delete $torrentCount torrents?',
          deleteWithFiles: deleteWithFiles,
          showDeleteFilesOption: true,
          icon: Icons.delete_outline,
          onDeleteWithFilesChanged: (value) =>
              setState(() => deleteWithFiles = value),
        ),
      ),
    );

    if (confirmed == true) {
      return (confirmed: true, deleteFiles: deleteWithFiles);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return AlertDialog(
      icon: Icon(
        icon,
        color: appColors.errorState,
        size: AppIconSize.xl,
      ),
      title: Text(
        title,
        textAlign: TextAlign.center,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (showDeleteFilesOption) ...[
            const SizedBox(height: AppSpacing.lg),
            CheckboxListTile(
              value: deleteWithFiles,
              onChanged: (value) =>
                  onDeleteWithFilesChanged?.call(value ?? false),
              title: Text(
                'Also delete files',
                style: theme.textTheme.bodyMedium,
              ),
              subtitle: Text(
                'Permanently remove downloaded files',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: appColors.mutedText,
                ),
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ],
        ],
      ),
      actionsAlignment: MainAxisAlignment.spaceEvenly,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelButtonText),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: appColors.errorState,
            foregroundColor: Colors.white,
          ),
          child: Text(deleteButtonText),
        ),
      ],
    );
  }
}
