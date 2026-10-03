import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/auto_download_event.dart';
import 'package:mediahub/models/auto_download_state.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/providers/auto_download/auto_download_ledger.dart';
import 'package:mediahub/providers/auto_download/engine_reconciler.dart';
import 'package:mediahub/services/auto_download_service.dart';

/// [EngineReconciler] over an in-memory state, recording what it reports.
class _World {
  _World(this.state);

  AutoDownloadState state;
  bool mounted = true;
  final List<AutoDownloadEvent> events = [];
  final List<String> completed = [];

  /// Runs after every save — to pull the notifier away mid-pass.
  void Function()? onSave;

  late final AutoDownloadLedger ledger = AutoDownloadLedger(
    read: () => state,
    write: (next) => state = next,
    save: () async => onSave?.call(),
    mounted: () => mounted,
    addEvent: (event) async => events.add(event),
  );

  late final EngineReconciler reconciler = EngineReconciler(
    ledger: ledger,
    markCompleted: (hash) async => completed.add(hash),
  );
}

EpisodeTrackingInfo _downloading(int episode, String? hash) =>
    EpisodeTrackingInfo(
      showId: 42,
      imdbId: 'tt11280740',
      showName: 'Severance',
      season: 1,
      episode: episode,
      status: EpisodeDownloadStatus.downloading,
      quality: '1080p',
      torrentHash: hash,
    );

Torrent _torrent(String hash, {String? name, String state = 'downloading'}) =>
    Torrent.fromJson({'hash': hash, 'name': name ?? hash, 'state': state});

/// Show 42 downloading S01E01 as [hash], queued under its key.
AutoDownloadState _oneDownload(String hash) => AutoDownloadState(
  downloadQueue: const {'42_S01E01'},
  queuedTorrents: {'42_S01E01': hash},
  lastDownloadedEpisodes: {42: _downloading(1, hash)},
);

