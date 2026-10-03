import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/local_media_file.dart';
import '../../models/watch_progress.dart';
import '../../providers/watch_progress_provider.dart';
import '../../services/app_logger.dart';
import '../../services/library_actions.dart';
import '../../utils/feedback_utils.dart';
import '../common/mediahub_confirm_dialog.dart';
import '../media/local_playback.dart';
import '../media/poster_lookup.dart';

/// What a library card can do.
///
/// Built once per screen and handed down whole. The Library used to thread
/// the same seven callbacks through three widget layers — fourteen fields on
/// one of them — and Home's Continue Watching row, which wanted three of
/// them, had none.
@immutable
class LibraryActions {
  const LibraryActions({
    required this.playFile,
    required this.playProgress,
    required this.removeProgress,
    required this.markWatched,
    required this.markNotWatched,
    required this.deleteFile,
  });

  /// The app's standard behaviour for each action, bound to the screen that
  /// owns [context] and [ref].
  factory LibraryActions.standard(BuildContext context, WidgetRef ref) {
    void run(String failure, Future<void> Function() action) =>
        unawaited(_guarded(context, failure, action));
    return LibraryActions(
      playFile: (file) => run(
        'open "${file.displayTitle}"',
        () => openLocalFile(context, ref, file),
      ),
      playProgress: (p) => run(
        'resume "${watchProgressTitle(p)}"',
        () => resumeProgress(context, ref, p),
      ),
      removeProgress: (p) => run(
        'remove "${watchProgressTitle(p)}" from Continue Watching',
        () => _removeProgress(context, ref, p),
      ),
      markWatched: (file) => run(
        'mark "${file.displayTitle}" as watched',
        () => _markWatched(context, ref, file),
      ),
      markNotWatched: (file) => run(
        'mark "${file.displayTitle}" as not watched',
        () => _markNotWatched(context, ref, file),
      ),
      deleteFile: (file) => run(
        'delete "${file.displayTitle}"',
        () => _deleteFile(context, ref, file),
      ),
    );
  }

  final ValueChanged<LocalMediaFile> playFile;
  final ValueChanged<WatchProgress> playProgress;
  final ValueChanged<WatchProgress> removeProgress;
  final ValueChanged<LocalMediaFile> markWatched;
  final ValueChanged<LocalMediaFile> markNotWatched;
  final ValueChanged<LocalMediaFile> deleteFile;

  /// The file a Continue Watching entry is about, for the actions that work
  /// on files — mark watched and delete.
  LocalMediaFile fileFor(WidgetRef ref, WatchProgress progress) =>
      libraryFileForProgress(ref, progress);
}

/// Run one action so a failure — a provider gone with its screen, a disk
/// error — is logged and said, rather than left as an uncaught error.
Future<void> _guarded(
  BuildContext context,
  String failure,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    AppLog.w('[Library] could not $failure: $e');
    if (context.mounted) {
      AppSnackBar.showError(context, message: "Couldn't $failure.");
    }
  }
}

Future<void> _removeProgress(
  BuildContext context,
  WidgetRef ref,
  WatchProgress progress,
) async {
  final title = watchProgressTitle(progress);
  final confirmed = await MediaHubConfirmDialog.show(
    context: context,
    title: 'Remove from Continue Watching?',
    message:
        '"$title" leaves the Continue Watching row. The file stays in '
        'your library.',
    confirmLabel: 'Remove',
  );
  if (confirmed != true || !context.mounted) return;
  // Awaited: the confirmation below claims the removal happened, so it must
  // actually have been persisted before it says so.
  await ref
      .read(watchProgressProvider.notifier)
      .clearProgress(progress.filePath);
  if (!context.mounted) return;
  AppSnackBar.showInfo(context, message: 'Removed from Continue Watching');
}

Future<void> _markWatched(
  BuildContext context,
  WidgetRef ref,
  LocalMediaFile file,
) async {
  await markAsWatched(ref, file, tmdbShowId: file.showId);
  if (!context.mounted) return;
  AppSnackBar.showInfo(
    context,
    message: 'Marked "${file.displayTitle}" as watched',
  );
}

Future<void> _markNotWatched(
  BuildContext context,
  WidgetRef ref,
  LocalMediaFile file,
) async {
  await markAsNotWatched(ref, file);
  if (!context.mounted) return;
  AppSnackBar.showInfo(
    context,
    message: 'Marked "${file.displayTitle}" as not watched',
  );
}

/// What a delete will take with it, said before it happens.
@visibleForTesting
String deleteConfirmationMessage(LibraryDeleteScope scope, String title) =>
    switch (scope) {
      LibraryDeleteScope.wholeTorrent =>
        'This deletes "$title" from disk and removes its download from '
            'Transfers.',
      LibraryDeleteScope.fileInPack =>
        'Delete this episode only — the rest of the season pack stays in '
            'Transfers.',
      LibraryDeleteScope.fileOnly => 'This deletes "$title" from disk.',
    };

Future<void> _deleteFile(
  BuildContext context,
  WidgetRef ref,
  LocalMediaFile file,
) async {
  final title = file.displayTitle;

  // Already gone — a Continue Watching entry can outlive its file. There is
  // nothing to delete; drop the entry so the card stops offering it.
  if (!File(file.path).existsSync()) {
    await ref.read(watchProgressProvider.notifier).clearProgress(file.path);
    if (!context.mounted) return;
    AppSnackBar.showInfo(
      context,
      message: '"$title" was already gone — removed it from the list.',
    );
    return;
  }

  final scope = await planLibraryDelete(ref, file);
  if (!context.mounted) return;
  final confirmed = await MediaHubConfirmDialog.show(
    context: context,
    title: scope == LibraryDeleteScope.fileInPack
        ? 'Delete this episode?'
        : 'Delete file?',
    message: deleteConfirmationMessage(scope, title),
    confirmLabel: 'Delete',
    destructive: true,
    icon: Icons.delete_outline_rounded,
  );
  if (confirmed != true || !context.mounted) return;

  final result = await deleteLibraryItem(ref, file);
  if (!context.mounted) return;
  if (result.success) {
    AppSnackBar.showInfo(
      context,
      message: switch (result.scope) {
        LibraryDeleteScope.fileInPack =>
          'Deleted "$title" — the rest of the season pack stays in Transfers',
        _ when result.torrentRemoved => 'Deleted "$title" and its download',
        _ => 'Deleted "$title"',
      },
    );
  } else {
    // describeDeleteFailure already words the common causes for people
    // ("the file is still in use — stop the torrent and try again").
    final why = result.error;
    AppSnackBar.showError(
      context,
      message: why == null || why.contains('Exception')
          ? 'Couldn\'t delete "$title".'
          : 'Couldn\'t delete "$title": $why',
    );
  }
}
