import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/stream_request.dart';
import '../models/torrentio_stream.dart';
import '../services/streaming_service.dart';
import 'connection_provider.dart';

/// Provider for the streaming service
final streamingServiceProvider = Provider<StreamingService>((ref) {
  final qbtService = ref.watch(torrentEngineProvider);
  final service = StreamingService(qbtService);

  ref.onDispose(() {
    service.dispose();
  });

  return service;
});

/// State for streaming sessions
class StreamingSessionsState {
  final Map<String, StreamingSession> sessions;
  final String? activeSessionId;

  const StreamingSessionsState({
    this.sessions = const {},
    this.activeSessionId,
  });

  /// [clearActive] is the only way to set [activeSessionId] back to null.
  /// A bare `activeSessionId: null` means "keep" under the `??` merge, which
  /// silently left `cancelSession` pointing at a session it had just removed.
  StreamingSessionsState copyWith({
    Map<String, StreamingSession>? sessions,
    String? activeSessionId,
    bool clearActive = false,
  }) {
    return StreamingSessionsState(
      sessions: sessions ?? this.sessions,
      activeSessionId: clearActive
          ? null
          : (activeSessionId ?? this.activeSessionId),
    );
  }

  StreamingSession? get activeSession =>
      activeSessionId != null ? sessions[activeSessionId] : null;

  List<StreamingSession> get activeSessions =>
      sessions.values.where((s) => s.isActive).toList();
}

/// Notifier for managing streaming sessions
class StreamingSessionsNotifier extends Notifier<StreamingSessionsState> {
  StreamSubscription<StreamingSession>? _activeSubscription;

  @override
  StreamingSessionsState build() {
    ref.onDispose(() {
      _activeSubscription?.cancel();
    });
    return const StreamingSessionsState();
  }

  /// Start a new streaming session from a Torrentio stream.
  Future<StreamingSession?> startStreaming({
    required TorrentioStream stream,
    String? showImdbId,
    String? showName,
    String? movieImdbId,
    int? season,
    int? episode,
    String? episodeCode,
    String? savePath,
  }) {
    return startStreamingRequest(
      request: StreamRequest.fromTorrentio(stream),
      showImdbId: showImdbId,
      showName: showName,
      movieImdbId: movieImdbId,
      season: season,
      episode: episode,
      episodeCode: episodeCode,
      savePath: savePath,
    );
  }

  /// Start a new streaming session from a normalised [StreamRequest] —
  /// used by the next-episode / binge flow, which resolves torrents through
  /// `AutoDownloadService` rather than Torrentio's stream list.
  ///
  /// [makeActive] controls whether this session becomes [activeSessionId].
  /// Leave it true for user-picked sources (details screens): the global
  /// safety-net in `MainNavigationScreen` opens the player when that
  /// session turns ready. Pass false for background next-episode prefetch
  /// — otherwise the safety-net would push a new player on top of the
  /// episode still playing.
  Future<StreamingSession?> startStreamingRequest({
    required StreamRequest request,
    String? showImdbId,
    String? showName,
    String? movieImdbId,
    int? season,
    int? episode,
    String? episodeCode,
    String? savePath,
    bool makeActive = true,
    bool allowSlowBuffer = false,
  }) async {
    final streamingService = ref.read(streamingServiceProvider);

    // Start the session
    final session = await streamingService.startStreamingRequest(
      request: request,
      showImdbId: showImdbId,
      showName: showName,
      movieImdbId: movieImdbId,
      season: season,
      episode: episode,
      episodeCode: episodeCode,
      savePath: savePath,
      allowSlowBuffer: allowSlowBuffer,
    );

    // Add to state
    final newSessions = Map<String, StreamingSession>.from(state.sessions);
    newSessions[session.id] = session;

    state = state.copyWith(
      sessions: newSessions,
      activeSessionId: makeActive ? session.id : state.activeSessionId,
    );

    if (makeActive) {
      unawaited(_activeSubscription?.cancel());
      _activeSubscription = streamingService
          .getSessionStream(session.id)
          ?.listen((updatedSession) {
            final updated = Map<String, StreamingSession>.from(state.sessions);
            updated[updatedSession.id] = updatedSession;
            state = state.copyWith(sessions: updated);
          });
    }

    return session;
  }

  /// Cancel a streaming session and forget it.
  Future<void> cancelSession(String sessionId) async {
    final wasActive = state.activeSessionId == sessionId;

    // Drop the listener first. `StreamingService.cancelSession` emits a final
    // `cancelled` event before closing the controller, and a broadcast
    // listener is notified in a later microtask — after the removal below —
    // so leaving it attached puts the cancelled session straight back into
    // the map, where nothing would ever clean it up again.
    if (wasActive) {
      unawaited(_activeSubscription?.cancel());
      _activeSubscription = null;
    }

    await ref.read(streamingServiceProvider).cancelSession(sessionId);

    final newSessions = Map<String, StreamingSession>.from(state.sessions);
    newSessions.remove(sessionId);

    state = state.copyWith(sessions: newSessions, clearActive: wasActive);
  }

  /// Clear the active session ID so global listeners (e.g. the safety-net in
  /// main_navigation_screen) don't fire after the originating screen already
  /// handled the ready→player transition.
  void clearActiveSession() {
    state = state.copyWith(clearActive: true);
  }

  /// Get session by ID
  StreamingSession? getSession(String sessionId) => state.sessions[sessionId];
}

/// Provider for streaming sessions notifier
final streamingSessionsProvider =
    NotifierProvider<StreamingSessionsNotifier, StreamingSessionsState>(
      StreamingSessionsNotifier.new,
    );

/// Provider for active streaming session (convenience)
final activeStreamingSessionProvider = Provider<StreamingSession?>((ref) {
  final state = ref.watch(streamingSessionsProvider);
  return state.activeSession;
});

/// Provider for all active streaming sessions
final activeStreamingSessionsProvider = Provider<List<StreamingSession>>((ref) {
  final state = ref.watch(streamingSessionsProvider);
  return state.activeSessions;
});

/// Check if a specific torrent is currently streaming
final isStreamingTorrentProvider = Provider.family<bool, String>((
  ref,
  infoHash,
) {
  final state = ref.watch(streamingSessionsProvider);
  return state.sessions.values.any(
    (s) =>
        s.request.infoHash.toLowerCase() == infoHash.toLowerCase() &&
        s.isActive,
  );
});

/// Helper provider to get sorted streams for streaming (single-file first)
final sortedStreamsForStreamingProvider =
    Provider.family<List<TorrentioStream>, List<TorrentioStream>>((
      ref,
      streams,
    ) {
      return streams.sortForStreaming();
    });

/// Helper provider to get the best stream for streaming
final bestStreamForStreamingProvider =
    Provider.family<TorrentioStream?, List<TorrentioStream>>((ref, streams) {
      return streams.getBestForStreaming();
    });
