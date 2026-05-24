import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import 'mediahub_confirm_dialog.dart';

/// Reusable delete-confirmation entry points. Renders the editorial
/// [MediaHubConfirmDialog] with a destructive accent and an optional
/// "Also delete files" checkbox.
///
/// This is API-compatible with the previous `AlertDialog`-based
/// implementation — the static `show*` helpers still return the same
/// shape so call sites don't change.
class DeleteConfirmationDialog {
  DeleteConfirmationDialog._();

  /// Show a generic confirm prompt and return true if the user
  /// confirms deletion. The optional `withFiles` checkbox is only
  /// rendered when [showDeleteFilesOption] is true — its value is
  /// returned via [showForTorrent] / [showForTorrents].
  static Future<bool?> show({
    required BuildContext context,
    required String title,
    required String message,
    String deleteButtonText = 'Delete',
    String cancelButtonText = 'Cancel',
    IconData icon = Icons.delete_outline,
  }) {
    return MediaHubConfirmDialog.show(
      context: context,
      title: title,
      message: message,
      confirmLabel: deleteButtonText,
      cancelLabel: cancelButtonText,
      destructive: true,
      icon: icon,
    );
  }

  /// Confirm deletion of a single torrent. Returns null on cancel.
  static Future<({bool confirmed, bool deleteFiles})?> showForTorrent({
    required BuildContext context,
    required String torrentName,
  }) {
    return _showWithDeleteFiles(
      context: context,
      title: 'Delete Torrent',
      message: 'Are you sure you want to delete "$torrentName"?',
    );
  }

  /// Confirm deletion of a batch of torrents.
  static Future<({bool confirmed, bool deleteFiles})?> showForTorrents({
    required BuildContext context,
    required int torrentCount,
  }) {
    return _showWithDeleteFiles(
      context: context,
      title: 'Delete Torrents',
      message: 'Are you sure you want to delete $torrentCount torrents?',
    );
  }

  static Future<({bool confirmed, bool deleteFiles})?> _showWithDeleteFiles({
    required BuildContext context,
    required String title,
    required String message,
  }) async {
    final notifier = ValueNotifier<bool>(false);

    final confirmed = await MediaHubConfirmDialog.show(
      context: context,
      title: title,
      message: message,
      confirmLabel: 'Delete',
      destructive: true,
      icon: Icons.delete_outline,
      extraContent: _DeleteFilesCheckbox(value: notifier),
    );

    final result = confirmed == true
        ? (confirmed: true, deleteFiles: notifier.value)
        : null;
    notifier.dispose();
    return result;
  }
}

class _DeleteFilesCheckbox extends StatefulWidget {
  const _DeleteFilesCheckbox({required this.value});
  final ValueNotifier<bool> value;

  @override
  State<_DeleteFilesCheckbox> createState() => _DeleteFilesCheckboxState();
}

class _DeleteFilesCheckboxState extends State<_DeleteFilesCheckbox> {
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      onTap: () => setState(() => widget.value.value = !widget.value.value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: widget.value.value,
              onChanged: (v) => setState(() => widget.value.value = v ?? false),
              activeColor: AppColors.err,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Also delete files',
                    style: AppType.ui(
                      size: 14,
                      color: AppColors.fg,
                      weight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Permanently remove downloaded files',
                    style: AppType.ui(size: 12, color: AppColors.fg2),
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