void main() {
  group('activeDownloads', () {
    test('the queue with its torrents, plus tracked downloads', () {
      final state = AutoDownloadState(
        downloadQueue: const {'42_S01E01', '7_S02E03'},
        queuedTorrents: const {'42_S01E01': 'queued'},
        lastDownloadedEpisodes: {
          42: _downloading(1, 'tracked'),
          9: EpisodeTrackingInfo(
            showId: 9,
            showName: 'Watched',
            season: 1,
            episode: 1,
            status: EpisodeDownloadStatus.watched,
            torrentHash: 'ignored',
          ),
          5: EpisodeTrackingInfo(
            showId: 5,
            showName: 'Running',
            season: 3,
            episode: 4,
            status: EpisodeDownloadStatus.downloading,
            torrentHash: 'only-tracked',
          ),
        },
      );

      expect(activeDownloads(state), {
        '42_S01E01': 'queued', // the queue's record wins
        '7_S02E03': null, // queued by an older build
        '5_S03E04': 'only-tracked',
      });
    });
  });

  test('engineTorrent matches hashes ignoring case', () {
    final torrents = [_torrent('ABC'), _torrent('def')];

    expect(engineTorrent(torrents, 'abc')!.hash, 'ABC');
    expect(engineTorrent(torrents, 'DEF')!.hash, 'def');
    expect(engineTorrent(torrents, 'xyz'), isNull);
  });

  group('reconcile', () {
    test('a running download is left alone', () async {
      final w = _World(_oneDownload('h1'));
      await w.reconciler.reconcile([_torrent('H1')]);
      await w.reconciler.reconcile([_torrent('H1')]);

      expect(w.state.downloadQueue, {'42_S01E01'});
      expect(w.completed, isEmpty);
      expect(w.events, isEmpty);
    });

    test('a finished download is reported by its engine hash', () async {
      final w = _World(_oneDownload('h1'));
      await w.reconciler.reconcile([_torrent('H1', state: 'uploading')]);

      expect(w.completed, ['H1']);
    });

    test('one miss could be a restart; two in a row release it', () async {
      final w = _World(_oneDownload('h1'));

      await w.reconciler.reconcile([]);
      expect(w.state.downloadQueue, {'42_S01E01'});
      expect(w.events, isEmpty);

      await w.reconciler.reconcile([]);
      expect(w.state.downloadQueue, isEmpty);
      expect(w.state.queuedTorrents, isEmpty);
      final tracking = w.state.lastDownloadedEpisodes[42]!;
      expect(tracking.status, EpisodeDownloadStatus.awaitingTorrent);
      expect(tracking.torrentHash, 'h1', reason: 'never picked again');
      final event = w.events.single;
      expect(event.type, AutoDownloadEventType.downloadFailed);
      expect(
        event.message,
        'Severance S01E01 left Transfers before it finished — another '
        'source will be tried.',
      );
    });

    test('a download seen again in between starts counting afresh', () async {
      final w = _World(_oneDownload('h1'));
      await w.reconciler.reconcile([]);
      await w.reconciler.reconcile([_torrent('h1')]);
      await w.reconciler.reconcile([]);

      expect(w.state.downloadQueue, {'42_S01E01'});
    });

    test('an older build\'s key is matched by the episode\'s name', () async {
      final w = _World(
        AutoDownloadState(
          downloadQueue: const {'42_S01E01'},
          lastDownloadedEpisodes: {42: _downloading(1, null)},
        ),
      );
      final engine = [_torrent('x', name: 'Severance.S01E01.1080p.mkv')];
      await w.reconciler.reconcile(engine);
      await w.reconciler.reconcile(engine);
      expect(w.state.downloadQueue, {'42_S01E01'});

      await w.reconciler.reconcile([]);
      await w.reconciler.reconcile([]);
      expect(w.state.downloadQueue, isEmpty);
    });

    test('stops when the notifier goes away mid-pass', () async {
      final w = _World(
        AutoDownloadState(
          downloadQueue: const {'42_S01E01', '42_S01E02'},
          queuedTorrents: const {'42_S01E01': 'h1', '42_S01E02': 'h2'},
        ),
      );
      await w.reconciler.reconcile([]);
      w.onSave = () => w.mounted = false;
      await w.reconciler.reconcile([]);

      expect(w.state.downloadQueue, {'42_S01E02'});
    });
  });

  group('completeDownload', () {
    test('releases every key queued under the torrent', () async {
      final w = _World(
        AutoDownloadState(
          downloadQueue: const {'42_S01E01', '42_S01E02', '7_S01E01'},
          queuedTorrents: const {
            '42_S01E01': 'h1',
            '42_S01E02': 'H1',
            '7_S01E01': 'h7',
          },
          lastDownloadedEpisodes: {42: _downloading(2, 'h1')},
        ),
      );
      await w.reconciler.completeDownload('H1');

      expect(w.state.downloadQueue, {'7_S01E01'});
      expect(
        w.state.lastDownloadedEpisodes[42]!.status,
        EpisodeDownloadStatus.downloaded,
      );
      final event = w.events.single;
      expect(event.type, AutoDownloadEventType.downloadCompleted);
      expect(event.message, 'Severance S01E02 finished downloading.');
    });

    test('a torrent it does not know changes nothing', () async {
      final before = _oneDownload('h1');
      final w = _World(before);
      await w.reconciler.completeDownload('someone-else');

      expect(w.state, same(before));
      expect(w.events, isEmpty);
    });

    test('only a download in progress is marked done', () async {
      // `awaitingTorrent` keeps the failed torrent's hash as the one not to
      // pick again; that torrent finishing later is not this episode done.
      final w = _World(
        AutoDownloadState(
          lastDownloadedEpisodes: {
            42: _downloading(
              1,
              'h1',
            ).copyWith(status: EpisodeDownloadStatus.awaitingTorrent),
          },
        ),
      );
      await w.reconciler.completeDownload('h1');

      expect(
        w.state.lastDownloadedEpisodes[42]!.status,
        EpisodeDownloadStatus.awaitingTorrent,
      );
      expect(w.events, isEmpty);
    });
  });
}
