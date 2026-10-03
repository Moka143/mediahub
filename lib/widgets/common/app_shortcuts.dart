import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../providers/navigation_provider.dart';

/// The shell's keyboard shortcuts, as they are written for [platform]:
/// ⌘ on macOS, Ctrl elsewhere.
///
/// ⌘1…⌘7 switch tabs in sidebar order and ⌘, opens Settings. ⌘W is not
/// here: the macOS File menu's Close Window item owns it, so the menu shows
/// it and the window's own close path handles it.
Map<ShortcutActivator, VoidCallback> appShellShortcuts({
  required TargetPlatform platform,
  required ValueChanged<AppTab> onTab,
  required VoidCallback onSettings,
}) {
  final mac = platform == TargetPlatform.macOS;
  SingleActivator chord(LogicalKeyboardKey key) =>
      SingleActivator(key, meta: mac, control: !mac);
  const digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
  return {
    for (final tab in AppTab.values.take(digits.length))
      chord(digits[tab.index]): () => onTab(tab),
    chord(LogicalKeyboardKey.comma): onSettings,
  };
}

/// The shell's shortcuts as the user reads them, for Settings → About.
/// Each entry's keys are alternatives — any one of them works.
List<({List<String> keys, String label})> appShellShortcutLabels(
  TargetPlatform platform,
) {
  final mac = platform == TargetPlatform.macOS;
  final mod = mac ? '⌘' : 'Ctrl+';
  return [
    (
      keys: ['${mod}1–$mod${AppTab.values.length}'],
      label: 'Switch tabs, in sidebar order',
    ),
    (keys: ['$mod,'], label: 'Open Settings'),
    (
      keys: ['Esc', if (mac) '⌘[' else 'Alt+←'],
      label: 'Go back from Settings or a details page',
    ),
    // Handled by the File menu, listed so the reference is complete.
    if (mac) (keys: ['⌘W'], label: 'Close the window'),
  ];
}
