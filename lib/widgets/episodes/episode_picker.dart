import 'package:flutter/material.dart';

import '../../models/episode.dart';
import 'episode_status.dart';
import 'number_strip.dart';

/// Quick-jump strip above the episode list — one chip per episode. Watched
/// episodes are washed in their colour; downloaded and downloading ones get
/// a coloured stripe, green and orange respectively.
class EpisodePicker extends StatelessWidget {
  const EpisodePicker({
    super.key,
    required this.episodes,
    required this.onSelect,
    required this.statusFor,
  });

  final List<Episode> episodes;

  /// Called with the episode's index in [episodes].
  final ValueChanged<int> onSelect;
  final EpisodeStatus Function(Episode) statusFor;

  @override
  Widget build(BuildContext context) {
    return NumberStrip(
      title: 'EPISODE',
      items: [
        for (var i = 0; i < episodes.length; i++)
          _item(i, episodes[i], statusFor(episodes[i])),
      ],
    );
  }

  NumberStripItem _item(int index, Episode episode, EpisodeStatus status) {
    final number = episode.episodeNumber;
    return NumberStripItem(
      label: number.toString().padLeft(2, '0'),
      semanticLabel: status == EpisodeStatus.none
          ? 'Episode $number'
          : 'Episode $number, ${status.label.toLowerCase()}',
      tone: status == EpisodeStatus.none ? null : status.color,
      tinted: status == EpisodeStatus.watched,
      onTap: () => onSelect(index),
    );
  }
}
