import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../models/local_media_file.dart';
import '../models/torrentio_stream.dart';
import '../providers/connection_provider.dart'
    show connectionProvider, torrentEngineProvider;
import '../providers/navigation_provider.dart';
import '../providers/streaming_provider.dart';
import '../providers/torrent_provider.dart';
import '../services/app_logger.dart';
import '../services/library_actions.dart';
import '../services/streaming_service.dart';
import '../utils/feedback_utils.dart';
import '../utils/formatters.dart';
import '../utils/platform_utils.dart';
import '../widgets/player/player_error_overlay.dart';
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
    this.onTryAnotherSource,
  });

  /// What the overlay calls this thing — `"Interstellar"`, `S02E01`.
  /// Composed into "Starting X" / "Preparing X" / "Downloading X".
  final String label;

  /// Build the player route once a file is in hand.
  ///
  /// [session] is null when there is nothing to stream through: a finished
  /// file already on disk, or the fallback path where the session reached
  /// `ready` without a resolved `videoFile` and we located the file
  /// ourselves.
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

  /// Per-screen bookkeeping whenever a flow started here ends, however it
  /// ends — clearing a spinner flag, say. Includes the paths that never
  /// start a session at all.
  final VoidCallback? onSettled;

  /// The player was closed with "Try another source" after the stream
  /// failed — reopen the source picker. Only called while the screen is
  /// still mounted.
  final VoidCallback? onTryAnotherSource;
}

/// One stream started from a details screen, and what the user has asked
/// of it so far.
class _StreamAttempt {
  _StreamAttempt(this.target, {this.infoHash, this.torrentWasNew = false});

  final DetailsStreamTarget target;

  /// Lower-cased info hash, when known.
  final String? infoHash;

  /// The torrent was not in the engine before this stream added it — so
  /// cancelling may offer to remove it again. A torrent that was already
  /// there is the user's own download and is never offered for removal.
  final bool torrentWasNew;

  /// Null until the engine has accepted the torrent.
  String? sessionId;

  /// The overlay was hidden: keep preparing, never show it again.
  bool hidden = false;

  /// Cancel was pressed — possibly before [sessionId] existed.
  bool cancelled = false;

  /// Reached the player, failed, or ended. Later session updates are
  /// ignored: a `playing` after `ready` must not open a second player.
  bool settled = false;
}

