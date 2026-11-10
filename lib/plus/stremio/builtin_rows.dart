// AnymeX+: Movies & TV rows the app provides itself (from TMDB), so the tab
// works without any catalog addons. They show up in Edit layout like the
// addon rows: move, hide, rename or restyle them there. Titles open by IMDb
// id, so details and streams work the same as for addon rows.

import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:anymex/plus/for_you/movies_for_you.dart';
import 'package:anymex/plus/stremio/stremio_disk_cache.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/ui/stremio_widgets.dart'
    show stremioMediaFromPreview;
import 'package:anymex/utils/logger.dart';
import 'package:anymex/widgets/common/reusable_carousel.dart';
import 'package:flutter/material.dart';

/// One built-in row: a TMDB list or discover query.
class PlusBuiltinRow {
  final String id; // layout key is 'tmdb:<id>'
  final String title;
  final String type; // Stremio type: movie | series
  final String path; // TMDB path, e.g. movie/popular
  final String query; // extra TMDB query ('&with_genres=28')
  final bool shown; // on before you change anything

  /// Streaming-service rows filter by the region's catalog.
  final bool regional;

  const PlusBuiltinRow(this.id, this.title, this.type, this.path,
      {this.query = '', this.shown = true, this.regional = false});

  String get layoutKey => 'tmdb:$id';
  String get tmdbKind => type == 'series' ? 'tv' : 'movie';
}

class PlusBuiltinRows {
  PlusBuiltinRows._();

  /// Built-in rows need the app's TMDB key (set at build time).
  static bool get enabled => MoviesForYou.tmdbKey != null;

  static List<PlusBuiltinRow> get available => enabled ? all : const [];

  static PlusBuiltinRow? byLayoutKey(String key) {
    for (final r in all) {
      if (r.layoutKey == key) return r;
    }
    return null;
  }

  static const _popularGenre = '&sort_by=popularity.desc&vote_count.gte=150';
  static const _popularTvGenre = '&sort_by=popularity.desc&vote_count.gte=50';

  static String _service(int provider) =>
      '&sort_by=popularity.desc&with_watch_providers=$provider'
      '&with_watch_monetization_types=flatrate';

