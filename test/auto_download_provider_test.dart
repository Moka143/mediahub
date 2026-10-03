import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/auto_download_event.dart';
import 'package:mediahub/models/episode.dart';
import 'package:mediahub/models/eztv_torrent.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/torrent_file.dart';
import 'package:mediahub/models/torrentio_stream.dart';
import 'package:mediahub/providers/auto_download_events_provider.dart';
import 'package:mediahub/providers/auto_download_provider.dart';
import 'package:mediahub/providers/local_media_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/services/auto_download_service.dart';
import 'package:mediahub/services/eztv_api_service.dart';
import 'package:mediahub/services/qbittorrent_api_service.dart';
import 'package:mediahub/services/tmdb_api_service.dart';
import 'package:mediahub/services/torrentio_api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// State, gating and orchestration tests for [AutoDownloadNotifier].
///
/// Everything outside the notifier is faked — TMDB, both indexers and the
/// torrent engine — so these exercise the decisions that cost a user
/// something when they go wrong: downloading a whole backlog unasked, never
/// downloading again after one stalled download was deleted, adding the
/// same episode twice, or searching for one that has not aired.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const key = 'auto_download_state';

  /// Aired a week before "today" in these tests, and one airing next month.
  const aired = '2026-01-01';
  const future = '2099-01-01';

  Future<(ProviderContainer, _Fakes)> container({
    Map<String, Object> seed = const {},
    List<LocalMediaFile> library = const [],
    _Fakes? fakes,
  }) async {
    SharedPreferences.setMockInitialValues(seed);
    final prefs = await SharedPreferences.getInstance();
    final f = fakes ?? _Fakes();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        autoDownloadServiceProvider.overrideWithValue(f.service),
        localMediaFilesProvider.overrideWith((ref) async => library),
        localMediaStreamProvider.overrideWith(
          (ref) => Stream<List<LocalMediaFile>>.value(library),
        ),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(localMediaFilesProvider, (_, _) {});
    addTearDown(sub.close);
    await c.read(localMediaFilesProvider.future);
    return (c, f);
  }

  AutoDownloadNotifier notifierOf(ProviderContainer c) {
    final sub = c.listen(autoDownloadProvider, (_, _) {});
    addTearDown(sub.close);
    final events = c.listen(autoDownloadEventsProvider, (_, _) {});
    addTearDown(events.close);
    return c.read(autoDownloadProvider.notifier);
  }

  Map<String, dynamic>? persisted(ProviderContainer c) {
    final raw = c.read(sharedPreferencesProvider).getString(key);
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  List<AutoDownloadEventType> eventTypes(ProviderContainer c) => [
    for (final e in c.read(autoDownloadEventsProvider)) e.type,
  ];

  /// A stored state tracking show 42 ("Severance") at S01E01 with [status].
  Map<String, Object> tracking(
    EpisodeDownloadStatus status, {
    String? hash,
    bool enabled = true,
    List<String> queue = const [],
    Map<String, String> queued = const {},
  }) => {
    key: jsonEncode({
      'enabled': enabled,
      'download_queue': queue,
      'queued_torrents': queued,
      'last_downloaded_episodes': {
        '42': EpisodeTrackingInfo(
          showId: 42,
          imdbId: 'tt11280740',
          showName: 'Severance',
          season: 1,
          episode: 1,
          status: status,
          torrentHash: hash,
        ).toJson(),
      },
    }),
  };

  group('load', () {
    test('a fresh store yields defaults with auto-download off', () async {
      final (c, _) = await container();
      expect(c.read(autoDownloadProvider).enabled, isFalse);
    });

    test('corrupt JSON degrades to defaults and is kept aside', () async {
      final (c, _) = await container(seed: {key: 'definitely not json'});
      expect(c.read(autoDownloadProvider).enabled, isFalse);
      expect(
        c.read(sharedPreferencesProvider).getString('$key.corrupt'),
        'definitely not json',
      );
    });

    test('one unreadable show costs that show, not every show', () async {
      // An unknown status index used to throw, and the loader reset the
      // whole state — which the next save then made permanent.
      final good = EpisodeTrackingInfo(
        showId: 1,
        showName: 'Good',
        season: 1,
        episode: 1,
        status: EpisodeDownloadStatus.watched,
      ).toJson();
      final raw = jsonEncode({
        'enabled': true,
        'default_quality': '2160p',
        'last_downloaded_episodes': {
          '1': good,
          '2': {...good, 'show_id': 2, 'status': 99},
        },
      });
      final (c, _) = await container(seed: {key: raw});

      final state = c.read(autoDownloadProvider);
      expect(state.enabled, isTrue);
      expect(state.defaultQuality, '2160p');
      expect(state.lastDownloadedEpisodes.keys, [1]);
      expect(c.read(sharedPreferencesProvider).getString('$key.corrupt'), raw);
    });
  });

  group('isAutoDownloadActiveForShow', () {
    test(
      'downloadOnProgress off gates everything, override included',
      () async {
        final (c, _) = await container();
        final n = notifierOf(c);
        await n.setDownloadOnProgress(false);
        await n.setEnabled(true);
        await n.setShowAutoDownloadOverride(42, true);

        expect(n.isAutoDownloadActiveForShow(42), isFalse);
      },
    );

    test('a null show id falls back to the global flag', () async {
      final (c, _) = await container();
      final n = notifierOf(c);
      await n.setDownloadOnProgress(true);
      await n.setEnabled(true);

      expect(n.isAutoDownloadActiveForShow(null), isTrue);
    });

    test(
      'an override of true fires even when the global flag is off',
      () async {
        final (c, _) = await container();
        final n = notifierOf(c);
        await n.setDownloadOnProgress(true);
        await n.setEnabled(false);
        await n.setShowAutoDownloadOverride(42, true);

        expect(n.isAutoDownloadActiveForShow(42), isTrue);
        expect(n.isAutoDownloadActiveForShow(99), isFalse);
      },
    );

    test('an override of false suppresses a globally-enabled show', () async {
      final (c, _) = await container();
      final n = notifierOf(c);
      await n.setDownloadOnProgress(true);
      await n.setEnabled(true);
      await n.setShowAutoDownloadOverride(42, false);

      expect(n.isAutoDownloadActiveForShow(42), isFalse);
      expect(n.isAutoDownloadActiveForShow(99), isTrue);
    });

    test('clearing an override reverts to the global flag', () async {
      final (c, _) = await container();
      final n = notifierOf(c);
      await n.setDownloadOnProgress(true);
      await n.setEnabled(true);
      await n.setShowAutoDownloadOverride(42, false);
      await n.setShowAutoDownloadOverride(42, null);

      expect(n.isAutoDownloadActiveForShow(42), isTrue);
      expect(c.read(autoDownloadProvider).showAutoDownloadOverrides, isEmpty);
    });
  });

  group('settings', () {
    test('a per-show preference wins over the default', () async {
      final (c, _) = await container();
      final n = notifierOf(c);
      await n.setDefaultQuality('1080p');
      await n.setShowQualityPreference(42, '2160p');

      expect(n.getQualityPreference(42), '2160p');
      expect(n.getQualityPreference(99), '1080p');
    });

    test('the threshold is clamped', () async {
      final (c, _) = await container();
      final n = notifierOf(c);
      await n.setProgressThreshold(0.1);
      expect(c.read(autoDownloadProvider).progressThreshold, 0.5);
      await n.setProgressThreshold(1.5);
      expect(c.read(autoDownloadProvider).progressThreshold, 0.95);
      await n.setProgressThreshold(0.8);
      expect(c.read(autoDownloadProvider).progressThreshold, 0.8);
    });

    test('state survives a rebuild from prefs', () async {
      final (c, _) = await container();
      final n = notifierOf(c);
      await n.setDownloadOnProgress(true);
      await n.setShowAutoDownloadOverride(42, false);
      await n.setDefaultQuality('2160p');

      final reloaded = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            c.read(sharedPreferencesProvider),
          ),
        ],
      );
      addTearDown(reloaded.dispose);

      final restored = reloaded.read(autoDownloadProvider);
      expect(restored.defaultQuality, '2160p');
      expect(restored.downloadOnProgress, isTrue);
      expect(restored.showAutoDownloadOverrides[42], isFalse);
      expect(jsonEncode(persisted(c)), contains('2160p'));
    });
  });

  group('tracking and queue', () {
    test('trackShow records the episode and adopts its quality', () async {
      final (c, _) = await container();
      final n = notifierOf(c);
      await n.trackShow(
        showId: 42,
        imdbId: 'tt123',
        showName: 'Lioness',
        season: 2,
        episode: 1,
        quality: '2160p',
      );

      final tracked = c.read(showAutoDownloadTrackingProvider(42));
      expect(tracked!.season, 2);
      expect(tracked.status, EpisodeDownloadStatus.downloaded);
      expect(n.getQualityPreference(42), '2160p');
      expect(c.read(showAutoDownloadTrackingProvider(7)), isNull);
    });

    test('completing an unknown torrent disturbs nothing', () async {
      final (c, _) = await container(
        seed: {
          key: jsonEncode({
            'download_queue': ['42_S02E01'],
            'queued_torrents': {'42_S02E01': 'h'},
          }),
        },
      );
      await notifierOf(c).markDownloadCompleted('someone-else');

      expect(c.read(autoDownloadProvider).downloadQueue, {'42_S02E01'});
    });

    test(
      'completion releases every key its torrent was queued under',
      () async {
        // The tracking moves on to the next episode; the earlier key used to
        // stay queued for good, keeping the Calendar dot lit.
        final (c, _) = await container(
          seed: tracking(
            EpisodeDownloadStatus.downloading,
            hash: 'h2',
            queue: ['42_S01E01', '42_S01E02'],
            queued: {'42_S01E01': 'h1', '42_S01E02': 'h2'},
          ),
        );
        final n = notifierOf(c);
        await n.markDownloadCompleted('H1');

        expect(c.read(autoDownloadProvider).downloadQueue, {'42_S01E02'});
      },
    );
  });

  group('periodic check', () {
    _Fakes withNextEpisode({String airDate = aired}) => _Fakes(
      seasons: {
        1: [_episode(1, 1, aired), _episode(1, 2, airDate)],
      },
      eztv: [_eztv('next', 'Severance.S01E02.1080p.mkv', seeds: 30)],
    );

    test('does not fetch onward from an episode not yet watched', () async {
      // The backlog bug: `downloaded` counted as "fetch the next", so every
      // five minutes the next episode came down as soon as the last
      // finished, until the whole aired backlog was on disk.
      final (c, f) = await container(
        seed: tracking(EpisodeDownloadStatus.downloaded),
        fakes: withNextEpisode(),
      );
      await notifierOf(c).checkAndDownloadNextEpisodes();

      expect(f.engine.added, isEmpty);
      expect(f.eztv.calls, 0);
    });

    test('fetches the next episode once the tracked one is watched', () async {
      final (c, f) = await container(
        seed: tracking(EpisodeDownloadStatus.watched),
        fakes: withNextEpisode(),
      );
      await notifierOf(c).checkAndDownloadNextEpisodes();

      expect(f.engine.added, ['magnet:?xt=urn:btih:next']);
      final tracked = c.read(showAutoDownloadTrackingProvider(42))!;
      expect(tracked.episode, 2);
      expect(tracked.status, EpisodeDownloadStatus.downloading);
      expect(c.read(autoDownloadProvider).downloadQueue, {'42_S01E02'});
      expect(eventTypes(c), [AutoDownloadEventType.downloadStarted]);
    });

    test('does not search for an episode that has not aired', () async {
      final (c, f) = await container(
        seed: tracking(EpisodeDownloadStatus.watched),
        fakes: withNextEpisode(airDate: future),
      );
      await notifierOf(c).checkAndDownloadNextEpisodes();

      expect(f.eztv.calls, 0);
      expect(f.engine.added, isEmpty);
    });

    test('a download deleted from Transfers is released and retried', () async {
      // Nothing ever cleared the queue key or the `downloading` status but
      // completion, so deleting a stalled download blocked that episode —
      // and the background check for that show — forever.
      final fakes = _Fakes(
        seasons: {
          1: [_episode(1, 1, aired)],
        },
        eztv: [
          _eztv('stalled', 'Severance.S01E01.1080p.mkv', seeds: 90),
          _eztv('healthy', 'Severance.S01E01.720p.mkv', seeds: 12),
        ],
      );
      final (c, f) = await container(
        seed: tracking(
          EpisodeDownloadStatus.downloading,
          hash: 'stalled',
          queue: ['42_S01E01'],
          queued: {'42_S01E01': 'stalled'},
        ),
        fakes: fakes,
      );
      final n = notifierOf(c);

      // One miss could be the engine restarting.
      await n.checkAndDownloadNextEpisodes();
      expect(c.read(autoDownloadProvider).downloadQueue, {'42_S01E01'});

      await n.checkAndDownloadNextEpisodes();
      expect(eventTypes(c), contains(AutoDownloadEventType.downloadFailed));
      // ...and fetched again — from another source, never the one that died.
      expect(f.engine.added, ['magnet:?xt=urn:btih:healthy']);
      expect(
        c.read(showAutoDownloadTrackingProvider(42))!.torrentHash,
        'healthy',
      );
    });

    test('an unreachable engine releases nothing', () async {
      final (c, f) = await container(
        seed: tracking(
          EpisodeDownloadStatus.downloading,
          hash: 'h',
          queue: ['42_S01E01'],
          queued: {'42_S01E01': 'h'},
        ),
        fakes: _Fakes(reachable: false),
      );
      final n = notifierOf(c);
      await n.checkAndDownloadNextEpisodes();
      await n.checkAndDownloadNextEpisodes();

      expect(c.read(autoDownloadProvider).downloadQueue, {'42_S01E01'});
      expect(f.engine.added, isEmpty);
    });
  });

  group('onWatchProgress', () {
    Future<void> watch(AutoDownloadNotifier n, {int episode = 1}) =>
        n.onWatchProgress(
          showId: 42,
          imdbId: 'tt11280740',
          showName: 'Severance',
          season: 1,
          episode: episode,
          progress: 0.8,
          currentQuality: '1080p',
        );

    test('downloads, not streams: no size cap on the preference', () async {
      // The 900 MB streaming cap applied here too, so a 2.1 GB 1080p lost
      // to an 800 MB 720p for every show that preferred 1080p.
      final (c, f) = await container(
        seed: {
          key: jsonEncode({'enabled': true}),
        },
        fakes: _Fakes(
          seasons: {
            1: [_episode(1, 1, aired), _episode(1, 2, aired)],
          },
          eztv: [
            _eztv('big', 'Severance.S01E02.1080p.mkv', seeds: 30, gb: 2.1),
            _eztv('small', 'Severance.S01E02.720p.mkv', seeds: 30, gb: 0.8),
          ],
        ),
      );
      await watch(notifierOf(c));

      expect(f.engine.added, ['magnet:?xt=urn:btih:big']);
    });

    test('two triggers at once add the episode once', () async {
      final (c, f) = await container(
        seed: {
          key: jsonEncode({'enabled': true}),
        },
        fakes: _Fakes(
          seasons: {
            1: [_episode(1, 1, aired), _episode(1, 2, aired)],
          },
          eztv: [_eztv('next', 'Severance.S01E02.1080p.mkv', seeds: 30)],
        ),
      );
      final n = notifierOf(c);
      await Future.wait([watch(n), watch(n), n.checkAndDownloadNextEpisodes()]);

      expect(f.engine.added, hasLength(1));
    });

    test('an unaired next episode is announced once, not searched', () async {
      final (c, f) = await container(
        seed: {
          key: jsonEncode({'enabled': true}),
        },
        fakes: _Fakes(
          seasons: {
            1: [_episode(1, 1, aired), _episode(1, 2, future)],
          },
        ),
      );
      final n = notifierOf(c);
      await watch(n);
      await watch(n);

      expect(f.eztv.calls, 0);
      expect(eventTypes(c), [AutoDownloadEventType.episodeQueued]);
    });

    test('logs the quality it found, not the one it asked for', () async {
      final (c, _) = await container(
        seed: {
          key: jsonEncode({'enabled': true}),
        },
        fakes: _Fakes(
          seasons: {
            1: [_episode(1, 1, aired), _episode(1, 2, aired)],
          },
          eztv: [_eztv('hd', 'Severance.S01E02.720p.mkv', seeds: 9)],
        ),
      );
      await watch(notifierOf(c));

      final started = c.read(autoDownloadEventsProvider).single;
      expect(started.quality, '720p');
      expect(started.message, contains('720p'));
    });
  });

  group('downloadEpisodeNow', () {
    _Fakes grabbable({String airDate = aired, List<EztvTorrent>? eztv}) =>
        _Fakes(
          seasons: {
            1: [_episode(1, 5, airDate)],
          },
          eztv: eztv ?? [_eztv('h5', 'Severance.S01E05.1080p.mkv', seeds: 20)],
          imdbId: 'tt11280740',
        );

    Future<EpisodeGrabResult> grab(AutoDownloadNotifier n) =>
        n.downloadEpisodeNow(
          showId: 42,
          showName: 'Severance',
          season: 1,
          episode: 5,
        );

    test('starts it, resolving the IMDB id itself', () async {
      final (c, f) = await container(fakes: grabbable());
      final result = await grab(notifierOf(c));

      expect(result.outcome, EpisodeGrabOutcome.started);
      expect(result.ok, isTrue);
      expect(f.tmdb.imdbLookups, 1);
      expect(f.engine.added, ['magnet:?xt=urn:btih:h5']);
      expect(c.read(autoDownloadProvider).downloadQueue, {'42_S01E05'});
    });

    test('a second click does not add it twice', () async {
      final (c, f) = await container(fakes: grabbable());
      final n = notifierOf(c);
      await grab(n);
      final again = await grab(n);

      expect(again.outcome, EpisodeGrabOutcome.alreadyQueued);
      expect(f.engine.added, hasLength(1));
    });

    test('an episode already on disk says so', () async {
      final (c, f) = await container(
        fakes: grabbable(),
        library: [
          LocalMediaFile(
            path: '/lib/Severance.S01E05.mkv',
            fileName: 'Severance.S01E05.mkv',
            sizeBytes: 1,
            modifiedDate: DateTime(2026),
            showName: 'Severance',
            seasonNumber: 1,
            episodeNumber: 5,
            extension: 'mkv',
          ),
        ],
      );
      final result = await grab(notifierOf(c));

      expect(result.outcome, EpisodeGrabOutcome.alreadyDownloaded);
      expect(f.engine.added, isEmpty);
    });

    test('an episode that has not aired is not searched for', () async {
      final (c, f) = await container(fakes: grabbable(airDate: future));
      final result = await grab(notifierOf(c));

      expect(result.outcome, EpisodeGrabOutcome.notAired);
      expect(result.ok, isFalse);
      expect(f.eztv.calls, 0);
    });

    test('no source is said plainly', () async {
      final (c, _) = await container(fakes: grabbable(eztv: const []));
      final result = await grab(notifierOf(c));

      expect(result.outcome, EpisodeGrabOutcome.noTorrent);
      expect(result.message, 'No source found for Severance S01E05 yet.');
    });

    test('a stale queue key does not block the click', () async {
      // Queued, but its torrent is no longer in the engine.
      final (c, f) = await container(
        seed: {
          key: jsonEncode({
            'download_queue': ['42_S01E05'],
            'queued_torrents': {'42_S01E05': 'gone'},
          }),
        },
        fakes: grabbable(),
      );
      final result = await grab(notifierOf(c));

      expect(result.outcome, EpisodeGrabOutcome.started);
      expect(f.engine.added, hasLength(1));
    });
  });
}

