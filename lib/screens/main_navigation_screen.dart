import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../providers/auto_download_provider.dart';
import '../providers/calendar_provider.dart';
import '../providers/connection_provider.dart' as connection_provider;
import '../providers/favorites_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/startup_notices_provider.dart';
import '../providers/streaming_provider.dart';
import '../providers/tmdb_account_provider.dart';
import '../providers/torrent_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../providers/watchlist_provider.dart';
import '../services/app_logger.dart';
import '../services/library_actions.dart';
import '../services/streaming_service.dart';
import '../utils/constants.dart';
import '../utils/feedback_utils.dart';
import '../widgets/add_torrent_dialog.dart';
import '../widgets/common/app_shortcuts.dart';
import '../widgets/common/mediahub_sidebar.dart';
import '../widgets/common/mediahub_topbar.dart';
import '../widgets/common/nav_badge.dart';
import '../widgets/common/notice_banner.dart';
import '../widgets/common/torrent_file_drop.dart';
import '../widgets/connection_status_widget.dart';
import 'calendar_screen.dart' show CalendarScreen;
import 'downloads_screen.dart';
import 'favorites_screen.dart';
import 'mediahub_home_screen.dart';
import 'movies_screen.dart';
import 'settings_screen.dart';
import 'shows_screen.dart';
import 'video_player_screen.dart';
import 'watch_screen.dart';

/// Everything the shell draws for one tab. The sidebar, the bottom bar and
/// the top bar all read this one table — they used to keep three parallel
/// lists in sidebar order and agree only by position.
typedef TabChrome = ({
  IconData icon,
  IconData selectedIcon,
  String subtitle,
  Widget screen,
});

/// The chrome for [tab]. A switch, so adding a tab without its chrome does
/// not compile.
TabChrome tabChrome(AppTab tab) => switch (tab) {
  AppTab.home => (
    icon: Icons.home_outlined,
    selectedIcon: Icons.home_rounded,
    subtitle: 'Ready to watch',
    screen: const MediaHubHomeScreen(),
  ),
  AppTab.transfers => (
    icon: Icons.download_outlined,
    selectedIcon: Icons.download_rounded,
    subtitle: '', // live: engine state and counts, see _buildAppBar
    screen: const DownloadsScreen(),
  ),
  AppTab.shows => (
    icon: Icons.live_tv_outlined,
    selectedIcon: Icons.live_tv_rounded,
    subtitle: 'Trending, popular, top rated',
    screen: const ShowsScreen(),
  ),
  AppTab.movies => (
    icon: Icons.movie_outlined,
    selectedIcon: Icons.movie_rounded,
    subtitle: 'Trending, popular, top rated',
    screen: const MoviesScreen(),
  ),
  AppTab.library => (
    icon: Icons.video_library_outlined,
    selectedIcon: Icons.video_library_rounded,
    subtitle: 'Files in your download folder',
    screen: const WatchScreen(),
  ),
  AppTab.calendar => (
    icon: Icons.calendar_month_outlined,
    selectedIcon: Icons.calendar_month_rounded,
    subtitle: 'Upcoming episodes of your favorites',
    screen: const CalendarScreen(),
  ),
  AppTab.favorites => (
    icon: Icons.favorite_outline_rounded,
    selectedIcon: Icons.favorite_rounded,
    subtitle: 'Favorites and watchlist',
    screen: const FavoritesScreen(),
  ),
};

/// The app's top-level layout: navigation (sidebar or bottom bar), the top
/// bar, one-time notices, and the tabs themselves, kept alive side by side.
class MainNavigationScreen extends ConsumerStatefulWidget {
  const MainNavigationScreen({super.key, this.tabContentBuilder});

  /// Replaces each tab's screen. For tests, which exercise the shell without
  /// standing up seven screens and their network-backed providers.
  @visibleForTesting
  final Widget Function(AppTab tab)? tabContentBuilder;

  @override
  ConsumerState<MainNavigationScreen> createState() =>
      _MainNavigationScreenState();
}

class _MainNavigationScreenState extends ConsumerState<MainNavigationScreen> {
  // Keep screens alive when switching tabs.
  late final List<Widget> _screens = [
    for (final tab in AppTab.values)
      widget.tabContentBuilder?.call(tab) ?? tabChrome(tab).screen,
  ];

