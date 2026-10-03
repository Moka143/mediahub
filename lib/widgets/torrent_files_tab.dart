import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/local_media_file.dart' show videoExtensions;
import '../models/torrent_file.dart';
import '../providers/connection_provider.dart';
import '../providers/torrent_provider.dart';
import '../utils/constants.dart';
import '../utils/feedback_utils.dart';
import '../utils/formatters.dart';
import 'common/empty_state.dart';
import 'common/hub_pressable.dart';
import 'common/loading_state.dart';
import 'editorial/editorial.dart';
import 'transfers/transfer_menu.dart';

/// One entry in a file-priority menu, worded and drawn for the engine in
/// use — the one mapping from a priority to its label, icon and colour.
class FilePriorityChoice {
  const FilePriorityChoice(this.priority, this.label, this.icon, this.tone);

  final FilePriority priority;
  final String label;
  final IconData icon;
  final Color tone;
}

const _maximum = FilePriorityChoice(
  FilePriority.maximum,
  'Maximum',
  Icons.keyboard_double_arrow_up_rounded,
  AppColors.accent,
);
const _high = FilePriorityChoice(
  FilePriority.high,
  'High',
  Icons.arrow_upward_rounded,
  AppColors.warn,
);
const _normal = FilePriorityChoice(
  FilePriority.normal,
  'Normal',
  Icons.remove_rounded,
  AppColors.fg1,
);
const _download = FilePriorityChoice(
  FilePriority.normal,
  'Download',
  Icons.download_rounded,
  AppColors.fg1,
);
const _skip = FilePriorityChoice(
  FilePriority.doNotDownload,
  'Skip',
  Icons.block_rounded,
  AppColors.fg2,
);

/// The priorities the engine can honour, highest first.
///
/// qBittorrent ranks files (Maximum, High, Normal) as well as skipping them.
/// The built-in engine only includes or excludes — it reports every included
/// file as priority 1 — so High and Maximum were accepted there and snapped
/// back to Normal on the next refresh. [ranked] is the engine's
/// `EngineCapabilities.rankedFilePriorities`; without it the choice is Download
/// or Skip.
List<FilePriorityChoice> filePriorityChoices({required bool ranked}) =>
    ranked ? const [_maximum, _high, _normal, _skip] : const [_download, _skip];

/// How a file's current [priority] reads for this engine.
FilePriorityChoice filePriorityChoice(int priority, {required bool ranked}) {
  if (priority <= 0) return _skip;
  if (!ranked) return _download;
  return switch (FilePriority.fromValue(priority)) {
    FilePriority.maximum => _maximum,
    FilePriority.high => _high,
    FilePriority.normal || FilePriority.doNotDownload => _normal,
  };
}

/// Whether [file] is a video, by the same list the library scanner uses.
bool isVideoFile(TorrentFile file) => videoExtensions.contains(file.extension);