Episode _episode(int season, int number, String airDate) => Episode(
  id: season * 100 + number,
  seasonNumber: season,
  episodeNumber: number,
  name: 'Episode $number',
  airDate: airDate,
);

EztvTorrent _eztv(
  String hash,
  String filename, {
  int seeds = 0,
  double gb = 0,
}) => EztvTorrent(
  id: hash.hashCode,
  hash: hash,
  filename: filename,
  magnetUrl: 'magnet:?xt=urn:btih:$hash',
  title: filename,
  seeds: seeds,
  sizeBytes: (gb * 1024 * 1024 * 1024).round(),
);

Torrent _torrent(String hash, String name) => Torrent(
  hash: hash,
  name: name,
  size: 0,
  progress: 0.2,
  dlspeed: 0,
  upspeed: 0,
  eta: 0,
  state: 'downloading',
  numSeeds: 0,
  numLeeches: 0,
  ratio: 0,
  addedOn: 0,
  completionOn: 0,
  savePath: '',
  downloaded: 0,
  uploaded: 0,
  numComplete: 0,
  numIncomplete: 0,
  category: '',
  tags: '',
  priority: 0,
  amountLeft: 0,
  tracker: '',
  seenComplete: 0,
  lastActivity: 0,
  totalSize: 0,
  pieceSize: 0,
  piecesNum: 0,
  piecesHave: 0,
  contentPath: '',
  sequentialDownload: false,
  firstLastPiecePriority: false,
);

