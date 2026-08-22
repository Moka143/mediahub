import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../models/local_media_file.dart';
import '../models/torrentio_stream.dart';
import '../providers/navigation_provider.dart';
import '../providers/streaming_provider.dart';
import '../services/app_logger.dart';
import '../services/streaming_service.dart';
import '../utils/feedback_utils.dart';
import '../utils/formatters.dart';
import '../utils/platform_utils.dart';
import '../widgets/streaming_progress_overlay.dart';

/// The parts of the streaming hand-off that genuinely differ between a movie
/// and an episode. Everything else is [DetailsPlaybackController]'s.
@immutable
class DetailsStreamTarget {
  const DetailsStreamTarget({
    required this.label,
    required this.openPlayer,
    this.packLabel = 'pack',
    this.showName,
    this.season,
    this.episode,
    this.onSettled,
  });

  /// What the overlay calls this thing — `Interstellar`, `S02E01`. Composed
  /// into "Starting X" / "Preparing X" / "Buffering X".
  final String label;

  /// Build the player route once a file is in hand.
  ///
  /// [session] is null on the fallback path, where the session reached
  /// `ready` without a resolved `videoFile` and we located the file
  /// ourselves — there is no proxy to hand over in that case.
  final Widget Function(LocalMediaFile file, StreamingSession? session)
  openPlayer;

  /// How to describe a multi-file torrent in the opening overlay. A show's
  /// packs really are season packs; a movie's are not.
  final String packLabel;

  /// Metadata for the fallback path, which has to synthesise a
  /// [LocalMediaFile] rather than being handed one.
  final String? showName;
  final int? season;
  final int? episode;

  /// Per-screen bookkeeping on every terminal transition — clearing a
  /// spinner flag, say.
  final VoidCallback? onSettled;
}