  static const all = <PlusBuiltinRow>[
    PlusBuiltinRow('trending-movies', 'Trending · Movies', 'movie',
        'trending/movie/day'),
    PlusBuiltinRow('trending-series', 'Trending · Series', 'series',
        'trending/tv/day'),
    PlusBuiltinRow('popular-movies', 'Popular · Movies', 'movie',
        'movie/popular'),
    PlusBuiltinRow('popular-series', 'Popular · Series', 'series',
        'tv/popular'),
    PlusBuiltinRow('theaters', 'In Theaters · Movies', 'movie',
        'movie/now_playing', regional: true),
    PlusBuiltinRow('airing', 'Airing This Week · Series', 'series',
        'tv/on_the_air'),
    PlusBuiltinRow('upcoming', 'Coming Soon · Movies', 'movie',
        'movie/upcoming', regional: true),
    PlusBuiltinRow('top-movies', 'Top Rated · Movies', 'movie',
        'movie/top_rated'),
    PlusBuiltinRow('top-series', 'Top Rated · Series', 'series',
        'tv/top_rated'),
    // Streaming services (your region's catalog).
    PlusBuiltinRow('netflix', 'Netflix · Series', 'series', 'discover/tv',
        query: '&with_watch_providers=8', regional: true),
    PlusBuiltinRow('netflix-movies', 'Netflix · Movies', 'movie',
        'discover/movie',
        query: '&with_watch_providers=8', regional: true, shown: false),
    PlusBuiltinRow('disney', 'Disney+ · Series', 'series', 'discover/tv',
        query: '&with_watch_providers=337', regional: true),
    PlusBuiltinRow('disney-movies', 'Disney+ · Movies', 'movie',
        'discover/movie',
        query: '&with_watch_providers=337', regional: true, shown: false),
    PlusBuiltinRow('prime', 'Prime Video · Series', 'series', 'discover/tv',
        query: '&with_watch_providers=9', regional: true),
    PlusBuiltinRow('prime-movies', 'Prime Video · Movies', 'movie',
        'discover/movie',
        query: '&with_watch_providers=9', regional: true, shown: false),
    PlusBuiltinRow('max', 'HBO Max · Series', 'series', 'discover/tv',
        query: '&with_watch_providers=1899', regional: true),
    PlusBuiltinRow('max-movies', 'HBO Max · Movies', 'movie',
        'discover/movie',
        query: '&with_watch_providers=1899', regional: true, shown: false),
    PlusBuiltinRow('appletv', 'Apple TV+ · Series', 'series', 'discover/tv',
        query: '&with_watch_providers=350', regional: true),
    PlusBuiltinRow('hulu', 'Hulu · Series', 'series', 'discover/tv',
        query: '&with_watch_providers=15', regional: true, shown: false),
    PlusBuiltinRow('paramount', 'Paramount+ · Series', 'series',
        'discover/tv',
        query: '&with_watch_providers=531', regional: true, shown: false),
    PlusBuiltinRow('peacock', 'Peacock · Series', 'series', 'discover/tv',
        query: '&with_watch_providers=386', regional: true, shown: false),
    // Genres (off until you turn them on in Edit layout).
    PlusBuiltinRow('g-action', 'Action · Movies', 'movie', 'discover/movie',
        query: '&with_genres=28', shown: false),
    PlusBuiltinRow('g-comedy', 'Comedy · Movies', 'movie', 'discover/movie',
        query: '&with_genres=35', shown: false),
    PlusBuiltinRow('g-horror', 'Horror · Movies', 'movie', 'discover/movie',
        query: '&with_genres=27', shown: false),
    PlusBuiltinRow('g-thriller', 'Thriller · Movies', 'movie',
        'discover/movie',
        query: '&with_genres=53', shown: false),
    PlusBuiltinRow('g-scifi', 'Sci-Fi · Movies', 'movie', 'discover/movie',
        query: '&with_genres=878', shown: false),
    PlusBuiltinRow('g-drama', 'Drama · Movies', 'movie', 'discover/movie',
        query: '&with_genres=18', shown: false),
    PlusBuiltinRow('g-romance', 'Romance · Movies', 'movie', 'discover/movie',
        query: '&with_genres=10749', shown: false),
    PlusBuiltinRow('g-family', 'Family · Movies', 'movie', 'discover/movie',
        query: '&with_genres=10751', shown: false),
    PlusBuiltinRow('g-docs', 'Documentary · Movies', 'movie',
        'discover/movie',
        query: '&with_genres=99', shown: false),
    PlusBuiltinRow('gs-action', 'Action & Adventure · Series', 'series',
        'discover/tv',
        query: '&with_genres=10759', shown: false),
    PlusBuiltinRow('gs-comedy', 'Comedy · Series', 'series', 'discover/tv',
        query: '&with_genres=35', shown: false),
    PlusBuiltinRow('gs-crime', 'Crime · Series', 'series', 'discover/tv',
        query: '&with_genres=80', shown: false),
    PlusBuiltinRow('gs-drama', 'Drama · Series', 'series', 'discover/tv',
        query: '&with_genres=18', shown: false),
    PlusBuiltinRow('gs-scifi', 'Sci-Fi & Fantasy · Series', 'series',
        'discover/tv',
        query: '&with_genres=10765', shown: false),
    PlusBuiltinRow('gs-mystery', 'Mystery · Series', 'series', 'discover/tv',
        query: '&with_genres=9648', shown: false),
    PlusBuiltinRow('gs-reality', 'Reality · Series', 'series', 'discover/tv',
        query: '&with_genres=10764', shown: false),
  ];

  /// Your country (from the phone's region), for theaters and services.
  static String get region {
    try {
      final c = PlatformDispatcher.instance.locale.countryCode;
      if (c != null && c.length == 2) return c.toUpperCase();
    } catch (_) {}
    return 'US';
  }

  /// The full TMDB query for [row] (after `?api_key=…`).
  static String queryFor(PlusBuiltinRow row, String region) {
    var q = row.query;
    if (row.path.startsWith('discover/') && !q.contains('sort_by=')) {
      // Genre rows: popular titles with enough votes; service rows: popular.
      if (q.contains('with_watch_providers=')) {
        final id = RegExp(r'with_watch_providers=(\d+)')
            .firstMatch(q)!
            .group(1)!;
        q = _service(int.parse(id));
      } else {
        q = '$q${row.type == 'series' ? _popularTvGenre : _popularGenre}';
      }
    }
    if (row.regional) q = '$q&region=$region&watch_region=$region';
    return q;
  }

