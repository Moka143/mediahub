import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/player_provider.dart';
import '../shortcuts_help_dialog.dart';

void showPlayerShortcutsDialog(
  BuildContext context, {
  required VoidCallback onUserInteraction,
}) {
  onUserInteraction();
  ShortcutsHelpDialog.show(context);
}

void handlePlayerKeyEvent(
  KeyEvent event, {
  required WidgetRef ref,
  required bool isFullscreen,
  required VoidCallback onUserInteraction,
  required VoidCallback onSeekBackward,
  required VoidCallback onSeekForward,
  required VoidCallback onToggleFullscreen,
  required VoidCallback onExitPlayer,
  required VoidCallback onShowShortcuts,
  bool mediaOpened = true,
  bool resumePromptVisible = false,
}) {
  if (event is! KeyDownEvent) return;

  // Resume prompt sits in front of an unopened player. Space / seek /
  // volume would hit media_kit with no file and can take the view down
  // with it. Escape still leaves.
  if (resumePromptVisible || !mediaOpened) {
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (isFullscreen) {
        onToggleFullscreen();
      } else {
        onExitPlayer();
      }
    }
    return;
  }

  final playerService = ref.read(playerServiceProvider);

  switch (event.logicalKey) {
    case LogicalKeyboardKey.space:
      playerService.playOrPause();
      onUserInteraction();
    case LogicalKeyboardKey.arrowLeft:
      onSeekBackward();
    case LogicalKeyboardKey.arrowRight:
      onSeekForward();
    case LogicalKeyboardKey.arrowUp:
      final player = ref.read(playerProvider);
      playerService.setVolume((player.state.volume + 10).clamp(0, 100));
      onUserInteraction();
    case LogicalKeyboardKey.arrowDown:
      final player = ref.read(playerProvider);
      playerService.setVolume((player.state.volume - 10).clamp(0, 100));
      onUserInteraction();
    case LogicalKeyboardKey.keyF:
      onToggleFullscreen();
    case LogicalKeyboardKey.keyM:
      playerService.toggleMute();
      onUserInteraction();
    case LogicalKeyboardKey.escape:
      if (isFullscreen) {
        onToggleFullscreen();
      } else {
        onExitPlayer();
      }
    case LogicalKeyboardKey.question:
    case LogicalKeyboardKey.slash:
      // ? on US layouts is Shift+/. Accept either.
      onShowShortcuts();
  }
}
