import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/services/tmdb_account_service.dart';

/// The account lists the TMDB syncs read. Every one of them is paged, and
/// the two paging loops this file used to carry are now one.
void main() {
  TmdbAccountService serviceAnswering(
    Map<String, List<Map<String, Object?>>> pages,
    List<String> requested,
  ) {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.themoviedb.org'))
      ..httpClientAdapter = _PagedAdapter(pages, requested);
    return TmdbAccountService(accessToken: 'test', dio: dio);
  }

  test('reads every page of an id list', () async {
    final requested = <String>[];
    final service = serviceAnswering({
      '/3/account/7/favorite/tv': [
        {
          'page': 1,
          'total_pages': 2,
          'results': [
            {'id': 1},
            {'id': 2},
          ],
        },
        {
          'page': 2,
          'total_pages': 2,
          'results': [
            {'id': 3},
            {'id': 'not an id'},
          ],
        },
      ],
    }, requested);

    expect(await service.getFavoriteShowIds(accountId: 7), {1, 2, 3});
    expect(requested, hasLength(2));
  });

  test('reads every page of rated episodes, skipping malformed rows', () async {
    final requested = <String>[];
    final service = serviceAnswering({
      '/3/account/7/rated/tv/episodes': [
        {
          'total_pages': 2,
          'results': [
            {'show_id': 1, 'season_number': 1, 'episode_number': 2},
          ],
        },
        {
          'total_pages': 2,
          'results': [
            {'show_id': 1, 'season_number': 'x', 'episode_number': 3},
            {'show_id': 9, 'season_number': 2, 'episode_number': 1},
          ],
        },
      ],
    }, requested);

    final episodes = await service.getRatedEpisodes(accountId: 7);
    expect(
      [
        for (final e in episodes)
          '${e.showId}/${e.seasonNumber}/${e.episodeNumber}',
      ],
      ['1/1/2', '9/2/1'],
    );
  });

  test('a list with no total stops after one page', () async {
    final requested = <String>[];
    final service = serviceAnswering({
      '/3/account/7/rated/movies': [
        {
          'results': [
            {'id': 550},
          ],
        },
      ],
    }, requested);

    expect(await service.getRatedMovieIds(accountId: 7), {550});
    expect(requested, hasLength(1));
  });
}

/// Answers each path with its pages in order, by the `page` parameter.
class _PagedAdapter implements HttpClientAdapter {
  _PagedAdapter(this.pages, this.requested);

  final Map<String, List<Map<String, Object?>>> pages;
  final List<String> requested;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri.toString());
    final page = int.parse('${options.queryParameters['page'] ?? 1}');
    final body = pages[options.path]![page - 1];
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
