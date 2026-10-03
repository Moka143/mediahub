import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The top-level destinations, in sidebar order.
///
/// [currentTabIndexProvider] stores the [index]. Navigate with
/// `ref.read(currentTabIndexProvider.notifier).show(AppTab.shows)` rather
/// than a bare number: the numbers used to be repeated in eight files, each
/// with a comment explaining which tab 2 was.
enum AppTab {
  home('Home'),
  transfers('Transfers'),
  shows('TV Shows'),
  movies('Movies'),
  library('Library'),
  calendar('Calendar'),
  favorites('Favorites');

  const AppTab(this.label);

  /// The destination's name as the navigation shows it.
  final String label;
}

/// Notifier for current tab index.
class CurrentTabIndexNotifier extends Notifier<int> {
  @override
  int build() => AppTab.home.index;

  /// Switch to [tab].
  void show(AppTab tab) => state = tab.index;
}

/// Provider for the current navigation tab index.
final currentTabIndexProvider = NotifierProvider<CurrentTabIndexNotifier, int>(
  CurrentTabIndexNotifier.new,
);

/// The current tab as an [AppTab], for code that would otherwise compare
/// [currentTabIndexProvider] against a number.
final currentTabProvider = Provider<AppTab>(
  (ref) => AppTab.values[ref.watch(currentTabIndexProvider)],
);
