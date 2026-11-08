// AnymeX+: the "For you" ranking, shared by anime and Movies & TV. Pure
// functions (no network, no app state), so they're unit-tested.
//
// How a pick is scored:
//   • every seed (something you loved, liked or watched) that recommends it
//     adds its weight × how strongly it was recommended;
//   • plus how well its genres match your taste (from your whole list);
//   • plus a little for being well rated overall;
//   • minus genres you've marked "Not interested" on before.
// Seeds can weigh less than zero (dropped, disliked): what they recommend
// counts against a pick, and a pick only they recommend never shows.
// Each pick keeps the seed that counted most, for "Because you loved X".

import 'dart:math' as math;

/// Something you watched that picks are found from.
class ForYouSeed {
  final String key;
  final String title;
  final double weight;
  final bool loved;
  final bool liked;

  const ForYouSeed({
    required this.key,
    required this.title,
    required this.weight,
    this.loved = false,
    this.liked = false,
  });

  /// The line under a pick this seed brought in.
  String get reason => key == aiPicksSeed
      ? 'Suggested by AI Picks'
      : loved
          ? 'Because you loved $title'
          : liked
              ? 'Because you liked $title'
              : 'Because you watched $title';

  static const aiPicksSeed = 'ai-picks';
}

/// A title that one or more seeds recommend.
class ForYouCandidate {
  final String key;
  final String id;
  final String kind; // anime | movie | series
  final String title;
  final String poster;
  final List<String> genres;

  /// Overall rating, -1 (poor) … 1 (great).
  final double quality;
  final String rating; // shown on the card ("8.4")

  /// seed key → how strongly that seed recommends it (about 0 … 1.5).
  final Map<String, double> votes = {};

  ForYouCandidate({
    required this.key,
    required this.id,
    required this.kind,
    required this.title,
    required this.poster,
    this.genres = const [],
    this.quality = 0,
    this.rating = '',
  });
}

/// A finished pick, ready to show (and to save on the device).
class ForYouPick {
  final String key;
  final String id;
  final String kind;
  final String title;
  final String poster;
  final String reason;
  final String rating;
  final List<String> genres;
  final double score;

  const ForYouPick({
    required this.key,
    required this.id,
    required this.kind,
    required this.title,
    required this.poster,
    required this.reason,
    this.rating = '',
    this.genres = const [],
    this.score = 0,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'id': id,
        'kind': kind,
        'title': title,
        'poster': poster,
        'reason': reason,
        'rating': rating,
        'genres': genres,
        'score': score,
      };

  factory ForYouPick.fromJson(Map<String, dynamic> j) => ForYouPick(
        key: '${j['key'] ?? ''}',
        id: '${j['id'] ?? ''}',
        kind: '${j['kind'] ?? ''}',
        title: '${j['title'] ?? ''}',
        poster: '${j['poster'] ?? ''}',
        reason: '${j['reason'] ?? ''}',
        rating: '${j['rating'] ?? ''}',
        genres: (j['genres'] is List ? j['genres'] as List : const [])
            .map((e) => '$e')
            .toList(),
        score: (j['score'] as num?)?.toDouble() ?? 0,
      );
}

/// How strongly one seed recommends something, from its place in that
/// seed's list (0 = first) and, for AniList, the recommendation's votes.
double recommendationStrength({int rank = 0, int? votes}) {
  final byRank = 1 / (1 + rank * 0.15);
  if (votes == null) return byRank;
  final byVotes = math.log(1 + math.max(votes, 1)) / math.log(51);
  return math.min(1.5, (byRank + byVotes) / 2 + 0.25);
}

/// Your taste per genre, -1 … 1, from (genres, weight) of what you watched.
/// Higher-weighted titles count more; negative weights (dropped) count
/// against their genres.
Map<String, double> genreProfile(Iterable<(List<String>, double)> entries) {
  final sums = <String, double>{};
  for (final (genres, weight) in entries) {
    for (final g in genres) {
      sums[g] = (sums[g] ?? 0) + weight;
    }
  }
  if (sums.isEmpty) return const {};
  final top = sums.values.map((v) => v.abs()).reduce(math.max);
  if (top == 0) return const {};
  return sums.map((g, v) => MapEntry(g, v / top));
}

/// Picks from [candidates], best first. [exclude] holds keys and ids that
/// must not show (on your list, in your library, hidden). [lessGenres]
/// counts how often you hid something with that genre.
List<ForYouPick> rankPicks({
  required List<ForYouSeed> seeds,
  required List<ForYouCandidate> candidates,
  Map<String, double> genreWeights = const {},
  Map<String, int> lessGenres = const {},
  Set<String> exclude = const {},
  int max = 30,
  int maxPerSeed = 4,
}) {
  final seedsByKey = {for (final s in seeds) s.key: s};
  final scored = <(double, ForYouCandidate, ForYouSeed)>[];
  for (final c in candidates) {
    if (exclude.contains(c.key) || exclude.contains(c.id)) continue;
    if (c.votes.isEmpty) continue;
    var fromSeeds = 0.0;
    ForYouSeed? best;
    var bestPart = 0.0; // only a seed that adds can be the reason
    c.votes.forEach((seedKey, strength) {
      final seed = seedsByKey[seedKey];
      if (seed == null) return;
      final part = seed.weight * strength;
      fromSeeds += part;
      if (part > bestPart) {
        bestPart = part;
        best = seed;
      }
    });
    if (best == null) continue;
    var affinity = 0.0;
    if (c.genres.isNotEmpty) {
      affinity = c.genres
              .map((g) => genreWeights[g] ?? 0)
              .fold<double>(0, (a, b) => a + b) /
          c.genres.length;
    }
    var less = 0.0;
    for (final g in c.genres) {
      less += 0.12 * (lessGenres[g] ?? 0);
    }
    final score = fromSeeds +
        0.6 * affinity +
        0.25 * c.quality.clamp(-1.0, 1.0) -
        math.min(less, 0.6);
    scored.add((score, c, best!));
  }
  scored.sort((a, b) => b.$1.compareTo(a.$1));

  final perSeed = <String, int>{};
  final out = <ForYouPick>[];
  for (final (score, c, seed) in scored) {
    final n = perSeed[seed.key] ?? 0;
    if (n >= maxPerSeed) continue;
    perSeed[seed.key] = n + 1;
    out.add(ForYouPick(
      key: c.key,
      id: c.id,
      kind: c.kind,
      title: c.title,
      poster: c.poster,
      reason: seed.reason,
      rating: c.rating,
      genres: c.genres,
      score: score,
    ));
    if (out.length >= max) break;
  }
  return out;
}
