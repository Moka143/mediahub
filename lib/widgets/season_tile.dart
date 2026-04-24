import 'package:flutter/material.dart';
import '../design/app_theme.dart';
import '../design/app_tokens.dart';
import '../models/season.dart';
import '../models/episode.dart';
import '../widgets/common/loading_state.dart';
import 'episode_list_item.dart';

/// Expandable tile for a TV show season
class SeasonTile extends StatelessWidget {
  final Season season;
  final List<Episode> episodes;
  final bool isExpanded;
  final bool isLoading;
  final String? showName;
  final bool isStreaming;
  final ValueChanged<bool>? onExpansionChanged;
  final Function(Episode)? onEpisodeTap;
  final Function(Episode)? onDownloadTap;
  final Map<String, bool>? torrentAvailability;

  const SeasonTile({
    super.key,
    required this.season,
    this.episodes = const [],
    this.isExpanded = false,
    this.isLoading = false,
    this.showName,
    this.isStreaming = false,
    this.onExpansionChanged,
    this.onEpisodeTap,
    this.onDownloadTap,
    this.torrentAvailability,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = theme.extension<AppColorsExtension>()!;

    return Card(
      margin: EdgeInsets.symmetric(
        horizontal: AppSpacing.screenPadding,
        vertical: AppSpacing.xs,
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey('season_${season.seasonNumber}'),
        initiallyExpanded: isExpanded,
        onExpansionChanged: onExpansionChanged,
        leading: _buildSeasonPoster(context),
        title: Text(
          season.name,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                Icon(
                  Icons.video_library,
                  size: AppIconSize.xs,
                  color: appColors.mutedText,
                ),
                SizedBox(width: AppSpacing.xs),
                Text(
                  '${season.episodeCount} episodes',
                  style: TextStyle(fontSize: 12, color: appColors.mutedText),
                ),
                if (season.year != null) ...[
                  SizedBox(width: AppSpacing.md),
                  Icon(
                    Icons.calendar_today,
                    size: AppIconSize.xs,
                    color: appColors.mutedText,
                  ),
                  SizedBox(width: AppSpacing.xs),
                  Text(
                    season.year!,
                    style: TextStyle(fontSize: 12, color: appColors.mutedText),
                  ),
                ],
              ],
            ),
          ],
        ),
        children: [
          if (isLoading)
            Padding(
              padding: EdgeInsets.all(AppSpacing.xl),
              child: const Center(child: LoadingIndicator()),
            )
          else if (episodes.isEmpty)
            Padding(
              padding: EdgeInsets.all(AppSpacing.xl),
              child: Text(
                'No episodes available',
                style: TextStyle(color: appColors.mutedText),
              ),
            )
          else
            ListView.separated(
              key: PageStorageKey('season_${season.seasonNumber}_episodes'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: episodes.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: theme.dividerColor),
              itemBuilder: (context, index) {
                final episode = episodes[index];
                final episodeKey =
                    'S${episode.seasonNumber.toString().padLeft(2, '0')}E${episode.episodeNumber.toString().padLeft(2, '0')}';
                final hasTorrents = torrentAvailability?[episodeKey] ?? false;

                return EpisodeListItem(
                  episode: episode,
                  showName: showName,
                  hasTorrents: hasTorrents,
                  isStreaming: isStreaming,
                  onTap: () => onEpisodeTap?.call(episode),
                  onDownloadTap: () => onDownloadTap?.call(episode),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildSeasonPoster(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: SizedBox(
        width: 40,
        height: 60,
        child: season.posterUrl != null
            ? Image.network(
                season.posterUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildPlaceholder(theme),
              )
            : _buildPlaceholder(theme),
      ),
    );
  }

  Widget _buildPlaceholder(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Text(
          season.isSpecials ? 'SP' : 'S${season.seasonNumber}',
          style: TextStyle(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

/// Simple list of seasons without expansion
class SeasonList extends StatelessWidget {
  final List<Season> seasons;
  final int? selectedSeasonNumber;
  final Function(Season)? onSeasonTap;

  const SeasonList({
    super.key,
    required this.seasons,
    this.selectedSeasonNumber,
    this.onSeasonTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      height: 50,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
        itemCount: seasons.length,
        itemBuilder: (context, index) {
          final season = seasons[index];
          final isSelected = season.seasonNumber == selectedSeasonNumber;

          return Padding(
            padding: EdgeInsets.only(
              right: index < seasons.length - 1 ? AppSpacing.sm : 0,
            ),
            child: FilterChip(
              selected: isSelected,
              onSelected: (_) => onSeasonTap?.call(season),
              label: Text(
                season.isSpecials
                    ? 'Specials'
                    : 'Season ${season.seasonNumber}',
              ),
              selectedColor: theme.colorScheme.primary.withValues(alpha: 0.2),
              checkmarkColor: theme.colorScheme.primary,
            ),
          );
        },
      ),
    );
  }
}

/// Dropdown for season selection
class SeasonDropdown extends StatelessWidget {
  final List<Season> seasons;
  final Season? selectedSeason;
  final ValueChanged<Season?>? onChanged;

  const SeasonDropdown({
    super.key,
    required this.seasons,
    this.selectedSeason,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButton<Season>(
      value: selectedSeason,
      hint: const Text('Select Season'),
      isExpanded: true,
      items: seasons.map((season) {
        return DropdownMenuItem<Season>(
          value: season,
          child: Text(
            season.isSpecials
                ? 'Specials (${season.episodeCount} eps)'
                : '${season.name} (${season.episodeCount} eps)',
          ),
        );
      }).toList(),
      onChanged: onChanged,
    );
  }
}
