import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/providers/auto_download_provider.dart';
import 'package:mediahub/providers/calendar_provider.dart';
import 'package:mediahub/providers/connection_provider.dart';
import 'package:mediahub/providers/navigation_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/startup_notices_provider.dart';
import 'package:mediahub/providers/streaming_provider.dart';
import 'package:mediahub/providers/torrent_provider.dart';
import 'package:mediahub/screens/main_navigation_screen.dart';
import 'package:mediahub/screens/settings_screen.dart';
import 'package:mediahub/widgets/common/app_shortcuts.dart';
import 'package:mediahub/widgets/common/mediahub_sidebar.dart';
import 'package:mediahub/widgets/common/notice_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fixed connection state, and nothing else: no engine process, no
/// polling.
class _Engine extends ConnectionNotifier {
  _Engine(this.status);
  final ConnectionStatus status;

  @override
  ConnectionState build() => ConnectionState(status: status);
}

class _NoTorrents extends TorrentListNotifier {
  @override
  TorrentListState build() => const TorrentListState();
}

class _IdleAutoDownload extends AutoDownloadNotifier {
  @override
  AutoDownloadState build() => const AutoDownloadState();
}

/// A settings blob as an install from before the engine setting saved it:
/// no `engine_kind`, so the app moves it to the built-in engine and owes
/// the user the one-time notice.
const Map<String, Object> _preEngineInstall = {
  'app_settings': '{"host":"localhost","port":8080}',
};

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late SharedPreferences prefs;

  Future<void> boot(
    WidgetTester tester, {
    Map<String, Object> stored = const {},
    bool prefsWereReset = false,
    Size window = const Size(1100, 760),
    ConnectionStatus engine = ConnectionStatus.connected,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues(stored);
    prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          connectionProvider.overrideWith(() => _Engine(engine)),
          torrentListProvider.overrideWith(_NoTorrents.new),
          autoDownloadProvider.overrideWith(_IdleAutoDownload.new),
          todayEpisodesCountProvider.overrideWithValue(0),
          activeStreamingSessionProvider.overrideWithValue(null),
          prefsWereResetProvider.overrideWithValue(prefsWereReset),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: MainNavigationScreen(
            tabContentBuilder: (tab) => Center(child: Text('tab:${tab.name}')),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(
        tester.element(find.byType(MainNavigationScreen)),
      );

  AppTab currentTab(WidgetTester tester) =>
      containerOf(tester).read(currentTabProvider);

  Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
    // flutter_test reports Android unless told otherwise, so the shell
    // listens for Ctrl here; the macOS variant below covers ⌘.
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final modifier = mac
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  group('keyboard', () {
    testWidgets('Ctrl+1…7 switch tabs in sidebar order', (tester) async {
      await boot(tester);
      expect(currentTab(tester), AppTab.home);

      const digits = [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.digit5,
        LogicalKeyboardKey.digit6,
        LogicalKeyboardKey.digit7,
      ];
      for (final tab in AppTab.values.reversed) {
        await chord(tester, digits[tab.index]);
        expect(currentTab(tester), tab);
        // The top bar follows.
        expect(find.text(tab.label), findsWidgets);
      }
    });

    testWidgets('⌘ instead of Ctrl on macOS', (tester) async {
      await boot(tester);
      await chord(tester, LogicalKeyboardKey.digit2);
      expect(currentTab(tester), AppTab.transfers);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('Ctrl+, opens Settings, and Esc comes back', (tester) async {
      await boot(tester);
      await chord(tester, LogicalKeyboardKey.comma);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);

      // The shell still hears its shortcuts after the round trip.
      await chord(tester, LogicalKeyboardKey.digit6);
      expect(currentTab(tester), AppTab.calendar);
    });

    test('the shortcut table covers every tab and Settings', () {
      final tabs = <AppTab>[];
      var settings = 0;
      final bindings = appShellShortcuts(
        platform: TargetPlatform.windows,
        onTab: tabs.add,
        onSettings: () => settings++,
      );
      for (final callback in bindings.values) {
        callback();
      }
      expect(tabs, AppTab.values);
      expect(settings, 1);
      // The same chords on macOS, written with ⌘.
      final mac = appShellShortcuts(
        platform: TargetPlatform.macOS,
        onTab: (_) {},
        onSettings: () {},
      );
      expect(mac.length, bindings.length);
      expect(
        mac.keys.whereType<SingleActivator>().every(
          (a) => a.meta && !a.control,
        ),
        isTrue,
      );
    });
  });

  group('layout', () {
    testWidgets('an 850px window gets the sidebar, not the phone bar', (
      tester,
    ) async {
      await boot(tester, window: const Size(850, 700));
      expect(find.byType(MediaHubSidebar), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      // Narrow: the rail starts collapsed.
      expect(find.byTooltip('Expand sidebar'), findsOneWidget);
    });

    testWidgets('a wide window gets the expanded sidebar', (tester) async {
      await boot(tester, window: const Size(1300, 800));
      expect(find.byTooltip('Collapse sidebar'), findsOneWidget);
    });

    testWidgets('below 600px the bottom bar takes over', (tester) async {
      await boot(tester, window: const Size(500, 800));
      expect(find.byType(MediaHubSidebar), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });

  group('Transfers subtitle', () {
    Future<void> showTransfers(WidgetTester tester) async {
      await chord(tester, LogicalKeyboardKey.digit2);
      expect(currentTab(tester), AppTab.transfers);
    }

    testWidgets('says the engine is offline rather than "nothing yet"', (
      tester,
    ) async {
      await boot(tester, engine: ConnectionStatus.error);
      await showTransfers(tester);
      // An empty list with the engine down is not an empty list.
      expect(find.text('ENGINE OFFLINE'), findsOneWidget);
      expect(find.text('NO TRANSFERS YET'), findsNothing);
    });

    testWidgets('and that it is connecting while it is', (tester) async {
      await boot(tester, engine: ConnectionStatus.connecting);
      await showTransfers(tester);
      expect(find.text('CONNECTING…'), findsOneWidget);
    });

    testWidgets('an empty list once connected', (tester) async {
      await boot(tester);
      await showTransfers(tester);
      expect(find.text('NO TRANSFERS YET'), findsOneWidget);
    });
  });

  group('one-time notices', () {
    testWidgets('engine migration notice stays until dismissed', (
      tester,
    ) async {
      await boot(tester, stored: _preEngineInstall);
      final notice = find.byKey(const ValueKey('engine-migration-notice'));
      expect(notice, findsOneWidget);

      // Showing it is not the same as the user having read it: it used to
      // be marked seen the moment a 3-second snackbar appeared.
      await tester.pump(const Duration(seconds: 10));
      expect(notice, findsOneWidget);
      expect(
        containerOf(tester).read(settingsProvider).engineMigrationNoticeSeen,
        isFalse,
      );

      await tester.tap(
        find.descendant(of: notice, matching: find.text('Got it')),
      );
      await tester.pump();
      expect(notice, findsNothing);
      expect(
        containerOf(tester).read(settingsProvider).engineMigrationNoticeSeen,
        isTrue,
      );
      final saved = jsonDecode(prefs.getString('app_settings')!) as Map;
      expect(saved['engine_migration_notice_seen'], isTrue);
    });

    testWidgets('no migration notice for a fresh install', (tester) async {
      await boot(tester);
      expect(find.byType(NoticeBanner), findsNothing);
    });

    testWidgets('settings-reset notice shows when prefs were recovered', (
      tester,
    ) async {
      await boot(tester, prefsWereReset: true);
      final notice = find.byKey(const ValueKey('prefs-reset-notice'));
      expect(notice, findsOneWidget);
      await tester.tap(
        find.descendant(of: notice, matching: find.text('Got it')),
      );
      await tester.pump();
      expect(notice, findsNothing);
    });
  });
}
