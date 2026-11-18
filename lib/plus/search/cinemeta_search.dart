// Movies & Series search for the unified Search page.
//
// TMDB (already used by the app, key bundled in .env) pages properly, so
// results keep loading as you scroll. Its ids are TMDB ids; the IMDb id that
// Stremio needs is looked up only when you open a result. If there is no TMDB
// key, Cinemeta (Stremio's built-in IMDb catalog) is used instead — it only
// gives one page.

import 'dart:convert';

import 'package:anymex/plus/categories/categories_data.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/ui/stremio_widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

typedef SearchPage = ({List<CatItem> items, bool hasMore});

class CinemetaSearch {
  static const _cinemeta = 'https://v3-cinemeta.strem.io/catalog';
  static const _empty = (items: <CatItem>[], hasMore: false);

  static String get _key => (dotenv.maybeGet('TMDB_API_KEY') ?? '').trim();

  /// [type] is `movie` or `series`; [page] starts at 1.
  static Future<SearchPage> fetch(String type, String query,
      {int page = 1}) async {
    final q = query.trim();
    if (q.isEmpty) return _empty;
    if (_key.isNotEmpty) {
      final r = await _tmdb(type, q, page);
      if (r != null) return r;
    }
    return page == 1 ? _fromCinemeta(type, q) : _empty;
  }

  static Future<SearchPage?> _tmdb(String type, String q, int page) async {
    try {
      final kind = type == 'movie' ? 'movie' : 'tv';
      final r = await http
          .get(Uri.https('api.themoviedb.org', '/3/search/$kind', {
            'api_key': _key,
            'query': q,
            'page': '$page',
            'include_adult': 'false',
          }))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final body = jsonDecode(r.body) as Map;
      final total = (body['total_pages'] as num?)?.toInt() ?? 1;
      final items = <CatItem>[];
      for (final m in (body['results'] as List? ?? const [])) {
        if (m is! Map) continue;
        final p = '${m['poster_path'] ?? ''}';
        if (p.isEmpty) continue;
        final date =
            '${m[type == 'movie' ? 'release_date' : 'first_air_date'] ?? ''}';
        final vote = (m['vote_average'] as num?)?.toDouble() ?? 0;
        final b = '${m['backdrop_path'] ?? ''}';
        items.add(CatItem(
          id: 'tmdb:${m['id']}',
          kind: type,
          title: '${m[type == 'movie' ? 'title' : 'name'] ?? ''}',
          poster: 'https://image.tmdb.org/t/p/w500$p',
          rating: vote > 0 ? vote.toStringAsFixed(1) : '',
          year: date.length >= 4 ? date.substring(0, 4) : '',
          backdrop: b.isEmpty ? '' : 'https://image.tmdb.org/t/p/w1280$b',
          overview: '${m['overview'] ?? ''}',
        ));
      }
      return (items: items, hasMore: page < total);
    } catch (_) {
      return null;
    }
  }

  static Future<SearchPage> _fromCinemeta(String type, String q) async {
    try {
      final r = await http
          .get(Uri.parse(
              '$_cinemeta/$type/top/search=${Uri.encodeComponent(q)}.json'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return _empty;
      final metas = (jsonDecode(r.body) as Map)['metas'];
      if (metas is! List) return _empty;
      final items = <CatItem>[];
      for (final m in metas) {
        if (m is! Map) continue;
        final j = m.cast<String, dynamic>();
        j['type'] ??= type;
        final it = CatItem.fromStremio(StremioMetaPreview.fromJson(j));
        if (it.id.isNotEmpty && it.poster.isNotEmpty) items.add(it);
      }
      return (items: items, hasMore: false);
    } catch (_) {
      return _empty;
    }
  }

  /// A TMDB result has no IMDb id yet: look it up, then open the Stremio page.
  static Future<void> open(CatItem it, String tag) async {
    var id = it.id;
    if (id.startsWith('tmdb:')) {
      final tmdbId = id.substring(5);
      final kind = it.kind == 'movie' ? 'movie' : 'tv';
      try {
        final r = await http
            .get(Uri.https('api.themoviedb.org', '/3/$kind/$tmdbId/external_ids',
                {'api_key': _key}))
            .timeout(const Duration(seconds: 8));
        id = '${(jsonDecode(r.body) as Map)['imdb_id'] ?? ''}';
      } catch (_) {
        id = '';
      }
      if (id.isEmpty) return;
    }
    openStremioDetails(it.kind, id,
        tag: tag, title: it.title, poster: it.poster);
  }
}
