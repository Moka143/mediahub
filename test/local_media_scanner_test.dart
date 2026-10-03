import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/services/local_media_scanner.dart';
import 'package:watcher/watcher.dart';

/// `findSubtitles` had no coverage and used `split('/').last.split('\\').last`
/// to derive the video's base name — the exact form `basenameOf` exists to
/// replace. It now uses `basenameOf`; these pin the matching rules that
/// change had to preserve.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mediahub_subs_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<File> touch(String name) async {
    final f = File('${tempDir.path}${Platform.pathSeparator}$name');
    await f.writeAsString('x');
    return f;
  }

  test('finds a sidecar sharing the video base name', () async {
    final video = await touch('Severance.S02E01.1080p.mkv');
    await touch('Severance.S02E01.1080p.srt');

    final subs = await LocalMediaScanner(
      tempDir.path,
    ).findSubtitles(video.path);

    expect(subs, hasLength(1));
    expect(subs.single, endsWith('.srt'));
  });

  test('finds language-tagged sidecars', () async {
    final video = await touch('Show.S01E01.mkv');
    await touch('Show.S01E01.en.srt');
    await touch('Show.S01E01.fr.srt');

    final subs = await LocalMediaScanner(
      tempDir.path,
    ).findSubtitles(video.path);

    expect(subs, hasLength(2));
  });

  test('ignores a sidecar belonging to another episode', () async {
    final video = await touch('Show.S01E01.mkv');
    await touch('Show.S01E02.srt');

    final subs = await LocalMediaScanner(
      tempDir.path,
    ).findSubtitles(video.path);

    expect(subs, isEmpty);
  });

  test('ignores non-subtitle files that share the name', () async {
    final video = await touch('Show.S01E01.mkv');
    await touch('Show.S01E01.nfo');

    final subs = await LocalMediaScanner(
      tempDir.path,
    ).findSubtitles(video.path);

    expect(subs, isEmpty);
  });

  test('accepts every subtitle extension it advertises', () async {
    final video = await touch('Show.S01E01.mkv');
    for (final ext in ['srt', 'ass', 'ssa', 'sub', 'vtt']) {
      await touch('Show.S01E01.$ext');
    }

    final subs = await LocalMediaScanner(
      tempDir.path,
    ).findSubtitles(video.path);

    expect(subs, hasLength(5));
  });

  test('a missing directory yields nothing rather than throwing', () async {
    final scanner = LocalMediaScanner('${tempDir.path}/nope');
    expect(await scanner.findSubtitles('${tempDir.path}/nope/x.mkv'), isEmpty);
  });

  group('findEpisodeFile', () {
    LocalMediaFile episodeFile(String show, int s, int e, {int? showId}) =>
        LocalMediaFile(
          path: '/lib/$show.S0${s}E0$e.mkv',
          fileName: '$show.S0${s}E0$e.mkv',
          sizeBytes: 1,
          modifiedDate: DateTime(2026),
          showName: show,
          seasonNumber: s,
          episodeNumber: e,
          showId: showId,
          extension: 'mkv',
        );

    final library = [
      episodeFile('Young Sheldon', 1, 1),
      episodeFile('Dark Matter', 1, 1),
      episodeFile('The Office', 2, 3, showId: 2316),
      episodeFile('Severance', 2, 4),
    ];

    LocalMediaFile? find(String show, int s, int e, {int? showId}) =>
        LocalMediaScanner('/lib').findEpisodeFile(
          library,
          showName: show,
          season: s,
          episode: e,
          showId: showId,
        );

    test('finds the same show under its other spellings', () {
      expect(find('severance', 2, 4), isNotNull);
      expect(find('Office', 2, 3), isNotNull);
    });

    test('never returns a show whose name merely contains this one', () {
      // "You" S01E01 used to open Young Sheldon; "Dark" opened Dark Matter.
      expect(find('You', 1, 1), isNull);
      expect(find('Dark', 1, 1), isNull);
    });

    test('a known TMDB id outranks the name', () {
      expect(find('The Office', 2, 3, showId: 2996), isNull);
      expect(find('The Office', 2, 3, showId: 2316), isNotNull);
    });
  });

  group('isLibraryEvent', () {
    bool relevant(
      ChangeType type,
      String path, {
      Set<String> listed = const {},
    }) => LocalMediaScanner.isLibraryEvent(WatchEvent(type, path), listed);

    test('only video files can change the library', () {
      expect(relevant(ChangeType.ADD, '/dl/Show.S01E01.mkv'), isTrue);
      expect(relevant(ChangeType.ADD, '/dl/Show.S01E01.srt'), isFalse);
      expect(relevant(ChangeType.MODIFY, '/dl/Show.S01E01.mkv.part'), isFalse);
      expect(relevant(ChangeType.ADD, '/dl/cover.jpg'), isFalse);
    });

    test('a listed video growing is a download, not a new entry', () {
      const path = '/dl/Show.S01E01.mkv';
      expect(relevant(ChangeType.MODIFY, path, listed: {path}), isFalse);
      expect(
        relevant(ChangeType.MODIFY, path),
        isTrue,
        reason: 'may now count',
      );
    });

    test('a removal counts when it takes a listed file with it', () {
      const path = '/dl/Show.S01.1080p.WEB/Show.S01E01.mkv';
      expect(relevant(ChangeType.REMOVE, path, listed: {path}), isTrue);
      // A whole release folder going — dots in its name and all.
      expect(
        relevant(ChangeType.REMOVE, '/dl/Show.S01.1080p.WEB', listed: {path}),
        isTrue,
      );
      expect(
        relevant(ChangeType.REMOVE, '/dl/Other.S02', listed: {path}),
        isFalse,
      );
      expect(relevant(ChangeType.REMOVE, '/dl/Show.S01E01.srt'), isFalse);
    });
  });

  group('coalesceBursts', () {
    test('a burst of events is one rescan, after the quiet period', () {
      fakeAsync((async) {
        final source = StreamController<int>();
        var fired = 0;
        final sub = coalesceBursts(
          source.stream,
          quiet: const Duration(seconds: 2),
          maxWait: const Duration(seconds: 15),
        ).listen((_) => fired++);

        for (var i = 0; i < 10; i++) {
          source.add(i);
          async.elapse(const Duration(milliseconds: 500));
        }
        expect(fired, 0, reason: 'still busy');
        async.elapse(const Duration(seconds: 2));
        expect(fired, 1);

        unawaited(sub.cancel());
        unawaited(source.close());
      });
    });

    test('a download that never stops still rescans every so often', () {
      fakeAsync((async) {
        final source = StreamController<int>();
        var fired = 0;
        final sub = coalesceBursts(
          source.stream,
          quiet: const Duration(seconds: 2),
          maxWait: const Duration(seconds: 15),
        ).listen((_) => fired++);

        for (var i = 0; i < 40; i++) {
          source.add(i);
          async.elapse(const Duration(seconds: 1));
        }
        expect(fired, 2, reason: 'one per 15 s of constant activity');

        unawaited(sub.cancel());
        unawaited(source.close());
      });
    });
  });
}
