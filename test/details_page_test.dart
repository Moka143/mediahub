import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/widgets/details/details_page.dart';

/// Push a [DetailsPageScaffold] over a home page, so Back has somewhere to go.
Future<void> _pushPage(
  WidgetTester tester,
  AsyncValue<String> value, {
  VoidCallback? onRetry,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DetailsPageScaffold<String>(
                  value: value,
                  subject: 'this movie',
                  onRetry: onRetry ?? () {},
                  builder: (context, data) => Text('loaded: $data'),
                ),
              ),
            ),
            child: const Text('home'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('home'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // A spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  testWidgets('a failed load offers Try again and Back — never the raw '
      'error', (tester) async {
    var retried = 0;
    await _pushPage(
      tester,
      AsyncValue.error(
        Exception('TmdbApiException: DioException [bad response]'),
        StackTrace.empty,
      ),
      onRetry: () => retried++,
    );

    expect(find.text("Couldn't load this movie"), findsOneWidget);
    expect(find.textContaining('DioException'), findsNothing);
    expect(find.textContaining('TmdbApiException'), findsNothing);

    await tester.tap(find.text('Try again'));
    expect(retried, 1);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('Back is there while it is still loading', (tester) async {
    await _pushPage(tester, const AsyncValue.loading(), settle: false);
    expect(find.byTooltip('Back'), findsOneWidget);
  });

  testWidgets('an error that arrives while Riverpod retries shows at once', (
    tester,
  ) async {
    // A provider in automatic retry reports "loading" with the error
    // attached; reading that as plain loading spun for ~40 s offline.
    final failing = FutureProvider<String>(
      (ref) async => throw Exception('Failed host lookup'),
      retry: (_, _) => const Duration(minutes: 1),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => DetailsPageScaffold<String>(
              value: ref.watch(failing),
              subject: 'this movie',
              onRetry: () {},
              builder: (context, data) => Text(data),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text("Couldn't load this movie"), findsOneWidget);

    // Dispose the scope, and with it the pending retry.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Esc leaves the page', (tester) async {
    await _pushPage(tester, const AsyncValue.data('Arrival'));
    expect(find.text('loaded: Arrival'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });
}
