import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/widgets/common/paged_browse_view.dart';

/// A loader whose pages complete only when the test says so.
class _ManualLoader {
  final requests = <int, Completer<List<int>>>{};

  Future<List<int>> call(int page) =>
      (requests[page] = Completer<List<int>>()).future;

  void complete(int page, List<int> items) => requests[page]!.complete(items);
  void fail(int page, Object error) => requests[page]!.completeError(error);
}

List<int> _page(int start, [int count = 20]) =>
    List.generate(count, (i) => start + i);

void main() {
  group('BrowsePager', () {
    test('a response from before a reset is dropped, not appended', () async {
      // The race this guards: pick "Action", then "Horror" before Action's
      // first page lands. Action's results used to be appended to Horror's
      // list and the page counter skipped ahead.
      final pager = BrowsePager<int>();
      final action = _ManualLoader();
      final horror = _ManualLoader();

      final actionLoad = pager.reset(action.call);
      final horrorLoad = pager.reset(horror.call);
      expect(pager.loading, isTrue);

      horror.complete(1, _page(1000));
      await horrorLoad;
      action.complete(1, _page(0));
      await actionLoad;

      expect(pager.items, _page(1000));
      expect(pager.nextPage, 2);
      expect(pager.loading, isFalse);
    });

    test('a stale response landing late does not clear the new loading '
        'flag', () async {
      final pager = BrowsePager<int>();
      final first = _ManualLoader();
      final second = _ManualLoader();

      final firstLoad = pager.reset(first.call);
      unawaited(pager.reset(second.call));
      first.complete(1, _page(0));
      await firstLoad;

      // The second request is still out: still loading.
      expect(pager.loading, isTrue);
      expect(pager.items, isEmpty);
    });

    test('a stale failure is dropped too', () async {
      final pager = BrowsePager<int>();
      final first = _ManualLoader();
      final second = _ManualLoader();

      final firstLoad = pager.reset(first.call);
      final secondLoad = pager.reset(second.call);
      first.fail(1, Exception('offline'));
      await firstLoad;
      second.complete(1, _page(0));
      await secondLoad;

      expect(pager.error, isNull);
      expect(pager.items, _page(0));
    });

    test('pages append in order and a short page ends the feed', () async {
      final pager = BrowsePager<int>();
      final loader = _ManualLoader();

      final load1 = pager.reset(loader.call);
      loader.complete(1, _page(0));
      await load1;

      final load2 = pager.loadMore();
      loader.complete(2, _page(20, 5));
      await load2;

      expect(pager.items, [..._page(0), ..._page(20, 5)]);
      expect(pager.exhausted, isTrue);
    });

    test('duplicates across pages are dropped', () async {
      // TMDB feeds shift between requests; page 2 can repeat page 1's tail.
      final pager = BrowsePager<int>(keyOf: (i) => i);
      final loader = _ManualLoader();

      final load1 = pager.reset(loader.call);
      loader.complete(1, _page(0));
      await load1;
      final load2 = pager.loadMore();
      loader.complete(2, _page(15));
      await load2;

      expect(pager.items, _page(0, 35));
    });

    test(
      'a failed page 2 keeps page 1 and waits for an explicit retry',
      () async {
        final pager = BrowsePager<int>();
        final loader = _ManualLoader();

        final load1 = pager.reset(loader.call);
        loader.complete(1, _page(0));
        await load1;

        final load2 = pager.loadMore();
        loader.fail(2, Exception('offline'));
        await load2;

        expect(pager.items, _page(0));
        expect(pager.error, isNotNull);
        expect(pager.loading, isFalse);

        // Scrolling near the bottom must not hammer a server that is down.
        loader.requests.remove(2);
        await pager.loadMore();
        expect(loader.requests.containsKey(2), isFalse);

        // Retry asks again, for the same page.
        final retry = pager.loadMore(retry: true);
        expect(loader.requests.containsKey(2), isTrue);
        expect(pager.error, isNull);
        loader.complete(2, _page(20));
        await retry;
        expect(pager.items, _page(0, 40));
      },
    );

    test('a page with nothing new ends the feed instead of asking '
        'forever', () async {
      final pager = BrowsePager<int>(keyOf: (i) => i);
      final loader = _ManualLoader();

      final load1 = pager.reset(loader.call);
      loader.complete(1, _page(0));
      await load1;
      final load2 = pager.loadMore();
      loader.complete(2, _page(0));
      await load2;

      expect(pager.items, _page(0));
      expect(pager.exhausted, isTrue);
    });

    test('notifies nothing after dispose', () async {
      final pager = BrowsePager<int>();
      final loader = _ManualLoader();
      final load = pager.reset(loader.call);
      pager.dispose();
      loader.complete(1, _page(0));
      // Would throw "used after being disposed" if it notified.
      await load;
    });
  });
}
