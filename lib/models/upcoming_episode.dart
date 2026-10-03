import '../utils/formatters.dart';
import 'show.dart';

/// A favorite show's next episode and when it airs.
class UpcomingEpisode {
  final Show show;
  final String airDate;
  UpcomingEpisode({required this.show, required this.airDate});

  DateTime? get airDateTime => DateTime.tryParse(airDate);

  /// Calendar days from today to the air date: tomorrow is 1 at any hour,
  /// across a DST change too. `difference().inDays` on timestamps called an
  /// episode airing tomorrow "Today" every evening and was a day short over
  /// long gaps ("In 277 days" for one 278 days away). -1 when the date is
  /// unreadable.
  int get daysUntilAir => daysUntilAirFrom(DateTime.now());

  /// [daysUntilAir] as of [now].
  int daysUntilAirFrom(DateTime now) {
    final date = airDateTime;
    if (date == null) return -1;
    return Formatters.calendarDaysBetween(now, date);
  }

  String get daysUntilAirFormatted {
    final days = daysUntilAir;
    if (days < 0) return 'Aired';
    if (days == 0) return 'Today';
    if (days == 1) return 'Tomorrow';
    return 'In $days days';
  }
}
