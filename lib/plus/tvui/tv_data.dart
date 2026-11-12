import 'dart:async';
import 'dart:convert';

import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/plus/for_you/movies_for_you.dart';
import 'package:anymex/plus/for_you/ranking.dart';
import 'package:anymex/plus/stremio/builtin_rows.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/utils/logger.dart';
import 'package:http/http.dart' as http;

/// AnymeX+ TV: one card on the TV, anime (AniList) or Movies & TV (Stremio).
class TvItem {
  final String id; // AniList id, or the Stremio / IMDb id
  final String kind; // anime | movie | series
  final String title;
  final String poster;
  final String backdrop;
  final String description;
  final String year;
  final String rating;
  final String format;
  final String episodes;
  final List<String> genres;
  final String sub; // a line under the card (progress, episode…)
  final double progress; // 0…1, for Continue Watching
  final String videoId; // Stremio: the video to resume

  const TvItem({
    required this.id,
    required this.kind,
    required this.title,
    this.poster = '',
    this.backdrop = '',
    this.description = '',
    this.year = '',
    this.rating = '',
    this.format = '',
    this.episodes = '',
    this.genres = const [],
    this.sub = '',
    this.progress = 0,
    this.videoId = '',
  });

  bool get isAnime => kind == 'anime';
  String get key => '$kind:$id';
  String get kindLabel => switch (kind) { 'anime' => 'Anime', 'movie' => 'Movie', _ => 'Series' };

  static String clean(String? s) {
    if (s == null) return '';
    return s
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _ok(String? s) => (s == null || s == '?' || s == 'null') ? '' : s;

  factory TvItem.fromMedia(Media m, {String sub = ''}) => TvItem(
        id: m.id,
        kind: 'anime',
        title: m.title,
        poster: _ok(m.largePoster).isNotEmpty ? m.largePoster : _ok(m.poster),
        backdrop: _ok(m.cover),
        description: clean(m.description),
        year: _ok(m.premiered).isNotEmpty ? m.premiered : _ok(m.aired),
        rating: _ok(m.rating) == '0' || _ok(m.rating) == '0.0' ? '' : _ok(m.rating),
        format: _ok(m.format),
        episodes: _ok(m.totalEpisodes),
        genres: m.genres,
        sub: sub,
      );

  factory TvItem.fromTracked(TrackedMedia t) => TvItem(
        id: t.id ?? '',
        kind: 'anime',
        title: t.title ?? '?',
        poster: _ok(t.poster),
        rating: _ok(t.rating),
        format: _ok(t.format),
        episodes: _ok(t.totalEpisodes),
        genres: t.genres,
        sub: t.formattedProgress,
        progress: () {
          final done = int.tryParse(t.episodeCount ?? '') ?? 0;
          final all = int.tryParse(t.totalEpisodes ?? '') ?? 0;
          return all > 0 ? (done / all).clamp(0.0, 1.0).toDouble() : 0.0;
        }(),
      );

  factory TvItem.fromStremio(StremioMetaPreview p, {String sub = ''}) => TvItem(
        id: p.id,
        kind: p.type == 'movie' ? 'movie' : 'series',
        title: p.name,
        poster: p.poster ?? '',
        backdrop: p.background ?? '',
        description: clean(p.description),
        year: p.releaseInfo ?? '',
        rating: p.imdbRating ?? '',
        genres: p.genres,
        sub: sub,
      );

  factory TvItem.fromLibrary(StremioLibraryItem i) => TvItem(
        id: i.id,
        kind: i.type == 'movie' ? 'movie' : 'series',
        title: i.name,
        poster: i.poster ?? '',
        progress: i.progress.clamp(0.0, 1.0).toDouble(),
        videoId: i.videoId ?? '',
        sub: () {
          final v = i.videoId ?? '';
          final m = RegExp(r':(\d+):(\d+)$').firstMatch(v);
          final left = i.duration > 0 ? ((i.duration - i.timeOffset) / 60000).round() : 0;
          final ep = m != null ? 'S${m[1]} E${m[2]}' : (i.type == 'movie' ? 'Movie' : 'Series');
          return left > 0 ? '$ep · $left min left' : ep;
        }(),
      );

  factory TvItem.fromPick(ForYouPick p) => TvItem(
        id: p.id,
        kind: p.kind == 'anime' ? 'anime' : (p.kind == 'movie' ? 'movie' : 'series'),
        title: p.title,
        poster: p.poster,
        rating: p.rating,
        genres: p.genres,
        sub: p.reason,
      );

  factory TvItem.fromAnilistJson(Map m) {
    final t = (m['title'] as Map?) ?? const {};
    final cover = (m['coverImage'] as Map?) ?? const {};
    final score = (m['averageScore'] as num?)?.toInt();
    return TvItem(
      id: '${m['id']}',
      kind: 'anime',
      title: '${t['english'] ?? t['romaji'] ?? t['userPreferred'] ?? '?'}',
      poster: '${cover['extraLarge'] ?? cover['large'] ?? ''}',
      backdrop: '${m['bannerImage'] ?? ''}' == 'null' ? '' : '${m['bannerImage'] ?? ''}',
      description: clean(m['description']?.toString()),
      year: m['seasonYear'] == null ? '' : '${m['seasonYear']}',
      rating: score == null || score == 0 ? '' : (score / 10).toStringAsFixed(1),
      format: m['format'] == null ? '' : '${m['format']}'.replaceAll('_', ' '),
      episodes: m['episodes'] == null ? '' : '${m['episodes']}',
      genres: [for (final g in (m['genres'] as List?) ?? const []) '$g'],
    );
  }
}

/// AniList lists for the TV (one query, any filters), cached for a while.
class TvAnilist {
  static final _cache = <String, (DateTime, List<TvItem>)>{};

