import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_tokens.dart';
import '../../models/local_media_file.dart';
import '../../models/watch_progress.dart';
import '../../providers/local_media_provider.dart';
import '../../utils/feedback_utils.dart';
import '../../utils/media_names.dart';
import '../media/media.dart';

class ContinueWatchingStrip extends ConsumerWidget {
  final List<WatchProgress> items;
  final void Function(WatchProgress) onTap;
  final void Function(WatchProgress) onRemove;
  final void Function(LocalMediaFile)? onMarkWatched;
  final void Function(LocalMediaFile)? onDelete;

  const ContinueWatchingStrip({
    super.key,
    required this.items,
    required this.onTap,
    required this.onRemove,
    this.onMarkWatched,
    this.onDelete,
  });

  /// Locate the underlying [LocalMediaFile] for a Continue-Watching entry —
  /// needed because the mark-watched / delete actions operate on files, not
  /// progress records. Returns null if the file is no longer on disk.
  LocalMediaFile? _fileFor(WidgetRef ref, WatchProgress progress) {
    final files = ref.read(localMediaFilesProvider).value ?? [];
    for (final f in files) {
      if (f.path == progress.filePath) return f;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      // Asked of the card rather than hard-coded: these rows carry a
      // subtitle ("48 min remaining"), and the previous fixed 190 clipped
      // 84 px off every card.
      height: MediaPosterCard.heightForWidth(context),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: items.length,
        itemBuilder: (context, index) {
          final progress = items[index];
          return ContinueWatchingCard(
            progress: progress,
            onTap: () => onTap(progress),
            onRemove: () => onRemove(progress),
            onMarkWatched: onMarkWatched == null
                ? null
                : () {
                    final f = _fileFor(ref, progress);
                    if (f != null) {
                      onMarkWatched!(f);
                    } else {
                      AppSnackBar.showInfo(
                        context,
                        message: 'File missing on disk — rescan to clean up',
                      );
                    }
                  },
            onDelete: onDelete == null
                ? null
                : () {
                    final f = _fileFor(ref, progress);
                    if (f != null) {
                      onDelete!(f);
                    } else {
                      AppSnackBar.showInfo(
                        context,
                        message: 'File missing on disk — rescan to clean up',
                      );
                    }
                  },
          );
        },
      ),
    );
  }
}

/// Grid of [MediaPosterCard]s for flat lists of local files (Recent / Movies).
class LocalMediaGrid extends StatelessWidget {
  final List<LocalMediaFile> files;
  final void Function(LocalMediaFile) onTap;
  final void Function(LocalMediaFile) onMarkWatched;
  final void Function(LocalMediaFile) onMarkNotWatched;
  final void Function(LocalMediaFile) onDelete;

  const LocalMediaGrid({
    super.key,
    required this.files,
    required this.onTap,
    required this.onMarkWatched,
    required this.onMarkNotWatched,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
        // 2:3 poster (width * 1.5) + ~45px caption block = needs ~width / 0.56.
        // Anything tighter clips the title row and triggers Flutter's striped
        // overflow indicator at the card's bottom edge.
        childAspectRatio: 152 / 272,
      ),
      itemCount: files.length,
      itemBuilder: (_, index) {
        final file = files[index];
        return LocalMediaCard(
          file: file,
          onTap: () => onTap(file),
          onMarkWatched: () => onMarkWatched(file),
          onMarkNotWatched: () => onMarkNotWatched(file),
          onDelete: () => onDelete(file),
        );
      },
    );
  }
}

/// Grid of show cards. Tap a show → modal sheet with seasons & episodes.
class ShowsGrid extends StatelessWidget {
  final List<ShowWithSeasons> shows;
  final void Function(LocalMediaFile) onFileTap;
  final void Function(LocalMediaFile) onMarkWatched;
  final void Function(LocalMediaFile) onMarkNotWatched;
  final void Function(LocalMediaFile) onDelete;

  const ShowsGrid({
    super.key,
    required this.shows,
    required this.onFileTap,
    required this.onMarkWatched,
    required this.onMarkNotWatched,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
        // 2:3 poster (width * 1.5) + ~45px caption block = needs ~width / 0.56.
        // Anything tighter clips the title row and triggers Flutter's striped
        // overflow indicator at the card's bottom edge.
        childAspectRatio: 152 / 272,
      ),
      itemCount: shows.length,
      itemBuilder: (_, index) {
        final showData = shows[index];
        return ShowCard(
          showData: showData,
          onFileTap: onFileTap,
          onMarkWatched: onMarkWatched,
          onMarkNotWatched: onMarkNotWatched,
          onDelete: onDelete,
        );
      },
    );
  }
}

