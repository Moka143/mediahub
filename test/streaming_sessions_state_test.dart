import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/stream_request.dart';
import 'package:mediahub/providers/streaming_provider.dart';
import 'package:mediahub/services/streaming_service.dart';

/// `copyWith` merges with `??`, so a bare `activeSessionId: null` means
/// "keep", not "clear". `cancelSession` relied on the second reading and so
/// never actually released the active session — it just removed it from the
/// map and left the id dangling. These pin the explicit escape hatch.
void main() {
  StreamingSession session(String id) => StreamingSession(
    id: id,
    request: const StreamRequest(
      displayName: 'Show S01E01',
      magnetUri: 'magnet:?xt=urn:btih:abc',
      infoHash: 'abc',
      isSingleFile: true,
      isSeasonPack: false,
    ),
  );

  test('a bare null keeps the active session', () {
    const state = StreamingSessionsState(activeSessionId: 'a');
    expect(state.copyWith(activeSessionId: null).activeSessionId, 'a');
  });

  test('clearActive is the way to release it', () {
    const state = StreamingSessionsState(activeSessionId: 'a');
    expect(state.copyWith(clearActive: true).activeSessionId, isNull);
  });

  test('clearActive wins over an explicit id', () {
    const state = StreamingSessionsState(activeSessionId: 'a');
    final next = state.copyWith(activeSessionId: 'b', clearActive: true);
    expect(next.activeSessionId, isNull);
  });

  test('clearing the active id does not disturb the session map', () {
    final state = StreamingSessionsState(
      sessions: {'a': session('a'), 'b': session('b')},
      activeSessionId: 'a',
    );
    final next = state.copyWith(clearActive: true);
    expect(next.sessions.keys, ['a', 'b']);
    expect(next.activeSession, isNull);
  });
}
