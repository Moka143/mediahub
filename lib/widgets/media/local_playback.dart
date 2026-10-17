import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../models/local_media_file.dart';
import '../../models/stream_request.dart';
import '../../models/streaming_session.dart';
import '../../models/watch_progress.dart';
import '../../providers/local_media_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/streaming_provider.dart';
import '../../screens/video_player_screen.dart';
import '../../services/app_logger.dart';
import '../../services/library_actions.dart';
import '../../utils/feedback_utils.dart';
import '../../utils/media_names.dart';
import '../player/player_error_overlay.dart';
import '../streaming_progress_overlay.dart';

/// Builds the player page — [VideoPlayerScreen.fromSession]'s shape, so
/// widget tests, which have no mpv, can stand in a page of their own.
typedef PlayerPageBuilder =
    Widget Function({
      Key? key,
      required LocalMediaFile file,
      StreamingSession? session,
      String? showImdbId,
      String? movieImdbId,
      Duration? startPosition,
    });

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
///   * still downloading with no stream running — a title that was
///     streamed, then closed, since closing the player ends its session but
///     not its torrent → stream it again from that torrent;
///   * otherwise → say why, with a way to Transfers.
Future<void> openLocalFile(
  BuildContext context,
  WidgetRef ref,
  LocalMediaFile file, {
  Duration? startPosition,
  String? showImdbId,
  String? movieImdbId,
  @visibleForTesting
  PlayerPageBuilder openPlayer = VideoPlayerScreen.fromSession,
}) async {
  // Captured up front: the snackbar action below can run after this widget
  // is gone, when its WidgetRef would throw.
  final container = ProviderScope.containerOf(context, listen: false);

  final complete = await isFileCompleteOnDisk(ref, file);
  if (!context.mounted) return;

  final navigator = rootNavigatorKey.currentState ?? Navigator.of(context);
  if (complete) {
    unawaited(
      navigator.push(
        MaterialPageRoute(
          builder: (_) => openPlayer(
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
          builder: (_) => openPlayer(
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

  final request = await streamRequestForIncompleteFile(ref, file);
  if (!context.mounted) return;
  if (request != null) {
    await _StreamAgain(
      container: container,
      file: file,
      request: request,
      startPosition: startPosition,
      showImdbId: showImdbId,
      movieImdbId: movieImdbId,
      openPlayer: openPlayer,
    ).start(context);
    return;
  }

  // No torrent is writing it, so nothing will finish it.
  if (!File(file.path).existsSync()) {
    AppSnackBar.showWarning(
      context,
      message: '"${file.displayTitle}" isn\'t on disk any more.',
    );
    return;
  }

  AppSnackBar.showInfo(
    context,
    message: '"${file.displayTitle}" hasn\'t finished downloading yet.',
    actionLabel: 'Open Transfers',
    onAction: () => showAppTab(container, AppTab.transfers),
  );
}

/// Resume a Continue Watching entry at its saved position.
Future<void> resumeProgress(
  BuildContext context,
  WidgetRef ref,
  WatchProgress progress, {
  @visibleForTesting
  PlayerPageBuilder openPlayer = VideoPlayerScreen.fromSession,
}) => openLocalFile(
  context,
  ref,
  libraryFileForProgress(ref, progress),
  startPosition: progress.position,
  openPlayer: openPlayer,
);

/// Streams a library file again from the torrent still writing it, behind
/// the same card the details screens show, and opens the player at
/// [startPosition] once enough of it is down.
///
/// Works from [container] rather than a `WidgetRef`: Home or the Library
/// may be gone by the time the stream is ready, and the player opens anyway
/// — the details screens make the same promise.
class _StreamAgain {
  _StreamAgain({
    required this.container,
    required this.file,
    required this.request,
    required this.openPlayer,
    this.startPosition,
    this.showImdbId,
    this.movieImdbId,
  });

  final ProviderContainer container;
  final LocalMediaFile file;
  final StreamRequest request;
  final PlayerPageBuilder openPlayer;
  final Duration? startPosition;
  final String? showImdbId;
  final String? movieImdbId;

  OverlayEntry? _overlay;
  ValueNotifier<StreamingOverlayData>? _overlayData;
  ProviderSubscription<StreamingSessionsState>? _monitor;

  /// Null until the engine has accepted the torrent.
  String? _sessionId;

  /// Cancel was pressed — possibly before [_sessionId] existed.
  bool _cancelled = false;

  /// Reached the player, failed, or ended. Later updates are ignored: a
  /// `playing` after `ready` must not open a second player.
  bool _settled = false;

  final DateTime _startedAt = DateTime.now();

  /// What the card and the snackbars call it — the show and episode, or
  /// the movie's cleaned-up file name.
  String get _label {
    final code = file.episodeCode;
    if (file.showName != null && code != null) {
      return '"${file.showName} $code"';
    }
    final title = cleanMediaTitle(file.fileName);
    return '"${title.isNotEmpty ? title : file.fileName}"';
  }

  Future<void> start(BuildContext context) async {
    final result = showUpdatableStreamingOverlay(
      context,
      title: 'Resuming $_label',
      subtitle: 'Connecting…',
      onHide: _hide,
      onCancel: _cancel,
      onViewTransfers: () {
        _hide();
        showAppTab(container, AppTab.transfers);
      },
      onClose: _removeOverlay,
    );
    _overlay = result.entry;
    _overlayData = result.data;

    AppLog.i(
      '[LocalPlayback] streaming "${file.fileName}" again from torrent '
      '${request.infoHash}, file ${request.fileIdx}',
    );
    final sessions = container.read(streamingSessionsProvider.notifier);
    final session = await sessions.startStreamingRequest(
      request: request,
      showName: file.showName,
      season: file.seasonNumber,
      episode: file.episodeNumber,
      episodeCode: file.episodeCode,
      showImdbId: showImdbId,
      movieImdbId: movieImdbId,
    );

    if (_cancelled) {
      // Cancel was pressed while the torrent was being added; the session
      // only exists now.
      if (session != null) await _stop(session.id);
      return;
    }
    if (session == null) {
      _settle();
      _say(
        streamFailedMessage(_label, null, fallback: 'Try again.'),
        AppSnackBarKind.error,
      );
      return;
    }

    _sessionId = session.id;
    // `fireImmediately` covers a session that reached `ready` on the way
    // back from the add: a finished head is ready on the first poll.
    _monitor = container.listen<StreamingSessionsState>(
      streamingSessionsProvider,
      (_, next) {
        // Another stream has started since. The sessions notifier follows
        // only the active one, so this one would never hear of `ready`.
        final active = next.activeSessionId;
        if (active != null && active != session.id) {
          _supersede(session.id);
          return;
        }
        final updated = next.sessions[session.id];
        if (updated != null) _onSession(updated);
      },
      fireImmediately: true,
    );
  }

  void _onSession(StreamingSession session) {
    if (_cancelled || _settled) return;
    switch (session.state) {
      case StreamingState.addingTorrent:
      case StreamingState.selectingFiles:
      case StreamingState.buffering:
        _overlayData?.value = StreamingOverlayData.preparing(
          session,
          label: _label,
          verb: 'Resuming',
          waited: DateTime.now().difference(_startedAt),
        );

      case StreamingState.ready:
      case StreamingState.playing:
        _settle();
        // So the app shell's safety net does not push a second player.
        container.read(streamingSessionsProvider.notifier).clearActiveSession();
        // The library's file, not the session's: same path, but this one
        // carries the watch-progress row's show and TMDB ids, which the
        // player's progress and watched sync key on.
        unawaited(
          rootNavigatorKey.currentState?.push(
            MaterialPageRoute<void>(
              builder: (_) => openPlayer(
                file: file,
                session: session,
                startPosition: startPosition,
                showImdbId: showImdbId,
                movieImdbId: movieImdbId,
              ),
            ),
          ),
        );

      case StreamingState.error:
        final card = _overlayData;
        if (card != null) {
          // On the card the user is looking at, until they close it — as on
          // the details pages.
          _settled = true;
          _monitor?.close();
          _monitor = null;
          card.value = StreamingOverlayData.failed(
            session,
            label: _label,
            fallback: 'Try again.',
          );
          return;
        }
        _settle();
        _say(
          streamFailedMessage(
            _label,
            session.errorMessage,
            fallback: 'Try again.',
          ),
          AppSnackBarKind.error,
        );

      case StreamingState.cancelled:
        _settle();

      case StreamingState.idle:
        break;
    }
  }

  /// Keep preparing out of sight. The monitor stays, so the player still
  /// opens when the stream is ready.
  void _hide() => _removeOverlay();

  /// Stop preparing. The session is cancelled now if the engine has
  /// accepted the torrent, or by [start] the moment it has. The torrent
  /// stays: it was the user's download before this stream.
  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _settle();
    final sessionId = _sessionId;
    if (sessionId != null) unawaited(_stop(sessionId));
  }

  /// Stop quietly: the user has moved on to another stream.
  void _supersede(String sessionId) {
    if (_cancelled || _settled) return;
    _cancelled = true;
    _settle();
    unawaited(_stop(sessionId, quietly: true));
  }

  Future<void> _stop(String sessionId, {bool quietly = false}) async {
    try {
      await container
          .read(streamingSessionsProvider.notifier)
          .cancelSession(sessionId);
    } catch (e) {
      AppLog.e('[LocalPlayback] cancelling $sessionId failed: $e');
    }
    if (!quietly) _say('Stopped streaming $_label.');
  }

  void _settle() {
    _settled = true;
    _monitor?.close();
    _monitor = null;
    _removeOverlay();
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
    _overlayData?.dispose();
    _overlayData = null;
  }

  void _say(String message, [AppSnackBarKind kind = AppSnackBarKind.info]) =>
      AppSnackBar.showOn(
        rootScaffoldMessengerKey.currentState,
        message: message,
        kind: kind,
      );
}
