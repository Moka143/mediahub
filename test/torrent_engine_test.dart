import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/peer.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/torrent_file.dart';
import 'package:mediahub/services/torrent_engine.dart';

/// An engine that implements only what [TorrentEngine] declares abstract.
///
/// Everything else falls through to the interface's defaults, which is exactly
/// what is under test: those defaults are the contract a partial engine
/// inherits, and a change to any of them is a silent behaviour change for
/// every such engine.
class _MinimalEngine extends TorrentEngine {
  @override
  String get baseUrl => 'http://127.0.0.1:1';

  @override
  bool get isAuthenticated => true;

  @override
  Future<bool> login() async => true;

  @override
  Future<void> logout() async {}

  @override
  Future<bool> testConnection() async => true;

  @override
  Future<String?> getVersion() async => '1.0';

  @override
  Future<String?> getApiVersion() async => null;

  @override
  Future<List<Torrent>> getTorrents({
    String? filter,
    String? category,
    String? tag,
    String? sort,
    bool? reverse,
    int? limit,
    int? offset,
    List<String>? hashes,
  }) async => const [];

  @override
  Future<Map<String, dynamic>?> getTorrentProperties(String hash) async => null;

  @override
  Future<List<TorrentFile>> getTorrentFiles(String hash) async => const [];

  @override
  Future<bool> addTorrent({
    String? magnetLink,
    File? torrentFile,
    String? savePath,
    String? category,
    bool? paused,
    bool? skipChecking,
    bool? sequentialDownload,
    bool? firstLastPiecePrio,
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
  Future<bool> setFilePriority(
    String hash,
    List<int> fileIds,
    int priority,
  ) async => true;

  @override
  Future<List<int>?> getPieceStates(String hash) async => null;

  @override
  void dispose() {}
}

void main() {
  late _MinimalEngine engine;

  setUp(() => engine = _MinimalEngine());

  group('EngineCapabilities', () {
    test('defaults to the qBittorrent answer — everything supported', () {
      const caps = EngineCapabilities();
      expect(caps.trackers, isTrue);
      expect(caps.peers, isTrue);
      expect(caps.deltaSync, isTrue);
      expect(caps.globalPreferences, isTrue);
      expect(caps.liveSpeedLimits, isTrue);
      expect(caps.pieceLevelControl, isTrue);
      expect(caps.maintenanceActions, isTrue);
    });

    test('an engine declares only what it lacks', () {
      const caps = EngineCapabilities(trackers: false, deltaSync: false);
      expect(caps.trackers, isFalse);
      expect(caps.deltaSync, isFalse);
      expect(caps.peers, isTrue, reason: 'undeclared flags stay supported');
    });

    test('an engine that says nothing supports everything', () {
      expect(engine.capabilities.trackers, isTrue);
      expect(engine.capabilities.pieceLevelControl, isTrue);
    });
  });

  group('streaming defaults', () {
    test('streamUrl is null — the caller must front the file itself', () {
      expect(engine.streamUrl('abc', 0), isNull);
    });

    test('getPieceSize is 0, meaning "unknown"', () async {
      expect(await engine.getPieceSize('abc'), 0);
    });
  });

  group('piece-level control defaults', () {
    // The asymmetry here is deliberate and load-bearing. `ensureInOrderDownload`
    // answers TRUE for an engine that cannot toggle sequential mode, because
    // callers read a false as "this session is broken" and give up — whereas
    // such an engine is precisely one that already delivers in order. The
    // toggles themselves answer false: nothing was toggled.
    test(
      'ensureInOrderDownload succeeds — order is the engine\'s job',
      () async {
        expect(await engine.ensureInOrderDownload('abc'), isTrue);
        expect(
          await engine.ensureInOrderDownload('abc', resetPicker: true),
          isTrue,
        );
      },
    );

    test('the toggles report that nothing was toggled', () async {
      expect(await engine.toggleSequentialDownload('abc'), isFalse);
      expect(await engine.toggleFirstLastPiecePrio('abc'), isFalse);
      expect(await engine.setPiecePriority('abc', const [0, 1], 7), isFalse);
    });
  });

  group('detail-tab defaults', () {
    test('trackers and peers come back empty, not null', () async {
      expect(await engine.getTorrentTrackers('abc'), isEmpty);
      expect(await engine.getTorrentPeers('abc'), isEmpty);
      expect(await engine.getTorrentPeers('abc'), isA<List<Peer>>());
    });
  });

  group('maintenance defaults', () {
    test('recheck, reannounce and queue priority all decline', () async {
      expect(await engine.recheckTorrents(const ['abc']), isFalse);
      expect(await engine.reannounceTorrents(const ['abc']), isFalse);
      expect(
        await engine.setTorrentPriority(const ['abc'], 'topPrio'),
        isFalse,
      );
    });
  });

  group('global-state defaults', () {
    test(
      'getMainData is null so the caller falls back to a full fetch',
      () async {
        expect(await engine.getMainData(), isNull);
        expect(await engine.getMainData(fullUpdate: true), isNull);
      },
    );

    test('preferences and transfer info are absent', () async {
      expect(await engine.getPreferences(), isNull);
      expect(await engine.setPreferences(const {'a': 1}), isFalse);
      expect(await engine.getTransferInfo(), isNull);
    });

    test('speed limits decline rather than pretending to apply', () async {
      expect(await engine.setDownloadLimit(1024), isFalse);
      expect(await engine.setUploadLimit(0), isFalse);
    });
  });
}
