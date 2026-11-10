// AnymeX+: "For you" for Movies & TV. Seeds come from your Stremio
// library and watch history (what you finished, how long you watched,
// how recently) plus the titles you Liked or Loved; picks come from TMDB's
// recommendations for those seeds, ranked by ranking.dart.
//
// Needs TMDB_API_KEY; without it the row stays hidden.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:anymex/plus/for_you/ranking.dart';
import 'package:anymex/plus/for_you/taste.dart';
import 'package:anymex/plus/stremio/stremio_disk_cache.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/utils/logger.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// What one library item tells us about your taste.
typedef MovieSeedInput = ({
  String id,
  String type, // movie | series
  String title,
  bool watched,
  int watchedMs,
  bool inLibrary,
  DateTime? lastWatched,
  TasteMark mark,
});

class MoviesForYou {
  MoviesForYou._();

  static final RxList<ForYouPick> picks = <ForYouPick>[].obs;
  static const _diskKey = 'foryou/movies';
  static const keepFor = Duration(hours: 24);
  static const maxSeeds = 15;

  static String _signature = '';
  static bool _restored = false;
  static Future<void>? _running;

  static String? get tmdbKey {
    try {
      final k = dotenv.env['TMDB_API_KEY'];
      return (k == null || k.trim().isEmpty) ? null : k.trim();
    } catch (_) {
      return null;
    }
  }

  /// How much one title counts as a seed. Finished, or watched for a good
  /// while, counts 1; being in your library adds a little; Like adds 1 and
  /// Love adds 2; things you watched long ago count up to half as much.
  /// Dislike is -1.5: what it recommends counts against.
  static double seedWeight(MovieSeedInput i, {DateTime? now}) {
    if (i.mark == TasteMark.dislike) return -1.5;
    final hours = i.watchedMs / 3600000;
    final full = i.type == 'movie' ? 1.5 : 6.0;
    var base = i.watched ? 1.0 : 0.0;
    base = math.max(base, math.min(hours / full, 1.5));
    if (i.inLibrary) base += 0.2;
    final last = i.lastWatched;
    if (last != null && base > 0) {
      final days = (now ?? DateTime.now()).difference(last).inHours / 24;
      base *= 0.5 + 0.5 * math.exp(-math.max(days, 0) / 120);
    }
    final bonus = switch (i.mark) {
      TasteMark.love => 2.0,
      TasteMark.like => 1.0,
      TasteMark.dislike || TasteMark.none => 0.0,
    };
    return base + bonus;
  }

  /// Library items (and Liked / Loved titles) → seed inputs. IMDb titles
  /// only; anime from Kitsu is covered by the anime row.
  static List<MovieSeedInput> inputsFrom(
      Iterable<StremioLibraryItem> items, Map<String, TasteMark> marks) {
    final out = <String, MovieSeedInput>{};
    for (final i in items) {
      if (!i.id.startsWith('tt')) continue;
      if (i.type != 'movie' && i.type != 'series') continue;
      out[i.id] = (
        id: i.id,
        type: i.type,
        title: i.name,
        watched: i.timesWatched > 0 || i.flaggedWatched > 0,
        watchedMs: i.overallTimeWatched,
        inLibrary: i.isInLibrary,
        lastWatched: i.lastWatched ?? i.mtime,
        mark: marks[i.id] ?? TasteMark.none,
      );
    }
    marks.forEach((id, mark) {
      if (!id.startsWith('tt') || out.containsKey(id)) return;
      out[id] = (
        id: id,
        type: '', // found on TMDB
        title: '',
        watched: false,
        watchedMs: 0,
        inLibrary: false,
        lastWatched: null,
        mark: mark,
      );
    });
    return out.values.toList();
  }

  /// Loads saved picks once, then recomputes when your library, marks or
  /// hidden picks change (or the saved ones are a day old).
  static Future<void> ensure(
      Iterable<StremioLibraryItem> items, Map<String, TasteMark> marks) async {
    if (tmdbKey == null) return;
    PlusTaste.ensureLoaded();
    final inputs = inputsFrom(items, marks);
    if (inputs.isEmpty) return;
    final sig = _fnv([
      for (final i in inputs)
        '${i.id}:${i.watched}:${i.watchedMs ~/ 600000}:${i.inLibrary}:${i.mark.name}',
      ...PlusTaste.hidden,
      ...PlusTaste.lessGenresFor('video').entries.map((e) => '${e.key}${e.value}'),
    ].join('|'));
    if (!_restored) {
      _restored = true;
      final saved = await StremioDiskCache.read(_diskKey);
      final v = saved?.value;
      if (v is Map && v['picks'] is List) {
        picks.assignAll((v['picks'] as List)
            .whereType<Map>()
            .map((e) => ForYouPick.fromJson(Map<String, dynamic>.from(e))));
        if (v['sig'] == sig && saved!.isFresherThan(keepFor)) {
          _signature = sig;
          return;
        }
      }
    }
    if (sig == _signature || _running != null) return;
    _signature = sig;
    final libraryIds = {
      for (final i in items)
        if (i.timesWatched > 0 || i.flaggedWatched > 0 || i.isInLibrary ||
            i.timeOffset > 0)
          i.id
    };
    _running =
        _compute(inputs, libraryIds, sig).whenComplete(() => _running = null);
  }

