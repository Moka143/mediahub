import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/auto_download_event.dart';
import '../../providers/auto_download_events_provider.dart';
import '../../utils/formatters.dart';

/// What auto-download did recently, newest first.
///
/// The log has always been written — downloads started, episodes not found
/// yet, shows with nothing left to fetch — but nothing showed it since its
/// card was removed, so auto-download was a black box: when an episode did
/// not appear there was no way to find out why.
class AutoDownloadActivity extends ConsumerStatefulWidget {
  const AutoDownloadActivity({super.key});

  /// How many entries show before "Show all".
  static const int collapsedCount = 5;

  @override
  ConsumerState<AutoDownloadActivity> createState() =>
      _AutoDownloadActivityState();
}

class _AutoDownloadActivityState extends ConsumerState<AutoDownloadActivity> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final events = ref.watch(autoDownloadEventsProvider);

    if (events.isEmpty) {
      return Row(
        children: [
          const Icon(
            Icons.history_rounded,
            size: AppIconSize.md,
            color: AppColors.fg2,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'Nothing yet. When auto-download looks for, starts or finishes '
              'an episode of a favorite show, it shows up here.',
              style: AppType.caption(),
            ),
          ),
        ],
      );
    }

    final shown = _expanded
        ? events
        : events.take(AutoDownloadActivity.collapsedCount).toList();
    final hidden = events.length - shown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const Divider(height: AppSpacing.lg),
          _EventRow(event: shown[i]),
        ],
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          children: [
            if (hidden > 0 || _expanded)
              TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? 'Show fewer' : 'Show all (${events.length})',
                ),
              ),
            TextButton(
              onPressed: () => unawaited(
                ref.read(autoDownloadEventsProvider.notifier).clearEvents(),
              ),
              child: const Text('Clear'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Icon, colour and plain-language headline for each kind of entry. A map
/// rather than a switch, so a kind added to the log later shows with the
/// fallback instead of breaking the build.
const Map<AutoDownloadEventType, (IconData, Color, String)> _kinds = {
  AutoDownloadEventType.downloadStarted: (
    Icons.download_rounded,
    AppColors.accent,
    'Download started',
  ),
  AutoDownloadEventType.downloadCompleted: (
    Icons.check_circle_rounded,
    AppColors.ok,
    'Downloaded',
  ),
  AutoDownloadEventType.downloadFailed: (
    Icons.error_outline_rounded,
    AppColors.err,
    'Download failed',
  ),
  AutoDownloadEventType.torrentNotFound: (
    Icons.search_off_rounded,
    AppColors.warn,
    'No source found yet',
  ),
  AutoDownloadEventType.episodeQueued: (
    Icons.schedule_rounded,
    AppColors.fg1,
    'Waiting for it to air',
  ),
  AutoDownloadEventType.checked: (
    Icons.done_all_rounded,
    AppColors.fg2,
    'Nothing new to download',
  ),
};

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final AutoDownloadEvent event;

  @override
  Widget build(BuildContext context) {
    final (icon, tone, headline) =
        _kinds[event.type] ??
        (Icons.info_outline_rounded, AppColors.fg2, 'Update');
    final quality = event.quality;
    final when = Formatters.formatRelativeTime(
      event.timestamp.millisecondsSinceEpoch ~/ 1000,
    );

    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xxs),
            child: Icon(icon, size: AppIconSize.sm, color: tone),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${event.showName} ${event.episodeCode}',
                  style: AppType.bodyStrong(),
                ),
                Text(
                  [
                    headline,
                    if (quality != null && quality.isNotEmpty) quality,
                  ].join(' · '),
                  style: AppType.caption(color: AppColors.fg1),
                ),
                if (event.message != null && event.message!.isNotEmpty)
                  Text(event.message!, style: AppType.caption()),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Text(when, style: AppType.caption()),
        ],
      ),
    );
  }
}
