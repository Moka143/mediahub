import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/torrent_provider.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for `filteredTorrentsProvider` — the derivation that decides what
/// the Downloads list actually shows.
///
/// It sits downstream of four independent inputs (filter, sort, direction,
/// search) and is re-derived on every poll tick, but nothing covered the
/// combination. A wrong predicate here hides a torrent the user can see is
/// running; a wrong comparator silently reorders the list under them.
///
/// `torrentListProvider` is overridden with a fixed list so no qBittorrent
/// connection is involved.
void main() {
  /// A torrent with only the fields a given test cares about.
  Torrent t({
    String hash = 'h',
    String name = 'sample',
    int size = 1000,
    double progress = 0.0,
    int dlspeed = 0,
    int upspeed = 0,
    int eta = 0,
    String state = TorrentState.downloading,
    int addedOn = 0,
  }) {
    return Torrent.fromJson({
      'hash': hash,
      'name': name,
      'size': size,
      'progress': progress,
      'dlspeed': dlspeed,
      'upspeed': upspeed,
      'eta': eta,
      'state': state,
      'added_on': addedOn,
    });
  }

  late SharedPreferences prefs;

  setUp(() async {
    // The filter/sort/direction notifiers persist the user's choice, so they
    // need a store even though these tests only care about the derivation.
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// A container whose torrent list is exactly [torrents].
  ProviderContainer withTorrents(List<Torrent> torrents) {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        torrentListProvider.overrideWith(
          () => _FixedTorrentList(TorrentListState(torrents: torrents)),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  List<String> namesFrom(ProviderContainer c) =>
      c.read(filteredTorrentsProvider).map((t) => t.name).toList();

  group('filter', () {
    test('all keeps everything', () {
      final c = withTorrents([
        t(name: 'a', state: TorrentState.downloading),
        t(name: 'b', state: TorrentState.uploading),
        t(name: 'c', state: TorrentState.pausedDL),
      ]);
      c.read(currentFilterProvider.notifier).set(TorrentFilter.all);

      expect(namesFrom(c), hasLength(3));
    });

    test('downloading keeps only downloading rows', () {
      final c = withTorrents([
        t(name: 'a', state: TorrentState.downloading),
        t(name: 'b', state: TorrentState.uploading),
      ]);
      c.read(currentFilterProvider.notifier).set(TorrentFilter.downloading);

      expect(namesFrom(c), ['a']);
    });

    test('paused treats qBit 5.x "stopped" as paused', () {
      final c = withTorrents([
        t(name: 'stopped', state: TorrentState.stoppedDL),
        t(name: 'running', state: TorrentState.downloading),
      ]);
      c.read(currentFilterProvider.notifier).set(TorrentFilter.paused);

      expect(namesFrom(c), ['stopped']);
    });

    test('inactive is the exact complement of active', () {
      final rows = [
        t(name: 'a', state: TorrentState.downloading, dlspeed: 500),
        t(name: 'b', state: TorrentState.pausedDL),
        t(name: 'c', state: TorrentState.uploading, upspeed: 500),
        t(name: 'd', state: TorrentState.stalledDL),
      ];

      final active = withTorrents(rows);
      active.read(currentFilterProvider.notifier).set(TorrentFilter.active);
      final inactive = withTorrents(rows);
      inactive.read(currentFilterProvider.notifier).set(TorrentFilter.inactive);

      expect(
        {...namesFrom(active), ...namesFrom(inactive)},
        {'a', 'b', 'c', 'd'},
        reason: 'every row lands in exactly one of the two',
      );
      expect(
        namesFrom(active).toSet().intersection(namesFrom(inactive).toSet()),
        isEmpty,
      );
    });

    test('errored keeps only rows in an error state', () {
      final c = withTorrents([
        t(name: 'broken', state: TorrentState.error),
        t(name: 'fine', state: TorrentState.downloading),
      ]);
      c.read(currentFilterProvider.notifier).set(TorrentFilter.errored);

      expect(namesFrom(c), ['broken']);
    });
  });

  group('search', () {
    test('matches a substring case-insensitively', () {
      final c = withTorrents([
        t(name: 'Lioness.S02E01.1080p'),
        t(name: 'Dune.Part.Two.2160p'),
      ]);
      c.read(torrentSearchQueryProvider.notifier).set('lioness');

      expect(namesFrom(c), ['Lioness.S02E01.1080p']);
    });

    test('surrounding whitespace does not defeat a match', () {
      final c = withTorrents([t(name: 'Lioness.S02E01')]);
      c.read(torrentSearchQueryProvider.notifier).set('  lioness  ');

      expect(namesFrom(c), hasLength(1));
    });

    test('an empty query filters nothing out', () {
      final c = withTorrents([t(name: 'a'), t(name: 'b')]);
      c.read(torrentSearchQueryProvider.notifier).set('   ');

      expect(namesFrom(c), hasLength(2));
    });

    test('applies on top of the filter, not instead of it', () {
      final c = withTorrents([
        t(name: 'Lioness', state: TorrentState.downloading),
        t(name: 'Lioness.Extras', state: TorrentState.uploading),
      ]);
      c.read(currentFilterProvider.notifier).set(TorrentFilter.downloading);
      c.read(torrentSearchQueryProvider.notifier).set('lioness');

      expect(namesFrom(c), ['Lioness']);
    });
  });

  group('sort', () {
    test('by name is case-insensitive', () {
      final c = withTorrents([t(name: 'beta'), t(name: 'Alpha')]);
      c.read(currentSortProvider.notifier).set(TorrentSort.name);
      c.read(sortAscendingProvider.notifier).set(true);

      expect(namesFrom(c), ['Alpha', 'beta']);
    });

    test('descending is the exact reverse of ascending', () {
      final rows = [
        t(name: 'small', size: 10),
        t(name: 'big', size: 300),
        t(name: 'mid', size: 100),
      ];

      final asc = withTorrents(rows);
      asc.read(currentSortProvider.notifier).set(TorrentSort.size);
      asc.read(sortAscendingProvider.notifier).set(true);

      final desc = withTorrents(rows);
      desc.read(currentSortProvider.notifier).set(TorrentSort.size);
      desc.read(sortAscendingProvider.notifier).set(false);

      expect(namesFrom(asc), ['small', 'mid', 'big']);
      expect(namesFrom(desc), namesFrom(asc).reversed.toList());
    });

    test('by progress orders by completion', () {
      final c = withTorrents([
        t(name: 'half', progress: 0.5),
        t(name: 'done', progress: 1.0),
        t(name: 'start', progress: 0.0),
      ]);
      c.read(currentSortProvider.notifier).set(TorrentSort.progress);
      c.read(sortAscendingProvider.notifier).set(true);

      expect(namesFrom(c), ['start', 'half', 'done']);
    });

    test('by addedOn orders oldest first when ascending', () {
      final c = withTorrents([
        t(name: 'newest', addedOn: 300),
        t(name: 'oldest', addedOn: 100),
        t(name: 'middle', addedOn: 200),
      ]);
      c.read(currentSortProvider.notifier).set(TorrentSort.addedOn);
      c.read(sortAscendingProvider.notifier).set(true);

      expect(namesFrom(c), ['oldest', 'middle', 'newest']);
    });

    test('sorting does not mutate the source list', () {
      final rows = [t(name: 'b', size: 2), t(name: 'a', size: 1)];
      final c = withTorrents(rows);
      c.read(currentSortProvider.notifier).set(TorrentSort.name);
      c.read(sortAscendingProvider.notifier).set(true);

      expect(namesFrom(c), ['a', 'b']);
      expect(c.read(torrentListProvider).torrents.map((t) => t.name), [
        'b',
        'a',
      ], reason: 'the provider must copy before sorting');
    });
  });

  group('selection', () {
    test('toggle adds then removes a hash', () {
      final c = withTorrents([]);
      final sel = c.read(selectedTorrentHashesProvider.notifier);

      sel.toggle('abc');
      expect(c.read(selectedTorrentHashesProvider), {'abc'});

      sel.toggle('abc');
      expect(c.read(selectedTorrentHashesProvider), isEmpty);
    });

    test('addAll unions rather than replaces', () {
      final c = withTorrents([]);
      final sel = c.read(selectedTorrentHashesProvider.notifier);

      sel.toggle('a');
      sel.addAll(['b', 'c']);

      expect(c.read(selectedTorrentHashesProvider), {'a', 'b', 'c'});
    });

    test('clear empties the set', () {
      final c = withTorrents([]);
      final sel = c.read(selectedTorrentHashesProvider.notifier);

      sel.addAll(['a', 'b']);
      sel.clear();

      expect(c.read(selectedTorrentHashesProvider), isEmpty);
    });
  });
}

/// A [TorrentListNotifier] stand-in that serves a fixed state and never
/// touches the network or starts a poll timer.
class _FixedTorrentList extends TorrentListNotifier {
  _FixedTorrentList(this._value);

  final TorrentListState _value;

  @override
  TorrentListState build() => _value;
}
