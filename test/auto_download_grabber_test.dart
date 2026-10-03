import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/auto_download_event.dart';
import 'package:mediahub/models/auto_download_state.dart';
import 'package:mediahub/models/episode_grab_result.dart';
import 'package:mediahub/models/eztv_torrent.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/providers/auto_download/auto_download_ledger.dart';
import 'package:mediahub/providers/auto_download/episode_grabber.dart';
import 'package:mediahub/services/auto_download_service.dart';
import 'package:mediahub/services/eztv_api_service.dart';
import 'package:mediahub/services/qbittorrent_api_service.dart';
import 'package:mediahub/services/tmdb_api_service.dart';
import 'package:mediahub/services/torrentio_api_service.dart';

/// The steps of one grab, with the indexers and the engine faked at the
/// service boundary and the state in memory.
void main() {
  const request = EpisodeGrabRequest(
    showId: 42,
    imdbId: 'tt11280740',
    showName: 'Severance',
    season: 1,
    episode: 2,
    quality: '1080p',
    announce: true,
  );

  late _World w;
  setUp(() => w = _World());

  test('the request names its episode', () {
    expect(request.key, '42_S01E02');
    expect(request.label, 'Severance S01E02');
    final t = request.tracking(
      EpisodeDownloadStatus.downloading,
      quality: '720p',
      torrentHash: 'abc',
    );
    expect(
      [t.showId, t.imdbId, t.showName, t.season, t.episode, t.quality],
      [42, 'tt11280740', 'Severance', 1, 2, '720p'],
    );
    expect(t.torrentHash, 'abc');
  });

  group('nothing to fetch', () {
    test('already queued: says so, searches nothing', () async {
      w.state = const AutoDownloadState(downloadQueue: {'42_S01E02'});
      final result = await w.grabber().grab(request);

      expect(result.outcome, EpisodeGrabOutcome.alreadyQueued);
      expect(result.message, 'Severance S01E02 is already downloading.');
      expect(w.service.searches, isEmpty);
      expect(w.saves, 0);
    });

    test('in the library: says so, searches nothing', () async {
      final result = await w
          .grabber(library: [_onDisk('Severance', 1, 2)])
          .grab(request);

      expect(result.outcome, EpisodeGrabOutcome.alreadyDownloaded);
      expect(result.message, 'Severance S01E02 is already in your library.');
      expect(w.service.searches, isEmpty);
    });

    test('already in Transfers: says so and releases the key', () async {
      w.service.inTransfers = true;
      final result = await w.grabber().grab(request);

      expect(result.outcome, EpisodeGrabOutcome.alreadyQueued);
      expect(result.message, 'Severance S01E02 is already in Transfers.');
      expect(w.service.searches, isEmpty);
      expect(w.state.downloadQueue, isEmpty);
    });
  });

  group('no source', () {
    test('backs off, keeps the episode wanted, and says so', () async {
      final quiet = <int, DateTime>{};
      final before = DateTime.now();
      final result = await w
          .grabber(quiet: quiet)
          .grab(_with(request, exclude: {'dead'}));

      expect(result.outcome, EpisodeGrabOutcome.noTorrent);
      expect(result.message, 'No source found for Severance S01E02 yet.');
      expect(
        quiet[42]!.isBefore(before.add(EpisodeGrabber.missBackoff)),
        isFalse,
      );
      final t = w.state.lastDownloadedEpisodes[42]!;
      expect(t.status, EpisodeDownloadStatus.awaitingTorrent);
      expect(t.quality, '1080p');
      expect(t.torrentHash, 'dead', reason: 'still the one not to pick');
      expect(w.events.single.type, AutoDownloadEventType.torrentNotFound);
      expect(w.state.downloadQueue, isEmpty);
    });

    test('the background check does not log it', () async {
      await w.grabber().grab(_with(request, announce: false));

      expect(w.events, isEmpty);
      expect(
        w.state.lastDownloadedEpisodes[42]!.status,
        EpisodeDownloadStatus.awaitingTorrent,
      );
    });

    test('an episode before the tracked one leaves the tracking', () async {
      final ahead = request.tracking(
        EpisodeDownloadStatus.watched,
        quality: '1080p',
      );
      w.state = AutoDownloadState(
        lastDownloadedEpisodes: {42: ahead.copyWith(episode: 5)},
      );
      await w.grabber().grab(request);

      expect(w.state.lastDownloadedEpisodes[42]!.episode, 5);
    });
  });

  test(
    'searches for a download: no size cap, the failed one excluded',
    () async {
      await w.grabber().grab(_with(request, exclude: {'dead'}));

      final search = w.service.searches.single;
      expect(search.imdbId, 'tt11280740');
      expect(search.quality, '1080p');
      expect(search.forStreaming, isFalse);
      expect(search.exclude, {'dead'});
    },
  );

  test('the engine refusing it is a failure, logged', () async {
    w.service
      ..source = _source('ABC', 'Severance.S01E02.720p.mkv')
      ..addOk = false;
    final result = await w.grabber().grab(request);

    expect(result.outcome, EpisodeGrabOutcome.failed);
    expect(result.message, grabFailed.message);
    final event = w.events.single;
    expect(event.type, AutoDownloadEventType.downloadFailed);
    expect(event.quality, '720p');
    expect(w.state.downloadQueue, isEmpty);
  });

  test('started: queued under its hash, tracked and logged', () async {
    w.service.source = _source('ABC', 'Severance.S01E02.720p.mkv', fileIdx: 3);
    final result = await w.grabber().grab(_with(request, waitForFiles: false));

    expect(result.outcome, EpisodeGrabOutcome.started);
    expect(result.message, 'Downloading Severance S01E02 in 720p.');
    expect(w.state.downloadQueue, {'42_S01E02'});
    expect(w.state.queuedTorrents, {'42_S01E02': 'abc'});
    final t = w.state.lastDownloadedEpisodes[42]!;
    expect(t.status, EpisodeDownloadStatus.downloading);
    expect(t.quality, '720p', reason: 'what was found, not what was asked');
    expect(t.torrentHash, 'abc');
    final event = w.events.single;
    expect(event.type, AutoDownloadEventType.downloadStarted);
    expect(event.message, 'Started downloading Severance S01E02 in 720p.');
    final add = w.service.adds.single;
    expect(add.magnet, 'magnet:?xt=urn:btih:ABC');
    expect(add.savePath, '/downloads');
    expect(add.fileIdx, 3);
    expect(add.wait, isFalse);
  });

  test('an unknown quality is not announced as one', () async {
    w.service.source = _source('ABC', 'Severance.S01E02.mkv');
    final result = await w.grabber().grab(request);

    expect(result.message, 'Downloading Severance S01E02.');
  });

  test('a failing engine is a failure, and frees the key', () async {
    w.service
      ..source = _source('ABC', 'Severance.S01E02.720p.mkv')
      ..addError = StateError('engine gone');
    final result = await w.grabber().grab(request);

    expect(result.outcome, EpisodeGrabOutcome.failed);
    expect(w.state.downloadQueue, isEmpty);
  });

  test('gone mid-grab: a started download keeps its key', () async {
    w.service
      ..source = _source('ABC', 'Severance.S01E02.720p.mkv')
      ..onAdd = () => w.mounted = false;
    final result = await w.grabber().grab(request);

    expect(result.outcome, EpisodeGrabOutcome.started);
    expect(w.state.downloadQueue, {'42_S01E02'});
    expect(w.state.lastDownloadedEpisodes, isEmpty);
  });
}

