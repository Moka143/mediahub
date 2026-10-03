import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/stream_request.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/torrent_file.dart';
import 'package:mediahub/providers/streaming_provider.dart';
import 'package:mediahub/services/streaming_service.dart';
import 'package:mediahub/services/torrent_engine.dart';

const _hash = '0123456789abcdef0123456789abcdef01234567';

/// An engine whose torrent never gets metadata: sessions stay "selecting
/// files" until the test acts on them.
class _QuietEngine extends TorrentEngine {
  @override
  String get baseUrl => 'http://fake';

  @override
  Future<bool> login() async => true;

  @override
  Future<bool> testConnection() async => true;

  @override
  Future<String?> getVersion() async => null;

  @override
  Future<List<Torrent>?> tryGetTorrents({List<String>? hashes}) async => [
    Torrent.fromJson(const {'hash': _hash, 'state': 'metaDL'}),
  ];

  @override
  Future<List<TorrentFile>?> tryGetTorrentFiles(String hash) async => const [];

  @override
  Future<bool> addTorrent({
    String? magnetLink,
    File? torrentFile,
    String? savePath,
    bool? paused,
    bool? sequentialDownload,
  }) async => true;

  @override
  Future<bool> pauseTorrents(List<String> hashes) async => true;

  @override
  Future<bool> resumeTorrents(List<String> hashes) async => true;

  @override
  Future<bool> deleteTorrents(
    List<String> hashes, {
    bool deleteFiles = false,
  }) async => true;

  @override
  Future<bool> setFilePriority(String h, List<int> ids, int p) async => true;

  @override
  Future<List<int>?> getPieceStates(String hash) async => null;

  @override
  void dispose() {}
}

const _request = StreamRequest(
  displayName: 'Show S01E01',
  magnetUri: 'magnet:?xt=urn:btih:$_hash',
  infoHash: _hash,
  isSingleFile: true,
  isSeasonPack: false,
);

void main() {
  late ProviderContainer container;
  late StreamingService service;

  setUp(() {
    service = StreamingService(
      _QuietEngine(),
      pollingInterval: const Duration(milliseconds: 20),
    );
    container = ProviderContainer.test(
      overrides: [streamingServiceProvider.overrideWithValue(service)],
    );
    addTearDown(service.dispose);
  });

  StreamingSessionsNotifier notifier() =>
      container.read(streamingSessionsProvider.notifier);

  test('a user-picked source becomes the active session', () async {
    final session = await notifier().startStreamingRequest(request: _request);

    final state = container.read(streamingSessionsProvider);
    expect(state.activeSessionId, session!.id);
    expect(state.sessions, contains(session.id));
  });

  test('the active session follows the service\'s updates', () async {
    final session = await notifier().startStreamingRequest(request: _request);

    await Future<void>.delayed(const Duration(milliseconds: 100));

    final active = container.read(streamingSessionsProvider).activeSession;
    expect(active?.id, session!.id);
    expect(active?.state, StreamingState.selectingFiles);
    expect(
      active?.state,
      service.getSession(session.id)?.state,
      reason: 'the notifier mirrors what the service publishes',
    );
  });

  test('a background prefetch does not take over the active slot', () async {
    final picked = await notifier().startStreamingRequest(request: _request);
    await notifier().startStreamingRequest(
      request: _request,
      makeActive: false,
    );

    expect(
      container.read(streamingSessionsProvider).activeSessionId,
      picked!.id,
    );
  });

  test('cancelling forgets the session and frees the active slot', () async {
    final session = await notifier().startStreamingRequest(request: _request);

    await notifier().cancelSession(session!.id);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(streamingSessionsProvider);
    expect(state.sessions, isEmpty);
    expect(state.activeSessionId, isNull);
    expect(service.getSession(session.id), isNull);
  });
}
