import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/player_provider.dart';
import '../../services/player_service.dart';
import '../shortcuts_help_dialog.dart';
import 'player_shortcuts.dart';

void showPlayerShortcutsDialog(
  BuildContext context, {
  required VoidCallback onUserInteraction,
}) {
  onUserInteraction();
  unawaited(ShortcutsHelpDialog.show(context));
}

/// Perform the [kPlayerShortcuts] entry [event] triggers. Returns whether it
/// was one — the caller marks those key events handled.
///
/// Dispatches on the table's [PlayerShortcutAction]s, so it can only do what
/// the help dialog documents. The two had drifted: tooltips advertised C, A
/// and S, which nothing handled, and a plain `/` opened the help that the
/// dialog said was on `?`.
///
/// Esc works outward from the most transient thing on screen: it dismisses
/// [onDismissUpNext]'s card when there is one, then leaves full screen, and
/// only then closes the player. It used to close the player from under the
/// Up Next card.
bool handlePlayerKeyEvent(
  KeyEvent event, {
  required WidgetRef ref,
  required bool isFullscreen,
  required VoidCallback onUserInteraction,
  required VoidCallback onSeekBackward,
  required VoidCallback onSeekForward,
  required VoidCallback onToggleFullscreen,
  required VoidCallback onExitPlayer,
  required VoidCallback onShowShortcuts,
  VoidCallback? onDismissUpNext,
  bool mediaOpened = true,
  bool resumePromptVisible = false,
}) {
  final action = playerShortcutActionFor(event);
  if (action == null) return false;

  switch (action) {
    case PlayerShortcutAction.back:
      if (onDismissUpNext != null) {
        onDismissUpNext();
      } else if (isFullscreen) {
        onToggleFullscreen();
      } else {
        onExitPlayer();
      }
      return true;
    case PlayerShortcutAction.toggleFullscreen:
      onToggleFullscreen();
      return true;
    case PlayerShortcutAction.showShortcuts:
      onShowShortcuts();
      return true;
    case PlayerShortcutAction.playPause:
    case PlayerShortcutAction.seekBack:
    case PlayerShortcutAction.seekForward:
    case PlayerShortcutAction.volumeUp:
    case PlayerShortcutAction.volumeDown:
    case PlayerShortcutAction.toggleMute:
      break;
  }

  // The rest act on the media. The resume prompt sits in front of an
  // unopened player, and these would reach media_kit with no file loaded —
  // which can take the view down with it.
  if (resumePromptVisible || !mediaOpened) return false;

  final playerService = ref.read(playerServiceProvider);
  switch (action) {
    case PlayerShortcutAction.playPause:
      unawaited(playerService.playOrPause());
      onUserInteraction();
    case PlayerShortcutAction.seekBack:
      onSeekBackward();
    case PlayerShortcutAction.seekForward:
      onSeekForward();
    case PlayerShortcutAction.volumeUp:
      unawaited(playerService.adjustVolume(PlayerService.volumeStep));
      onUserInteraction();
    case PlayerShortcutAction.volumeDown:
      unawaited(playerService.adjustVolume(-PlayerService.volumeStep));
      onUserInteraction();
    case PlayerShortcutAction.toggleMute:
      unawaited(playerService.toggleMute());
      onUserInteraction();
    case PlayerShortcutAction.back:
    case PlayerShortcutAction.toggleFullscreen:
    case PlayerShortcutAction.showShortcuts:
      break;
  }
  return true;
}