/// Streaming orchestration for the movie / show details screens.
///
/// Both screens used to carry their own `_startStreamingSession`,
/// `_monitorStreamingSession`, `_handleSessionState`, `_openStreamingPlayer`
/// and `_findVideoFile` — around 200 near-identical lines whose only real
/// differences were the overlay strings and the `VideoPlayerScreen`
/// arguments. This mixin previously held only the three lifecycle fields and
/// said the rest was future work; this is that work.
///
/// They had already drifted: the show's failure path removed the overlay
/// without disposing its `ValueNotifier`, and only the movie cleared its
/// `_isStreaming` flag. Both now go through [dismissPlaybackOverlay] and
/// [DetailsStreamTarget.onSettled].
mixin DetailsPlaybackController<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// Floating overlay showing buffering / ready progress.
  OverlayEntry? streamingOverlay;

  /// Live state behind [streamingOverlay] — mutate to update the overlay
  /// in-place without rebuilding it.
  ValueNotifier<StreamingOverlayData>? streamingOverlayData;

  /// Subscription to `streamingSessionsProvider` — `listenManual` rather than
  /// `ref.listen` so it survives a rebuild of the screen; re-created
  /// explicitly when a new session starts.
  ProviderSubscription<StreamingSessionsState>? monitorSubscription;

  /// Tear down all three lifecycle pieces. Call from each screen's
  /// `dispose()` before `super.dispose()`.
  void disposePlaybackController() {
    monitorSubscription?.close();
    streamingOverlay?.remove();
    streamingOverlayData?.dispose();
  }

  /// Drop the current overlay + data + subscription without disposing the
  /// State. Used when moving from one session to another, and on every
  /// terminal state.
  void dismissPlaybackOverlay() {
    monitorSubscription?.close();
    monitorSubscription = null;
    streamingOverlay?.remove();
    streamingOverlay = null;
    streamingOverlayData?.dispose();
    streamingOverlayData = null;
  }

  // ---------------------------------------------------------------------
  // Orchestration
  // ---------------------------------------------------------------------

  /// Start a streaming session and drive it through to the player.
  Future<void> startDetailsStream({
    required TorrentioStream stream,
    required DetailsStreamTarget target,
    String? showImdbId,
    String? movieImdbId,
    String? episodeCode,
    String? savePath,
  }) async {
    dismissPlaybackOverlay();
    _presentOverlay(
      title: 'Starting ${target.label}',
      subtitle: stream.isSingleFile
          ? 'Connecting...'
          : 'Selecting from ${target.packLabel}...',
    );

    final session = await ref
        .read(streamingSessionsProvider.notifier)
        .startStreaming(
          stream: stream,
          showImdbId: showImdbId,
          showName: target.showName,
          movieImdbId: movieImdbId,
          season: target.season,
          episode: target.episode,
          episodeCode: episodeCode,
          savePath: savePath,
        );

    if (session == null) {
      dismissPlaybackOverlay();
      target.onSettled?.call();
      AppSnackBar.showOn(
        rootScaffoldMessengerKey.currentState,
        message: 'Failed to start streaming session',
        kind: AppSnackBarKind.error,
      );
      return;
    }

    monitorDetailsStream(session.id, target);
  }

  /// Watch a session through to a terminal state.
  ///
  /// Listens to the *notifier's* state rather than the streaming service's
  /// broadcast stream: the notifier already subscribes once and re-publishes,
  /// so watching it cannot miss the transitions that happen between
  /// `startStreaming()` returning and the UI subscribing. `fireImmediately`
  /// covers a session that has already reached `ready` via the fast path.
  void monitorDetailsStream(String sessionId, DetailsStreamTarget target) {
    if (mounted && streamingOverlayData == null) {
      // Reached from an entry point that didn't open one.
      _presentOverlay(title: 'Preparing ${target.label}', subtitle: null);
    }

    monitorSubscription?.close();
    monitorSubscription = ref.listenManual<StreamingSessionsState>(
      streamingSessionsProvider,
      (previous, next) {
        final session = next.sessions[sessionId];
        if (session == null) return;
        _handleDetailsSessionState(session, target);
      },
      fireImmediately: true,
    );
  }

  void _handleDetailsSessionState(
    StreamingSession session,
    DetailsStreamTarget target,
  ) {
    switch (session.state) {
      case StreamingState.addingTorrent:
      case StreamingState.selectingFiles:
      case StreamingState.buffering:
        // Update in place — no remove/recreate, no flicker. Always show the
        // real percentage so there is visible motion during the metadata and
        // file-selection phases too.
        final pct = session.bufferProgress * 100;
        final speed = session.downloadRateBytesPerSec;
        final speedSuffix = speed > 0
            ? ' • ${Formatters.formatSpeed(speed)}'
            : '';
        final verb = session.state == StreamingState.buffering
            ? 'Buffering'
            : 'Preparing';
        streamingOverlayData?.value = StreamingOverlayData(
          title: '$verb ${target.label}',
          subtitle: pct > 0
              ? '${pct.toStringAsFixed(1)}% downloaded$speedSuffix'
              : 'Connecting…$speedSuffix',
          progress: pct > 0 ? session.bufferProgress : null,
          isIndeterminate: pct == 0,
        );

      case StreamingState.ready:
      case StreamingState.playing:
        dismissPlaybackOverlay();
        target.onSettled?.call();

        // Clear the active session so the safety-net listener in
        // main_navigation_screen doesn't push a second player on top.
        ref.read(streamingSessionsProvider.notifier).clearActiveSession();

        final videoFile = session.videoFile;
        if (videoFile != null) {
          // rootNavigatorKey, not this screen's Navigator: the session may
          // land after the screen is gone.
          rootNavigatorKey.currentState?.push(
            MaterialPageRoute(
              builder: (_) => target.openPlayer(videoFile, session),
            ),
          );
        } else if (session.contentPath != null) {
          _openFromContentPath(session.contentPath!, target);
        }

      case StreamingState.error:
        dismissPlaybackOverlay();
        target.onSettled?.call();
        AppSnackBar.showOn(
          rootScaffoldMessengerKey.currentState,
          message:
              'Streaming error: ${session.errorMessage ?? "Failed to stream"}',
          kind: AppSnackBarKind.error,
        );

      case StreamingState.cancelled:
        dismissPlaybackOverlay();
        target.onSettled?.call();

      case StreamingState.idle:
        break;
    }
  }

  // ---------------------------------------------------------------------
  // Overlay
  // ---------------------------------------------------------------------

  void _presentOverlay({required String title, required String? subtitle}) {
    final containerRef = ProviderScope.containerOf(context);
    final result = showUpdatableStreamingOverlay(
      context,
      title: title,
      subtitle: subtitle,
      isIndeterminate: true,
      showClose: true,
      onClose: () {
        streamingOverlay = null;
        streamingOverlayData = null;
      },
      onViewDownloads: () {
        dismissPlaybackOverlay();
        containerRef.read(currentTabIndexProvider.notifier).set(1);
        rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
      },
    );
    streamingOverlay = result.entry;
    streamingOverlayData = result.data;
  }

  // ---------------------------------------------------------------------
  // Fallback: find the file ourselves
  // ---------------------------------------------------------------------

  /// Reached only when a session turned `ready` without resolving its own
  /// `videoFile` — rare, since `_promoteToReady` errors instead. Opens the
  /// largest video under qBittorrent's content path, direct from disk.
  Future<void> _openFromContentPath(
    String contentPath,
    DetailsStreamTarget target,
  ) async {
    final videoFile = await findLargestVideo(contentPath, target: target);
    if (videoFile == null) {
      AppSnackBar.showOn(
        rootScaffoldMessengerKey.currentState,
        message: 'Could not find video file in: $contentPath',
        kind: AppSnackBarKind.error,
      );
      return;
    }
    rootNavigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => target.openPlayer(videoFile, null)),
    );
  }

  /// The largest video file at or under [contentPath], as a
  /// [LocalMediaFile] carrying [target]'s metadata.
  Future<LocalMediaFile?> findLargestVideo(
    String contentPath, {
    DetailsStreamTarget? target,
  }) async {
    try {
      final entityType = FileSystemEntity.typeSync(contentPath);
      final videoFiles = <File>[];

      bool isVideo(String path) =>
          videoExtensions.contains(path.split('.').last.toLowerCase());

      if (entityType == FileSystemEntityType.file) {
        if (isVideo(contentPath)) videoFiles.add(File(contentPath));
      } else if (entityType == FileSystemEntityType.directory) {
        await for (final entity in Directory(
          contentPath,
        ).list(recursive: true)) {
          if (entity is File && isVideo(entity.path)) videoFiles.add(entity);
        }
      }

      if (videoFiles.isEmpty) return null;

      // Largest is the main content; the rest are samples and extras.
      videoFiles.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
      final largest = videoFiles.first;
      final stat = largest.statSync();

      return LocalMediaFile(
        path: largest.path,
        fileName: basenameOf(largest.path),
        sizeBytes: stat.size,
        modifiedDate: stat.modified,
        extension: largest.path.split('.').last.toLowerCase(),
        showName: target?.showName,
        seasonNumber: target?.season,
        episodeNumber: target?.episode,
      );
    } catch (e) {
      AppLog.e('[DetailsPlayback] Error finding video file: $e');
      return null;
    }
  }
}