/// The faked world, and a real [AutoDownloadService] wired to it.
class _Fakes {
  _Fakes({
    Map<int, List<Episode>> seasons = const {},
    List<EztvTorrent> eztv = const [],
    bool reachable = true,
    String? imdbId,
  }) : tmdb = _FakeTmdb(seasons, imdbId),
       eztv = _FakeEztv(eztv),
       engine = _FakeEngine(reachable: reachable);

  final _FakeTmdb tmdb;
  final _FakeEztv eztv;
  final _FakeEngine engine;

  late final AutoDownloadService service = AutoDownloadService(
    tmdbService: tmdb,
    eztvService: eztv,
    engine: engine,
    torrentioService: _NoTorrentio(),
    clock: () => DateTime.utc(2026, 1, 8, 12),
    metadataPollInterval: Duration.zero,
    metadataTimeout: Duration.zero,
  );
}

class _FakeTmdb extends TmdbApiService {
  _FakeTmdb(this.seasons, this.imdbId) : super(accessToken: 'test');

  final Map<int, List<Episode>> seasons;
  final String? imdbId;
  int imdbLookups = 0;

  @override
  Future<Show> getShowDetails(int showId) async =>
      Show(id: showId, name: 'Severance', numberOfSeasons: seasons.length);

  @override
  Future<List<Episode>> getSeasonEpisodes(int showId, int seasonNumber) async {
    final found = seasons[seasonNumber];
    if (found == null) throw TmdbApiException('no season', statusCode: 404);
    return found;
  }