/// Streaming orchestration for the movie / show details screens.
///
/// Both screens used to carry their own `_startStreamingSession`,
/// `_monitorStreamingSession`, `_handleSessionState`, `_openStreamingPlayer`
/// and `_findVideoFile` — around 200 near-identical lines whose only real
/// differences were the overlay strings and the `VideoPlayerScreen`
/// arguments. [startDetailsDownload] does the same for what the source
/// picker's buttons do — Play or Download — which both screens still
/// carried separately.
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

  /// The stream this screen is currently seeing through to the player.
  _StreamAttempt? _attempt;

  /// Tear down all three lifecycle pieces. Call from each screen's
  /// `dispose()` before `super.dispose()`.
  ///
  /// A stream still preparing keeps going: the app shell opens the player
  /// when it is ready, wherever the user is by then.
  void disposePlaybackController() {
    monitorSubscription?.close();
    monitorSubscription = null;
    _removeOverlay();
  }

  /// Drop the current overlay + data + subscription without disposing the
  /// State. Used when moving from one session to another, and on every
  /// terminal state.
  void dismissPlaybackOverlay() {
    monitorSubscription?.close();
    monitorSubscription = null;
    _removeOverlay();
  }

  void _removeOverlay() {
    streamingOverlay?.remove();
    streamingOverlay = null;
    streamingOverlayData?.dispose();
    streamingOverlayData = null;
  }

  // ---------------------------------------------------------------------
  // The source picker's two buttons
  // ---------------------------------------------------------------------

  /// What the source picker does with the [stream] the user chose: watch it
  /// now ([isStreaming]) or download it.
  ///
  /// Streaming plays [localFile] instead when it is a finished copy already
  /// on disk — pass it only if the caller has not just checked that itself.
  /// Otherwise it hands over to [startDetailsStream].
  ///
  /// Downloading adds the torrent and confirms with a way to Transfers.
  /// [onTorrentAdded] runs once the engine has accepted it, not awaited —
  /// the show screen uses it to pick one episode out of a season pack, which
  /// waits on the torrent's metadata.
  ///
  /// [DetailsStreamTarget.onSettled] runs on every way out of here that
  /// does not start a session, so a busy flag set before calling is always
  /// cleared.
  Future<void> startDetailsDownload({
    required TorrentioStream stream,
    required DetailsStreamTarget target,
    required bool isStreaming,
    LocalMediaFile? localFile,
    String? showImdbId,
    String? movieImdbId,
    String? episodeCode,
    String? savePath,
    Future<void> Function()? onTorrentAdded,
  }) async {
    final messenger = rootScaffoldMessengerKey.currentState;
    messenger?.hideCurrentSnackBar();

    if (!ref.read(connectionProvider).isConnected) {
      AppSnackBar.showOn(
        messenger,
        message:
            "MediaHub isn't connected to the torrent engine. Check "
            'Settings → Connection.',
        kind: AppSnackBarKind.warning,
      );
      target.onSettled?.call();
      return;
    }

    if (isStreaming) {
      if (localFile != null) {
        // Local first: a finished copy plays straight away. Re-adding the
        // magnet for a file the engine no longer tracks would start a fresh
        // download or a full recheck, and the overlay would wait on a buffer
        // that never fills. "Finished" matters — see [isFileCompleteOnDisk].
        final complete = await isFileCompleteOnDisk(ref, localFile);
        if (complete) {
          target.onSettled?.call();
          unawaited(_pushPlayer(target, localFile, null));
          return;
        }
        if (!mounted) {
          target.onSettled?.call();
          return;
        }
      }
      await startDetailsStream(
        stream: stream,
        target: target,
        showImdbId: showImdbId,
        movieImdbId: movieImdbId,
        episodeCode: episodeCode,
        savePath: savePath,
      );
      return;
    }

    final engine = ref.read(torrentEngineProvider);
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final added = await engine.addTorrent(
        magnetLink: stream.magnetUri,
        savePath: savePath,
        sequentialDownload: false,
      );
      if (!added) {
        AppSnackBar.showOn(
          messenger,
          message: "Couldn't start the download. Try another source.",
          kind: AppSnackBarKind.error,
        );
        return;
      }
      if (onTorrentAdded != null) unawaited(onTorrentAdded());

      final fromPack = stream.isSeasonPack
          ? ' from the ${target.packLabel}'
          : '';
      AppSnackBar.showOn(
        messenger,
        message: 'Downloading ${target.label}$fromPack.',
        kind: AppSnackBarKind.success,
        actionLabel: 'View transfers',
        onAction: () => _showTransfers(container),
      );
    } catch (e) {
      AppLog.e('[DetailsPlayback] download failed to start: $e');
      AppSnackBar.showOn(
        messenger,
        message:
            "Couldn't start the download. Make sure the torrent engine is "
            'running.',
        kind: AppSnackBarKind.error,
      );
    } finally {
      target.onSettled?.call();
    }
  }

  // ---------------------------------------------------------------------
  // Streaming
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
    final sessions = ref.read(streamingSessionsProvider.notifier);
    final container = ProviderScope.containerOf(context, listen: false);

    // A new pick supersedes a stream still preparing out of sight.
    final previous = _attempt;
    final previousSession = previous?.sessionId;
    if (previous != null &&
        !previous.cancelled &&
        !previous.settled &&
        previousSession != null) {
      previous.cancelled = true;
      unawaited(sessions.cancelSession(previousSession));
    }
    dismissPlaybackOverlay();

    final hash = stream.infoHash.toLowerCase();
    final attempt = _StreamAttempt(
      target,
      infoHash: hash,
      torrentWasNew: !ref
          .read(torrentListProvider)
          .torrents
          .any((t) => t.hash.toLowerCase() == hash),
    );
    _attempt = attempt;

    _presentOverlay(
      attempt,
      container,
      title: 'Starting ${target.label}',
      subtitle: stream.isSingleFile ? 'Connecting…' : 'Finding the right file…',
    );

    final session = await sessions.startStreaming(
      stream: stream,
      showImdbId: showImdbId,
      showName: target.showName,
      movieImdbId: movieImdbId,
      season: target.season,
      episode: target.episode,
      episodeCode: episodeCode,
      savePath: savePath,
    );

    if (attempt.cancelled) {
      // Cancel was pressed while the torrent was being added; the session
      // only exists now. (A newer pick cancelling this one lands here too.)
      if (session != null && identical(_attempt, attempt)) {
        unawaited(_stopAttempt(container, attempt, session.id));
      } else if (session != null) {
        unawaited(sessions.cancelSession(session.id));
      }
      return;
    }

    // The add is an HTTP round trip and the user can leave during it. Past
    // this point `ref` may be disposed — `listenManual` throws on a disposed
    // ref, and `OverlayEntry.remove()` asserts if the overlay is already
    // gone. The session itself carries on, and the app shell opens the
    // player when it is ready.
    if (!mounted) return;

    if (session == null) {
      dismissPlaybackOverlay();
      target.onSettled?.call();
      AppSnackBar.showOn(
        rootScaffoldMessengerKey.currentState,
        message:
            "Couldn't start streaming ${target.label}. Try another "
            'source.',
        kind: AppSnackBarKind.error,
      );
      return;
    }

    attempt.sessionId = session.id;
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
    var attempt = _attempt;
    if (attempt == null || !identical(attempt.target, target)) {
      attempt = _StreamAttempt(target);
      _attempt = attempt;
    }
    attempt.sessionId = sessionId;

    // Reached from an entry point that didn't open one — but never for a
    // stream the user has hidden or cancelled. Clicking ✕ while the torrent
    // was still being added used to pop a fresh "Preparing…" card the moment
    // the add finished.
    if (mounted &&
        streamingOverlay == null &&
        !attempt.hidden &&
        !attempt.cancelled) {
      _presentOverlay(
        attempt,
        ProviderScope.containerOf(context, listen: false),
        title: 'Preparing ${target.label}',
        subtitle: null,
      );
    }

    final watched = attempt;
    monitorSubscription?.close();
    monitorSubscription = ref.listenManual<StreamingSessionsState>(
      streamingSessionsProvider,
      (previous, next) {
        final session = next.sessions[sessionId];
        if (session == null) return;
        _handleDetailsSessionState(session, watched);
      },
      fireImmediately: true,
    );
  }

  void _handleDetailsSessionState(
    StreamingSession session,
    _StreamAttempt attempt,
  ) {
    if (attempt.cancelled || attempt.settled) return;
    final target = attempt.target;
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
            ? ' · ${Formatters.formatSpeed(speed)}'
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
        attempt.settled = true;
        dismissPlaybackOverlay();
        target.onSettled?.call();

        // Clear the active session so the safety-net listener in
        // main_navigation_screen doesn't push a second player on top.
        ref.read(streamingSessionsProvider.notifier).clearActiveSession();

        final videoFile = session.videoFile;
        if (videoFile != null) {
          unawaited(_pushPlayer(target, videoFile, session));
        } else if (session.contentPath != null) {
          unawaited(
            _openFromContentPath(
              session.contentPath!,
              target,
              torrentHash: session.torrentHash,
            ),
          );
        }

      case StreamingState.error:
        attempt.settled = true;
        dismissPlaybackOverlay();
        target.onSettled?.call();
        final reason =
            presentableStreamError(session.errorMessage) ??
            'Try another source.';
        AppSnackBar.showOn(
          rootScaffoldMessengerKey.currentState,
          message: "Couldn't stream ${target.label}. $reason",
          kind: AppSnackBarKind.error,
        );

      case StreamingState.cancelled:
        attempt.settled = true;
        dismissPlaybackOverlay();
        target.onSettled?.call();

      case StreamingState.idle:
        break;
    }
  }

  /// Open the player for [file], and reopen the source picker if it comes
  /// back with "Try another source".
  ///
  /// Through [rootNavigatorKey], not this screen's Navigator: the session may
  /// land after the screen is gone.
  Future<void> _pushPlayer(
    DetailsStreamTarget target,
    LocalMediaFile file,
    StreamingSession? session,
  ) async {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;
    final result = await navigator.push<Object?>(
      MaterialPageRoute<Object?>(
        builder: (_) => target.openPlayer(file, session),
      ),
    );
    if (result == PlayerExitReason.tryAnotherSource && mounted) {
      target.onTryAnotherSource?.call();
    }
  }

  // ---------------------------------------------------------------------
  // Overlay
  // ---------------------------------------------------------------------

  void _presentOverlay(
    _StreamAttempt attempt,
    ProviderContainer container, {
    required String title,
    required String? subtitle,
  }) {
    final result = showUpdatableStreamingOverlay(
      context,
      title: title,
      subtitle: subtitle,
      onHide: () => _hideAttempt(attempt),
      onCancel: () => _cancelAttempt(attempt, container),
      onViewTransfers: () {
        _hideAttempt(attempt);
        _showTransfers(container);
      },
    );
    streamingOverlay = result.entry;
    streamingOverlayData = result.data;
  }

  /// Keep preparing out of sight. The monitor stays, so the player still
  /// opens when the stream is ready; nothing brings the card back.
  void _hideAttempt(_StreamAttempt attempt) {
    attempt.hidden = true;
    if (identical(_attempt, attempt)) _removeOverlay();
  }

  /// Stop preparing. The session is cancelled now if the engine has
  /// accepted the torrent, or by [startDetailsStream] the moment it has.
  void _cancelAttempt(_StreamAttempt attempt, ProviderContainer container) {
    if (attempt.cancelled) return;
    attempt.cancelled = true;
    if (identical(_attempt, attempt)) dismissPlaybackOverlay();
    attempt.target.onSettled?.call();
    final sessionId = attempt.sessionId;
    if (sessionId != null) {
      unawaited(_stopAttempt(container, attempt, sessionId));
    }
  }

  /// Cancel [sessionId] and say so — offering to remove the download when
  /// this stream is what added it.
  ///
  /// Works from [container] rather than `ref`: it can finish after the
  /// screen is gone.
  Future<void> _stopAttempt(
    ProviderContainer container,
    _StreamAttempt attempt,
    String sessionId,
  ) async {
    try {
      await container
          .read(streamingSessionsProvider.notifier)
          .cancelSession(sessionId);
    } catch (e) {
      AppLog.e('[DetailsPlayback] cancelling $sessionId failed: $e');
    }
    final label = attempt.target.label;
    final hash = attempt.infoHash;
    final messenger = rootScaffoldMessengerKey.currentState;
    if (attempt.torrentWasNew && hash != null) {
      AppSnackBar.showOn(
        messenger,
        message:
            'Stopped streaming $label. Its download is still in '
            'Transfers.',
        actionLabel: 'Remove download',
        onAction: () => unawaited(_removeDownload(container, hash, label)),
      );
    } else {
      AppSnackBar.showOn(messenger, message: 'Stopped streaming $label.');
    }
  }

  Future<void> _removeDownload(
    ProviderContainer container,
    String hash,
    String label,
  ) async {
    final result = await container
        .read(torrentListProvider.notifier)
        .deleteTorrent(hash, deleteFiles: true);
    AppSnackBar.showOn(
      rootScaffoldMessengerKey.currentState,
      message: result.success
          ? 'Removed the download of $label.'
          : "Couldn't remove the download. Remove it from Transfers.",
      kind: result.success ? AppSnackBarKind.success : AppSnackBarKind.error,
    );
  }

  /// Switch to the Transfers tab, closing whatever is pushed over the shell.
  void _showTransfers(ProviderContainer container) {
    container.read(currentTabIndexProvider.notifier).show(AppTab.transfers);
    rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  // ---------------------------------------------------------------------
  // Fallback: find the file ourselves
  // ---------------------------------------------------------------------

  /// Reached only when a session turned `ready` without resolving its own
  /// `videoFile` — rare, since `_promoteToReady` errors instead. Opens the
  /// largest video under the torrent's content path, direct from disk.
  Future<void> _openFromContentPath(
    String contentPath,
    DetailsStreamTarget target, {
    String? torrentHash,
  }) async {
    final videoFile = await findLargestVideo(
      contentPath,
      target: target,
      torrentHash: torrentHash,
    );
    if (videoFile == null) {
      AppLog.w('[DetailsPlayback] no video under $contentPath');
      AppSnackBar.showOn(
        rootScaffoldMessengerKey.currentState,
        message: "Couldn't find the video in this download.",
        kind: AppSnackBarKind.error,
      );
      return;
    }
    await _pushPlayer(target, videoFile, null);
  }

  /// The largest video file at or under [contentPath], as a
  /// [LocalMediaFile] carrying [target]'s metadata.
  ///
  /// [torrentHash] travels with the file so library actions on it (delete,
  /// "is it complete?") resolve the owning torrent directly instead of
  /// searching every torrent's file list for it.
  Future<LocalMediaFile?> findLargestVideo(
    String contentPath, {
    DetailsStreamTarget? target,
    String? torrentHash,
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
        torrentHash: torrentHash,
      );
    } catch (e) {
      AppLog.e('[DetailsPlayback] Error finding video file: $e');
      return null;
    }
  }
}
