import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/subtitle_provider.dart';
import 'package:mediahub/services/opensubtitles_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

LocalMediaFile _file(String path, {String? show, int? season, int? episode}) =>
    LocalMediaFile(
      path: path,
      fileName: path.split('/').last,
      sizeBytes: 0,
      modifiedDate: DateTime(2026),
      extension: 'mkv',
      showName: show,
      seasonNumber: season,
      episodeNumber: episode,
    );

Subtitle _sub(String id, {String lang = 'en', String langName = 'English'}) =>
    Subtitle(
      id: id,
      url: 'https://example.test/subs/$id.srt',
      lang: lang,
      langName: langName,
    );

void main() {
  group('subtitleCacheKeyFor', () {
    // One key per file, from the file alone. The auto-load and the picker
    // used to derive keys from whichever IMDB ids each had at the time, so a
    // choice was saved under one key and looked up under another.
    final movie = _file('/library/Movie 2020.mkv');
    final episode = _file(
      '/library/Show.S03E07.mkv',
      show: 'Show',
      season: 3,
      episode: 7,
    );

    test('is stable for the same file', () {
      expect(subtitleCacheKeyFor(movie), subtitleCacheKeyFor(movie));
      expect(
        subtitleCacheKeyFor(_file('/library/Movie 2020.mkv')),
        subtitleCacheKeyFor(movie),
      );
    });

    test('differs between files', () {
      expect(subtitleCacheKeyFor(movie), isNot(subtitleCacheKeyFor(episode)));
    });

    test('ignores parsed metadata — only the file matters', () {
      // A second release of the same episode is a different file with
      // different timing; it must not inherit the first one's subtitles.
      final otherRelease = _file(
        '/library/Show.S03E07.720p.mkv',
        show: 'Show',
        season: 3,
        episode: 7,
      );
      expect(
        subtitleCacheKeyFor(otherRelease),
        isNot(subtitleCacheKeyFor(episode)),
      );
      expect(subtitleCacheKeyFor(movie), startsWith('path:'));
    });
  });

  group('per-file subtitle state', () {
    late ProviderContainer container;
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
    });

    tearDown(() => container.dispose());

    CurrentExternalSubtitleNotifier selection() =>
        container.read(currentExternalSubtitleProvider.notifier);

    test('persist then loadFor round-trips Subtitle metadata', () async {
      final sub = _sub('sub-42');
      await selection().persist('path:abc', sub);
      final loaded = selection().loadFor('path:abc');

      expect(loaded, isNotNull);
      expect(loaded!.id, sub.id);
      expect(loaded.url, sub.url);
      expect(loaded.lang, sub.lang);
      expect(loaded.langName, sub.langName);
    });

    test('loadFor returns null for an unknown key', () {
      expect(selection().loadFor('path:never-saved'), isNull);
    });

    test('opening a new file drops the previous selection', () async {
      // The selection used to survive into the next video: its picker showed
      // the old track as selected, and F re-applied it to the new file.
      final a = _file('/library/A.mkv');
      final b = _file('/library/B.mkv');
      selection().beginFile(a);
      await selection().choose(_sub('a-en'));
      expect(container.read(currentExternalSubtitleProvider)?.id, 'a-en');

      selection().beginFile(b);
      expect(container.read(currentExternalSubtitleProvider), isNull);
      expect(selection().savedForCurrentFile(), isNull);
    });

    test('a choice is saved against its own file only', () async {
      final a = _file('/library/A.mkv');
      final b = _file('/library/B.mkv');
      selection().beginFile(a);
      await selection().choose(_sub('a-en'));
      selection().beginFile(b);
      await selection().choose(_sub('b-fr', lang: 'fr', langName: 'French'));

      selection().beginFile(a);
      expect(selection().savedForCurrentFile()?.id, 'a-en');
      selection().beginFile(b);
      expect(selection().savedForCurrentFile()?.id, 'b-fr');
    });

    test('turning subtitles off forgets the saved choice', () async {
      final a = _file('/library/A.mkv');
      selection().beginFile(a);
      await selection().choose(_sub('a-en'));
      await selection().chooseNone();

      expect(container.read(currentExternalSubtitleProvider), isNull);
      expect(selection().savedForCurrentFile(), isNull);
    });

    test('a sidecar file is a selectable subtitle like any other', () {
      final sidecar = sidecarSubtitle('/library/Movie.en.srt');
      expect(sidecar.url, '/library/Movie.en.srt');
      expect(sidecar.langName, 'Movie.en.srt');
      expect(sidecar.id, isNot(sidecarSubtitle('/library/Movie.fr.srt').id));
    });
  });
}