  @override
  Future<String?> getShowImdbId(int showId) async {
    imdbLookups++;
    return imdbId;
  }
}

class _FakeEztv extends EztvApiService {
  _FakeEztv(this.torrents);

  final List<EztvTorrent> torrents;
  int calls = 0;

  @override
  Future<List<EztvTorrent>> getTorrentsForEpisode(
    String imdbId, {
    int? season,
    int? episode,
  }) async {
    calls++;
    return EztvApiService.filterForEpisode(
      torrents,
      season: season,
      episode: episode,
    );
  }
}

class _NoTorrentio extends TorrentioApiService {
  @override
  Future<TorrentioResponse> getSeriesStreams(
    String imdbId, {
    required int season,
    required int episode,
  }) async => TorrentioResponse(streams: const <TorrentioStream>[]);
}

/// An engine that records adds and lists whatever [torrents] holds.
class _FakeEngine extends QBittorrentApiService {
  _FakeEngine({this.reachable = true});

  final bool reachable;
  final List<Torrent> torrents = [];
  final List<String> added = [];

  @override
  Future<bool> testConnection() async => reachable;

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
  }) async => reachable ? List.of(torrents) : const [];

  @override
  Future<bool> addTorrent({
    String? magnetLink,
    File? torrentFile,
    String? savePath,
    String? category,
    bool? paused,
    bool? skipChecking,
    bool? sequentialDownload,
  }) async {
    // Yield, like a real request, so concurrent triggers can interleave.
    await Future<void>.delayed(Duration.zero);
    added.add(magnetLink!);
    // The torrent is in Transfers from now on, as on a real engine.
    final hash = magnetLink.split('btih:').last;
    torrents.add(_torrent(hash, hash));
    return true;
  }

  @override
  Future<List<TorrentFile>> getTorrentFiles(String hash) async => const [];
}
