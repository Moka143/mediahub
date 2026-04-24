import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Notifier for current tab index.
class CurrentTabIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void set(int value) => state = value;
}

/// Provider for the current navigation tab index.
final currentTabIndexProvider = NotifierProvider<CurrentTabIndexNotifier, int>(
  CurrentTabIndexNotifier.new,
);
