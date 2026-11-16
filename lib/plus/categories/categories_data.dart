// AnymeX+ / Yumori Categories: lists, genres and streaming services that
// mix AniList anime with the built-in Movies & TV lists, in one grid.
// (Same data the TV app's Categories tab uses.)

import 'dart:async';
import 'dart:convert';

import 'package:anymex/plus/for_you/movies_for_you.dart';
import 'package:anymex/plus/stremio/builtin_rows.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/utils/logger.dart';
import 'package:http/http.dart' as http;

/// One card in a category: anime (AniList) or a movie / series (Stremio).
class CatItem {
  final String id; // AniList id, or the Stremio / IMDb id
  final String kind; // anime | movie | series
  final String title;
  final String poster;
  final String rating;
  final String year;
  final String backdrop; // wide art, for the Home hero
  final String overview;
  final String genre;

  const CatItem({
    required this.id,
    required this.kind,
    required this.title,
    this.poster = '',
    this.rating = '',
    this.year = '',
    this.backdrop = '',
    this.overview = '',
    this.genre = '',
  });

  bool get isAnime => kind == 'anime';
  String get key => '$kind:$id';
  String get kindLabel =>
      switch (kind) { 'anime' => 'ANIME', 'movie' => 'MOVIE', _ => 'SERIES' };

  factory CatItem.fromStremio(StremioMetaPreview p) => CatItem(
        id: p.id,
        kind: p.type == 'movie' ? 'movie' : 'series',
        title: p.name,
        poster: p.poster ?? '',
        rating: p.imdbRating ?? '',
        year: p.releaseInfo ?? '',
        backdrop: p.background ?? '',
        overview: p.description ?? '',
        genre: p.genres.isEmpty ? '' : p.genres.first,
      );

  factory CatItem.fromAnilistJson(Map m) {
    final t = (m['title'] as Map?) ?? const {};
    final cover = (m['coverImage'] as Map?) ?? const {};
    final score = (m['averageScore'] as num?)?.toInt();
    return CatItem(
      id: '${m['id']}',
      kind: 'anime',
      title: '${t['english'] ?? t['romaji'] ?? t['userPreferred'] ?? '?'}',
      poster: '${cover['extraLarge'] ?? cover['large'] ?? ''}',
      rating: score == null || score == 0 ? '' : (score / 10).toStringAsFixed(1),
      year: m['seasonYear'] == null ? '' : '${m['seasonYear']}',
      backdrop: '${m['bannerImage'] ?? ''}',
      overview: '${m['description'] ?? ''}'
          .replaceAll(RegExp(r'<[^>]*>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim(),
      genre: (m['genres'] is List && (m['genres'] as List).isNotEmpty)
          ? '${(m['genres'] as List).first}'
          : '',
    );
  }
}

/// AniList lists (one query, any filters), cached for a while.
class CatAnilist {
  static final _cache = <String, (DateTime, List<CatItem>)>{};

  static const _fields = 'id idMal title { english romaji userPreferred } coverImage { extraLarge large } bannerImage '
      'description(asHtml: false) averageScore seasonYear format episodes genres';

  static const _query = '''
query (\$genres: [String], \$sort: [MediaSort], \$status: MediaStatus, \$season: MediaSeason, \$seasonYear: Int, \$search: String, \$page: Int) {
  Page(page: \$page, perPage: 40) {
    media(type: ANIME, genre_in: \$genres, sort: \$sort, status: \$status, season: \$season, seasonYear: \$seasonYear, search: \$search, isAdult: false) {
      $_fields
    }
  }
}''';

  static Future<List<CatItem>> list(Map<String, dynamic> vars) async {
    final key = jsonEncode(vars);
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(minutes: 30)) return hit.$2;
    try {
      final resp = await http
          .post(Uri.parse('https://graphql.anilist.co'),
              headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
              body: jsonEncode({'query': _query, 'variables': vars}))
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final media = (jsonDecode(resp.body)['data']?['Page']?['media'] as List?) ?? const [];
      final out = [for (final m in media) if (m is Map) CatItem.fromAnilistJson(m)];
      _cache[key] = (DateTime.now(), out);
      return out;
    } catch (e) {
      Logger.i('Categories: AniList list failed: $e');
      return hit?.$2 ?? const [];
    }
  }

  /// This AniList season (WINTER, SPRING, SUMMER, FALL) and year.
  static (String, int) currentSeason() {
    final now = DateTime.now();
    const seasons = ['WINTER', 'WINTER', 'SPRING', 'SPRING', 'SPRING', 'SUMMER', 'SUMMER', 'SUMMER', 'FALL', 'FALL', 'FALL', 'WINTER'];
    final s = seasons[now.month - 1];
    return (s, now.month == 12 ? now.year + 1 : now.year);
  }
}

/// A category: AniList filters and built-in
/// Movies & TV lists, merged into one grid.
class CatCategory {
  final String name;
  final String group; // lists | genres | services
  final Map<String, dynamic>? anilist;
  final List<String> rows; // PlusBuiltinRow ids

  const CatCategory(this.name, this.group, {this.anilist, this.rows = const []});

  String get sub {
    final anime = anilist != null;
    final movies = rows.isNotEmpty && PlusBuiltinRows.enabled;
    if (anime && movies) return 'Anime + Movies & TV';
    return anime ? 'Anime' : 'Movies & TV';
  }

