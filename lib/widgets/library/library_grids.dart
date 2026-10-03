import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_tokens.dart';
import '../../models/local_media_file.dart';
import '../../models/show_with_seasons.dart';
import '../../models/watch_progress.dart';
import '../../utils/media_names.dart';
import '../media/continue_watching_card.dart';
import '../media/media_poster_card.dart';
import '../media/poster_lookup.dart';
import 'library_item_actions.dart';
import 'library_show_drawer.dart';

/// Widest a poster tile may get before the grid adds another column.
const double _tileWidth = 180.0;

/// Horizontal Continue Watching row.
class ContinueWatchingStrip extends ConsumerWidget {
  const ContinueWatchingStrip({
    super.key,
    required this.items,
    required this.actions,
  });

  final List<WatchProgress> items;
  final LibraryActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      // Asked of the card rather than hard-coded: these cards carry a
      // subtitle ("48m left"), and the previous fixed 190 clipped 84 px off
      // every card.
      height: MediaPosterCard.heightForWidth(context),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) {
          final progress = items[index];
          return ContinueWatchingCard(
            progress: progress,
            onTap: () => actions.playProgress(progress),
            onRemove: () => actions.removeProgress(progress),
            onMarkWatched: () =>
                actions.markWatched(actions.fileFor(ref, progress)),
            onDelete: () => actions.deleteFile(actions.fileFor(ref, progress)),
          );
        },
      ),
    );
  }
}

/// A lazily built grid of library cards.
///
/// A sliver, so only the cards on screen exist — and only they look up a
/// poster. The shrink-wrapped GridView this replaces built every card up
/// front, and every card fires a TMDB search: 500 files meant up to 500
/// searches and image loads at once.
///
/// Rows are sized from each tile's *actual* width through
/// [MediaPosterCard.heightForWidth]. The aspect ratio used before was
/// measured at the widest tile only, so narrower tiles clipped their
/// caption by a few pixels.
class _LibraryCardGrid extends StatelessWidget {
  const _LibraryCardGrid({required this.itemCount, required this.itemBuilder});

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        const spacing = AppSpacing.md;
        final width = constraints.crossAxisExtent;
        final columns = math.max(1, (width / (_tileWidth + spacing)).ceil());
        final tileWidth = (width - spacing * (columns - 1)) / columns;
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: MediaPosterCard.heightForWidth(
              context,
              width: tileWidth,
            ),
          ),
          delegate: SliverChildBuilderDelegate(
            itemBuilder,
            childCount: itemCount,
          ),
        );
      },
    );
  }
}

/// Library files (Recent / Movies) as a sliver grid.
class LibraryFileGrid extends StatelessWidget {
  const LibraryFileGrid({
    super.key,
    required this.files,
    required this.actions,
  });

  final List<LocalMediaFile> files;
  final LibraryActions actions;

  @override
  Widget build(BuildContext context) {
    return _LibraryCardGrid(
      itemCount: files.length,
      itemBuilder: (_, i) => LocalMediaCard(file: files[i], actions: actions),
    );
  }
}

/// Library shows as a sliver grid; a card opens that show's episodes.
class LibraryShowGrid extends StatelessWidget {
  const LibraryShowGrid({
    super.key,
    required this.shows,
    required this.actions,
  });

  final List<ShowWithSeasons> shows;
  final LibraryActions actions;

  @override
  Widget build(BuildContext context) {
    return _LibraryCardGrid(
      itemCount: shows.length,
      itemBuilder: (_, i) => ShowCard(showData: shows[i], actions: actions),
    );
  }
}

/// One library file as a poster card.
class LocalMediaCard extends ConsumerWidget {
  const LocalMediaCard({super.key, required this.file, required this.actions});

  final LocalMediaFile file;
  final LibraryActions actions;

  String _title() {
    final show = file.showName;
    if (show != null && show.isNotEmpty) {
      return file.episodeCode != null ? '$show ${file.episodeCode}' : show;
    }
    final cleaned = cleanMediaTitle(file.fileName);
    return cleaned.isNotEmpty ? cleaned : file.fileName;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isEpisode = file.seasonNumber != null || file.episodeNumber != null;
    return MediaPosterCard(
      posterAsync: watchFilePoster(ref, file),
      title: _title(),
      subtitle: [file.formattedSize, ?file.quality].join(' · '),
      badge: file.episodeCode,
      progress: file.hasProgress ? file.watchProgress : null,
      isWatched: file.isWatched,
      width: null,
      placeholderIcon: isEpisode ? Icons.live_tv_rounded : Icons.movie_rounded,
      onTap: () => actions.playFile(file),
      actions: [
        if (file.isWatched)
          MediaCardAction(
            icon: Icons.remove_circle_outline_rounded,
            label: 'Mark as not watched',
            onSelected: () => actions.markNotWatched(file),
          )
        else
          MediaCardAction(
            icon: Icons.check_circle_outline_rounded,
            label: 'Mark as watched',
            onSelected: () => actions.markWatched(file),
          ),
        MediaCardAction(
          icon: Icons.delete_outline_rounded,
          label: 'Delete',
          onSelected: () => actions.deleteFile(file),
          destructive: true,
        ),
      ],
    );
  }
}

/// A show in the library as one card; opening it lists its episodes.
class ShowCard extends ConsumerWidget {
  const ShowCard({super.key, required this.showData, required this.actions});

  final ShowWithSeasons showData;
  final LibraryActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seasons = showData.seasons.length;
    final episodes = showData.totalEpisodes;
    final episodeLabel = episodes == 1 ? '1 episode' : '$episodes episodes';
    return MediaPosterCard(
      posterAsync: watchPoster(ref, PosterQuery.show(showData.showName)),
      title: showData.showName,
      subtitle: seasons > 1 ? '$seasons seasons · $episodeLabel' : episodeLabel,
      width: null,
      placeholderIcon: Icons.live_tv_rounded,
      onTap: () => LibraryShowDrawer.open(
        context,
        showName: showData.showName,
        actions: actions,
      ),
    );
  }
}
