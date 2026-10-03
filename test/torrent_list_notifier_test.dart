import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/torrent_file.dart';
import 'package:mediahub/providers/auto_download_provider.dart';
import 'package:mediahub/providers/connection_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/torrent_provider.dart';
import 'package:mediahub/services/torrent_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Connected extends ConnectionNotifier {
  @override
  ConnectionState build() =>
      const ConnectionState(status: ConnectionStatus.connected);
}

class _FakeAutoDownload extends AutoDownloadNotifier {
  final List<String> completed = [];

  @override
  AutoDownloadState build() => const AutoDownloadState();

  @override
  Future<void> markDownloadCompleted(String torrentHash) async =>
      completed.add(torrentHash);
}

/// Answers the list from a script: a delta-sync engine when [deltas] is set,
/// a full-listing one otherwise.
class _ScriptedEngine extends TorrentEngine {
  _ScriptedEngine({this.listing, this.deltas});

  List<Torrent>? listing;
  final List<Map<String, dynamic>>? deltas;
  final List<List<String>> paused = [];
  int _delta = 0;

  @override
  EngineCapabilities get capabilities =>
      EngineCapabilities(deltaSync: deltas != null);

  @override
  Future<Map<String, dynamic>?> getMainData({bool fullUpdate = false}) async {
    final script = deltas;
    if (script == null || _delta >= script.length) return null;
    return script[_delta++];
  }

  @override
  String get baseUrl => 'http://fake';

  @override
  Future<bool> login() async => true;

  @override
  Future<bool> testConnection() async => true;

  @override
  Future<String?> getVersion() async => null;

  @override
  Future<List<Torrent>?> tryGetTorrents({List<String>? hashes}) async =>
      listing;

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
  Future<bool> pauseTorrents(List<String> hashes) async {
    paused.add(hashes);
    return true;
  }

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

Torrent _torrent(String hash, String state, {double progress = 0.5}) =>
    Torrent.fromJson({
      'hash': hash,
      'name': hash,
      'state': state,
      'progress': progress,
    });

Future<(ProviderContainer, _FakeAutoDownload)> _container(
  _ScriptedEngine engine,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final autoDownload = _FakeAutoDownload();
  final container = ProviderContainer.test(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      torrentEngineProvider.overrideWithValue(engine),
      connectionProvider.overrideWith(_Connected.new),
      autoDownloadProvider.overrideWith(() => autoDownload),
    ],
  );
  return (container, autoDownload);
}

void main() {
  test('a delta changes only the fields it names', () async {
    final engine = _ScriptedEngine(
      deltas: [
        {
          'full_update': true,
          'torrents': {
            'aaa': {'name': 'Show.S01E01', 'progress': 0.1, 'dlspeed': 100},
            'bbb': {'name': 'Movie', 'progress': 0.9},
          },
        },
        {
          'torrents': {
            'aaa': {'progress': 0.4},
          },
          'torrents_removed': ['bbb'],
        },
      ],
    );
    final (container, _) = await _container(engine);
    final notifier = container.read(torrentListProvider.notifier);

    await notifier.refresh(fullUpdate: true);
    await notifier.refresh();

    final torrents = container.read(torrentListProvider).torrents;
    expect(torrents.map((t) => t.hash), ['aaa']);
    expect(torrents.single.progress, 0.4);
    expect(torrents.single.name, 'Show.S01E01', reason: 'not in the delta');
    expect(torrents.single.dlspeed, 100);
  });

  test(
    'a finished download is reported once and stopped from seeding',
    () async {
      final engine = _ScriptedEngine(listing: [_torrent('aaa', 'downloading')]);
      final (container, autoDownload) = await _container(engine);
      final notifier = container.read(torrentListProvider.notifier);

      await notifier.refresh();
      expect(autoDownload.completed, isEmpty);

      engine.listing = [_torrent('aaa', 'uploading', progress: 1)];
      await notifier.refresh();
      await notifier.refresh();

      expect(autoDownload.completed, ['aaa'], reason: 'edge, not level');
      expect(engine.paused, isNotEmpty);
      expect(engine.paused.first, ['aaa']);
    },
  );

  test('an engine that does not answer keeps the list and says why', () async {
    final engine = _ScriptedEngine(listing: [_torrent('aaa', 'downloading')]);
    final (container, _) = await _container(engine);
    final notifier = container.read(torrentListProvider.notifier);

    await notifier.refresh();
    engine.listing = null;
    await notifier.refresh();

    final state = container.read(torrentListProvider);
    expect(state.torrents.map((t) => t.hash), [
      'aaa',
    ], reason: 'an empty list would read as "no torrents"');
    expect(state.error, "Can't reach the torrent engine");
  });
}
