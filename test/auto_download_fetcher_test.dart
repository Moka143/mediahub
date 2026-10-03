import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/auto_download_event.dart';
import 'package:mediahub/models/auto_download_state.dart';
import 'package:mediahub/models/episode.dart';
import 'package:mediahub/models/episode_grab_result.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/providers/auto_download/auto_download_ledger.dart';
import 'package:mediahub/providers/auto_download/episode_fetcher.dart';
import 'package:mediahub/providers/auto_download/episode_grabber.dart';
import 'package:mediahub/services/auto_download_service.dart';
import 'package:mediahub/services/eztv_api_service.dart';
import 'package:mediahub/services/qbittorrent_api_service.dart';
import 'package:mediahub/services/tmdb_api_service.dart';
import 'package:mediahub/services/torrentio_api_service.dart';

/// What happens before a grab: is there a next episode, has it aired, which
/// IMDB id to search with, and is a queued key stale. TMDB and the engine
/// are faked at the service boundary; the grab itself only records.
void main() {
  late _World w;
  setUp(() => w = _World());

  group('fetchNextAfter', () {
    Future<void> next({bool announce = true}) => w.fetcher.fetchNextAfter(
      w.service,
      showId: 42,
      imdbId: 'tt11280740',
      showName: 'Severance',
      season: 1,
      episode: 1,
      quality: '2160p',
      announce: announce,
    );

    test('an aired episode is handed to the grab', () async {
      w.service.next = NextEpisodeResult(
        nextEpisode: _episode(2, 1, '2026-01-01'),
        hasAired: true,
      );
      await next(announce: false);

      final r = w.grabs.single;
      expect(
        [r.showId, r.imdbId, r.season, r.episode],
        [42, 'tt11280740', 2, 1],
      );
      expect(r.quality, '2160p');
      expect(r.announce, isFalse);
      expect(r.excludeHashes, isEmpty);
      expect(r.waitForFileSelection, isTrue);
    });

    test('nothing next: quiet for a day, and logged', () async {
      w.service.next = NextEpisodeResult(
        isSeriesEnd: true,
        message: 'The series has ended.',
      );
      final before = DateTime.now();
      await next();

      expect(w.grabs, isEmpty);
      expect(
        w.quiet[42]!.isBefore(before.add(EpisodeFetcher.idleBackoff)),
        isFalse,
      );
      final event = w.events.single;
      expect(event.type, AutoDownloadEventType.checked);
      expect(event.message, 'The series has ended.');
    });

    test('a failed lookup is asked again next time', () async {
      w.service.next = NextEpisodeResult(lookupFailed: true);
      await next(announce: false);

      expect(w.quiet, isEmpty);
      expect(w.events, isEmpty);
    });

    test('not aired: quiet until it airs, announced once', () async {
      w.service.next = NextEpisodeResult(
        nextEpisode: _episode(1, 2, '2099-03-04'),
      );
      await next();
      await next();

      expect(w.grabs, isEmpty);
      expect(w.quiet[42], DateTime.utc(2099, 3, 4).add(airDateGrace));
      final event = w.events.single;
      expect(event.type, AutoDownloadEventType.episodeQueued);
      expect(event.episodeCode, 'S01E02');
      expect(
        event.message,
        'Severance S01E02 will download once it airs (Mar 4, 2099).',
      );
    });

    test('nothing more once the notifier is gone', () async {
      w.service.next = NextEpisodeResult(isSeriesEnd: true);
      w.service.onLookup = () => w.mounted = false;
      await next();

      expect(w.quiet, isEmpty);
      expect(w.events, isEmpty);
    });
  });

  group('fetchNow', () {
    Future<EpisodeGrabResult> now({String? imdbId}) => w.fetcher.fetchNow(
      w.service,
      showId: 42,
      showName: 'Severance',
      imdbId: imdbId,
      season: 1,
      episode: 5,
    );

    test('an episode that has not aired is not searched for', () async {
      w.service.details = _episode(1, 5, '2099-03-04');
      final result = await now(imdbId: 'tt1');

      expect(result.outcome, EpisodeGrabOutcome.notAired);
      expect(result.message, 'Severance S01E05 airs Mar 4, 2099.');
      expect(w.grabs, isEmpty);
    });

    test('nor one TMDB has no date for', () async {
      w.service.details = _episode(1, 5, null);
      final result = await now(imdbId: 'tt1');

      expect(result.message, "Severance S01E05 hasn't aired yet.");
      expect(w.grabs, isEmpty);
    });

    test('without the air date it tries anyway', () async {
      w.service.detailsError = Exception('TMDB down');
      await now(imdbId: 'tt1');

      expect(w.grabs, hasLength(1));
    });

    test('resolves the IMDB id when it has none', () async {
      w.service.imdbId = 'tt11280740';
      await now();

      expect(w.service.imdbLookups, 1);
      expect(w.grabs.single.imdbId, 'tt11280740');
    });

    test('uses the IMDB id it is given', () async {
      await now(imdbId: 'tt1');

      expect(w.service.imdbLookups, 0);
      expect(w.grabs.single.imdbId, 'tt1');
    });

    test('TMDB unreachable for the IMDB id is said plainly', () async {
      w.service.imdbError = Exception('offline');
      final result = await now();

      expect(result.outcome, EpisodeGrabOutcome.failed);
      expect(
        result.message,
        "Couldn't reach TMDB. Check your connection and try again.",
      );
      expect(w.grabs, isEmpty);
    });

    test('a show TMDB has no IMDB id for is said plainly', () async {
      final result = await now();

      expect(
        result.message,
        "Couldn't search for Severance S01E05: TMDB has no IMDb id for "
        'Severance.',
      );
      expect(w.grabs, isEmpty);
    });

    test('asks for the show\'s quality, and does not wait on a pack', () async {
      w.quality = '720p';
      await now(imdbId: 'tt1');

      final r = w.grabs.single;
      expect([r.season, r.episode, r.quality], [1, 5, '720p']);
      expect(r.announce, isTrue);
      expect(r.waitForFileSelection, isFalse);
    });

    group('a queued key', () {
      setUp(
        () => w.state = const AutoDownloadState(
          downloadQueue: {'42_S01E05'},
          queuedTorrents: {'42_S01E05': 'abc'},
        ),
      );

      test('whose torrent is gone is released first', () async {
        w.service.engine = [];
        await now(imdbId: 'tt1');

        expect(w.queueAtGrab, isEmpty);
      });

      test('whose torrent is there stays', () async {
        w.service.engine = [
          Torrent.fromJson({'hash': 'ABC'}),
        ];
        await now(imdbId: 'tt1');

        expect(w.queueAtGrab, {'42_S01E05'});
      });

      test('stays while the engine cannot be asked', () async {
        w.service.engine = null;
        await now(imdbId: 'tt1');

        expect(w.queueAtGrab, {'42_S01E05'});
      });
    });
  });
}

