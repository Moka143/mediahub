import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What a player keyboard shortcut does.
enum PlayerShortcutAction {
  playPause,
  seekBack,
  seekForward,
  volumeUp,
  volumeDown,
  toggleMute,
  toggleFullscreen,

  /// Esc: dismiss the Up Next card, else leave full screen, else close.
  back,
  showShortcuts,
}

/// One row of the player's keyboard reference.
class PlayerShortcut {
  const PlayerShortcut({
    required this.keys,
    required this.label,
    this.action,
    this.activators = const [],
  });

  /// Key caps as shown to the user, e.g. `['Space']` or `['Shift', '?']`.
  final List<String> keys;
  final String label;

  /// What the key press does. Null for pointer gestures (double-click,
  /// drag), which the player handles itself and the table only documents.
  final PlayerShortcutAction? action;

  /// The key presses that trigger [action]. Held keys do not repeat it:
  /// each seek re-opens the stream at a new offset, so a held arrow became a
  /// storm of abandoned reads.
  final List<ShortcutActivator> activators;
}

/// The player's shortcuts, in the order they are documented.
///
/// The single source for them: the in-player help dialog and Settings →
/// About both render this list, and `handlePlayerKeyEvent` can only perform
/// what an entry here declares. There used to be three hand-written copies
/// that disagreed with each other, and tooltips advertising keys nothing
/// handled.
const List<PlayerShortcut> kPlayerShortcuts = [
  PlayerShortcut(
    keys: ['Space'],
    label: 'Play / pause',
    action: PlayerShortcutAction.playPause,
    activators: [
      SingleActivator(LogicalKeyboardKey.space, includeRepeats: false),
    ],
  ),
  PlayerShortcut(keys: ['Double-click'], label: 'Play / pause'),
  PlayerShortcut(keys: ['Drag'], label: 'Drag across the picture to seek'),
  PlayerShortcut(
    keys: ['←'],
    label: 'Back 10 seconds',
    action: PlayerShortcutAction.seekBack,
    activators: [
      SingleActivator(LogicalKeyboardKey.arrowLeft, includeRepeats: false),
    ],
  ),
  PlayerShortcut(
    keys: ['→'],
    label: 'Forward 10 seconds',
    action: PlayerShortcutAction.seekForward,
    activators: [
      SingleActivator(LogicalKeyboardKey.arrowRight, includeRepeats: false),
    ],
  ),
  PlayerShortcut(
    keys: ['↑'],
    label: 'Volume up',
    action: PlayerShortcutAction.volumeUp,
    activators: [
      SingleActivator(LogicalKeyboardKey.arrowUp, includeRepeats: false),
    ],
  ),
  PlayerShortcut(
    keys: ['↓'],
    label: 'Volume down',
    action: PlayerShortcutAction.volumeDown,
    activators: [
      SingleActivator(LogicalKeyboardKey.arrowDown, includeRepeats: false),
    ],
  ),
  PlayerShortcut(
    keys: ['M'],
    label: 'Mute / unmute',
    action: PlayerShortcutAction.toggleMute,
    activators: [
      SingleActivator(LogicalKeyboardKey.keyM, includeRepeats: false),
    ],
  ),
  PlayerShortcut(
    keys: ['F'],
    label: 'Full screen',
    action: PlayerShortcutAction.toggleFullscreen,
    activators: [
      SingleActivator(LogicalKeyboardKey.keyF, includeRepeats: false),
    ],
  ),
  PlayerShortcut(
    keys: ['Esc'],
    label: 'Dismiss Up Next, leave full screen, then close',
    action: PlayerShortcutAction.back,
    activators: [
      SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false),
    ],
  ),
  PlayerShortcut(
    keys: ['?'],
    label: 'Show these shortcuts',
    action: PlayerShortcutAction.showShortcuts,
    // By character, not key: `?` is Shift+/ on a US layout and a key of its
    // own elsewhere, and a plain `/` is not this shortcut.
    activators: [CharacterActivator('?', includeRepeats: false)],
  ),
];

/// The action [event] triggers according to [kPlayerShortcuts], or null
/// when it is not a player shortcut.
PlayerShortcutAction? playerShortcutActionFor(
  KeyEvent event, {
  HardwareKeyboard? keyboard,
}) {
  final state = keyboard ?? HardwareKeyboard.instance;
  for (final shortcut in kPlayerShortcuts) {
    final action = shortcut.action;
    if (action == null) continue;
    for (final activator in shortcut.activators) {
      if (activator.accepts(event, state)) return action;
    }
  }
  return null;
}
