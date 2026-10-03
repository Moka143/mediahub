import 'package:flutter/material.dart';

/// The Library's filter chips.
enum LibrarySection { all, continueWatching, recent, movies, shows }

/// Everything a section is called and shows when empty, in one place.
///
/// Each section's label, icon and empty copy used to be written out three
/// times — in the chip row, the focused view and the all-sections view —
/// and the copies had drifted ("Continue" on the chip, "Continue Watching"
/// on the header).
extension LibrarySectionInfo on LibrarySection {
  String get label => switch (this) {
    LibrarySection.all => 'All',
    LibrarySection.continueWatching => 'Continue watching',
    LibrarySection.recent => 'Recently downloaded',
    LibrarySection.movies => 'Movies',
    LibrarySection.shows => 'Shows',
  };

  /// Shorter label for the chip row.
  String get chipLabel => switch (this) {
    LibrarySection.all => 'All',
    LibrarySection.continueWatching => 'Continue',
    LibrarySection.recent => 'Recent',
    LibrarySection.movies => 'Movies',
    LibrarySection.shows => 'Shows',
  };

  IconData get icon => switch (this) {
    LibrarySection.all => Icons.dashboard_rounded,
    LibrarySection.continueWatching => Icons.play_circle_outline_rounded,
    LibrarySection.recent => Icons.download_done_rounded,
    LibrarySection.movies => Icons.movie_rounded,
    LibrarySection.shows => Icons.video_library_rounded,
  };

  String emptyTitle({required bool hasQuery}) => switch (this) {
    LibrarySection.all =>
      hasQuery ? 'No matches in your library' : 'Nothing in your library yet',
    LibrarySection.continueWatching =>
      hasQuery ? 'No matches in Continue Watching' : 'Nothing to continue yet',
    LibrarySection.recent =>
      hasQuery ? 'No recent downloads match' : 'No recent downloads',
    LibrarySection.movies =>
      hasQuery ? 'No movies match' : 'No movies in your library',
    LibrarySection.shows =>
      hasQuery ? 'No shows match' : 'No shows in your library',
  };

  String emptySubtitle({required bool hasQuery}) {
    if (hasQuery) return 'Try a different name.';
    return switch (this) {
      LibrarySection.all => 'Download something to get started.',
      LibrarySection.continueWatching =>
        'Start watching something and it will wait for you here.',
      LibrarySection.recent => 'New downloads appear here for a week.',
      LibrarySection.movies =>
        'Movies appear here when their downloads finish.',
      LibrarySection.shows =>
        'Episodes appear here when their downloads finish.',
    };
  }
}
