import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/auto_download_event.dart';
import 'package:mediahub/models/auto_download_state.dart';
import 'package:mediahub/providers/auto_download/auto_download_ledger.dart';
import 'package:mediahub/providers/auto_download_provider.dart'
    show AutoDownloadNotifier;
import 'package:mediahub/services/auto_download_service.dart';

/// [AutoDownloadLedger] over an in-memory state, counting saves.
class _Book {
  AutoDownloadState state;
  int saves = 0;
  bool mounted = true;
  final List<AutoDownloadEvent> events = [];

  _Book([this.state = const AutoDownloadState()]);

  late final AutoDownloadLedger ledger = AutoDownloadLedger(
    read: () => state,
    write: (next) => state = next,
    save: () async {
      saves++;
    },
    mounted: () => mounted,
    addEvent: (event) async => events.add(event),
  );
}

EpisodeTrackingInfo _tracking(
  int showId,
  int season,
  int episode, {
  EpisodeDownloadStatus status = EpisodeDownloadStatus.watched,
}) => EpisodeTrackingInfo(
  showId: showId,
  showName: 'Show $showId',
  season: season,
  episode: episode,
  status: status,
);

void main() {
  group('downloadQueueKey', () {
    test('is the key the notifier exposes as queueKeyFor', () {
      expect(downloadQueueKey(1396, 2, 1), '1396_S02E01');
      expect(
        downloadQueueKey(7, 12, 134),
        AutoDownloadNotifier.queueKeyFor(7, 12, 134),
      );
    });
  });

  group('movesTracking', () {
    final at = _tracking(1, 2, 5);

    test('anything moves a show with no tracking yet', () {
      expect(movesTracking(null, 1, 1), isTrue);
    });

    test('the same episode or a later one moves it', () {
      expect(movesTracking(at, 2, 5), isTrue);
      expect(movesTracking(at, 2, 6), isTrue);
      expect(movesTracking(at, 3, 1), isTrue);
    });

    test('an earlier episode does not drag it back', () {
      expect(movesTracking(at, 2, 4), isFalse);
      expect(movesTracking(at, 1, 9), isFalse);
    });
  });

  test('trackingForKey finds the show at that episode, or none', () {
    final state = AutoDownloadState(
      lastDownloadedEpisodes: {1: _tracking(1, 1, 3), 2: _tracking(2, 4, 1)},
    );

    expect(trackingForKey(state, '2_S04E01')!.showId, 2);
    expect(trackingForKey(state, '1_S01E04'), isNull);
  });

  group('writes', () {
    test('queue a key, then its torrent, saving each time', () async {
      final book = _Book(const AutoDownloadState(error: 'old'));

      await book.ledger.setQueued('1_S01E01', null);
      expect(book.state.downloadQueue, {'1_S01E01'});
      expect(book.state.queuedTorrents, isEmpty);
      expect(book.state.error, isNull, reason: 'every write is a copy');

      await book.ledger.setQueued('1_S01E01', 'abc');
      expect(book.state.downloadQueue, {'1_S01E01'});
      expect(book.state.queuedTorrents, {'1_S01E01': 'abc'});
      expect(book.saves, 2);
    });

    test('release a key from both the queue and its torrent', () async {
      final book = _Book(
        const AutoDownloadState(
          downloadQueue: {'1_S01E01', '1_S01E02'},
          queuedTorrents: {'1_S01E01': 'abc'},
        ),
      );

      await book.ledger.releaseQueued('1_S01E01');

      expect(book.state.downloadQueue, {'1_S01E02'});
      expect(book.state.queuedTorrents, isEmpty);
      expect(book.saves, 1);
    });

    test('releasing a key that is not queued writes nothing', () async {
      const before = AutoDownloadState(error: 'kept');
      final book = _Book(before);

      await book.ledger.releaseQueued('1_S01E01');

      expect(book.state, same(before));
      expect(book.saves, 0);
    });

    test('tracking replaces one show and keeps the rest', () async {
      final book = _Book(
        AutoDownloadState(
          lastDownloadedEpisodes: {
            1: _tracking(1, 1, 1),
            2: _tracking(2, 1, 1),
          },
        ),
      );

      await book.ledger.updateTracking(1, _tracking(1, 1, 2));

      expect(book.state.lastDownloadedEpisodes.keys, [1, 2]);
      expect(book.state.lastDownloadedEpisodes[1]!.episode, 2);
      expect(book.saves, 1);
    });
  });

  group('log', () {
    Future<void> logOne(AutoDownloadLedger ledger) => ledger.log(
      AutoDownloadEventType.downloadStarted,
      showId: 1,
      showName: 'Show 1',
      season: 1,
      episode: 2,
      quality: '720p',
      message: 'Started.',
    );

    test('adds the entry as given', () async {
      final book = _Book();
      await logOne(book.ledger);

      final event = book.events.single;
      expect(event.type, AutoDownloadEventType.downloadStarted);
      expect(event.episodeCode, 'S01E02');
      expect(event.quality, '720p');
      expect(event.message, 'Started.');
    });

    test('says nothing once the notifier is gone', () async {
      final book = _Book()..mounted = false;
      await logOne(book.ledger);

      expect(book.events, isEmpty);
    });
  });
}