Episode _episode(int season, int number, String? airDate) => Episode(
  id: season * 100 + number,
  seasonNumber: season,
  episodeNumber: number,
  name: 'Episode $number',
  airDate: airDate,
);

/// The state in memory, the service faked, and the grab recorded.
class _World {
  AutoDownloadState state = const AutoDownloadState();
  bool mounted = true;
  String quality = '1080p';
  final Map<int, DateTime> quiet = {};
  final List<AutoDownloadEvent> events = [];
  final List<EpisodeGrabRequest> grabs = [];

  /// The queue as the grab found it.
  Set<String>? queueAtGrab;

  final _Service service = _Service();

  late final AutoDownloadLedger ledger = AutoDownloadLedger(
    read: () => state,
    write: (next) => state = next,
    save: () async {},
    mounted: () => mounted,
    addEvent: (event) async => events.add(event),
  );

  late final EpisodeFetcher fetcher = EpisodeFetcher(
    ledger: ledger,
    quietUntil: quiet,
    grab: (request) async {
      grabs.add(request);
      queueAtGrab = state.downloadQueue;
      return const EpisodeGrabResult(EpisodeGrabOutcome.started, 'ok');
    },
    qualityFor: (_) => quality,
  );
}

class _Service extends AutoDownloadService {
  _Service()
    : super(
        tmdbService: TmdbApiService(accessToken: 'test'),
        eztvService: EztvApiService(),
        engine: QBittorrentApiService(),
        torrentioService: TorrentioApiService(),
        clock: () => DateTime.utc(2026, 1, 8, 12),
      );

  NextEpisodeResult next = NextEpisodeResult();
  void Function()? onLookup;
  Episode? details;
  Object? detailsError;
  String? imdbId;
  Object? imdbError;
  int imdbLookups = 0;
  List<Torrent>? engine = const [];

  @override
  Future<NextEpisodeResult> getNextEpisode({
    required int showId,
    required int currentSeason,
    required int currentEpisode,
  }) async {
    onLookup?.call();
    return next;
  }

  @override
  Future<Episode?> episodeDetails(int showId, int season, int episode) async {
    final error = detailsError;
    if (error != null) throw error;
    return details;
  }

  @override
  Future<String?> imdbIdForShow(int showId) async {
    imdbLookups++;
    final error = imdbError;
    if (error != null) throw error;
    return imdbId;
  }

  @override
  Future<List<Torrent>?> engineTorrents() async => engine;
}
