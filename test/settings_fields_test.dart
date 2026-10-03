import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/providers/connection_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/screens/settings/connection_tab.dart';
import 'package:mediahub/screens/settings/settings_text_field.dart';
import 'package:mediahub/screens/settings/settings_validation.dart';
import 'package:mediahub/screens/settings_screen.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ConnectedEngine extends ConnectionNotifier {
  @override
  ConnectionState build() =>
      const ConnectionState(status: ConnectionStatus.connected);
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('validation', () {
    test('ports', () {
      expect(validatePort('8080'), isNull);
      expect(validatePort('1'), isNull);
      expect(validatePort('65535'), isNull);
      for (final bad in ['', '0', '65536', '70000', 'abc', '-1']) {
        expect(validatePort(bad), isNotNull, reason: bad);
      }
    });

    test('hosts', () {
      for (final good in ['localhost', '192.168.1.20', 'nas.local', '[::1]']) {
        expect(validateHost(good), isNull, reason: good);
      }
      for (final bad in [
        '',
        'http://localhost',
        'localhost:8080',
        'my host',
        'nas/qbt',
      ]) {
        expect(validateHost(bad), isNotNull, reason: bad);
      }
    });

    test('speed limits: empty means no limit', () {
      expect(validateSpeedLimit(''), isNull);
      expect(validateSpeedLimit('0'), isNull);
      expect(validateSpeedLimit('512'), isNull);
      expect(validateSpeedLimit('x'), isNotNull);
      expect(validateSpeedLimit('${maxSpeedLimitKbps + 1}'), isNotNull);
      expect(speedLimitBytes(''), 0);
      expect(speedLimitBytes('512'), 512 * 1024);
      expect(speedLimitText(0), '');
      expect(speedLimitText(512 * 1024), '512');
    });

    test('TMDB tokens: the v4 read token, not the old hex key', () {
      expect(
        tmdbTokenFormatError('eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiIx.sig'),
        isNull,
      );
      expect(tmdbTokenFormatError(''), isNotNull);
      expect(
        tmdbTokenFormatError('0123456789abcdef0123456789abcdef'),
        isNotNull,
      );
      expect(tmdbTokenFormatError('eyJnotajwt'), isNotNull);
    });
  });

  group('SettingsTextField', () {
    late List<String> saved;

    Widget host({String value = '3030', String? Function(String)? validator}) =>
        MaterialApp(
          theme: buildDarkTheme(),
          home: Scaffold(
            body: Column(
              children: [
                SettingsTextField(
                  label: 'Engine port',
                  value: value,
                  validator: validator ?? validatePort,
                  onSave: (v) async {
                    saved.add(v);
                    return null;
                  },
                ),
                // Somewhere else to put focus.
                const TextField(key: Key('other')),
              ],
            ),
          ),
        );

    setUp(() => saved = []);

    testWidgets('typing saves nothing; Enter saves once', (tester) async {
      await tester.pumpWidget(host());
      final field = find.byType(TextField).first;
      await tester.tap(field);
      // Typing 7000 used to point the engine at 7, 70 and 700 on the way.
      for (final partial in ['7', '70', '700', '7000']) {
        await tester.enterText(field, partial);
        await tester.pump();
      }
      expect(saved, isEmpty);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(saved, ['7000']);
    });

    testWidgets('leaving the field saves too', (tester) async {
      await tester.pumpWidget(host());
      await tester.tap(find.byType(TextField).first);
      await tester.enterText(find.byType(TextField).first, '4040');
      await tester.tap(find.byKey(const Key('other')));
      await tester.pump();
      expect(saved, ['4040']);
    });

    testWidgets('an invalid value shows why and is not saved', (tester) async {
      await tester.pumpWidget(host());
      final field = find.byType(TextField).first;
      await tester.tap(field);
      await tester.enterText(field, '70000');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(saved, isEmpty);
      expect(find.text('Enter a port number from 1 to 65535.'), findsOneWidget);

      // Fixing it clears the complaint at once, and saves on Enter.
      await tester.enterText(field, '7000');
      await tester.pump();
      expect(find.text('Enter a port number from 1 to 65535.'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(saved, ['7000']);
    });

    testWidgets('an unchanged value is not saved again', (tester) async {
      await tester.pumpWidget(host());
      await tester.tap(find.byType(TextField).first);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(saved, isEmpty);
    });

    testWidgets('follows the saved value when it changes elsewhere', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.pumpWidget(host(value: '3031'));
      expect(find.text('3031'), findsOneWidget);
    });

    testWidgets('a save error stays under the field', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsTextField(
              label: 'Token',
              value: '',
              onSave: (_) async => 'TMDB didn\'t accept this token.',
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('TMDB didn\'t accept this token.'), findsOneWidget);
    });
  });

  group('Connection tab', () {
    late SharedPreferences prefs;

    Future<ProviderContainer> boot(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'app_settings': '{"engine_kind":0,"rqbit_port":3030}',
      });
      prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            connectionProvider.overrideWith(_ConnectedEngine.new),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            home: const Scaffold(body: SettingsConnectionTab()),
          ),
        ),
      );
      await tester.pump();
      return ProviderScope.containerOf(
        tester.element(find.byType(SettingsConnectionTab)),
      );
    }

    Finder portField() => find.ancestor(
      of: find.text('Engine port'),
      matching: find.byType(TextField),
    );

    testWidgets('the engine port saves on Enter, not per keystroke', (
      tester,
    ) async {
      final container = await boot(tester);
      expect(
        container.read(settingsProvider).engineKind,
        TorrentEngineKind.builtin,
      );

      await tester.tap(portField());
      await tester.enterText(portField(), '7');
      await tester.pump();
      await tester.enterText(portField(), '7000');
      await tester.pump();
      expect(container.read(settingsProvider).rqbitPort, 3030);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(container.read(settingsProvider).rqbitPort, 7000);
    });

    testWidgets('an invalid port is refused with a message', (tester) async {
      final container = await boot(tester);
      await tester.tap(portField());
      await tester.enterText(portField(), '99999');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(container.read(settingsProvider).rqbitPort, 3030);
      expect(find.text('Enter a port number from 1 to 65535.'), findsOneWidget);
    });

    testWidgets('switching engines asks first', (tester) async {
      final container = await boot(tester);

      await tester.tap(find.text('qBittorrent'));
      await tester.pumpAndSettle();
      expect(find.text('Use qBittorrent?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).engineKind,
        TorrentEngineKind.builtin,
      );

      await tester.tap(find.text('qBittorrent'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Switch'));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).engineKind,
        TorrentEngineKind.qbittorrent,
      );
      // qBittorrent's own fields appear once it is chosen.
      expect(find.text('Host'), findsOneWidget);
    });
  });

  group('Reset', () {
    testWidgets('says what it does, then does it', (tester) async {
      SharedPreferences.setMockInitialValues({
        // qBittorrent (index 1) on a custom port.
        'app_settings': '{"engine_kind":1,"port":9090}',
      });
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            connectionProvider.overrideWith(_ConnectedEngine.new),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            home: const SettingsScreen(),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsScreen)),
      );
      expect(
        container.read(settingsProvider).engineKind,
        TorrentEngineKind.qbittorrent,
      );

      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset…'));
      await tester.pumpAndSettle();
      // The dialog spells out the engine switch and the cleared secrets.
      expect(
        find.textContaining('the built-in engine is selected'),
        findsOneWidget,
      );
      expect(
        find.textContaining('qBittorrent password and TMDB token are cleared'),
        findsOneWidget,
      );

      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).engineKind,
        TorrentEngineKind.builtin,
      );
      expect(container.read(settingsProvider).port, AppConstants.defaultPort);
    });
  });
}
