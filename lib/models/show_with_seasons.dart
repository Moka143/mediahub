import 'local_media_file.dart';

/// A show's library files, grouped by season.
class ShowWithSeasons {
  final String showName;
  final Map<int, List<LocalMediaFile>> seasons;
  final int totalEpisodes;

  ShowWithSeasons({
    required this.showName,
    required this.seasons,
    required this.totalEpisodes,
  });
}
