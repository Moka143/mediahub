import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/models/torrent_action_result.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/torrent_provider.dart';
import 'package:mediahub/widgets/add_torrent_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/transfers_fakes.dart';

const _hex = '0123456789abcdef0123456789abcdef01234567';
const _magnet = 'magnet:?xt=urn:btih:$_hex';

/// Returns [path] from the .torrent chooser, as if the user had picked it.
class _FakePicker extends FilePicker {
  _FakePicker(this.path);

  final String path;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    PlatformFile(path: path, name: path.split('/').last, size: 10),
  ]);
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late SharedPreferences prefs;
  late FakeTorrentList list;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    list = FakeTorrentList();
  });

  void clipboardHolds(WidgetTester tester, String? text) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return text == null ? null : <String, dynamic>{'text': text};
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(showAddTorrentDialog(context)),
            child: const Text('open'),
          ),
        ),
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          torrentListProvider.overrideWith(() => list),
        ],
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('clipboard', () {
    testWidgets('a magnet link on the clipboard is offered in the field', (
      tester,
    ) async {
      clipboardHolds(tester, '  $_magnet  ');
      await openDialog(tester);

      expect(find.text(_magnet), findsOneWidget);
      expect(find.text('Pasted from the clipboard'), findsOneWidget);
    });

    testWidgets('anything else on the clipboard is left alone', (tester) async {
      clipboardHolds(tester, 'https://example.org/some-page');
      await openDialog(tester);

      expect(find.text('https://example.org/some-page'), findsNothing);
      expect(find.text('Pasted from the clipboard'), findsNothing);
    });
  });

  group('checking what was typed', () {
    testWidgets('junk is explained under the field and never sent', (
      tester,
    ) async {
      clipboardHolds(tester, null);
      await openDialog(tester);

      await tester.enterText(find.byType(TextField), 'hello world');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(
        find.text("That isn't a magnet link or a torrent web address."),
        findsOneWidget,
      );
      expect(list.addedLinks, isEmpty);
      expect(find.byType(AddTorrentDialog), findsOneWidget);
    });

    testWidgets('a bare info hash is added as a magnet link', (tester) async {
      clipboardHolds(tester, null);
      await openDialog(tester);

      await tester.enterText(find.byType(TextField), '  ${_hex.toUpperCase()}');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(list.addedLinks, [_magnet]);
      expect(find.byType(AddTorrentDialog), findsNothing);
    });
  });

  group('while adding', () {
    testWidgets('Esc and a click outside do not close the dialog', (
      tester,
    ) async {
      clipboardHolds(tester, null);
      list.addGate = Completer<TorrentActionResult>();
      await openDialog(tester);

      await tester.enterText(find.byType(TextField), _magnet);
      await tester.tap(find.text('Add'));
      await tester.pump();
      expect(find.text('Adding…'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.byType(AddTorrentDialog), findsOneWidget);

      // A failure comes back in words, and the dialog is usable again.
      list.addGate!.complete(
        const TorrentActionResult.failure("Can't reach the torrent engine"),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Couldn't add the torrent. The torrent engine isn't reachable "
          'right now.',
        ),
        findsOneWidget,
      );
      expect(find.text('Add'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AddTorrentDialog), findsNothing);
    });

    testWidgets('an answer after the dialog is gone is ignored safely', (
      tester,
    ) async {
      clipboardHolds(tester, null);
      list.addGate = Completer<TorrentActionResult>();
      await openDialog(tester);

      await tester.enterText(find.byType(TextField), _magnet);
      await tester.tap(find.text('Add'));
      await tester.pump();

      // Forced away (not something the user can do — Esc is blocked).
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.byType(AddTorrentDialog), findsNothing);

      list.addGate!.complete(const TorrentActionResult.failure('late'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('torrent file', () {
    // No picker is registered under test, so there is nothing to restore;
    // each test file runs in its own isolate.
    testWidgets('a chosen file can be dropped again, and typing a link '
        'replaces it', (tester) async {
      FilePicker.platform = _FakePicker('/downloads/show.torrent');
      clipboardHolds(tester, null);
      await openDialog(tester);

      await tester.tap(find.text('Choose .torrent file'));
      await tester.pumpAndSettle();
      expect(find.text('show.torrent'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove this file'));
      await tester.pumpAndSettle();
      expect(find.text('show.torrent'), findsNothing);
      expect(find.text('Choose .torrent file'), findsOneWidget);

      await tester.tap(find.text('Choose .torrent file'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), _magnet);
      await tester.pumpAndSettle();
      expect(find.text('show.torrent'), findsNothing);

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(list.addedLinks, [_magnet]);
      expect(list.addedFiles, isEmpty);
    });
  });

  group('a dropped .torrent file', () {
    testWidgets('opens the dialog with that file chosen, clipboard untouched', (
      tester,
    ) async {
      clipboardHolds(tester, _magnet);
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                showAddTorrentDialog(
                  context,
                  torrentFile: '/downloads/dropped.torrent',
                ),
              ),
              child: const Text('open'),
            ),
          ),
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            torrentListProvider.overrideWith(() => list),
          ],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('dropped.torrent'), findsOneWidget);
      // The drop is what the user asked for; a magnet sitting on the
      // clipboard must not replace it.
      expect(find.text('Pasted from the clipboard'), findsNothing);

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(list.addedFiles, ['/downloads/dropped.torrent']);
      expect(list.addedLinks, isEmpty);
    });
  });
}
