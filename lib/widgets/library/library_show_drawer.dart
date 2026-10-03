import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/local_media_file.dart';
import '../../models/show_with_seasons.dart';
import '../../providers/local_media_provider.dart';
import '../common/hub_pressable.dart';
import '../common/mediahub_drawer_header.dart';
import '../common/mediahub_popup_menu.dart';
import '../editorial/editorial.dart';
import '../episodes/season_tabs.dart';
import '../mediahub_drawer.dart';
import 'library_item_actions.dart';

/// The episodes of one show that are in the library, in the same side
/// drawer and season strip as the show page's episode browser.
///
/// It replaces a Material bottom sheet that rendered a snapshot of the show
/// taken when it opened: after "Mark as watched" the row kept offering
/// "Mark as watched", and after "Delete" the deleted file stayed listed —
/// clicking it opened the player on a missing path. This drawer watches the
/// library, so every action shows the moment it lands.
class LibraryShowDrawer extends ConsumerStatefulWidget {
  const LibraryShowDrawer({
    super.key,
    required this.showName,
    required this.actions,
  });

  final String showName;
  final LibraryActions actions;

  static Future<void> open(
    BuildContext context, {
    required String showName,
    required LibraryActions actions,
  }) {
    return MediaHubDrawer.show<void>(
      context: context,
      builder: (_) => LibraryShowDrawer(showName: showName, actions: actions),
    );
  }

  @override
  ConsumerState<LibraryShowDrawer> createState() => _LibraryShowDrawerState();
}

class _LibraryShowDrawerState extends ConsumerState<LibraryShowDrawer> {
  int? _season;

  @override
  Widget build(BuildContext context) {
    // The same case-insensitive key the library groups shows by.
    final key = widget.showName.toLowerCase();
    ShowWithSeasons? show;
    for (final s in ref.watch(localMediaByShowAndSeasonProvider)) {
      if (s.showName.toLowerCase() == key) {
        show = s;
        break;
      }
    }

    final seasons = show?.seasons.keys.toList() ?? const <int>[];
    final season = seasons.contains(_season)
        ? _season!
        : (seasons.isEmpty ? null : seasons.first);
    final files = season == null
        ? const <LocalMediaFile>[]
        : show!.seasons[season]!;

    final episodeCount = show?.totalEpisodes ?? 0;
    return Padding(
      padding: const EdgeInsets.only(left: MediaHubDrawer.dragGripWidth),
      child: Column(
        children: [
          MediaHubDrawerHeader(
            kicker: 'IN YOUR LIBRARY',
            title: show?.showName ?? widget.showName,
            subtitle: [
              seasons.length == 1 ? '1 season' : '${seasons.length} seasons',
              episodeCount == 1 ? '1 episode' : '$episodeCount episodes',
            ].join(' · '),
            subtitleUppercase: true,
            onClose: () => Navigator.of(context).pop(),
          ),
          if (seasons.length > 1 && season != null)
            SeasonTabs(
              seasonNumbers: seasons,
              selected: season,
              onSelect: (n) => setState(() => _season = n),
            ),
          Expanded(
            child: files.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text(
                        'No episodes of this show are left in your library.',
                        textAlign: TextAlign.center,
                        style: AppType.ui(
                          size: AppType.sizeBody,
                          color: AppColors.fg1,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    itemCount: files.length,
                    itemBuilder: (_, i) => _LocalEpisodeRow(
                      file: files[i],
                      actions: widget.actions,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One library file in the drawer: click plays it; the menu (or a right
/// click) marks it watched or deletes it.
class _LocalEpisodeRow extends StatefulWidget {
  const _LocalEpisodeRow({required this.file, required this.actions});

  final LocalMediaFile file;
  final LibraryActions actions;

  @override
  State<_LocalEpisodeRow> createState() => _LocalEpisodeRowState();
}

enum _RowAction { watched, notWatched, delete }

class _LocalEpisodeRowState extends State<_LocalEpisodeRow> {
  final _menuKey = GlobalKey<PopupMenuButtonState<_RowAction>>();
  bool _hover = false;
  bool _focus = false;

  void _run(_RowAction action) {
    final file = widget.file;
    switch (action) {
      case _RowAction.watched:
        widget.actions.markWatched(file);
      case _RowAction.notWatched:
        widget.actions.markNotWatched(file);
      case _RowAction.delete:
        widget.actions.deleteFile(file);
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final active = _hover || _focus;
    final inProgress = file.hasProgress && !file.isWatched;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: HubPressable(
        onTap: () => widget.actions.playFile(file),
        onSecondaryTap: () => _menuKey.currentState?.showButtonMenu(),
        onHoverChanged: (h) => setState(() => _hover = h),
        onFocusChanged: (f) => setState(() => _focus = f),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AnimatedContainer(
          duration: AppDuration.fast,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: active ? AppColors.bgSurfaceHi : AppColors.bgSurface,
            border: Border.all(
              color: active ? AppColors.lineStrong : AppColors.line,
            ),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              Icon(
                file.isWatched
                    ? Icons.check_circle_rounded
                    : Icons.play_circle_outline_rounded,
                size: 20,
                color: file.isWatched ? AppColors.ok : AppColors.accent,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      file.episodeCode ?? file.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.mono(
                        size: AppType.sizeBody,
                        color: AppColors.fg,
                        weight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        file.formattedSize,
                        ?file.quality,
                        if (file.isWatched) 'Watched',
                        if (inProgress)
                          '${(file.watchProgress * 100).round()}% watched',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.ui(
                        size: AppType.sizeSmall,
                        color: AppColors.fg2,
                      ),
                    ),
                    if (inProgress) ...[
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: EditorialProgress(
                          value: file.watchProgress,
                          thin: true,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<_RowAction>(
                key: _menuKey,
                tooltip: 'More actions',
                color: kMediaHubPopupColor,
                shape: kMediaHubPopupShape,
                icon: const Icon(
                  Icons.more_vert_rounded,
                  size: 18,
                  color: AppColors.fg1,
                ),
                onSelected: _run,
                itemBuilder: (_) => [
                  if (file.isWatched)
                    PopupMenuItem(
                      value: _RowAction.notWatched,
                      child: mediaHubMenuLabel(
                        icon: Icons.remove_circle_outline_rounded,
                        label: 'Mark as not watched',
                      ),
                    )
                  else
                    PopupMenuItem(
                      value: _RowAction.watched,
                      child: mediaHubMenuLabel(
                        icon: Icons.check_circle_outline_rounded,
                        label: 'Mark as watched',
                      ),
                    ),
                  PopupMenuItem(
                    value: _RowAction.delete,
                    child: mediaHubMenuLabel(
                      icon: Icons.delete_outline_rounded,
                      label: 'Delete',
                      destructive: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
