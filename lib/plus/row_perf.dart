// AnymeX+: smoother scrolling for card rows.
// - AnymeX's card animation plays once, when a row first shows, instead of
//   every time a row (or card) comes back on screen.
// - Rows load small posters; the details page keeps the large one.

class PlusRowPerf {
  PlusRowPerf._();

  /// How long after a row first shows its cards still animate in.
  static const animateWindow = Duration(milliseconds: 1200);

  static final Map<String, DateTime> _firstShown = {};

  /// For tests.
  static DateTime Function() now = DateTime.now;

  /// True while row [rowKey] is showing for the first time (its first
  /// [animateWindow]); false when it comes back later.
  static bool shouldAnimate(String rowKey) {
    final t = now();
    final first = _firstShown.putIfAbsent(rowKey, () => t);
    return t.difference(first) < animateWindow;
  }

  /// For tests.
  static void reset() => _firstShown.clear();

  /// A smaller copy of a poster for cards in rows, where the host offers
  /// one (TMDB, Metahub). Other URLs are returned unchanged.
  static String smallPoster(String url) {
    if (url.isEmpty) return url;
    final tmdb = RegExp(r'(image\.tmdb\.org/t/p/)(original|w500|w780|w1280)/');
    if (tmdb.hasMatch(url)) {
      return url.replaceFirstMapped(tmdb, (m) => '${m[1]}w342/');
    }
    final metahub = RegExp(r'(images\.metahub\.space/poster/)large/');
    if (metahub.hasMatch(url)) {
      return url.replaceFirstMapped(metahub, (m) => '${m[1]}medium/');
    }
    return url;
  }
}
