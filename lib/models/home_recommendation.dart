import 'movie.dart';
import 'show.dart';

/// A TMDB title recommended because the user favorited (or is watching)
/// another title. Show and movie share one row on Home.
class HomeRecTile {
  const HomeRecTile.show(Show this.show) : movie = null;
  const HomeRecTile.movie(Movie this.movie) : show = null;

  final Show? show;
  final Movie? movie;

  bool get isShow => show != null;

  // Branch on which one this is. `show?.year ?? movie!.year` read a show
  // with no first-air date (or no poster) as a movie and crashed on the
  // null `movie!`.
  int get id => isShow ? show!.id : movie!.id;
  String get title => isShow ? show!.name : movie!.title;
  String? get year => isShow ? show!.year : movie!.year;
  String? get posterUrl => isShow ? show!.posterUrl : movie!.posterUrl;
}

class HomeRecommendationFeed {
  const HomeRecommendationFeed({
    required this.becauseTitle,
    required this.items,
  });

  /// Seed title used in the section header — "Because you liked Lioness".
  final String becauseTitle;
  final List<HomeRecTile> items;
}