/// Single library item rendered as a poster card. Resolves its poster (show
/// poster if it's an episode, movie poster otherwise) via the existing
/// TMDB poster providers.
class LocalMediaCard extends ConsumerWidget {
  final LocalMediaFile file;
  final VoidCallback onTap;
  final VoidCallback onMarkWatched;
  final VoidCallback onMarkNotWatched;
  final VoidCallback onDelete;

  const LocalMediaCard({
    super.key,
    required this.file,
    required this.onTap,
    required this.onMarkWatched,
    required this.onMarkNotWatched,
    required this.onDelete,
  });

  AsyncValue<String?>? _resolvePoster(WidgetRef ref) {
    if (file.showName != null &&
        file.showName!.isNotEmpty &&
        (file.seasonNumber != null || file.episodeNumber != null)) {
      return ref.watch(showPosterProvider(file.showName!));
    }
    // For movies, strip quality/year/extension noise before searching TMDB —
    // a raw filename like `Movie.2020.1080p.BluRay.mkv` rarely matches.
    final movieName = file.showName ?? cleanMediaTitle(file.fileName);
    if (movieName.isEmpty) return null;
    return ref.watch(moviePosterProvider(movieName));
  }

  String _displayTitle() {
    if (file.showName != null && file.showName!.isNotEmpty) {
      return file.episodeCode != null
          ? '${file.showName} ${file.episodeCode}'
          : file.showName!;
    }
    final cleaned = cleanMediaTitle(file.fileName);
    return cleaned.isNotEmpty ? cleaned : file.fileName;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = <MediaCardAction>[
      if (!file.isWatched)
        MediaCardAction(
          icon: Icons.check_circle_outline_rounded,
          label: 'Mark as watched',
          onSelected: onMarkWatched,
        ),
      if (file.isWatched)
        MediaCardAction(
          icon: Icons.remove_circle_outline_rounded,
          label: 'Mark as not watched',
          onSelected: onMarkNotWatched,
        ),
      MediaCardAction(
        icon: Icons.delete_outline_rounded,
        label: 'Delete',
        onSelected: onDelete,
        destructive: true,
      ),
    ];

    return MediaPosterCard(
      posterAsync: _resolvePoster(ref),
      title: _displayTitle(),
      subtitle: [
        file.formattedSize,
        if (file.quality != null) file.quality!,
      ].join(' • '),
      badge: file.episodeCode,
      progress: file.hasProgress ? file.watchProgress : null,
      isWatched: file.isWatched,
      onTap: onTap,
      actions: actions,
    );
  }
}

/// Show-level card. Tap opens [ShowEpisodesSheet] for season/episode drill-in.
class ShowCard extends ConsumerWidget {
  final ShowWithSeasons showData;
  final void Function(LocalMediaFile) onFileTap;
  final void Function(LocalMediaFile) onMarkWatched;
  final void Function(LocalMediaFile) onMarkNotWatched;
  final void Function(LocalMediaFile) onDelete;

  const ShowCard({
    super.key,
    required this.showData,
    required this.onFileTap,
    required this.onMarkWatched,
    required this.onMarkNotWatched,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final posterAsync = ref.watch(showPosterProvider(showData.showName));
    final hasMultipleSeasons = showData.seasons.length > 1;
    final subtitle = hasMultipleSeasons
        ? '${showData.seasons.length} seasons • ${showData.totalEpisodes} ep'
        : '${showData.totalEpisodes} episode'
              '${showData.totalEpisodes > 1 ? 's' : ''}';

    return MediaPosterCard(
      posterAsync: posterAsync,
      title: showData.showName,
      subtitle: subtitle,
      onTap: () => ShowEpisodesSheet.show(
        context,
        showData: showData,
        onFileTap: (f) {
          Navigator.of(context).maybePop();
          onFileTap(f);
        },
        onMarkWatched: onMarkWatched,
        onMarkNotWatched: onMarkNotWatched,
        onDelete: onDelete,
      ),
    );
  }
}

// ============================================================================
// All Sections View
// ============================================================================
