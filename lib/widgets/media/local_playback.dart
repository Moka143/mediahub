import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../models/local_media_file.dart';
import '../../models/streaming_session.dart';
import '../../models/watch_progress.dart';
import '../../providers/local_media_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/streaming_provider.dart';
import '../../screens/video_player_screen.dart';
import '../../services/library_actions.dart';
import '../../utils/feedback_utils.dart';

/// The library file a watch-progress entry refers to: the scanned one when
/// the scanner has it (it carries quality and size), otherwise one built
/// from the entry itself — a file the scanner has not picked up yet.
LocalMediaFile libraryFileForProgress(WidgetRef ref, WatchProgress progress) {
  final files = ref.read(localMediaFilesProvider).value ?? const [];
  for (final f in files) {
    if (f.path == progress.filePath) return f;
  }
  return LocalMediaFile.fromProgress(progress);
}

/// The running stream that is writing [file], if there is one.
StreamingSession? streamingSessionFor(
  StreamingSessionsState state,
  LocalMediaFile file,
) {
  for (final session in state.sessions.values) {
    if (session.isActive && session.videoFile?.path == file.path) {
      return session;
    }
  }
  return null;
}

/// Open [file] in the player — the one way the app plays something that is
/// already on disk.
///
/// Four play paths (Library ×2, the Home hero, the movie page's local Play)
/// used to push the player directly, skipping the completeness check that
/// exists for exactly this: qBittorrent pre-allocates a file at full size, so
/// a half-downloaded one *exists* — and mpv shows a black screen on its
/// zero-filled tail with no error. Now:
///   * finished on disk → play it;
///   * still downloading, but a stream of it is running → hand the player
///     that session, so it reads through the proxy instead of the zeros;
///   * otherwise → say why, with a way to Transfers.
Future<void> openLocalFile(
  BuildContext context,
  WidgetRef ref,
  LocalMediaFile file, {
  Duration? startPosition,
  String? showImdbId,
  String? movieImdbId,
}) async {
  // Captured up front: the snackbar action below can run after this widget
  // is gone, when its WidgetRef would throw.
  final container = ProviderScope.containerOf(context, listen: false);

  if (!File(file.path).existsSync()) {
    AppSnackBar.showWarning(
      context,
      message: '"${file.displayTitle}" isn\'t on disk any more.',
    );
    return;
  }

  final complete = await isFileCompleteOnDisk(ref, file);
  if (!context.mounted) return;

  final navigator = rootNavigatorKey.currentState ?? Navigator.of(context);
  if (complete) {
    unawaited(
      navigator.push(
        MaterialPageRoute(
          builder: (_) => VideoPlayerScreen.fromSession(
            file: file,
            startPosition: startPosition,
            showImdbId: showImdbId,
            movieImdbId: movieImdbId,
          ),
        ),
      ),
    );
    return;
  }

  final session = streamingSessionFor(
    container.read(streamingSessionsProvider),
    file,
  );
  if (session != null) {
    unawaited(
      navigator.push(
        MaterialPageRoute(
          builder: (_) => VideoPlayerScreen.fromSession(
            file: session.videoFile ?? file,
            session: session,
            startPosition: startPosition,
            showImdbId: showImdbId,
            movieImdbId: movieImdbId,
          ),
        ),
      ),
    );
    return;
  }

  AppSnackBar.showInfo(
    context,
    message: '"${file.displayTitle}" hasn\'t finished downloading yet.',
    actionLabel: 'Open Transfers',
    onAction: () {
      container.read(currentTabIndexProvider.notifier).show(AppTab.transfers);
      rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
    },
  );
}

/// Resume a Continue Watching entry at its saved position.
Future<void> resumeProgress(
  BuildContext context,
  WidgetRef ref,
  WatchProgress progress,
) => openLocalFile(
  context,
  ref,
  libraryFileForProgress(ref, progress),
  startPosition: progress.position,
);
