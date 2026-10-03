import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/design/app_colors.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/utils/feedback_utils.dart';
import 'package:mediahub/widgets/common/back_shortcuts.dart';
import 'package:mediahub/widgets/common/delete_confirmation_dialog.dart';
import 'package:mediahub/widgets/common/mediahub_confirm_dialog.dart';
import 'package:mediahub/widgets/common/mediahub_picker_sheet.dart';
import 'package:mediahub/widgets/common/mediahub_topbar.dart';
import 'package:mediahub/widgets/common/nav_badge.dart';
import 'package:mediahub/widgets/common/notice_banner.dart';
import 'package:mediahub/widgets/editorial/editorial_button.dart';
import 'package:mediahub/widgets/editorial/editorial_progress.dart';

Widget _app(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  home: Scaffold(body: child),
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('EditorialProgress', () {
    testWidgets('spans its parent, not just its fill', (tester) async {
      // The one real caller is a start-aligned Column. The bar used to be as
      // wide as its fill there — 120px at 30% of 400 — with no track
      // showing how much was left.
      await tester.pumpWidget(
        _app(
          const SizedBox(
            width: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [EditorialProgress(value: 0.3, thin: true)],
            ),
          ),
        ),
      );
      final size = tester.getSize(find.byType(EditorialProgress));
      expect(size.width, 400);
      expect(size.height, 2);

      final fill = find.descendant(
        of: find.byType(FractionallySizedBox),
        matching: find.byType(DecoratedBox),
      );
      expect(tester.getSize(fill).width, closeTo(120, 0.01));
      expect(tester.getSize(fill).height, 2);
      expect(
        tester.getTopLeft(fill),
        tester.getTopLeft(find.byType(EditorialProgress)),
      );
    });

    testWidgets('clamps out-of-range values', (tester) async {
      await tester.pumpWidget(
        _app(const SizedBox(width: 100, child: EditorialProgress(value: 4))),
      );
      final fill = find.descendant(
        of: find.byType(FractionallySizedBox),
        matching: find.byType(DecoratedBox),
      );
      expect(tester.getSize(fill).width, 100);
    });
  });

  group('EditorialButton', () {
    testWidgets('works from the keyboard and is a button', (tester) async {
      final handle = tester.ensureSemantics();
      var pressed = 0;
      await tester.pumpWidget(
        _app(
          Center(
            child: EditorialButton(
              label: 'Add torrent',
              kind: EditorialButtonKind.accent,
              autofocus: true,
              onPressed: () => pressed++,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(pressed, 2);
      expect(
        tester.getSemantics(find.text('Add torrent')),
        isSemantics(
          label: 'Add torrent',
          isButton: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('looks and acts disabled without a handler', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(const Center(child: EditorialButton(label: 'Adding…'))),
      );
      final opacity = tester.widget<Opacity>(
        find.ancestor(of: find.text('Adding…'), matching: find.byType(Opacity)),
      );
      expect(opacity.opacity, lessThan(1));
      expect(
        tester.getSemantics(find.text('Adding…')),
        isSemantics(isButton: true, isEnabled: false, hasEnabledState: true),
      );
      handle.dispose();
    });

    testWidgets('filled kinds put dark text on the fill', (tester) async {
      for (final kind in [
        EditorialButtonKind.accent,
        EditorialButtonKind.danger,
      ]) {
        await tester.pumpWidget(
          _app(
            Center(
              child: EditorialButton(label: 'Go', kind: kind, onPressed: () {}),
            ),
          ),
        );
        final text = tester.widget<Text>(find.text('Go'));
        expect(text.style!.color, AppColors.onAccent, reason: '$kind');
      }
    });
  });

  group('confirm dialogs', () {
    testWidgets('a destructive prompt starts on Cancel, so Enter is safe', (
      tester,
    ) async {
      bool? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await MediaHubConfirmDialog.show(
                context: context,
                title: 'Delete torrent?',
                message: 'Gone for good.',
                confirmLabel: 'Delete',
                destructive: true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });

    testWidgets('torrent delete says files are kept unless ticked', (
      tester,
    ) async {
      ({bool confirmed, bool deleteFiles})? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await DeleteConfirmationDialog.showForTorrent(
                    context: context,
                    torrentName: 'Show.S01E01',
                  ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Delete torrent?'), findsOneWidget);
      expect(
        find.textContaining(DeleteConfirmationDialog.filesKeptNote),
        findsOneWidget,
      );
      await tester.tap(find.text('Also delete files'));
      await tester.pump();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(result, (confirmed: true, deleteFiles: true));
    });

    testWidgets('batch delete counts properly', (tester) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => DeleteConfirmationDialog.showForTorrents(
                context: context,
                torrentCount: 1,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Delete 1 torrent?'), findsOneWidget);
      expect(find.textContaining('It will be removed'), findsOneWidget);
    });
  });

  group('navigation badges', () {
    testWidgets('NavDot pulses when asked to — it used to ignore it', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const Center(
            child: NavDot(isVisible: true, pulse: true, child: Icon(Icons.abc)),
          ),
        ),
      );
      Color ledColor() =>
          (tester
                      .widget<Container>(
                        find.descendant(
                          of: find.byType(NavStatusDot),
                          matching: find.byType(Container),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;
      final first = ledColor();
      await tester.pump(const Duration(milliseconds: 600));
      expect(ledColor(), isNot(first));
    });

    testWidgets('NavBadge shows nothing at zero, a solid count otherwise', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(const NavBadge(count: 0, child: Icon(Icons.abc))),
      );
      expect(find.byType(NavCountTag), findsNothing);
      await tester.pumpWidget(
        _app(const NavBadge(count: 120, isError: true, child: Icon(Icons.abc))),
      );
      expect(find.text('99+'), findsOneWidget);
      final text = tester.widget<Text>(find.text('99+'));
      expect(text.style!.color, AppColors.onAccent);
    });
  });

  group('MediaHubIconButton', () {
    testWidgets('is a focusable, named button', (tester) async {
      final handle = tester.ensureSemantics();
      var pressed = false;
      await tester.pumpWidget(
        _app(
          Center(
            child: MediaHubIconButton(
              icon: Icons.settings_outlined,
              tooltip: 'Settings',
              onPressed: () => pressed = true,
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(pressed, isTrue);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Settings')),
        isSemantics(isButton: true, isFocusable: true, hasTapAction: true),
      );
      handle.dispose();
    });
  });

  testWidgets('picker rows can be picked from the keyboard', (tester) async {
    String? picked;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            for (final speed in ['1x', '1.5x'])
              PickerSheetTile(
                icon: Icons.speed,
                title: speed,
                selected: speed == '1x',
                onTap: () => picked = speed,
              ),
          ],
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(picked, '1.5x');
  });

  testWidgets('NoticeBanner stays until dismissed', (tester) async {
    var dismissed = false;
    await tester.pumpWidget(
      _app(
        NoticeBanner(
          title: 'Heads up',
          message: 'Something changed.',
          onDismiss: () => dismissed = true,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Heads up'), findsOneWidget);
    await tester.tap(find.text('Got it'));
    expect(dismissed, isTrue);
  });

  group('BackShortcuts', () {
    Future<void> pushPage(WidgetTester tester) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const BackShortcuts(
                    child: Scaffold(body: Text('pushed page')),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('pushed page'), findsOneWidget);
    }

    testWidgets('Esc leaves a pushed page', (tester) async {
      await pushPage(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('pushed page'), findsNothing);
    });

    testWidgets('⌘[ leaves it on macOS', (tester) async {
      await pushPage(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.text('pushed page'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('Alt+← leaves it elsewhere', (tester) async {
      await pushPage(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(find.text('pushed page'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  group('AppSnackBar', () {
    Future<SnackBar> show(
      WidgetTester tester,
      void Function(BuildContext) fire,
    ) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => fire(context),
              child: const Text('fire'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('fire'));
      await tester.pump();
      return tester.widget<SnackBar>(find.byType(SnackBar));
    }

    testWidgets('errors get room and time to be read', (tester) async {
      final bar = await show(
        tester,
        (c) => AppSnackBar.showError(c, message: 'Something broke.'),
      );
      expect(bar.duration, greaterThanOrEqualTo(const Duration(seconds: 6)));
      final text = tester.widget<Text>(find.text('Something broke.'));
      expect(text.maxLines, 4);
    });

    testWidgets('routine confirmations stay short', (tester) async {
      final bar = await show(
        tester,
        (c) => AppSnackBar.showSuccess(c, message: 'Copied'),
      );
      expect(bar.duration, lessThanOrEqualTo(const Duration(seconds: 4)));
      expect(tester.widget<Text>(find.text('Copied')).maxLines, 2);
    });

    testWidgets('nothing outstays the ceiling', (tester) async {
      final bar = await show(
        tester,
        (c) => AppSnackBar.showInfo(
          c,
          message: 'x',
          duration: const Duration(minutes: 1),
        ),
      );
      expect(bar.duration, AppSnackBar.maxDuration);
    });
  });
}
