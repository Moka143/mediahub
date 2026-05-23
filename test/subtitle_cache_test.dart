import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_torrent_client/models/local_media_file.dart';
import 'package:flutter_torrent_client/providers/settings_provider.dart';
import 'package:flutter_torrent_client/providers/subtitle_provider.dart';
import 'package:flutter_torrent_client/services/opensubtitles_service.dart';

void main() {
  group('computeSubtitleCacheKey', () {
    final movieFile = LocalMediaFile(
      path: '/library/Movie 2020.mkv',
      fileName: 'Movie 2020.mkv',
      sizeBytes: 0,
      modifiedDate: DateTime.now(),
      extension: 'mkv',
    );
    final episodeFile = LocalMediaFile(
      path: '/library/Show.S03E07.mkv',
      fileName: 'Show.S03E07.mkv',
      sizeBytes: 0,
      modifiedDate: DateTime.now(),
      extension: 'mkv',
      showName: 'Show',
      seasonNumber: 3,
      episodeNumber: 7,
    );

    test('uses movie:<imdb> when a movie IMDB id is provided', () {
      expect(
        computeSubtitleCacheKey(movieFile, movieImdbId: 'tt0111161'),
        'movie:tt0111161',
      );
    });

    test('uses series:<imdb>:s##e## for episodes with show IMDB id', () {
      expect(
        computeSubtitleCacheKey(episodeFile, showImdbId: 'tt0903747'),
        'series:tt0903747:s03e07',
      );
    });

    test('falls back to path:<sha1> when no IMDB id is available', () {
      final key = computeSubtitleCacheKey(movieFile);
      expect(key, startsWith('path:'));
      expect(key.length, greaterThan('path:'.length));
    });

    test('different paths produce different fallback keys', () {
      final a = computeSubtitleCacheKey(movieFile);
      final b = computeSubtitleCacheKey(episodeFile);
      expect(a, isNot(equals(b)));
    });
  });

  group('cacheKeyFromContext', () {
    test('movie context returns movie:<id>', () {
      final ctx = const SubtitleContext(imdbId: 'tt0468569', isMovie: true);
      expect(cacheKeyFromContext(ctx), 'movie:tt0468569');
    });

    test('episode context returns series:<id>:s##e##', () {
      final ctx = const SubtitleContext(
        imdbId: 'tt0944947',
        isMovie: false,
        seasonNumber: 1,
        episodeNumber: 2,
      );
      expect(cacheKeyFromContext(ctx), 'series:tt0944947:s01e02');
    });

    test('episode context without S/E returns null', () {
      final ctx = const SubtitleContext(
        imdbId: 'tt0944947',
        isMovie: false,
      );
      expect(cacheKeyFromContext(ctx), isNull);
    });
  });

  group('CurrentExternalSubtitleNotifier persistence', () {
    late ProviderContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
    });

    tearDown(() => container.dispose());

    test('persist then loadFor round-trips Subtitle metadata', () async {
      final sub = Subtitle(
        id: 'sub-42',
        url: 'https://example.test/subs/en.srt',
        lang: 'en',
        langName: 'English',
      );
      final notifier = container.read(
        currentExternalSubtitleProvider.notifier,
      );

      await notifier.persist('movie:tt0111161', sub);
      final loaded = notifier.loadFor('movie:tt0111161');

      expect(loaded, isNotNull);
      expect(loaded!.id, sub.id);
      expect(loaded.url, sub.url);
      expect(loaded.lang, sub.lang);
      expect(loaded.langName, sub.langName);
    });

    test('loadFor returns null for unknown cache key', () {
      final notifier = container.read(
        currentExternalSubtitleProvider.notifier,
      );
      expect(notifier.loadFor('movie:never-saved'), isNull);
    });
  });
}
