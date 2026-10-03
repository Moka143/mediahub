import 'package:flutter/material.dart';

import 'number_strip.dart';

/// The season strip at the top of an episode list. Season 0 — TMDB's
/// specials — reads "SP".
class SeasonTabs extends StatelessWidget {
  const SeasonTabs({
    super.key,
    required this.seasonNumbers,
    required this.selected,
    required this.onSelect,
  });

  final List<int> seasonNumbers;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return NumberStrip(
      title: 'SEASON',
      items: [
        for (final n in seasonNumbers)
          NumberStripItem(
            label: n == 0 ? 'SP' : n.toString().padLeft(2, '0'),
            semanticLabel: n == 0 ? 'Specials' : 'Season $n',
            selected: n == selected,
            onTap: () => onSelect(n),
          ),
      ],
    );
  }
}
