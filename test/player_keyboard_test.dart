import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/providers/player_provider.dart';
import 'package:mediahub/services/player_service.dart';
import 'package:mediahub/widgets/player/player_keyboard.dart';
import 'package:mediahub/widgets/player/player_shortcuts.dart';
import 'package:mediahub/widgets/shortcuts_help_dialog.dart';

class _RecordingPlayerService extends PlayerService {
  _RecordingPlayerService(super.ref);

  final List<String> calls = [];

  @override
  Future<void> playOrPause() async => calls.add('playOrPause');

  @override
  Future<void> adjustVolume(double delta) async => calls.add('volume $delta');

  @override
  Future<void> toggleMute() async => calls.add('toggleMute');
}

KeyDownEvent _down(LogicalKeyboardKey key, {String? character}) => KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.keyQ,
  logicalKey: key,
  character: character,
  timeStamp: Duration.zero,
);

/// A key press that triggers [shortcut], built from its own activator.
KeyDownEvent _pressFor(PlayerShortcut shortcut) {
  final activator = shortcut.activators.first;
  if (activator is SingleActivator) return _down(activator.trigger);
  if (activator is CharacterActivator) {
    return _down(LogicalKeyboardKey.slash, character: activator.character);
  }
  throw StateError('unexpected activator $activator');
}

/// The player's keyboard handling and its documentation are one table.
///
/// There used to be three hand-written lists — the handler, the help dialog
/// and Settings → About — that disagreed, and tooltips advertising C, A and S
/// that nothing handled.
void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  group('the shortcut table', () {
    test('every documented key maps to its own action', () {
      for (final shortcut in kPlayerShortcuts) {
        final action = shortcut.action;
        if (action == null) {
          // Pointer gestures are documented, not dispatched.
          expect(shortcut.activators, isEmpty, reason: shortcut.label);
          continue;
        }
        expect(shortcut.activators, isNotEmpty, reason: shortcut.label);
        expect(
          playerShortcutActionFor(_pressFor(shortcut)),
          action,
          reason: '${shortcut.keys.join('+')} → ${shortcut.label}',
        );
      }
    });

    test('each action is documented once', () {
      final actions = [
        for (final s in kPlayerShortcuts)
          if (s.action != null) s.action,
      ];
      expect(actions.toSet(), hasLength(actions.length));
      expect(actions.toSet(), PlayerShortcutAction.values.toSet());
    });

    test('keys that are not in the table do nothing', () {
      for (final key in [
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyS,
        LogicalKeyboardKey.enter,
      ]) {
        expect(playerShortcutActionFor(_down(key)), isNull, reason: '$key');
      }
      // A plain slash is not "?" — it used to open the help as well.
      expect(
        playerShortcutActionFor(
          _down(LogicalKeyboardKey.slash, character: '/'),
        ),
        isNull,
      );
    });
  });

  group('handlePlayerKeyEvent', () {
    late WidgetRef capturedRef;
    late _RecordingPlayerService service;
    late List<String> calls;

    Future<void> pumpHost(WidgetTester tester) async {
      calls = [];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerServiceProvider.overrideWith(
              (ref) => service = _RecordingPlayerService(ref),
            ),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              capturedRef = ref;
              return const SizedBox();
            },
          ),
        ),
      );
      capturedRef.read(playerServiceProvider);
    }

    bool press(
      KeyEvent event, {
      bool fullscreen = false,
      bool upNextShowing = false,
      bool mediaOpened = true,
      bool resumePrompt = false,
    }) => handlePlayerKeyEvent(
      event,
      ref: capturedRef,
      isFullscreen: fullscreen,
      onUserInteraction: () {},
      onSeekBackward: () => calls.add('seekBack'),
      onSeekForward: () => calls.add('seekForward'),
      onToggleFullscreen: () => calls.add('fullscreen'),
      onExitPlayer: () => calls.add('exit'),
      onShowShortcuts: () => calls.add('shortcuts'),
      onDismissUpNext: upNextShowing ? () => calls.add('dismissUpNext') : null,
      mediaOpened: mediaOpened,
      resumePromptVisible: resumePrompt,
    );

    testWidgets('does what each entry in the table says', (tester) async {
      await pumpHost(tester);
      final expected = <PlayerShortcutAction, String>{
        PlayerShortcutAction.playPause: 'playOrPause',
        PlayerShortcutAction.seekBack: 'seekBack',
        PlayerShortcutAction.seekForward: 'seekForward',
        PlayerShortcutAction.volumeUp: 'volume ${PlayerService.volumeStep}',
        PlayerShortcutAction.volumeDown: 'volume ${-PlayerService.volumeStep}',
        PlayerShortcutAction.toggleMute: 'toggleMute',
        PlayerShortcutAction.toggleFullscreen: 'fullscreen',
        PlayerShortcutAction.back: 'exit',
        PlayerShortcutAction.showShortcuts: 'shortcuts',
      };
      for (final shortcut in kPlayerShortcuts) {
        final action = shortcut.action;
        if (action == null) continue;
        calls.clear();
        service.calls.clear();
        expect(press(_pressFor(shortcut)), isTrue, reason: shortcut.label);
        expect(
          [...calls, ...service.calls],
          [expected[action]],
          reason: shortcut.label,
        );
      }
    });

    testWidgets('Esc dismisses the Up Next card before anything else', (
      tester,
    ) async {
      // It used to close the player out from under the card.
      await pumpHost(tester);
      final esc = _down(LogicalKeyboardKey.escape);

      expect(press(esc, upNextShowing: true, fullscreen: true), isTrue);
      expect(calls, ['dismissUpNext']);

      calls.clear();
      press(esc, fullscreen: true);
      expect(calls, ['fullscreen']);

      calls.clear();
      press(esc);
      expect(calls, ['exit']);
    });

    testWidgets('media keys wait for the media; Esc never does', (
      tester,
    ) async {
      await pumpHost(tester);

      expect(
        press(_down(LogicalKeyboardKey.space), resumePrompt: true),
        isFalse,
      );
      expect(
        press(_down(LogicalKeyboardKey.keyM), mediaOpened: false),
        isFalse,
      );
      expect(service.calls, isEmpty);

      expect(
        press(_down(LogicalKeyboardKey.escape), resumePrompt: true),
        isTrue,
      );
      expect(calls, ['exit']);
    });
  });

  testWidgets('the help dialog lists the table', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: const Scaffold(body: ShortcutsHelpDialog()),
      ),
    );
    for (final shortcut in kPlayerShortcuts) {
      expect(find.text(shortcut.label), findsWidgets, reason: shortcut.label);
      for (final key in shortcut.keys) {
        expect(find.text(key), findsWidgets, reason: key);
      }
    }
  });
}