  /// The user's own collapse choice. Null until they make one: until then
  /// the sidebar collapses itself on narrow windows.
  bool? _sidebarCollapsedByUser;

  /// "Settings were reset" is about this launch only, so dismissing it does
  /// not need to persist.
  bool _prefsNoticeDismissed = false;

  @override
  void initState() {
    super.initState();
    // Pull authoritative favorites/watchlist from TMDB on launch when
    // already signed in. Best-effort: failures are logged and the user
    // still sees the local cache. Also reconcile watched/ratings —
    // bidirectional, additive, so episodes you marked on another device
    // show up here and items you watched locally before signing in get
    // pushed up.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Unconditional and first: recovers watched marks stranded in the
      // legacy manual-watched store. Must run before the TMDB reconcile so
      // the recovered marks are part of the local set that gets pushed up,
      // rather than being seen as absent and unmarked by the pull step.
      await migrateManualWatchedMarks(ref);
      if (!mounted) return;
      if (ref.read(tmdbSessionProvider) != null) {
        final favorites = ref.read(favoritesProvider.notifier);
        final watchlist = ref.read(watchlistProvider.notifier);
        // Deliberately not awaited: these three reconcile in the
        // background so the first frame is not held behind three round
        // trips to TMDB. The list syncs record a failure in their own state,
        // which Settings → TMDB account shows; each is also guarded here,
        // because an error escaping this callback used to be fatal.
        unawaited(_quietly('favorites', favorites.syncFromTmdb));
        unawaited(_quietly('watchlist', watchlist.syncFromTmdb));
        unawaited(_quietly('watched', () => reconcileWatchedWithTmdb(ref)));
      }
    });
  }

  Future<void> _quietly(String what, Future<Object?> Function() sync) async {
    try {
      await sync();
    } catch (e) {
      // At launch, offline, a failure is expected and not worth an
      // interruption; the next sync tries again.
      AppLog.w('[Shell] launch $what sync failed: $e');
    }
  }

  bool get _isMac => defaultTargetPlatform == TargetPlatform.macOS;

  void _goTo(AppTab tab) =>
      ref.read(currentTabIndexProvider.notifier).show(tab);

  void _openSettings() {
    unawaited(
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(currentTabProvider);
    final connectionState = ref.watch(connection_provider.connectionProvider);
    final width = MediaQuery.sizeOf(context).width;

    // The sidebar from 600px up — collapsed to its icon rail below 900px —
    // and the phone-style bottom bar only below that. The old 900px gate
    // gave 800–899px desktop windows the bottom bar and a floating button.
    final useSidebar = width >= AppBreakpoints.mobile;
    final sidebarCollapsed =
        _sidebarCollapsedByUser ?? width < AppBreakpoints.tablet;

    // Navigation badges.
    final activeDownloads = ref.watch(activeDownloadsCountProvider);
    final errored = ref.watch(erroredTorrentsCountProvider);
    final todayEpisodes = ref.watch(todayEpisodesCountProvider);
    // Only the two facts the badge shows, so the shell does not rebuild on
    // every tracking update auto-download makes.
    final (queued, calendarPulse) = ref.watch(
      autoDownloadProvider.select(
        (s) => (s.downloadQueue.isNotEmpty, s.isProcessing),
      ),
    );
    final calendarDot = todayEpisodes > 0 || queued;
    final calendarStatus = calendarPulse
        ? 'auto-download running'
        : todayEpisodes > 0
        ? '$todayEpisodes airing today'
        : calendarDot
        ? 'auto-downloads queued'
        : null;

    // ── Global streaming safety net ────────────────────────────────────────
    // If a *foreground* session becomes ready while its originating screen
    // is gone, this listener opens the player via the root navigator.
    // Next-episode prefetch passes makeActive: false so it never lands
    // here and cannot replace the episode still playing.
    ref.listen<StreamingSession?>(activeStreamingSessionProvider, (
      previous,
      next,
    ) {
      if (next == null) return;
      // Only fire on the transition into ready/playing, not on every rebuild
      final wasReady = previous?.isReady ?? false;
      if (!wasReady && next.isReady && next.videoFile != null) {
        unawaited(
          rootNavigatorKey.currentState?.push(
            MaterialPageRoute<void>(
              builder: (_) => VideoPlayerScreen.fromSession(
                file: next.videoFile!,
                session: next,
              ),
            ),
          ),
        );
      }
    });

    SidebarItem sidebarItem(AppTab t) {
      final chrome = tabChrome(t);
      return switch (t) {
        // Errors outrank activity: a red count next to a warning icon reads
        // as "this many need attention", which is what it then means.
        AppTab.transfers => SidebarItem(
          icon: errored > 0 ? Icons.warning_amber_rounded : chrome.icon,
          selectedIcon: errored > 0
              ? Icons.warning_amber_rounded
              : chrome.selectedIcon,
          label: t.label,
          badge: errored > 0 ? errored : activeDownloads,
          errorBadge: errored > 0,
          status: errored > 0
              ? '$errored need attention'
              : activeDownloads > 0
              ? '$activeDownloads active'
              : null,
        ),
        AppTab.calendar => SidebarItem(
          icon: chrome.icon,
          selectedIcon: chrome.selectedIcon,
          label: t.label,
          dot: calendarDot,
          dotPulse: calendarPulse,
          status: calendarStatus,
        ),
        _ => SidebarItem(
          icon: chrome.icon,
          selectedIcon: chrome.selectedIcon,
          label: t.label,
        ),
      };
    }

    return TorrentFileDropListener(
      onTorrentFiles: (paths) => unawaited(_addDroppedTorrents(paths)),
      child: CallbackShortcuts(
        bindings: appShellShortcuts(
          platform: defaultTargetPlatform,
          onTab: _goTo,
          onSettings: _openSettings,
        ),
        // Key events travel up from whatever has focus, so the shortcuts only
        // hear them while focus is somewhere inside the shell. A scope of its
        // own makes sure it always is: when a focused field disappears with
        // its tab, focus falls back to this scope — below the shortcuts —
        // rather than to the route's, which sits above them.
        child: FocusScope(
          autofocus: true,
          child: Scaffold(
            appBar: _buildAppBar(tab, connectionState),
            body: Row(
              children: [
                if (useSidebar)
                  MediaHubSidebar(
                    currentIndex: tab.index,
                    collapsed: sidebarCollapsed,
                    onToggleCollapse: () => setState(
                      () => _sidebarCollapsedByUser = !sidebarCollapsed,
                    ),
                    onAddTorrent: () =>
                        _handleAddTorrentAction(connectionState),
                    engineName: ref.watch(
                      settingsProvider.select((s) => s.engineKind.label),
                    ),
                    connected: connectionState.isConnected,
                    onDestinationSelected: (index) =>
                        _goTo(AppTab.values[index]),
                    items: [for (final t in AppTab.values) sidebarItem(t)],
                  ),
                Expanded(
                  child: Column(
                    children: [
                      ..._notices(),
                      // Main content — fade between tabs while keeping all
                      // screens alive.
                      Expanded(
                        child: _FadeIndexedStack(
                          index: tab.index,
                          children: _screens,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            bottomNavigationBar: useSidebar
                ? null
                : NavigationBar(
                    selectedIndex: tab.index,
                    onDestinationSelected: (index) =>
                        _goTo(AppTab.values[index]),
                    destinations: [
                      for (final t in AppTab.values)
                        _bottomDestination(
                          t,
                          errored: errored,
                          activeDownloads: activeDownloads,
                          calendarDot: calendarDot,
                          calendarPulse: calendarPulse,
                        ),
                    ],
                  ),
            floatingActionButton: !useSidebar && tab == AppTab.transfers
                ? FloatingActionButton.extended(
                    onPressed: () => _handleAddTorrentAction(connectionState),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add torrent'),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  NavigationDestination _bottomDestination(
    AppTab t, {
    required int errored,
    required int activeDownloads,
    required bool calendarDot,
    required bool calendarPulse,
  }) {
    final chrome = tabChrome(t);
    Widget icon(IconData data) => switch (t) {
      AppTab.transfers => NavBadge(
        count: errored > 0 ? errored : activeDownloads,
        isError: errored > 0,
        child: Icon(errored > 0 ? Icons.warning_amber_rounded : data),
      ),
      AppTab.calendar => NavDot(
        isVisible: calendarDot,
        pulse: calendarPulse,
        child: Icon(data),
      ),
      _ => Icon(data),
    };
    return NavigationDestination(
      icon: icon(chrome.icon),
      selectedIcon: icon(chrome.selectedIcon),
      label: t.label,
    );
  }

  /// One-time notices, above the tab content. Each stays until it is
  /// dismissed.
  List<Widget> _notices() {
    final (migrationSeen, engine) = ref.watch(
      settingsProvider.select(
        (s) => (s.engineMigrationNoticeSeen, s.engineKind),
      ),
    );
    final prefsReset = ref.watch(prefsWereResetProvider);
    return [
      // Without this the engine migration is silent, and the first thing it
      // shows is an empty Transfers list — because torrents still running in
      // their qBittorrent belong to a backend the app is no longer talking
      // to. An empty list reads as data loss. It used to be a 3-second
      // snackbar, cut to two lines and marked as seen the moment it
      // appeared; now it is marked seen only when dismissed.
      if (!migrationSeen && engine == TorrentEngineKind.builtin)
        NoticeBanner(
          key: const ValueKey('engine-migration-notice'),
          title: 'MediaHub now has its own torrent engine',
          message:
              'Nothing else to install or keep running. Torrents still in '
              'your qBittorrent won\'t appear in Transfers unless you switch '
              'back in Settings → Connection — your qBittorrent settings are '
              'saved.',
          icon: Icons.bolt_rounded,
          actionLabel: 'Open Settings',
          onAction: _openSettings,
          onDismiss: () => unawaited(
            ref.read(settingsProvider.notifier).markEngineMigrationNoticeSeen(),
          ),
        ),
      if (prefsReset && !_prefsNoticeDismissed)
        NoticeBanner(
          key: const ValueKey('prefs-reset-notice'),
          title: 'Your settings were reset',
          message:
              'MediaHub couldn\'t read its saved data — usually after an '
              'unexpected shutdown — so it started with the defaults. '
              'Downloaded files are untouched. If you use a TMDB account, '
              'sign in again in Settings to bring back your favorites and '
              'watchlist.',
          icon: Icons.restart_alt_rounded,
          tone: AppColors.warn,
          actionLabel: 'Open Settings',
          onAction: _openSettings,
          onDismiss: () => setState(() => _prefsNoticeDismissed = true),
        ),
    ];
  }

  /// Open the add dialog for each `.torrent` dropped onto the window, one
  /// after another.
  Future<void> _addDroppedTorrents(List<String> paths) async {
    final connection = ref.read(connection_provider.connectionProvider);
    for (final path in paths) {
      if (!mounted) return;
      final added = await _handleAddTorrentAction(
        connection,
        torrentFile: path,
      );
      // Cancelled or offline: don't open the next one on top of that.
      if (added != true) return;
    }
  }

  Future<bool?> _handleAddTorrentAction(
    connection_provider.ConnectionState connectionState, {
    String? torrentFile,
  }) async {
    if (!connectionState.isConnected) {
      final engine = ref.read(settingsProvider).engineKind.sentenceName;
      AppSnackBar.showWarning(
        context,
        message:
            "Can't add torrents while $engine is offline. Check Settings → "
            'Connection.',
      );
      _openSettings();
      return false;
    }

    final added = await showAddTorrentDialog(context, torrentFile: torrentFile);
    if (added == true && mounted) {
      AppSnackBar.showSuccess(
        context,
        message: 'Torrent added',
        actionLabel: ref.read(currentTabProvider) == AppTab.transfers
            ? null
            : 'Show',
        onAction: () => _goTo(AppTab.transfers),
      );
    }
    return added;
  }

  PreferredSizeWidget _buildAppBar(
    AppTab tab,
    connection_provider.ConnectionState connection,
  ) {
    var subtitle = tabChrome(tab).subtitle;
    final actions = <Widget>[];

    switch (tab) {
      case AppTab.transfers:
        final torrents = ref.watch(torrentListProvider).torrents;
        final active = ref.watch(activeDownloadsCountProvider);
        final total = torrents.length;
        // With the engine down the list is empty because nothing can be
        // asked, not because there is nothing — "No transfers yet" there
        // read as if every download had vanished.
        subtitle = connection.isConnecting
            ? 'Connecting…'
            : !connection.isConnected
            ? 'Engine offline'
            : total == 0
            ? 'No transfers yet'
            : '$total ${total == 1 ? 'transfer' : 'transfers'} · '
                  '$active active';
        // Aggregate dl/ul speeds — surfaced in the TopBar speed pill,
        // matching the design's `↓ 27.5 MB/s   ↑ 12.2 MB/s` widget.
        final totalDl = torrents.fold<int>(0, (s, t) => s + t.dlspeed.toInt());
        final totalUl = torrents.fold<int>(0, (s, t) => s + t.upspeed.toInt());
        final selecting = ref.watch(isSelectionModeProvider);
        actions.addAll([
          TransfersSpeedPill(totalDl: totalDl, totalUl: totalUl),
          const ConnectionStatusWidget(),
          MediaHubIconButton(
            icon: selecting ? Icons.close_rounded : Icons.checklist_rounded,
            tooltip: selecting ? 'Done selecting' : 'Select several',
            active: selecting,
            onPressed: () {
              if (selecting) {
                ref.read(selectedTorrentHashesProvider.notifier).clear();
                ref.read(selectionModeProvider.notifier).disable();
              } else {
                ref.read(selectionModeProvider.notifier).enable();
              }
            },
          ),
        ]);
      case AppTab.library:
        actions.add(
          MediaHubIconButton(
            icon: Icons.refresh_rounded,
            tooltip: 'Rescan for new videos',
            onPressed: () {
              refreshLocalMedia(ref);
              AppSnackBar.showInfo(
                context,
                message: 'Looking for new videos in your download folder…',
              );
            },
          ),
        );
      case AppTab.home ||
          AppTab.shows ||
          AppTab.movies ||
          AppTab.calendar ||
          AppTab.favorites:
        break;
    }

    // Settings lives at the rightmost position of the TopBar's
    // actions row — single source for global app actions.
    actions.add(
      MediaHubIconButton(
        icon: Icons.settings_outlined,
        tooltip: _isMac ? 'Settings (⌘,)' : 'Settings (Ctrl+,)',
        onPressed: _openSettings,
      ),
    );

    return MediaHubTopBar(
      title: tab.label,
      subtitle: subtitle,
      actions: actions,
    );
  }
}

// ---------------------------------------------------------------------------
// Fade-animated IndexedStack — keeps all screens alive, fades between them
// ---------------------------------------------------------------------------

class _FadeIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;

  const _FadeIndexedStack({required this.index, required this.children});

  @override
  State<_FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<_FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: AppDuration.fast,
      value: 1.0, // start fully visible — no fade on first load
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
  }

  @override
  void didUpdateWidget(_FadeIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      unawaited(_ctrl.forward(from: 0.0));
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: IndexedStack(
        index: widget.index,
        children: [
          for (var i = 0; i < widget.children.length; i++)
            // Every tab screen stays mounted for the whole session — that is
            // the point of the IndexedStack, and it is what keeps scroll
            // offsets and already-loaded pages alive across tab switches.
            // What the IndexedStack does *not* do is stop the hidden children
            // animating: it skips painting them, nothing more. So a shimmer
            // skeleton or a pulsing dot on a tab nobody is looking at goes on
            // asking for a frame sixty times a second for as long as the app
            // is open, and the app never reaches an idle frame at all.
            // TickerMode mutes the tickers under the hidden children.
            //
            // Visible effect: an off-screen animation is frozen while it is
            // off-screen and picks up when its tab comes forward. Since it was
            // off-screen, there is nothing to have seen.
            //
            // ExcludeFocus keeps Tab from walking into a hidden screen's
            // fields and buttons.
            TickerMode(
              enabled: i == widget.index,
              child: ExcludeFocus(
                excluding: i != widget.index,
                child: widget.children[i],
              ),
            ),
        ],
      ),
    );
  }
}
