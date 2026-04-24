import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/torrentio_stream.dart';
import '../services/streaming_service.dart';
import 'connection_provider.dart';

/// Provider for the streaming service
final streamingServiceProvider = Provider<StreamingService>((ref) {
  final qbtService = ref.watch(qbApiServiceProvider);
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

  StreamingSessionsState copyWith({
    Map<String, StreamingSession>? sessions,
    String? activeSessionId,
  }) {
    return StreamingSessionsState(
      sessions: sessions ?? this.sessions,
      activeSessionId: activeSessionId ?? this.activeSessionId,
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

  /// Start a new streaming session
  Future<StreamingSession?> startStreaming({
    required TorrentioStream stream,
    String? showImdbId,
    String? showName,
    String? movieImdbId,
    int? season,
    int? episode,
    String? episodeCode,
    String? savePath,
  }) async {
    final streamingService = ref.read(streamingServiceProvider);

    // Start the session
    final session = await streamingService.startStreaming(
      stream: stream,
      showImdbId: showImdbId,
      showName: showName,
      movieImdbId: movieImdbId,
      season: season,
      episode: episode,
      episodeCode: episodeCode,
      savePath: savePath,
    );

    // Add to state
    final newSessions = Map<String, StreamingSession>.from(state.sessions);
    newSessions[session.id] = session;

    state = state.copyWith(sessions: newSessions, activeSessionId: session.id);

    // Subscribe to session updates
    _activeSubscription?.cancel();
    _activeSubscription = streamingService.getSessionStream(session.id)?.listen(
      (updatedSession) {
        final newSessions = Map<String, StreamingSession>.from(state.sessions);
        newSessions[updatedSession.id] = updatedSession;
        state = state.copyWith(sessions: newSessions);
      },
    );

    return session;
  }

  /// Cancel a streaming session
  Future<void> cancelSession(String sessionId) async {
    final streamingService = ref.read(streamingServiceProvider);
    await streamingService.cancelSession(sessionId);

    final newSessions = Map<String, StreamingSession>.from(state.sessions);
    newSessions.remove(sessionId);

    state = state.copyWith(
      sessions: newSessions,
      activeSessionId: state.activeSessionId == sessionId
          ? null
          : state.activeSessionId,
    );
  }

  /// Clear the active session ID so global listeners (e.g. the safety-net in
  /// main_navigation_screen) don't fire after the originating screen already
  /// handled the ready→player transition.
  void clearActiveSession() {
    state = StreamingSessionsState(
      sessions: state.sessions,
      activeSessionId: null,
    );
  }

  /// Get session by ID
  StreamingSession? getSession(String sessionId) => state.sessions[sessionId];

  /// Clear all completed or errored sessions
  void clearInactiveSessions() {
    final newSessions = Map<String, StreamingSession>.from(state.sessions);
    newSessions.removeWhere((_, s) => !s.isActive);
    state = state.copyWith(sessions: newSessions);
  }
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
        s.stream.infoHash.toLowerCase() == infoHash.toLowerCase() && s.isActive,
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
