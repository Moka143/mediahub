import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/torrent_action_result.dart';
import '../../providers/torrent_provider.dart';
import '../../utils/error_messages.dart';
import '../../utils/feedback_utils.dart';
import '../common/delete_confirmation_dialog.dart';

/// Something the user can do to a transfer from the list or its details.
enum TransferAction {
  pause('pause'),
  resume('resume'),
  recheck('recheck'),
  reannounce('reannounce'),
  delete('delete');

  const TransferAction(this.verb);

  /// Lower-case verb for "Couldn't … this transfer."
  final String verb;
}

/// Why a transfer action did not go through, in the terms the advice
/// depends on.
enum TransferFailure {
  /// Nothing answered.
  unreachable,

  /// It answered too late.
  slow,

  /// qBittorrent turned the login down.
  rejectedLogin,

  /// The engine no longer has that torrent.
  gone,

  /// The engine answered with an error of its own.
  engineError,

  /// The engine said no, or something nobody anticipated happened.
  unknown,
}

/// Classify the cause a [TorrentActionResult] carries.
///
/// That cause is engine wording, and its last-resort branch is an
/// exception's own text — fine for the log, never for the screen — so it is
/// read here, once, for the list rows, the details pane and the add dialog.
TransferFailure classifyTransferFailure(String? cause) {
  if (cause == null || cause.trim().isEmpty) return TransferFailure.unknown;
  final lower = cause.toLowerCase();
  bool mentions(List<String> needles) => needles.any(lower.contains);
  if (mentions(['cannot reach', "can't reach", 'not running', 'unreachable'])) {
    return TransferFailure.unreachable;
  }
  if (mentions(["didn't answer in time", 'took too long'])) {
    return TransferFailure.slow;
  }
  if (mentions(['reported an error'])) return TransferFailure.engineError;
  return switch (classifyFailure(cause)) {
    FailureKind.offline => TransferFailure.unreachable,
    FailureKind.timeout => TransferFailure.slow,
    FailureKind.unauthorized => TransferFailure.rejectedLogin,
    FailureKind.notFound => TransferFailure.gone,
    FailureKind.serviceDown => TransferFailure.engineError,
    FailureKind.unknown => TransferFailure.unknown,
  };
}

/// One plain sentence saying why a transfer action did not go through.
String transferFailureReason(String? cause) =>
    switch (classifyTransferFailure(cause)) {
      TransferFailure.unreachable =>
        "The torrent engine isn't reachable right now.",
      TransferFailure.slow => 'The torrent engine took too long to answer.',
      TransferFailure.rejectedLogin =>
        'The torrent engine turned down the login. Check it in Settings.',
      TransferFailure.gone => 'The engine no longer has this transfer.',
      TransferFailure.engineError =>
        'The torrent engine ran into a problem. Try again in a moment.',
      TransferFailure.unknown => 'Try again in a moment.',
    };

/// "Couldn't pause this transfer. The torrent engine isn't reachable right
/// now." — what a failed [action] on [count] transfers tells the user.
String transferActionFailure(
  TransferAction action,
  TorrentActionResult result, {
  int count = 1,
}) {
  final what = count == 1 ? 'this transfer' : '$count transfers';
  return "Couldn't ${action.verb} $what. ${transferFailureReason(result.error)}";
}

/// Run [call] and report how it went: an error snackbar on failure, and
/// [successMessage] (when given) on success. Returns whether it succeeded.
///
/// The messenger is captured before the await. The widget that asked may be
/// gone by the time the engine answers — the row of a torrent that was just
/// deleted, a details pane whose selection moved on — and the outcome still
/// deserves to be heard.
Future<bool> runTransferAction(
  BuildContext context, {
  required TransferAction action,
  required Future<TorrentActionResult> Function() call,
  int count = 1,
  String? successMessage,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  TorrentActionResult result;
  try {
    result = await call();
  } catch (e) {
    result = TorrentActionResult.failure('$e');
  }
  if (!result.success) {
    AppSnackBar.showOn(
      messenger,
      message: transferActionFailure(action, result, count: count),
      kind: AppSnackBarKind.error,
    );
  } else if (successMessage != null) {
    AppSnackBar.showOn(
      messenger,
      message: successMessage,
      kind: AppSnackBarKind.success,
    );
  }
  return result.success;
}

/// Ask, then delete [hashes]. Returns true once they are gone.
///
/// [name] words the prompt and the confirmation for a single transfer.
/// Everything that outlives the dialog — the notifier and the messenger — is
/// read before the first await, so this is safe to call from a widget that
/// the deletion itself removes from the tree.
Future<bool> confirmAndDeleteTransfers(
  BuildContext context,
  WidgetRef ref, {
  required List<String> hashes,
  String? name,
}) async {
  if (hashes.isEmpty) return false;
  final notifier = ref.read(torrentListProvider.notifier);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final single = hashes.length == 1 && name != null;

  final choice = single
      ? await DeleteConfirmationDialog.showForTorrent(
          context: context,
          torrentName: name,
        )
      : await DeleteConfirmationDialog.showForTorrents(
          context: context,
          torrentCount: hashes.length,
        );
  if (choice == null || !choice.confirmed) return false;

  TorrentActionResult result;
  try {
    result = await notifier.deleteTorrents(
      hashes,
      deleteFiles: choice.deleteFiles,
    );
  } catch (e) {
    result = TorrentActionResult.failure('$e');
  }

  if (result.success) {
    final what = single ? '“$name”' : '${hashes.length} transfers';
    AppSnackBar.showOn(
      messenger,
      message: choice.deleteFiles
          ? 'Deleted $what and the downloaded files'
          : 'Deleted $what',
      kind: AppSnackBarKind.success,
    );
  } else {
    AppSnackBar.showOn(
      messenger,
      message: transferActionFailure(
        TransferAction.delete,
        result,
        count: hashes.length,
      ),
      kind: AppSnackBarKind.error,
    );
  }
  return result.success;
}
