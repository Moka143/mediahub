import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../design/app_tokens.dart';
import '../../design/torrent_tone.dart';
import '../../models/local_media_file.dart';
import '../../models/torrent.dart';
import '../../utils/formatters.dart';
import '../../utils/media_names.dart';
import '../../utils/media_quality.dart';
import '../../widgets/media/media_poster_card.dart';
import '../../widgets/media/poster_lookup.dart';
import '../../widgets/media/row_header.dart';

/// Width of the cards in Home's horizontal rows.
const double homeCardWidth = 160;

/// A titled horizontal row of cards.
///
/// [height] defaults to a bare 2:3 poster — the overlay card has no text
/// below it, so the row needs no allowance for the text size. Rows that do
/// carry a caption pass a height measured through the text scaler.
class HomeRow extends StatelessWidget {
  const HomeRow({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.onSeeAll,
    this.height,
  });

  final String title;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final VoidCallback? onSeeAll;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RowHeader(title: title, onSeeAll: onSeeAll),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: height ?? homeCardWidth * 3 / 2,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              itemCount: itemCount,
              separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
              itemBuilder: itemBuilder,
            ),
          ),
        ],
      ),
    );
  }
}

/// Finished torrents for the "Freshly downloaded" row, most recently
/// finished first.
///
/// qBittorrent reports when each one finished. The built-in engine (rqbit)
/// reports neither an add time nor a completion time — both are 0 — so
/// there the engine's own list order, oldest first, reversed is the best
/// proxy left. The row used to reverse the list on both engines and ignore
/// completion time altogether.
List<Torrent> freshlyDownloaded(List<Torrent> torrents, {int limit = 8}) {
  final done = <({int index, Torrent torrent})>[
    for (var i = 0; i < torrents.length; i++)
      if (torrents[i].isCompleted || torrents[i].isSeeding)
        (index: i, torrent: torrents[i]),
  ];
  done.sort((a, b) {
    final byCompletion = b.torrent.completionOn.compareTo(
      a.torrent.completionOn,
    );
    if (byCompletion != 0) return byCompletion;
    final byAdded = b.torrent.addedOn.compareTo(a.torrent.addedOn);
    if (byAdded != 0) return byAdded;
    return b.index.compareTo(a.index);
  });
  return [for (final d in done.take(limit)) d.torrent];
}

/// The library file a finished torrent produced, or null when there is no
/// single answer.
///
/// A single-file torrent is named after its file, which settles it. For a
/// multi-file torrent the content path is the torrent's own folder, and its
/// largest video is the feature. Anything else — a content path that is a
/// shared download folder — is no answer: matching everything under it is
/// how a library delete once took another download's files with it.
LocalMediaFile? libraryFileForTorrent(
  Torrent torrent,
  List<LocalMediaFile> files,
) {
  final root = torrent.contentPath;
  if (root.isEmpty) return null;
  final inside = [
    for (final f in files)
      if (p.equals(f.path, root) || p.isWithin(root, f.path)) f,
  ];
  for (final f in inside) {
    if (f.fileName == torrent.name) return f;
  }
  if (p.basename(root) != torrent.name || inside.isEmpty) return null;
  return inside.reduce((a, b) => b.sizeBytes > a.sizeBytes ? b : a);
}

/// What to call a finished torrent on its card — the title it names, and
/// the episode when it is one.
String freshTitle(String torrentName) {
  final title = searchTitleFromTorrentName(torrentName);
  final code = parseEpisodeCode(torrentName);
  final base = title.isEmpty ? torrentName : title;
  if (code == null) return base;
  return '$base ${Formatters.episodeCode(code.season, code.episode)}';
}

/// One finished torrent as a poster card. Clicking it plays the file — the
/// tile used to have no tap handler at all.
class FreshTile extends ConsumerWidget {
  const FreshTile({super.key, required this.torrent, required this.onTap});

  final Torrent torrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quality = qualityBadgeLabel(torrent.name);
    final isEpisode = parseEpisodeCode(torrent.name) != null;
    return MediaPosterCard(
      title: freshTitle(torrent.name),
      posterAsync: watchPoster(ref, posterQueryForTorrent(torrent.name)),
      titleStyle: CardTitleStyle.overlay,
      overlayRating: quality,
      overlayRatingTone: qualityTone(MediaQuality.fromText(quality)),
      subtitle: 'Downloaded',
      width: homeCardWidth,
      placeholderIcon: isEpisode ? Icons.live_tv_rounded : Icons.movie_rounded,
      onTap: onTap,
    );
  }
}
