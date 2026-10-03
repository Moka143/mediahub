import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_typography.dart';
import 'mediahub_confirm_dialog.dart';

/// Confirmation for removing torrents from Transfers, with the "Also delete
/// files" choice. Built on [MediaHubConfirmDialog], the one confirm shell;
/// any other destructive prompt should use that directly.
class DeleteConfirmationDialog {
  DeleteConfirmationDialog._();

  /// The sentence every variant ends with. Deleting files is opt-in, and the
  /// dialog used to leave that unsaid — "Delete torrent?" reads as if the
  /// download goes too.
  static const String filesKeptNote =
      'Files on disk are kept unless you tick "Also delete files".';

  /// Confirm deletion of a single torrent. Returns null on cancel.
  static Future<({bool confirmed, bool deleteFiles})?> showForTorrent({
    required BuildContext context,
    required String torrentName,
  }) {
    return _showWithDeleteFiles(
      context: context,
      title: 'Delete torrent?',
      message: '"$torrentName" will be removed from Transfers. $filesKeptNote',
    );
  }

  /// Confirm deletion of a batch of torrents. Returns null on cancel.
  static Future<({bool confirmed, bool deleteFiles})?> showForTorrents({
    required BuildContext context,
    required int torrentCount,
  }) {
    final one = torrentCount == 1;
    return _showWithDeleteFiles(
      context: context,
      title: one ? 'Delete 1 torrent?' : 'Delete $torrentCount torrents?',
      message:
          '${one ? 'It' : 'They'} will be removed from Transfers. '
          '$filesKeptNote',
    );
  }

  static Future<({bool confirmed, bool deleteFiles})?> _showWithDeleteFiles({
    required BuildContext context,
    required String title,
    required String message,
  }) async {
    final deleteFiles = ValueNotifier<bool>(false);

    final confirmed = await MediaHubConfirmDialog.show(
      context: context,
      title: title,
      message: message,
      confirmLabel: 'Delete',
      destructive: true,
      icon: Icons.delete_outline,
      extraContent: _DeleteFilesCheckbox(value: deleteFiles),
    );

    final result = confirmed == true
        ? (confirmed: true, deleteFiles: deleteFiles.value)
        : null;
    deleteFiles.dispose();
    return result;
  }
}

class _DeleteFilesCheckbox extends StatelessWidget {
  const _DeleteFilesCheckbox({required this.value});
  final ValueNotifier<bool> value;

  @override
  Widget build(BuildContext context) {
    // One control, not an InkWell wrapped around a Checkbox: the old pair
    // put two stops in the focus order for one choice.
    return ValueListenableBuilder<bool>(
      valueListenable: value,
      builder: (context, checked, _) => CheckboxListTile(
        value: checked,
        onChanged: (v) => value.value = v ?? false,
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        dense: true,
        activeColor: AppColors.err,
        title: Text(
          'Also delete files',
          style: AppType.ui(
            size: AppType.sizeLead,
            color: AppColors.fg,
            weight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          'Permanently remove the downloaded files from disk',
          style: AppType.caption(),
        ),
      ),
    );
  }
}
