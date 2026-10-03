import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/torrent_file.dart';
import 'package:mediahub/providers/connection_provider.dart';
import 'package:mediahub/providers/torrent_provider.dart';
import 'package:mediahub/services/torrent_engine.dart';

Torrent _torrent({double progress = 0.1, int dlspeed = 0}) => Torrent.fromJson({
  'hash': 'abc',
  'name': 'Show.S01E01',
  'progress': progress,
  'dlspeed': dlspeed,
  'state': 'downloading',
});

class _Connected extends ConnectionNotifier {
  @override
  ConnectionState build() =>
      const ConnectionState(status: ConnectionStatus.connected);
}

class _CountingEngine extends TorrentEngine {
  int fileReads = 0;

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
      const [];

  @override
  Future<List<TorrentFile>?> tryGetTorrentFiles(String hash) async {
    fileReads++;
    return const [];
  }

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

/// A list holder the test can push new snapshots into, standing in for the
/// polling torrent list.
class _Snapshots extends Notifier<List<Torrent>> {
  @override
  List<Torrent> build() => [_torrent()];

  void push(List<Torrent> next) => state = next;
}

final _snapshots = NotifierProvider<_Snapshots, List<Torrent>>(_Snapshots.new);

void main() {
  group('Torrent equality', () {
    test('two snapshots of one torrent differ when anything differs', () {
      // Equal-by-hash made every snapshot of a torrent equal, so nothing
      // that compared old and new values ever saw a change.
      expect(_torrent(progress: 0.1), isNot(_torrent(progress: 0.2)));
      expect(_torrent(dlspeed: 0), isNot(_torrent(dlspeed: 1024)));
    });

    test('identical snapshots are equal, with equal hash codes', () {
      expect(_torrent(), _torrent());
      expect(_torrent().hashCode, _torrent().hashCode);
    });
  });

  group('live updates', () {
    test('a view of one torrent hears about every change to it', () async {
      final container = ProviderContainer.test();
      final selected = Provider<Torrent?>(
        (ref) =>
            ref.watch(_snapshots).where((t) => t.hash == 'abc').firstOrNull,
      );
      final seen = <double>[];
      container.listen<Torrent?>(
        selected,
        (_, next) => seen.add(next!.progress),
        fireImmediately: true,
      );

      container.read(_snapshots.notifier).push([_torrent(progress: 0.5)]);
      await container.pump();
      container.read(_snapshots.notifier).push([_torrent(progress: 0.9)]);
      await container.pump();
      // The same values again: no spurious rebuild.
      container.read(_snapshots.notifier).push([_torrent(progress: 0.9)]);
      await container.pump();

      expect(seen, [0.1, 0.5, 0.9]);
    });

    test('the files tab re-reads while it is open, and stops after', () async {
      final engine = _CountingEngine();
      final container = ProviderContainer.test(
        overrides: [
          torrentEngineProvider.overrideWithValue(engine),
          connectionProvider.overrideWith(_Connected.new),
        ],
      );

      final subscription = container.listen(
        torrentFilesProvider('abc'),
        (_, _) {},
      );
      await Future<void>.delayed(
        kTorrentDetailRefreshInterval + const Duration(milliseconds: 400),
      );
      expect(engine.fileReads, greaterThanOrEqualTo(2));

      subscription.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.exists(torrentFilesProvider('abc')), isFalse);
    });
  });
}
