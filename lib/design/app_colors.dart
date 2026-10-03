import 'package:flutter/material.dart';

/// Cinematic editorial palette — warm near-black + single cinema-leader
/// orange accent. Replaces the previous indigo/violet "Stremio-clone"
/// palette. Sourced from the MediaHub redesign brief:
///
///   --bg: oklch(0.135 0.005 60)
///   --accent: oklch(0.72 0.18 38)
///   --ok: oklch(0.78 0.16 145)
///
/// OKLCH values converted to sRGB and stored here as flat constants.
///
/// Contrast rules (WCAG 2.1, pinned by `test/design_contrast_test.dart`):
/// text uses [fg], [fg1] or [fg2] — never [fg3] — and the status colours
/// read as text on every surface up to [bgSurfaceHi]. Anything drawn *on* an
/// [accent], [ok], [warn] or [err] fill uses [onAccent].
abstract final class AppColors {
  // ==========================================================================
  // Backgrounds — warm near-black with subtle warm cast
  // ==========================================================================
  /// Page background — deepest surface (window body)
  static const Color bgPage = Color(0xFF0A0806);

  /// Alternate page surface (sidebar, drawer chrome)
  static const Color bgPageAlt = Color(0xFF080706);

  /// Elevated surface (buttons, inputs, pills)
  static const Color bgSurface = Color(0xFF100E0C);

  /// Higher-elevation surface (cards, panels, hover state)
  static const Color bgSurfaceHi = Color(0xFF191714);

  /// Highest-elevation surface (tooltips, snackbars, switch tracks).
  ///
  /// Only [fg] and [fg1] are legible on it — [fg2] drops to 3.9:1 here — so
  /// keep secondary text off this surface.
  static const Color bgSurfaceHigher = Color(0xFF272321);

  // ==========================================================================
  // Foregrounds — warm off-white scale
  // ==========================================================================
  /// Primary text — warm off-white
  static const Color fg = Color(0xFFF6F1E9);

  /// Secondary text
  static const Color fg1 = Color(0xFFC9C3BC);

  /// Tertiary text (subtitles, captions, hints, mono labels).
  ///
  /// The dimmest colour any text may use: 4.5:1 or better on every surface
  /// up to [bgSurfaceHi].
  static const Color fg2 = Color(0xFF857F79);

  /// Muted non-text marks: inactive glyphs, drag handles, idle LEDs.
  ///
  /// Not for text. It used to be #514C47 — 2.1–2.4:1 against the dark
  /// surfaces — and was the default for hints, mono labels, inactive tabs
  /// and every Settings subtitle, which were barely readable. It now clears
  /// the 3:1 non-text minimum on [bgSurfaceHi] while staying visibly dimmer
  /// than [fg2].
  static const Color fg3 = Color(0xFF6E6862);

  // ==========================================================================
  // Hairline rules — almost invisible by design
  // ==========================================================================
  /// 6% white — section dividers, row separators
  static const Color line = Color(0x0FFFFFFF);

  /// 12% white — stronger borders (modals, key surfaces)
  static const Color lineStrong = Color(0x1FFFFFFF);

  // ==========================================================================
  // Accent — cinema-leader orange. The ONE color that means something.
  // ==========================================================================
  /// Primary accent — active state, primary CTA, current row indicator
  static const Color accent = Color(0xFFFF7448);

  /// Text and icons drawn on an [accent] fill — and on [ok], [warn] and
  /// [err] fills. Dark, not white: white on this orange is 2.7:1 and fails
  /// WCAG AA, white on [ok] is 1.9:1; the page colour is 7.5:1 on [accent].
  static const Color onAccent = bgPage;

  /// 16% accent — soft fill (selected chip, badge background)
  static const Color accentSoft = Color(0x29FF7448);

  // ==========================================================================
  // Status — restrained. Use sparingly.
  // ==========================================================================
  /// Ready / seeding / downloaded
  static const Color ok = Color(0xFF6ED274);

  /// 14% ok — soft fill
  static const Color okSoft = Color(0x246ED274);

  /// Queued / checking / warning
  static const Color warn = Color(0xFFF3B94C);

  /// Error / missing
  static const Color err = Color(0xFFFF5F5B);

  // ==========================================================================
  // Glass overlays — used by floating chrome stacked over hero artwork
  // (back / favorite / watchlist buttons on details, etc.). Constants
  // rather than `Colors.white.withAlpha(N)` literals so call sites stay
  // `const`-correct.
  // ==========================================================================
  /// 8% white — base glass fill
  static const Color glassFill = Color(0x14FFFFFF);

  /// 15% white — glass border / emphasis stroke
  static const Color glassBorder = Color(0x26FFFFFF);

  /// 30% black — soft scrim over imagery (gradient top)
  static const Color scrimSoft = Color(0x50000000);

  /// 60% black — stronger scrim over imagery (gradient bottom / text)
  static const Color scrimStrong = Color(0xA0000000);

  // ==========================================================================
  // Depth
  // ==========================================================================
  /// 10% white — the unfilled part of a progress bar or slider.
  static const Color track = Color(0x1AFFFFFF);

  /// 50% black — the dimming behind a modal sheet, drawer or dialog. One
  /// value, so every modal pushes the app back by the same amount.
  static const Color barrier = Color(0x80000000);

  /// Drop shadows under raised surfaces: pure black, at the opacity the
  /// surface's elevation calls for.
  static const Color shadow = Color(0xFF000000);

  // ==========================================================================
  // Media chrome — controls and text drawn over video frames and artwork.
  // Neutral white and black rather than the warm palette: a warm tint over
  // a picture reads as a colour cast, and these must stay legible over any
  // frame. Scrims are [mediaBlack] at the opacity the artwork needs.
  // ==========================================================================
  /// Icons and text over video or artwork.
  static const Color onMedia = Color(0xFFFFFFFF);

  /// Secondary text and idle icons over video or artwork — 70% white.
  static const Color onMediaMuted = Color(0xB3FFFFFF);

  /// The letterbox behind the picture, and the base of every scrim.
  static const Color mediaBlack = Color(0xFF000000);

  // ==========================================================================
  // Torrent states — what `torrentStateTone` maps a torrent onto. Named for
  // the state rather than the hue so a state can be re-coloured in one place.
  // ==========================================================================
  static const Color downloading = accent;
  static const Color seeding = ok;

  /// [fg2], not [fg3]: it colours the state badge's *text* as well as the
  /// row's dot and progress bar.
  static const Color paused = fg2;
  static const Color errorState = err;
}

/// The rating colour for a 0–10 TMDB score.
Color getRatingColor(double rating) {
  if (rating >= 8.0) return AppColors.ok;
  if (rating >= 6.0) return AppColors.accent;
  if (rating >= 4.0) return AppColors.warn;
  return AppColors.err;
}