IconData _iconFor(TorrentFile file) {
  if (isVideoFile(file)) return Icons.movie_outlined;
  return switch (file.extension) {
    'mp3' ||
    'flac' ||
    'wav' ||
    'aac' ||
    'ogg' ||
    'm4a' => Icons.audiotrack_outlined,
    'jpg' ||
    'jpeg' ||
    'png' ||
    'gif' ||
    'bmp' ||
    'webp' => Icons.image_outlined,
    'srt' || 'sub' || 'ass' || 'ssa' || 'vtt' => Icons.subtitles_outlined,
    'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_outlined,
    'nfo' || 'txt' || 'md' || 'pdf' => Icons.description_outlined,
    'exe' || 'msi' || 'dmg' || 'app' => Icons.apps_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

/// The files inside a torrent: what each one is, how far along, and whether
/// (or how urgently) it downloads — singly, or for a ticked selection.
class TorrentFilesTab extends ConsumerStatefulWidget {
  const TorrentFilesTab({super.key, required this.torrentHash});

  final String torrentHash;

  @override
  ConsumerState<TorrentFilesTab> createState() => _TorrentFilesTabState();
}

class _TorrentFilesTabState extends ConsumerState<TorrentFilesTab> {
  final Set<int> _checked = {};
  bool _selecting = false;

  /// A priority change is in flight; the controls wait for it.
  bool _busy = false;

  void _toggle(int index) => setState(() {
    _selecting = true;
    if (!_checked.remove(index)) _checked.add(index);
  });

  void _check(Iterable<TorrentFile> files) => setState(() {
    _selecting = true;
    _checked.addAll(files.map((file) => file.index));
  });

  void _cancelSelection() => setState(() {
    _selecting = false;
    _checked.clear();
  });

  Future<void> _setPriority(
    List<TorrentFile> files,
    Iterable<int> indices,
    FilePriority priority, {
    required bool ranked,
  }) async {
    final targets = indices.toSet();
    if (targets.isEmpty || _busy) return;

    // The built-in engine downloads a *set* of files and refuses an empty
    // one; say why here instead of letting the request fail.
    if (!ranked &&
        priority == FilePriority.doNotDownload &&
        files.every((f) => f.priority <= 0 || targets.contains(f.index))) {
      AppSnackBar.showWarning(
        context,
        message: 'At least one file has to stay selected for download.',
      );
      return;
    }

    // Read before the await: leaving the tab mid-request must not turn the
    // follow-up into a crash.
    final engine = ref.read(torrentEngineProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final hash = widget.torrentHash;
    setState(() => _busy = true);

    var ok = false;
    try {
      ok = await engine.setFilePriority(
        hash,
        targets.toList()..sort(),
        priority.value,
      );
    } catch (_) {
      ok = false;
    }

    if (!ok) {
      AppSnackBar.showOn(
        messenger,
        message: ranked
            ? "Couldn't change the file priority. Try again in a moment."
            : "Couldn't change which files download. Try again in a moment.",
        kind: AppSnackBarKind.error,
      );
    }
    if (!mounted) return;
    ref.invalidate(torrentFilesProvider(hash));
    setState(() {
      _busy = false;
      if (ok) {
        _checked.clear();
        _selecting = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final filesAsync = ref.watch(torrentFilesProvider(widget.torrentHash));
    final ranked = ref.watch(
      torrentEngineProvider.select(
        (engine) => engine.capabilities.rankedFilePriorities,
      ),
    );

    return filesAsync.when(
      data: (files) => files.isEmpty
          ? EmptyState.noData(
              icon: Icons.folder_off_outlined,
              title: 'No files yet',
              subtitle:
                  'The file list appears once the engine has the torrent’s '
                  'details.',
            )
          : _content(files, ranked),
      loading: () => const LoadingIndicator(message: 'Loading files…'),
      error: (_, _) => EmptyState.error(
        title: "Couldn't load the files",
        message: "The torrent engine didn't answer.",
        onRetry: () => ref.invalidate(torrentFilesProvider(widget.torrentHash)),
      ),
    );
  }

  Widget _content(List<TorrentFile> files, bool ranked) {
    final choices = filePriorityChoices(ranked: ranked);
    void apply(Iterable<int> indices, FilePriority priority) =>
        unawaited(_setPriority(files, indices, priority, ranked: ranked));

    return Column(
      children: [
        if (_selecting)
          _SelectionToolbar(
            checkedCount: _checked.length,
            totalCount: files.length,
            ranked: ranked,
            busy: _busy,
            choices: choices,
            onSelectAll: () => _check(files),
            onChoose: (priority) => apply(_checked, priority),
            onCancel: _cancelSelection,
          )
        else
          _QuickActions(
            files: files,
            ranked: ranked,
            busy: _busy,
            onSelectFiles: () => setState(() => _selecting = true),
            onSelectVideos: () => _check(files.where(isVideoFile)),
            onAll: (priority) =>
                apply(files.map((file) => file.index), priority),
          ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView.builder(
            itemCount: files.length,
            itemBuilder: (context, index) {
              final file = files[index];
              return _FileRow(
                file: file,
                current: filePriorityChoice(file.priority, ranked: ranked),
                choices: choices,
                selecting: _selecting,
                checked: _checked.contains(file.index),
                busy: _busy,
                onToggle: () => _toggle(file.index),
                onChoose: (priority) => apply([file.index], priority),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Shortcuts above the list when nothing is ticked.
class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.files,
    required this.ranked,
    required this.busy,
    required this.onSelectFiles,
    required this.onSelectVideos,
    required this.onAll,
  });

  final List<TorrentFile> files;
  final bool ranked;
  final bool busy;
  final VoidCallback onSelectFiles;
  final VoidCallback onSelectVideos;
  final ValueChanged<FilePriority> onAll;

  @override
  Widget build(BuildContext context) {
    final videos = files.where(isVideoFile).length;
    final anySkipped = files.any((file) => file.priority <= 0);
    final anyBelowMaximum = files.any(
      (file) => file.priority != FilePriority.maximum.value,
    );

    return _ToolbarFrame(
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          EditorialButton(
            label: 'Select files',
            icon: Icons.check_box_outlined,
            onPressed: onSelectFiles,
          ),
          if (videos > 0)
            EditorialButton(
              label: 'Select videos ($videos)',
              icon: Icons.video_file_outlined,
              onPressed: onSelectVideos,
            ),
          if (anySkipped)
            EditorialButton(
              label: 'Download all',
              icon: Icons.download_rounded,
              onPressed: busy ? null : () => onAll(FilePriority.normal),
            ),
          if (ranked && anyBelowMaximum)
            EditorialButton(
              label: 'Maximum for all',
              icon: Icons.keyboard_double_arrow_up_rounded,
              onPressed: busy ? null : () => onAll(FilePriority.maximum),
            ),
        ],
      ),
    );
  }
}

/// Count, select-all and the priority menu while files are ticked.
class _SelectionToolbar extends StatelessWidget {
  const _SelectionToolbar({
    required this.checkedCount,
    required this.totalCount,
    required this.ranked,
    required this.busy,
    required this.choices,
    required this.onSelectAll,
    required this.onChoose,
    required this.onCancel,
  });

  final int checkedCount;
  final int totalCount;
  final bool ranked;
  final bool busy;
  final List<FilePriorityChoice> choices;
  final VoidCallback onSelectAll;
  final ValueChanged<FilePriority> onChoose;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final canChoose = checkedCount > 0 && !busy;
    return _ToolbarFrame(
      highlighted: true,
      child: Row(
        children: [
          Text(
            '$checkedCount selected',
            style: AppType.ui(
              size: AppType.sizeBody,
              color: AppColors.fg,
              weight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (checkedCount < totalCount)
            EditorialButton(
              label: 'Select all',
              kind: EditorialButtonKind.ghost,
              onPressed: onSelectAll,
            ),
          const Spacer(),
          // A real, enabled button that opens the menu. It used to be a
          // button with `onPressed: null` inside a PopupMenuButton, which
          // worked but was drawn disabled.
          Builder(
            builder: (anchor) => EditorialButton(
              label: ranked ? 'Set priority' : 'Download or skip',
              icon: Icons.low_priority_rounded,
              kind: EditorialButtonKind.accent,
              onPressed: canChoose
                  ? () => unawaited(_choose(anchor, null))
                  : null,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          IconButton(
            tooltip: 'Cancel selection',
            color: AppColors.fg1,
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Future<void> _choose(BuildContext anchor, FilePriority? current) async {
    final picked = await _showPriorityMenu(anchor, choices, current);
    if (picked != null) onChoose(picked);
  }
}

class _ToolbarFrame extends StatelessWidget {
  const _ToolbarFrame({required this.child, this.highlighted = false});

  final Widget child;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: highlighted ? AppColors.bgSurface : AppColors.bgPage,
        border: const Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: child,
    );
  }
}

/// Draws the priority badge inert while a change is in flight.
class _Dimmed extends StatelessWidget {
  const _Dimmed({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Opacity(opacity: enabled ? 1 : 0.45, child: child);
}

Future<FilePriority?> _showPriorityMenu(
  BuildContext anchor,
  List<FilePriorityChoice> choices,
  FilePriority? current,
) {
  return showTransfersMenu<FilePriority>(
    context: anchor,
    items: [
      for (final choice in choices)
        PopupMenuItem(
          value: choice.priority,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(choice.icon, size: AppIconSize.xs, color: choice.tone),
              const SizedBox(width: AppSpacing.sm),
              Text(choice.label, style: AppType.caption(color: AppColors.fg1)),
              if (choice.priority == current) ...[
                const SizedBox(width: AppSpacing.sm),
                const Icon(
                  Icons.check_rounded,
                  size: AppIconSize.xs,
                  color: AppColors.fg1,
                ),
              ],
            ],
          ),
        ),
    ],
  );
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.current,
    required this.choices,
    required this.selecting,
    required this.checked,
    required this.busy,
    required this.onToggle,
    required this.onChoose,
  });

  final TorrentFile file;
  final FilePriorityChoice current;
  final List<FilePriorityChoice> choices;
  final bool selecting;
  final bool checked;
  final bool busy;
  final VoidCallback onToggle;
  final ValueChanged<FilePriority> onChoose;

  @override
  Widget build(BuildContext context) {
    final skipped = file.priority <= 0;
    final Color tone;
    if (skipped) {
      tone = AppColors.fg3;
    } else if (file.progress >= 1) {
      tone = AppColors.ok;
    } else {
      tone = AppColors.accent;
    }

    return HubPressable(
      onTap: onToggle,
      selected: selecting ? checked : null,
      borderRadius: BorderRadius.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: checked ? AppColors.accentSoft : null,
          border: const Border(bottom: BorderSide(color: AppColors.line)),
        ),
        child: Row(
          children: [
            Icon(
              selecting
                  ? (checked
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded)
                  : _iconFor(file),
              size: AppIconSize.md,
              color: selecting && checked ? AppColors.accent : AppColors.fg2,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.ui(
                      size: AppType.sizeBody,
                      color: skipped ? AppColors.fg2 : AppColors.fg,
                      weight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Text(
                        Formatters.formatBytes(file.size),
                        style: AppType.mono(
                          size: AppType.sizeSmall,
                          color: AppColors.fg2,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: EditorialProgress(
                          value: file.progress,
                          color: tone,
                          height: 3,
                          glow: false,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      SizedBox(
                        width: 40,
                        child: Text(
                          Formatters.formatProgress(file.progress, decimals: 0),
                          textAlign: TextAlign.right,
                          style: AppType.mono(
                            size: AppType.sizeSmall,
                            color: AppColors.fg2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (!selecting) ...[
              const SizedBox(width: AppSpacing.md),
              _PriorityButton(
                current: current,
                choices: choices,
                enabled: !busy,
                onChoose: onChoose,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The file's priority as a small badge that opens the priority menu.
class _PriorityButton extends StatelessWidget {
  const _PriorityButton({
    required this.current,
    required this.choices,
    required this.enabled,
    required this.onChoose,
  });

  final FilePriorityChoice current;
  final List<FilePriorityChoice> choices;
  final bool enabled;
  final ValueChanged<FilePriority> onChoose;

  @override
  Widget build(BuildContext context) {
    final tone = current.tone;
    return Builder(
      builder: (anchor) => HubPressable(
        onTap: enabled ? () => unawaited(_choose(anchor)) : null,
        tooltip: 'Change',
        semanticLabel: '${current.label}. Change',
        excludeChildSemantics: true,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: _Dimmed(
          enabled: enabled,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: tone.withAlpha(AppOpacity.subtle),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: tone.withAlpha(AppOpacity.semi)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(current.icon, size: AppIconSize.xs, color: tone),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  current.label,
                  style: AppType.ui(
                    size: AppType.sizeSmall,
                    color: tone,
                    weight: FontWeight.w600,
                  ),
                ),
                Icon(
                  Icons.arrow_drop_down_rounded,
                  size: AppIconSize.sm,
                  color: tone,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _choose(BuildContext anchor) async {
    final picked = await _showPriorityMenu(anchor, choices, current.priority);
    if (picked != null && picked != current.priority) onChoose(picked);
  }
}
