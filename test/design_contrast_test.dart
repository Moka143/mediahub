import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/design/app_colors.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/design/torrent_tone.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/utils/media_quality.dart';
import 'package:mediahub/widgets/editorial/mono_label.dart';

/// WCAG 2.1 contrast ratio: (L1 + 0.05) / (L2 + 0.05), with L the relative
/// luminance (0.2126 R + 0.7152 G + 0.0722 B over linearised sRGB) of the
/// lighter and darker colour. [Color.computeLuminance] is that formula.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Normal-size text (AA).
const double textMin = 4.5;

/// Non-text marks and large text (AA).
const double nonTextMin = 3.0;

/// Every surface text is drawn on. bgSurfaceHigher is checked separately:
/// only the two brightest text colours are allowed on it.
const surfaces = <String, Color>{
  'bgPage': AppColors.bgPage,
  'bgPageAlt': AppColors.bgPageAlt,
  'bgSurface': AppColors.bgSurface,
  'bgSurfaceHi': AppColors.bgSurfaceHi,
};

void main() {
  group('text tokens', () {
    const textColors = <String, Color>{
      'fg': AppColors.fg,
      'fg1': AppColors.fg1,
      'fg2': AppColors.fg2,
      'accent': AppColors.accent,
      'ok': AppColors.ok,
      'warn': AppColors.warn,
      'err': AppColors.err,
      'paused': AppColors.paused,
    };

    test('every text colour reads on every surface', () {
      for (final fg in textColors.entries) {
        for (final bg in surfaces.entries) {
          expect(
            contrast(fg.value, bg.value),
            greaterThanOrEqualTo(textMin),
            reason: '${fg.key} on ${bg.key}',
          );
        }
      }
    });

    test('the highest surface only carries the brightest text', () {
      for (final fg in [AppColors.fg, AppColors.fg1]) {
        expect(
          contrast(fg, AppColors.bgSurfaceHigher),
          greaterThanOrEqualTo(textMin),
        );
      }
    });

    test('text on a status fill uses onAccent, which reads on all of them', () {
      for (final fill in [
        AppColors.accent,
        AppColors.ok,
        AppColors.warn,
        AppColors.err,
      ]) {
        expect(
          contrast(AppColors.onAccent, fill),
          greaterThanOrEqualTo(textMin),
          reason: 'onAccent on $fill',
        );
      }
      // The reason it exists: white on the orange accent fails.
      expect(contrast(Colors.white, AppColors.accent), lessThan(textMin));
    });
  });

  group('fg3', () {
    test('clears the non-text minimum on every surface it sits on', () {
      for (final bg in surfaces.entries) {
        expect(
          contrast(AppColors.fg3, bg.value),
          greaterThanOrEqualTo(nonTextMin),
          reason: 'fg3 on ${bg.key}',
        );
      }
    });

    test('stays visibly dimmer than fg2', () {
      expect(
        AppColors.fg3.computeLuminance(),
        lessThan(AppColors.fg2.computeLuminance()),
      );
      expect(contrast(AppColors.fg2, AppColors.fg3), greaterThan(1.25));
    });
  });

  group('torrent state tone', () {
    Torrent torrent(String state) =>
        Torrent.fromJson({'hash': state, 'name': state, 'state': state});

    test('the built-in engine\'s states read as downloading', () {
      // rqbit reports a new torrent as metaDL and one with no peers as
      // stalledDL; the old string mapping had no case for either and showed
      // them grey, as if paused.
      for (final state in [
        'metaDL',
        'stalledDL',
        'allocating',
        'downloading',
      ]) {
        expect(
          torrentStateTone(torrent(state)),
          AppColors.downloading,
          reason: state,
        );
      }
      expect(torrentStateTone(torrent('pausedDL')), AppColors.paused);
      expect(torrentStateTone(torrent('error')), AppColors.err);
      expect(torrentStateTone(torrent('stalledUP')), AppColors.seeding);
    });

    test('every state tone reads as badge text', () {
      for (final state in [
        'downloading',
        'pausedDL',
        'error',
        'uploading',
        'checkingResumeData',
      ]) {
        for (final bg in surfaces.entries) {
          expect(
            contrast(torrentStateTone(torrent(state)), bg.value),
            greaterThanOrEqualTo(textMin),
            reason: '$state on ${bg.key}',
          );
        }
      }
    });
  });

  group('tones used as text', () {
    test('every quality tone reads as badge text', () {
      for (final quality in MediaQuality.values) {
        for (final bg in surfaces.entries) {
          expect(
            contrast(qualityTone(quality), bg.value),
            greaterThanOrEqualTo(textMin),
            reason: '$quality on ${bg.key}',
          );
        }
      }
    });
  });

  group('theme', () {
    setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

    test('muted text, hints and unselected tabs are legible', () {
      final theme = buildDarkTheme();
      final muted = theme.extension<AppColorsExtension>()!.mutedText;
      final hint = theme.inputDecorationTheme.hintStyle!.color!;
      final label = theme.inputDecorationTheme.labelStyle!.color!;
      final tab = theme.tabBarTheme.unselectedLabelColor!;

      for (final bg in surfaces.entries) {
        expect(contrast(muted, bg.value), greaterThanOrEqualTo(textMin));
        expect(contrast(hint, bg.value), greaterThanOrEqualTo(textMin));
        expect(contrast(label, bg.value), greaterThanOrEqualTo(textMin));
        expect(contrast(tab, bg.value), greaterThanOrEqualTo(textMin));
      }
    });

    test('keyboard focus is visible on buttons', () {
      final theme = buildDarkTheme();
      const focused = {WidgetState.focused};
      final styles = [
        theme.filledButtonTheme.style!,
        theme.outlinedButtonTheme.style!,
        theme.textButtonTheme.style!,
        theme.elevatedButtonTheme.style!,
        theme.iconButtonTheme.style!,
      ];
      for (final style in styles) {
        final side = style.side!.resolve(focused);
        expect(side, isNotNull);
        expect(side!.width, greaterThanOrEqualTo(2));
      }
      // ...and nothing is drawn around an unfocused text button.
      expect(theme.textButtonTheme.style!.side!.resolve({}), isNull);
    });
  });

  testWidgets('MonoLabel defaults to a legible colour', (tester) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MonoLabel('section'),
      ),
    );
    final text = tester.widget<Text>(find.text('SECTION'));
    for (final bg in surfaces.values) {
      expect(contrast(text.style!.color!, bg), greaterThanOrEqualTo(textMin));
    }
  });
}