  static Future<void> _compute(List<MovieSeedInput> inputs,
      Set<String> libraryIds, String sig) async {
    try {
      final now = DateTime.now();
      final ranked = [
        for (final i in inputs) (i, seedWeight(i, now: now))
      ]..sort((a, b) => b.$2.compareTo(a.$2));

      // Seeds, with their TMDB entry (type, id, genres).
      final seeds = <ForYouSeed>[];
      final seedGenres = <(List<String>, double)>[];
      final seedTmdb = <String, (String, int)>{}; // seed id → (movie|tv, id)
      final against = [
        for (final (i, w) in ranked)
          if (w < 0) (i, w)
      ].take(8);
      for (final (i, w) in [
        ...ranked.where((e) => e.$2 >= 0.5).take(maxSeeds * 2),
        ...against,
      ]) {
        if (w > 0 && seeds.where((s) => s.weight > 0).length >= maxSeeds) {
          continue;
        }
        final found = await _find(i.id, i.type);
        if (found == null) continue;
        seeds.add(ForYouSeed(
          key: i.id,
          title: i.title.isNotEmpty ? i.title : found.title,
          weight: w,
          loved: i.mark == TasteMark.love,
          liked: i.mark == TasteMark.like,
        ));
        seedGenres.add((found.genres, w));
        seedTmdb[i.id] = (found.kind, found.id);
      }
      if (!seeds.any((s) => s.weight > 0)) {
        picks.clear();
        return;
      }

      final candidates = <String, ForYouCandidate>{};
      for (final s in seeds) {
        final (kind, id) = seedTmdb[s.key]!;
        final results = await _recommendations(kind, id);
        var rank = 0;
        for (final r in results.whereType<Map>()) {
          final c = _candidateFrom(r, kind);
          if (c == null) continue;
          final cand = candidates.putIfAbsent(c.key, () => c);
          cand.votes[s.key] = math.max(
              cand.votes[s.key] ?? 0, recommendationStrength(rank: rank++));
        }
      }

      final exclude = <String>{
        ...seedTmdb.values.map((t) => 'tmdb:${t.$1}:${t.$2}'),
        ...PlusTaste.hidden,
      };
      final ranking = rankPicks(
        seeds: seeds,
        candidates: candidates.values.toList(),
        genreWeights: genreProfile(seedGenres),
        lessGenres: PlusTaste.lessGenresFor('video'),
        exclude: exclude,
        max: 45,
      );

      // Stremio opens titles by IMDb id.
      final out = <ForYouPick>[];
      for (var i = 0; i < ranking.length && out.length < 30; i += 8) {
        final part = ranking.sublist(i, math.min(i + 8, ranking.length));
        final imdbs = await Future.wait(part.map((p) {
          final bits = p.key.split(':'); // tmdb:movie:123
          return _imdbFor(bits[1], bits[2]);
        }));
        for (var j = 0; j < part.length; j++) {
          final imdb = imdbs[j];
          final p = part[j];
          if (imdb == null || libraryIds.contains(imdb)) continue;
          if (PlusTaste.hidden.contains(imdb) ||
              PlusTaste.marks.containsKey(imdb)) {
            continue;
          }
          out.add(ForYouPick(
            key: p.key,
            id: imdb,
            kind: p.kind,
            title: p.title,
            poster: p.poster,
            reason: p.reason,
            rating: p.rating,
            genres: p.genres,
            score: p.score,
          ));
          if (out.length >= 30) break;
        }
      }
      picks.assignAll(out);
      unawaited(StremioDiskCache.write(_diskKey, {
        'sig': sig,
        'picks': out.map((p) => p.toJson()).toList(),
      }));
      Logger.i('For you (Movies & TV): ${out.length} picks from ${seeds.length} seeds');
    } catch (e) {
      _signature = '';
      Logger.i('For you (Movies & TV) failed: $e');
    }
  }

  /// A TMDB recommendation result → candidate (null if unusable).
  static ForYouCandidate? candidateFromTmdb(Map r, String fallbackKind) =>
      _candidateFrom(r, fallbackKind);

  static ForYouCandidate? _candidateFrom(Map r, String fallbackKind) {
    final id = r['id'];
    if (id == null || r['adult'] == true) return null;
    final kind = '${r['media_type'] ?? fallbackKind}';
    if (kind != 'movie' && kind != 'tv') return null;
    final poster = r['poster_path']?.toString();
    if (poster == null || poster.isEmpty) return null;
    final votes = (r['vote_count'] as num?)?.toInt() ?? 0;
    final avg = (r['vote_average'] as num?)?.toDouble() ?? 0;
    final title = '${r['title'] ?? r['name'] ?? ''}';
    if (title.isEmpty) return null;
    return ForYouCandidate(
      key: 'tmdb:$kind:$id',
      id: '$id',
      kind: kind == 'tv' ? 'series' : 'movie',
      title: title,
      poster: 'https://image.tmdb.org/t/p/w342$poster',
      genres: tmdbGenres(r['genre_ids']),
      // Few votes → not much to go on.
      quality: votes < 50 ? 0 : ((avg - 6.5) / 2).clamp(-1.0, 1.0),
      rating: avg > 0 ? avg.toStringAsFixed(1) : '',
    );
  }

