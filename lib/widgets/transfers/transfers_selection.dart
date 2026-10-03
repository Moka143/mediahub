/// What a click — or Enter / Space — on a Transfers row means.
enum TransfersClick {
  /// Show the transfer's details.
  open,

  /// Add the row to the multi-selection, or take it out.
  toggle,

  /// Select every row from the anchor to this one.
  extend,
}

/// The desktop convention: Shift extends from the last row clicked, ⌘ (Ctrl
/// on Windows and Linux) toggles one row, and once a selection is under way
/// a plain click toggles too — it would be surprising for a click in the
/// middle of picking rows to open one and lose the place.
TransfersClick transfersClickIntent({
  required bool selectionMode,
  required bool shiftHeld,
  required bool toggleModifierHeld,
}) {
  if (shiftHeld) return TransfersClick.extend;
  if (toggleModifierHeld || selectionMode) return TransfersClick.toggle;
  return TransfersClick.open;
}

/// The hashes from [anchor] to [target] inclusive, in on-screen order.
///
/// Without a usable anchor — none yet, or that row has since been filtered
/// out or deleted — the range is just [target].
List<String> transfersRange(
  List<String> orderedHashes,
  String? anchor,
  String target,
) {
  final to = orderedHashes.indexOf(target);
  if (to < 0) return const [];
  final from = anchor == null ? -1 : orderedHashes.indexOf(anchor);
  if (from < 0) return [target];
  final start = from < to ? from : to;
  final end = from < to ? to : from;
  return orderedHashes.sublist(start, end + 1);
}