EpisodeGrabRequest _with(
  EpisodeGrabRequest r, {
  Set<String> exclude = const {},
  bool announce = true,
  bool waitForFiles = true,
}) => EpisodeGrabRequest(
  showId: r.showId,
  imdbId: r.imdbId,
  showName: r.showName,
  season: r.season,
  episode: r.episode,
  quality: r.quality,
  announce: announce,
  excludeHashes: exclude,
  waitForFileSelection: waitForFiles,
);

EztvTorrent _source(String hash, String filename, {int? fileIdx}) =>
    EztvTorrent(
      id: 1,
      hash: hash,
      filename: filename,
      magnetUrl: 'magnet:?xt=urn:btih:$hash',
      title: filename,
      seeds: 10,
      fileIdx: fileIdx,
    );

LocalMediaFile _onDisk(String show, int season, int episode) => LocalMediaFile(
  path: '/lib/$show.S0${season}E0$episode.mkv',
  fileName: '$show.S0${season}E0$episode.mkv',
  sizeBytes: 1,
  modifiedDate: DateTime(2026),
  showName: show,
  seasonNumber: season,
  episodeNumber: episode,
  extension: 'mkv',
);

/// The state in memory, and the service with its network faked.
class _World {
  AutoDownloadState state = const AutoDownloadState();
  int saves = 0;
  bool mounted = true;
  final List<AutoDownloadEvent> events = [];
  final _Service service = _Service();

  late final AutoDownloadLedger ledger = AutoDownloadLedger(
    read: () => state,
    write: (next) => state = next,
    save: () async {
      saves++;
    },
    mounted: () => mounted,
    addEvent: (event) async => events.add(event),
  );

  EpisodeGrabber grabber({
    List<LocalMediaFile> library = const [],
    Map<int, DateTime>? quiet,
  }) => EpisodeGrabber(
    service: service,
    ledger: ledger,
    savePath: '/downloads',
    library: () => library,
    quietUntil: quiet ?? {},
  );
}

typedef _Search = ({
  String imdbId,
  String? quality,
  bool forStreaming,
  Set<String> exclude,
});

typedef _Add = ({String magnet, String? savePath, int? fileIdx, bool wait});

class _Service extends AutoDownloadService {
  _Service()
    : super(
        tmdbService: TmdbApiService(accessToken: 'test'),
        eztvService: EztvApiService(),
        engine: QBittorrentApiService(),
        torrentioService: TorrentioApiService(),
      );

  bool inTransfers = false;
  EztvTorrent? source;
  bool addOk = true;
  Object? addError;
  void Function()? onAdd;
  final List<_Search> searches = [];
  final List<_Add> adds = [];

  @override
  Future<bool> isEpisodeCurrentlyDownloading({
    required String showName,
    required int season,
    required int episode,
  }) async => inTransfers;

  @override
  Future<EztvTorrent?> findTorrentForEpisode({
    required String imdbId,
    required int season,
    required int episode,
    String? preferredQuality,
    bool forStreaming = true,
    Set<String> excludeHashes = const {},
  }) async {
    searches.add((
      imdbId: imdbId,
      quality: preferredQuality,
      forStreaming: forStreaming,
      exclude: excludeHashes,
    ));
    return source;
  }

  @override
  Future<bool> downloadNextEpisode({
    required String magnetLink,
    String? savePath,
    String? infoHash,
    int? fileIdx,
    bool waitForFileSelection = true,
  }) async {
    final error = addError;
    if (error != null) throw error;
    adds.add((
      magnet: magnetLink,
      savePath: savePath,
      fileIdx: fileIdx,
      wait: waitForFileSelection,
    ));
    onAdd?.call();
    return addOk;
  }
}