  /// TMDB genre ids → names shared by movies and TV ("Action & Adventure"
  /// counts as both Action and Adventure).
  static List<String> tmdbGenres(dynamic ids) {
    if (ids is! List) return const [];
    final out = <String>{};
    for (final id in ids) {
      out.addAll(_genreNames[id] ?? const []);
    }
    return out.toList();
  }

  static const Map<int, List<String>> _genreNames = {
    28: ['Action'],
    12: ['Adventure'],
    16: ['Animation'],
    35: ['Comedy'],
    80: ['Crime'],
    99: ['Documentary'],
    18: ['Drama'],
    10751: ['Family'],
    14: ['Fantasy'],
    36: ['History'],
    27: ['Horror'],
    10402: ['Music'],
    9648: ['Mystery'],
    10749: ['Romance'],
    878: ['Science Fiction'],
    10770: ['TV Movie'],
    53: ['Thriller'],
    10752: ['War'],
    37: ['Western'],
    10759: ['Action', 'Adventure'],
    10762: ['Kids'],
    10763: ['News'],
    10764: ['Reality'],
    10765: ['Science Fiction', 'Fantasy'],
    10766: ['Soap'],
    10767: ['Talk'],
    10768: ['War', 'Politics'],
  };

  // ---- TMDB (answers kept on the device) -----------------------------------

  static Future<dynamic> _get(String path, String cacheKey, Duration keep,
      {String query = ''}) async {
    final key = tmdbKey;
    if (key == null) return null;
    final saved = await StremioDiskCache.read(cacheKey);
    if (saved != null && saved.isFresherThan(keep)) return saved.value;
    try {
      final r = await http
          .get(Uri.parse(
              'https://api.themoviedb.org/3/$path?api_key=$key$query'))
          .timeout(const Duration(seconds: 12));
      if (r.statusCode == 200) {
        final body = jsonDecode(r.body);
        unawaited(StremioDiskCache.write(cacheKey, body));
        return body;
      }
      Logger.i('For you: TMDB HTTP ${r.statusCode} for $path');
    } catch (e) {
      Logger.i('For you: TMDB failed for $path: $e');
    }
    return saved?.value; // older answer beats none
  }

  /// IMDb id → TMDB entry. [type] picks movie vs show when both match.
  static Future<({String kind, int id, String title, List<String> genres})?>
      _find(String imdb, String type) async {
    final data = await _get('find/$imdb', 'foryou/tmdb-find/$imdb',
        const Duration(days: 60),
        query: '&external_source=imdb_id');
    if (data is! Map) return null;
    final movies = data['movie_results'] is List
        ? (data['movie_results'] as List).whereType<Map>().toList()
        : const <Map>[];
    final shows = data['tv_results'] is List
        ? (data['tv_results'] as List).whereType<Map>().toList()
        : const <Map>[];
    final useShow = type == 'series'
        ? shows.isNotEmpty
        : (type == 'movie' ? movies.isEmpty && shows.isNotEmpty : movies.isEmpty);
    final hit = useShow
        ? (shows.isEmpty ? null : shows.first)
        : (movies.isEmpty ? null : movies.first);
    final id = (hit?['id'] as num?)?.toInt();
    if (hit == null || id == null) return null;
    return (
      kind: useShow ? 'tv' : 'movie',
      id: id,
      title: '${hit['title'] ?? hit['name'] ?? ''}',
      genres: tmdbGenres(hit['genre_ids']),
    );
  }

  static Future<List<dynamic>> _recommendations(String kind, int id) async {
    final data = await _get('$kind/$id/recommendations',
        'foryou/tmdb-rec/$kind/$id', const Duration(days: 7));
    return data is Map && data['results'] is List
        ? data['results'] as List
        : const [];
  }

  /// TMDB GET kept on the device for [keep] (also used by the built-in
  /// Movies & TV rows).
  static Future<dynamic> tmdbGet(String path, String cacheKey, Duration keep,
          {String query = ''}) =>
      _get(path, cacheKey, keep, query: query);

  /// TMDB id → IMDb id (Stremio opens titles by IMDb id).
  static Future<String?> imdbFor(String kind, String id) => _imdbFor(kind, id);

  static Future<String?> _imdbFor(String kind, String id) async {
    final tmdbKind = kind == 'series' || kind == 'tv' ? 'tv' : 'movie';
    final data = await _get('$tmdbKind/$id/external_ids',
        'foryou/tmdb-imdb/$tmdbKind/$id', const Duration(days: 30));
    final imdb = data is Map ? data['imdb_id']?.toString() : null;
    return (imdb != null && imdb.startsWith('tt')) ? imdb : null;
  }

  static String _fnv(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16);
  }
}