  /// A TMDB list result → a row item opened by [imdb] (null if unusable).
  static StremioMetaPreview? previewFrom(Map r, String type, String imdb) {
    if (r['adult'] == true || !imdb.startsWith('tt')) return null;
    final title = '${r['title'] ?? r['name'] ?? ''}'.trim();
    final poster = r['poster_path']?.toString() ?? '';
    if (title.isEmpty || poster.isEmpty) return null;
    final backdrop = r['backdrop_path']?.toString() ?? '';
    final date = '${r['release_date'] ?? r['first_air_date'] ?? ''}';
    final votes = (r['vote_count'] as num?)?.toInt() ?? 0;
    final avg = (r['vote_average'] as num?)?.toDouble() ?? 0;
    final overview = r['overview']?.toString() ?? '';
    return StremioMetaPreview(
      id: imdb,
      type: type,
      name: title,
      poster: 'https://image.tmdb.org/t/p/w500$poster',
      background: backdrop.isEmpty
          ? null
          : 'https://image.tmdb.org/t/p/w1280$backdrop',
      description: overview.isEmpty ? null : overview,
      releaseInfo: date.length >= 4 ? date.substring(0, 4) : null,
      imdbRating: votes >= 10 && avg > 0 ? avg.toStringAsFixed(1) : null,
      genres: MoviesForYou.tmdbGenres(r['genre_ids']),
    );
  }

  static const refreshAfter = Duration(hours: 6);
  static String _saveKey(PlusBuiltinRow row) =>
      'builtin/${row.id}/${row.regional ? region : 'all'}';

  /// The row saved on the device last time (shown straight away).
  static Future<List<StremioMetaPreview>?> saved(PlusBuiltinRow row) async {
    final entry = await StremioDiskCache.read(_saveKey(row));
    if (entry?.value is! List) return null;
    return (entry!.value as List)
        .whereType<Map>()
        .map((e) => StremioMetaPreview.fromJson(Map<String, dynamic>.from(e)))
        .where((m) => m.id.isNotEmpty)
        .toList();
  }

  /// Loads [row] from TMDB (kept 6 hours unless [force]) and saves it.
  static Future<List<StremioMetaPreview>> load(PlusBuiltinRow row,
      {bool force = false}) async {
    final key = _saveKey(row);
    final entry = await StremioDiskCache.read(key);
    if (!force && entry != null && entry.isFresherThan(refreshAfter)) {
      final s = await saved(row);
      if (s != null && s.isNotEmpty) return s;
    }
    try {
      final q = queryFor(row, region);
      final data = await MoviesForYou.tmdbGet(row.path,
          'builtin-tmdb/${row.id}/$q', force ? Duration.zero : refreshAfter,
          query: q);
      final results = data is Map && data['results'] is List
          ? (data['results'] as List).whereType<Map>().toList()
          : const <Map>[];
      final out = <StremioMetaPreview>[];
      final seen = <String>{};
      // IMDb ids, 10 at a time (each one is kept on the device a month).
      for (var i = 0; i < results.length; i += 10) {
        final part = results.skip(i).take(10).toList();
        final imdbs = await Future.wait(part.map((r) =>
            MoviesForYou.imdbFor(row.tmdbKind, '${r['id']}')
                .catchError((_) => null)));
        for (var j = 0; j < part.length; j++) {
          final imdb = imdbs[j];
          if (imdb == null || !seen.add(imdb)) continue;
          final p = previewFrom(part[j], row.type, imdb);
          if (p != null) out.add(p);
        }
      }
      if (out.isNotEmpty) {
        unawaited(StremioDiskCache.write(
            key, out.map((m) => m.toJson()).toList()));
        return out;
      }
    } catch (e) {
      Logger.i('Built-in row ${row.id} failed: $e');
    }
    return await saved(row) ?? const [];
  }
}

/// One built-in row as an AnymeX carousel (uses your card style).
class PlusBuiltinCarousel extends StatefulWidget {
  final PlusBuiltinRow row;
  final String title;
  final bool force;

  const PlusBuiltinCarousel(
      {super.key, required this.row, required this.title, this.force = false});

  @override
  State<PlusBuiltinCarousel> createState() => _PlusBuiltinCarouselState();
}

class _PlusBuiltinCarouselState extends State<PlusBuiltinCarousel>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<StremioMetaPreview>? _items;
  bool _fresh = false;

  @override
  void initState() {
    super.initState();
    PlusBuiltinRows.saved(widget.row).then((s) {
      if (mounted && !_fresh && s != null && s.isNotEmpty) {
        setState(() => _items = s);
      }
    }, onError: (_) {});
    PlusBuiltinRows.load(widget.row, force: widget.force)
        .then((v) => v, onError: (_) => <StremioMetaPreview>[])
        .then((v) {
      if (!mounted) return;
      _fresh = true;
      if (v.isEmpty && (_items?.isNotEmpty ?? false)) return;
      setState(() => _items = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final items = _items;
    if (items != null && items.isEmpty) return const SizedBox.shrink();
    return ReusableCarousel(
      data: (items ?? const <StremioMetaPreview>[])
          .take(25)
          .map(stremioMediaFromPreview)
          .toList(),
      title: widget.title,
      isLoading: items == null,
    );
  }
}
