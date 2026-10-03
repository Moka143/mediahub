import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../models/local_media_file.dart';
import '../../models/torrent.dart';
import '../../providers/torrent_provider.dart';
import '../../utils/media_names.dart';

/// Per-episode lifecycle status. One visual language for the episode
/// drawer's quick-jump pills and rows, and the calendar.
enum EpisodeStatus { none, downloading, downloaded, watched }

/// Named rather than anonymous: an unnamed extension is library-private, so
/// sibling files could not see these getters.
extension EpisodeStatusDisplay on EpisodeStatus {
  /// Downloaded and downloading used to share the accent orange, so a pill
  /// could not say which it was. Downloaded is the "ready" green; watched is
  /// dimmed — done, and the least interesting row to scan for.
  Color get color => switch (this) {
    EpisodeStatus.watched => AppColors.fg2,
    EpisodeStatus.downloaded => AppColors.ok,
    EpisodeStatus.downloading => AppColors.accent,
    EpisodeStatus.none => AppColors.fg2,
  };

  IconData? get icon => switch (this) {
    EpisodeStatus.watched => Icons.check_rounded,
    EpisodeStatus.downloaded => Icons.download_done_rounded,
    EpisodeStatus.downloading => Icons.downloading_rounded,
    EpisodeStatus.none => null,
  };

  String get label => switch (this) {
    EpisodeStatus.watched => 'Watched',
    EpisodeStatus.downloaded => 'Downloaded',
    EpisodeStatus.downloading => 'Downloading',
    EpisodeStatus.none => '',
  };
}

/// One torrent in Transfers that names a single episode.
typedef _EpisodeTorrent = ({
  String title,
  int season,
  int episode,
  bool complete,
});

/// What the Transfers list says about each episode it holds.
///
/// Built once per torrent poll and compared by value, so a widget that
/// `select`s it rebuilds only when an episode's status actually changes —
/// not every two seconds while a download's speed figure moves.
///
/// The drawer this replaces matched a torrent to a show on the *first word*
/// of the show's name, so every "The …" show matched every torrent with the
/// same `SxxEyy`, and counted any torrent that was not actively downloading
/// — paused at 10%, errored — as downloaded. Now: the full title must match
/// ([titlesMatch]) and the episode code must be exact ([parseEpisodeCode]);
/// only a finished torrent is "downloaded"; anything else in Transfers is
/// "downloading".
@immutable
class TransfersEpisodeIndex {
  const TransfersEpisodeIndex._(this._entries);

  factory TransfersEpisodeIndex.from(Iterable<Torrent> torrents) {
    final entries = <_EpisodeTorrent>[];
    for (final t in torrents) {
      final code = parseEpisodeCode(t.name);
      if (code == null) continue;
      final title = searchTitleFromTorrentName(t.name);
      if (title.isEmpty) continue;
      entries.add((
        title: title,
        season: code.season,
        episode: code.episode,
        complete: t.progress >= 1 && !t.hasError,
      ));
    }
    return TransfersEpisodeIndex._(entries);
  }

  static const TransfersEpisodeIndex empty = TransfersEpisodeIndex._([]);

  final List<_EpisodeTorrent> _entries;

  /// Status of [showName]'s [season]x[episode] in Transfers.
  EpisodeStatus statusOf(String showName, int season, int episode) {
    var status = EpisodeStatus.none;
    for (final e in _entries) {
      if (e.season != season || e.episode != episode) continue;
      if (!titlesMatch(e.title, showName)) continue;
      if (e.complete) return EpisodeStatus.downloaded;
      status = EpisodeStatus.downloading;
    }
    return status;
  }

  static const _equality = ListEquality<_EpisodeTorrent>();

  @override
  bool operator ==(Object other) =>
      other is TransfersEpisodeIndex &&
      _equality.equals(other._entries, _entries);

  @override
  int get hashCode => _equality.hash(_entries);
}

/// The Transfers list as a [TransfersEpisodeIndex].
///
/// `select`ed, so it notifies only when some episode's status changes — the
/// torrent list itself changes on every two-second poll.
final transfersEpisodeIndexProvider = Provider<TransfersEpisodeIndex>((ref) {
  return ref.watch(
    torrentListProvider.select(
      (state) => TransfersEpisodeIndex.from(state.torrents),
    ),
  );
});

/// Whether the library holds [showName]'s [season]x[episode].
bool libraryHasEpisode(
  Iterable<LocalMediaFile> files,
  String showName,
  int season,
  int episode,
) {
  for (final f in files) {
    if (f.seasonNumber != season || f.episodeNumber != episode) continue;
    final name = f.showName;
    if (name != null && titlesMatch(name, showName)) return true;
  }
  return false;
}
