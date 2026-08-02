import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_torrent_client/models/watch_progress.dart';
import 'package:flutter_torrent_client/providers/watch_progress_provider.dart';

void main() {
  group('WatchProgress.isSyntheticPath', () {
    test('recognises every watched-only prefix', () {
      expect(WatchProgress.isSyntheticPath('tmdb:rated:1399/1/1'), isTrue);
      expect(WatchProgress.isSyntheticPath('tmdb:rated-movie:550'), isTrue);
      expect(WatchProgress.isSyntheticPath('manual:watched:1399/1/2'), isTrue);
    });

    test('a real path is not synthetic', () {
      expect(
        WatchProgress.isSyntheticPath('/Users/me/Media/Show.S01E01.mkv'),
        isFalse,
      );
      expect(WatchProgress.isSyntheticPath(r'C:\Media\Show.mkv'), isFalse);
    });

    test('a path merely containing a prefix is not synthetic', () {
      expect(
        WatchProgress.isSyntheticPath('/Media/tmdb:rated:not-really.mkv'),
        isFalse,
        reason: 'prefixes anchor at the start, not anywhere in the path',
      );
    });
  });

  group('isProgressPlayable', () {
    const libraryPath = '/Users/me/Media/Show.S01E01.mkv';

    test('a file present in the library is playable', () {
      expect(isProgressPlayable(libraryPath, {libraryPath}), isTrue);
    });

    test('a file no longer in the library is not', () {
      expect(isProgressPlayable(libraryPath, <String>{}), isFalse);
    });

    test('a file outside the library is not offered for playback', () {
      expect(
        isProgressPlayable('/elsewhere/Other.mkv', {libraryPath}),
        isFalse,
      );
    });

    test('synthetic entries are never playable, even mid-scan', () {
      // These carry a watched mark for something never downloaded here, so
      // they must not appear in Continue Watching under any condition —
      // including the optimistic null-library case below.
      expect(isProgressPlayable('tmdb:rated:1399/1/1', null), isFalse);
      expect(isProgressPlayable('tmdb:rated:1399/1/1', {libraryPath}), isFalse);
      expect(isProgressPlayable('manual:watched:1399/1/2', null), isFalse);
      expect(isProgressPlayable('tmdb:rated-movie:550', null), isFalse);
    });

    test('stays optimistic while the first scan is in flight', () {
      // Null means "scan hasn't landed". Filtering everything out here would
      // flash an empty Continue Watching row on every cold start.
      expect(isProgressPlayable(libraryPath, null), isTrue);
      expect(isProgressPlayable('/anything/at/all.mkv', null), isTrue);
    });
  });
}