  static const _fields = 'id title { english romaji userPreferred } coverImage { extraLarge large } bannerImage '
      'description(asHtml: false) averageScore seasonYear format episodes genres';

  static const _query = '''
query (\$genres: [String], \$sort: [MediaSort], \$status: MediaStatus, \$season: MediaSeason, \$seasonYear: Int, \$search: String, \$page: Int) {
  Page(page: \$page, perPage: 40) {
    media(type: ANIME, genre_in: \$genres, sort: \$sort, status: \$status, season: \$season, seasonYear: \$seasonYear, search: \$search, isAdult: false) {
      $_fields
    }
  }
}''';

  static Future<List<TvItem>> list(Map<String, dynamic> vars) async {
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
      final out = [for (final m in media) if (m is Map) TvItem.fromAnilistJson(m)];
      _cache[key] = (DateTime.now(), out);
      return out;
    } catch (e) {
      Logger.i('TV: AniList list failed: $e');
      return hit?.$2 ?? const [];
    }
  }

  static const _one = '''
query (\$id: Int) {
  Media(id: \$id, type: ANIME) {
    $_fields
    status nextAiringEpisode { episode }
    studios(isMain: true) { nodes { name } }
  }
}''';

  /// Full details of one show: the item and the number of episodes out.
  static Future<(TvItem, int, String)?> details(String id) async {
    try {
      final resp = await http
          .post(Uri.parse('https://graphql.anilist.co'),
              headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
              body: jsonEncode({'query': _one, 'variables': {'id': int.tryParse(id) ?? 0}}))
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final m = jsonDecode(resp.body)['data']?['Media'];
      if (m is! Map) return null;
      final item = TvItem.fromAnilistJson(m);
      final next = (m['nextAiringEpisode'] as Map?)?['episode'] as num?;
      final total = (m['episodes'] as num?)?.toInt() ?? 0;
      final out = next != null ? next.toInt() - 1 : total;
      final studios = ((m['studios'] as Map?)?['nodes'] as List?) ?? const [];
      final studio = studios.isEmpty ? '' : '${(studios.first as Map)['name'] ?? ''}';
      return (item, out < 1 ? (total > 0 ? total : 1) : out, studio);
    } catch (e) {
      Logger.i('TV: AniList details failed: $e');
      return null;
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

/// A category on the TV's Categories tab: AniList filters and built-in
/// Movies & TV lists, merged into one grid.
class TvCategory {
  final String name;
  final String group; // lists | genres | services
  final Map<String, dynamic>? anilist;
  final List<String> rows; // PlusBuiltinRow ids

  const TvCategory(this.name, this.group, {this.anilist, this.rows = const []});

  String get sub {
    final anime = anilist != null;
    final movies = rows.isNotEmpty && PlusBuiltinRows.enabled;
    if (anime && movies) return 'Anime + Movies & TV';
    return anime ? 'Anime' : 'Movies & TV';
  }

  static List<TvCategory> all() {
    final (season, year) = TvAnilist.currentSeason();
    return [
      const TvCategory('Trending now', 'lists', anilist: {'sort': ['TRENDING_DESC']}, rows: ['trending-movies', 'trending-series']),
      TvCategory('Popular this season', 'lists', anilist: {'sort': ['POPULARITY_DESC'], 'season': season, 'seasonYear': year}),
      const TvCategory('Top rated', 'lists', anilist: {'sort': ['SCORE_DESC']}, rows: ['top-movies', 'top-series']),
      const TvCategory('Airing now', 'lists', anilist: {'sort': ['POPULARITY_DESC'], 'status': 'RELEASING'}, rows: ['airing']),
      const TvCategory('Coming soon', 'lists', anilist: {'sort': ['POPULARITY_DESC'], 'status': 'NOT_YET_RELEASED'}, rows: ['upcoming']),
      const TvCategory('Action', 'genres', anilist: {'genres': ['Action'], 'sort': ['POPULARITY_DESC']}, rows: ['g-action', 'gs-action']),
      const TvCategory('Adventure', 'genres', anilist: {'genres': ['Adventure'], 'sort': ['POPULARITY_DESC']}, rows: ['gs-action']),
      const TvCategory('Comedy', 'genres', anilist: {'genres': ['Comedy'], 'sort': ['POPULARITY_DESC']}, rows: ['g-comedy', 'gs-comedy']),
      const TvCategory('Drama', 'genres', anilist: {'genres': ['Drama'], 'sort': ['POPULARITY_DESC']}, rows: ['g-drama', 'gs-drama']),
      const TvCategory('Fantasy', 'genres', anilist: {'genres': ['Fantasy'], 'sort': ['POPULARITY_DESC']}, rows: ['gs-scifi']),
      const TvCategory('Romance', 'genres', anilist: {'genres': ['Romance'], 'sort': ['POPULARITY_DESC']}, rows: ['g-romance']),
      const TvCategory('Sci-Fi', 'genres', anilist: {'genres': ['Sci-Fi'], 'sort': ['POPULARITY_DESC']}, rows: ['g-scifi', 'gs-scifi']),
      const TvCategory('Mystery', 'genres', anilist: {'genres': ['Mystery'], 'sort': ['POPULARITY_DESC']}, rows: ['gs-mystery']),
      const TvCategory('Horror', 'genres', anilist: {'genres': ['Horror'], 'sort': ['POPULARITY_DESC']}, rows: ['g-horror']),
      const TvCategory('Thriller', 'genres', anilist: {'genres': ['Thriller'], 'sort': ['POPULARITY_DESC']}, rows: ['g-thriller']),
      const TvCategory('Slice of Life', 'genres', anilist: {'genres': ['Slice of Life'], 'sort': ['POPULARITY_DESC']}),
      const TvCategory('Sports', 'genres', anilist: {'genres': ['Sports'], 'sort': ['POPULARITY_DESC']}),
      const TvCategory('Crime', 'genres', rows: ['gs-crime']),
      const TvCategory('Family', 'genres', rows: ['g-family']),
      const TvCategory('Documentary', 'genres', rows: ['g-docs']),
      const TvCategory('Netflix', 'services', rows: ['netflix', 'netflix-movies']),
      const TvCategory('Disney+', 'services', rows: ['disney', 'disney-movies']),
      const TvCategory('Prime Video', 'services', rows: ['prime', 'prime-movies']),
      const TvCategory('HBO Max', 'services', rows: ['max', 'max-movies']),
      const TvCategory('Apple TV+', 'services', rows: ['appletv']),
      const TvCategory('Hulu', 'services', rows: ['hulu']),
      const TvCategory('Paramount+', 'services', rows: ['paramount']),
      const TvCategory('Peacock', 'services', rows: ['peacock']),
    ].where((c) => c.anilist != null || PlusBuiltinRows.enabled).toList();
  }

  /// Everything in the category: anime, movies and series taken in turn.
  Future<List<TvItem>> load() async {
    final parts = await Future.wait<List<TvItem>>([
      if (anilist != null) TvAnilist.list(anilist!),
      for (final id in rows) TvMovies.row(id),
    ]);
    return interleave(parts);
  }

  static List<TvItem> interleave(List<List<TvItem>> parts) {
    final out = <TvItem>[];
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

/// The built-in Movies & TV lists (TMDB), as TV items.
class TvMovies {
  /// The id Stremio opens a title by. Search results carry a TMDB id
  /// (`tmdb:<movie|series>:<id>`) until they're opened.
  static Future<String?> stremioId(TvItem it) async {
    if (!it.id.startsWith('tmdb:')) return it.id;
    final parts = it.id.split(':');
    if (parts.length != 3) return null;
    return MoviesForYou.imdbFor(parts[1], parts[2]);
  }

  static Future<List<TvItem>> row(String id) async {
    PlusBuiltinRow? row;
    for (final r in PlusBuiltinRows.available) {
      if (r.id == id) row = r;
    }
    if (row == null) return const [];
    try {
      final items = await PlusBuiltinRows.load(row);
      return [for (final p in items) TvItem.fromStremio(p)];
    } catch (e) {
      Logger.i('TV: row $id failed: $e');
      return const [];
    }
  }
}
