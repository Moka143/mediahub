import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/providers/shows_provider.dart';
import 'package:mediahub/services/tmdb_api_service.dart';
import 'package:mediahub/widgets/common/paged_browse_view.dart';

/// A browse config over plain ints, with pages served by [loader].
class _IntBrowse extends BrowseConfig<int> {
  _IntBrowse(this.loader);

  final Future<List<int>> Function(int page) loader;

  @override
  String get keyPrefix => 'test';

  @override
  String get noun => 'things';

  @override
  String get searchHint => 'Search…';

  @override
  List<BrowseGenre> get genres => const [BrowseGenre('All')];

  @override
  List<BrowseFeed> get feeds => const [BrowseFeed('Top')];

  @override
  Future<List<int>> fetchPage(
    TmdbApiService tmdb, {
    required BrowseFeed feed,
    required BrowseGenre genre,
    required int page,
  }) => loader(page);

  @override
  String watchSearchQuery(WidgetRef ref) => '';

  @override
  String readSearchQuery(WidgetRef ref) => '';

  @override
  void setSearchQuery(WidgetRef ref, String query) {}

  @override
  AsyncValue<List<int>> watchSearchResults(WidgetRef ref) =>
      const AsyncValue.data([]);

  @override
  int idOf(int item) => item;

  @override
  Widget buildCard(BuildContext context, int item) =>
      ColoredBox(key: ValueKey('card-$item'), color: Colors.grey);

  @override
  Widget buildSpotlight(
    BuildContext context,
    int item, {
    required BrowseFeed feed,
    required BrowseGenre genre,
  }) => const SizedBox(height: 40);
}

/// [_IntBrowse] with a real genre list, recording the genre of each fetch.
class _GenreBrowse extends _IntBrowse {
  _GenreBrowse(this.asked) : super((page) async => _page((page - 1) * 20));

  final List<String> asked;

  static final List<BrowseGenre> _genres = BrowseGenre.listFrom(const {
    18: 'Drama',
    35: 'Comedy',
    99: 'Documentary',
  });

  @override
  List<BrowseGenre> get genres => _genres;

  @override
  Future<List<int>> fetchPage(
    TmdbApiService tmdb, {
    required BrowseFeed feed,
    required BrowseGenre genre,
    required int page,
  }) {
    asked.add(genre.label);
    return loader(page);
  }
}

Widget _host(BrowseConfig<int> config) => ProviderScope(
  overrides: [
    tmdbApiServiceProvider.overrideWithValue(
      TmdbApiService(accessToken: 'test'),
    ),
  ],
  child: MaterialApp(
    home: Scaffold(body: PagedBrowseView<int>(config: config)),
  ),
);

List<int> _page(int start) => List.generate(20, (i) => start + i);

void main() {
  testWidgets('shows a loading skeleton on the first frame, not a blank '
      'grid', (tester) async {
    final first = Completer<List<int>>();
    await tester.pumpWidget(_host(_IntBrowse((_) => first.future)));

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('match this filter'), findsNothing);

    first.complete(_page(0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-0')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a failed first page explains itself and offers Try again', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      _host(
        _IntBrowse((page) async {
          calls++;
          if (calls == 1) {
            throw Exception('SocketException: Failed host lookup');
          }
          return _page(0);
        }),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load things"), findsOneWidget);
    // Plain language, never the exception text.
    expect(find.textContaining('SocketException'), findsNothing);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-0')), findsOneWidget);
  });

  testWidgets('a failed later page shows in the footer with a retry', (
    tester,
  ) async {
    var failPage2 = true;
    await tester.pumpWidget(
      _host(
        _IntBrowse((page) async {
          if (page == 2 && failPage2) throw Exception('timed out');
          return _page((page - 1) * 20);
        }),
      ),
    );
    await tester.pumpAndSettle();

    // Scroll to the end to ask for page 2.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load more."), findsOneWidget);
    expect(find.byKey(const ValueKey('card-19')), findsOneWidget);

    failPage2 = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load more."), findsNothing);
    expect(find.byKey(const ValueKey('card-39')), findsOneWidget);
  });

  testWidgets('the genre drop-down lists every genre and reloads with the '
      'one picked', (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(_host(_GenreBrowse(asked)));
    await tester.pumpAndSettle();
    // Page 1, and page 2 when the first does not fill the view.
    expect(asked, everyElement(BrowseGenre.allLabel));
    final before = asked.length;

    await tester.tap(find.byTooltip('Genre'));
    await tester.pumpAndSettle();
    // Every genre, not a hand-picked few — A to Z after "All genres".
    for (final name in ['Comedy', 'Documentary', 'Drama']) {
      expect(find.text(name), findsOneWidget);
    }

    await tester.tap(find.text('Documentary'));
    await tester.pumpAndSettle();
    final after = asked.sublist(before);
    expect(after, isNotEmpty);
    expect(after, everyElement('Documentary'));
    // The button now names the filter.
    expect(find.text('Documentary'), findsOneWidget);
    expect(find.text(BrowseGenre.allLabel), findsNothing);
  });
}