  static List<CatCategory> all() {
    final (season, year) = CatAnilist.currentSeason();
    return [
      const CatCategory('Trending now', 'lists', anilist: {'sort': ['TRENDING_DESC']}, rows: ['trending-movies', 'trending-series']),
      CatCategory('Popular this season', 'lists', anilist: {'sort': ['POPULARITY_DESC'], 'season': season, 'seasonYear': year}),
      const CatCategory('Top rated', 'lists', anilist: {'sort': ['SCORE_DESC']}, rows: ['top-movies', 'top-series']),
      const CatCategory('Airing now', 'lists', anilist: {'sort': ['POPULARITY_DESC'], 'status': 'RELEASING'}, rows: ['airing']),
      const CatCategory('Coming soon', 'lists', anilist: {'sort': ['POPULARITY_DESC'], 'status': 'NOT_YET_RELEASED'}, rows: ['upcoming']),
      const CatCategory('Action', 'genres', anilist: {'genres': ['Action'], 'sort': ['POPULARITY_DESC']}, rows: ['g-action', 'gs-action']),
      const CatCategory('Adventure', 'genres', anilist: {'genres': ['Adventure'], 'sort': ['POPULARITY_DESC']}, rows: ['gs-action']),
      const CatCategory('Comedy', 'genres', anilist: {'genres': ['Comedy'], 'sort': ['POPULARITY_DESC']}, rows: ['g-comedy', 'gs-comedy']),
      const CatCategory('Drama', 'genres', anilist: {'genres': ['Drama'], 'sort': ['POPULARITY_DESC']}, rows: ['g-drama', 'gs-drama']),
      const CatCategory('Fantasy', 'genres', anilist: {'genres': ['Fantasy'], 'sort': ['POPULARITY_DESC']}, rows: ['gs-scifi']),
      const CatCategory('Romance', 'genres', anilist: {'genres': ['Romance'], 'sort': ['POPULARITY_DESC']}, rows: ['g-romance']),
      const CatCategory('Sci-Fi', 'genres', anilist: {'genres': ['Sci-Fi'], 'sort': ['POPULARITY_DESC']}, rows: ['g-scifi', 'gs-scifi']),
      const CatCategory('Mystery', 'genres', anilist: {'genres': ['Mystery'], 'sort': ['POPULARITY_DESC']}, rows: ['gs-mystery']),
      const CatCategory('Horror', 'genres', anilist: {'genres': ['Horror'], 'sort': ['POPULARITY_DESC']}, rows: ['g-horror']),
      const CatCategory('Thriller', 'genres', anilist: {'genres': ['Thriller'], 'sort': ['POPULARITY_DESC']}, rows: ['g-thriller']),
      const CatCategory('Slice of Life', 'genres', anilist: {'genres': ['Slice of Life'], 'sort': ['POPULARITY_DESC']}),
      const CatCategory('Sports', 'genres', anilist: {'genres': ['Sports'], 'sort': ['POPULARITY_DESC']}),
      const CatCategory('Crime', 'genres', rows: ['gs-crime']),
      const CatCategory('Family', 'genres', rows: ['g-family']),
      const CatCategory('Documentary', 'genres', rows: ['g-docs']),
      const CatCategory('Netflix', 'services', rows: ['netflix', 'netflix-movies']),
      const CatCategory('Disney+', 'services', rows: ['disney', 'disney-movies']),
      const CatCategory('Prime Video', 'services', rows: ['prime', 'prime-movies']),
      const CatCategory('HBO Max', 'services', rows: ['max', 'max-movies']),
      const CatCategory('Apple TV+', 'services', rows: ['appletv']),
      const CatCategory('Hulu', 'services', rows: ['hulu']),
      const CatCategory('Paramount+', 'services', rows: ['paramount']),
      const CatCategory('Peacock', 'services', rows: ['peacock']),
    ].where((c) => c.anilist != null || PlusBuiltinRows.enabled).toList();
  }

  /// Everything in the category: anime, movies and series taken in turn.
  /// [page] 2, 3, … loads more as you scroll (empty = the end).
  Future<List<CatItem>> load({int page = 1}) async {
    final parts = await Future.wait<List<CatItem>>([
      if (anilist != null) CatAnilist.list(page <= 1 ? anilist! : {...anilist!, 'page': page}),
      for (final id in rows) CatMovies.row(id, page: page),
    ]);
    return interleave(parts);
  }

  static List<CatItem> interleave(List<List<CatItem>> parts) {
    final out = <CatItem>[];
    final seen = <String>{};
    final longest = parts.fold<int>(0, (a, p) => p.length > a ? p.length : a);
    for (var i = 0; i < longest; i++) {
      for (final p in parts) {
        if (i < p.length && seen.add(p[i].key)) out.add(p[i]);
      }
    }
    return out;
  }
}

/// The built-in Movies & TV lists (TMDB), as items.
class CatMovies {
  static Future<List<CatItem>> row(String id, {int page = 1}) async {
    PlusBuiltinRow? row;
    for (final r in PlusBuiltinRows.available) {
      if (r.id == id) row = r;
    }
    if (row == null) return const [];
    try {
      final items = page <= 1 ? await PlusBuiltinRows.load(row) : await PlusBuiltinRows.loadPage(row, page);
      return [for (final p in items) CatItem.fromStremio(p)];
    } catch (e) {
      Logger.i('Categories: row $id failed: $e');
      return const [];
    }
  }
}

