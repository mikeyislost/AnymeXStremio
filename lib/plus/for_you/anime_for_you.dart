// AnymeX+: "For you" for anime. Seeds come from your AniList list (your
// scores, what you finished, your favourites); picks come from AniList's
// "if you liked this" recommendations for those seeds plus AnymeX's AI
// Picks, ranked by ranking.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:anymex/ai/animeo.dart';
import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/plus/for_you/ranking.dart';
import 'package:anymex/plus/for_you/taste.dart';
import 'package:anymex/plus/stremio/stremio_disk_cache.dart';
import 'package:anymex/utils/logger.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// A favourite from your AniList profile (id, title, genres).
typedef AnimeFavourite = ({String id, String title, List<String> genres});

class AnimeForYou {
  AnimeForYou._();

  static final RxList<ForYouPick> picks = <ForYouPick>[].obs;
  static const _diskKey = 'foryou/anime';
  static const keepFor = Duration(hours: 24);
  static const recsKeptFor = Duration(days: 3);
  static const maxSeeds = 24;

  static String _signature = '';
  static bool _restored = false;
  static Future<void>? _running;

  /// Seeds and genre taste from your list. Scores are AniList's 0-100.
  static ({List<ForYouSeed> seeds, Map<String, double> genres}) seedsFrom(
      List<TrackedMedia> list, List<AnimeFavourite> favourites) {
    final favIds = {for (final f in favourites) f.id};
    final scores = <double>[
      for (final m in list)
        if ((double.tryParse(m.score ?? '') ?? 0) > 0)
          double.parse(m.score!)
    ];
    final mean = scores.isEmpty
        ? 0.0
        : scores.reduce((a, b) => a + b) / scores.length;
    final sd = scores.length < 2
        ? 10.0
        : math.sqrt(scores
                .map((s) => (s - mean) * (s - mean))
                .reduce((a, b) => a + b) /
            scores.length);

    final weighted = <(TrackedMedia, double, bool, bool)>[];
    for (final m in list) {
      final id = m.id;
      if (id == null || (m.type ?? 'ANIME').toUpperCase() != 'ANIME') continue;
      final status = (m.watchingStatus ?? '').toUpperCase();
      final score = double.tryParse(m.score ?? '') ?? 0;
      var w = 0.0;
      var liked = false;
      if (status == 'DROPPED') {
        w = -1;
      } else if (score > 0) {
        final z = (score - mean) / math.max(sd, 8);
        w = (1 + z).clamp(0.0, 3.0);
        liked = z >= 0.5;
      } else if (status == 'COMPLETED') {
        w = 0.8;
      } else if ((status == 'CURRENT' || status == 'REPEATING') &&
          (m.userProgress ?? int.tryParse(m.episodeCount ?? '') ?? 0) >= 3) {
        w = 0.6;
      }
      final loved = favIds.contains(id);
      if (loved) w = math.max(w + 1.5, 2.0);
      weighted.add((m, w, loved, liked));
    }

    final genres = genreProfile([
      for (final (m, w, _, _) in weighted)
        if (w != 0) (m.genres, w),
      for (final f in favourites)
        if (!weighted.any((e) => e.$1.id == f.id)) (f.genres, 2.0),
    ]);

    final seeds = <ForYouSeed>[
      for (final (m, w, loved, liked) in weighted)
        if (w >= 1.0 || loved)
          ForYouSeed(
            key: m.id!,
            title: m.title ?? m.romajiTitle ?? '?',
            weight: w,
            loved: loved,
            liked: liked,
          ),
      // Favourites that aren't on your list.
      for (final f in favourites)
        if (!weighted.any((e) => e.$1.id == f.id))
          ForYouSeed(key: f.id, title: f.title, weight: 2.0, loved: true),
    ]..sort((a, b) => b.weight.compareTo(a.weight));
    return (
      seeds: seeds.take(maxSeeds).toList(),
      genres: genres,
    );
  }

  /// Turns AniList recommendation nodes of [seedKey] into candidates.
  static void addCandidates(
      Map<String, ForYouCandidate> into, String seedKey, List<dynamic> nodes) {
    var rank = 0;
    for (final n in nodes.whereType<Map>()) {
      final rec = n['mediaRecommendation'];
      if (rec is! Map || rec['id'] == null) continue;
      if (rec['type'] != 'ANIME' || rec['isAdult'] == true) continue;
      final status = '${rec['status'] ?? ''}';
      if (status == 'NOT_YET_RELEASED' || rec['format'] == 'MUSIC') continue;
      final id = '${rec['id']}';
      final t = rec['title'] is Map ? rec['title'] as Map : const {};
      final avg = (rec['averageScore'] as num?)?.toDouble();
      final c = into.putIfAbsent(
          'al:$id',
          () => ForYouCandidate(
                key: 'al:$id',
                id: id,
                kind: 'anime',
                title: '${t['userPreferred'] ?? t['english'] ?? t['romaji'] ?? '?'}',
                poster: '${(rec['coverImage'] is Map ? rec['coverImage']['large'] : null) ?? ''}',
                genres: (rec['genres'] is List ? rec['genres'] as List : const [])
                    .map((e) => '$e')
                    .toList(),
                quality: avg == null ? 0 : ((avg - 72) / 20).clamp(-1.0, 1.0),
                rating: avg == null ? '' : (avg / 10).toStringAsFixed(1),
              ));
      final strength = recommendationStrength(
          rank: rank++, votes: (n['rating'] as num?)?.toInt());
      c.votes[seedKey] = math.max(c.votes[seedKey] ?? 0, strength);
    }
  }

  /// Loads saved picks once, then recomputes when your list, favourites or
  /// hidden picks change (or the saved ones are a day old).
  static Future<void> ensure(
      List<TrackedMedia> list, List<AnimeFavourite> favourites) async {
    if (list.isEmpty) return;
    PlusTaste.ensureLoaded();
    final sig = _fnv([
      for (final m in list) '${m.id}:${m.score}:${m.watchingStatus}',
      for (final f in favourites) 'f${f.id}',
      ...PlusTaste.hidden,
      ...PlusTaste.lessGenresFor('anime').entries.map((e) => '${e.key}${e.value}'),
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
    if (sig == _signature) return;
    if (_running != null) return;
    _signature = sig;
    _running = _compute(list, favourites, sig).whenComplete(() => _running = null);
  }

  static Future<void> _compute(List<TrackedMedia> list,
      List<AnimeFavourite> favourites, String sig) async {
    try {
      final (:seeds, :genres) = seedsFrom(list, favourites);
      final candidates = <String, ForYouCandidate>{};
      final recs = await _recommendationsFor(seeds.map((s) => s.key).toList());
      recs.forEach((seedKey, nodes) => addCandidates(candidates, seedKey, nodes));

      final allSeeds = [...seeds];
      final ai = await _aiPicks();
      if (ai.isNotEmpty) {
        allSeeds.add(const ForYouSeed(
            key: ForYouSeed.aiPicksSeed, title: 'AI Picks', weight: 0.8));
        var rank = 0;
        for (final m in ai) {
          final c = candidates.putIfAbsent(
              'al:${m.id}',
              () => ForYouCandidate(
                    key: 'al:${m.id}',
                    id: m.id,
                    kind: 'anime',
                    title: m.title,
                    poster: m.poster,
                    genres: m.genres,
                    quality: ((double.tryParse(m.rating) ?? 7.2) * 10 - 72) / 20,
                    rating: m.rating,
                  ));
          c.votes[ForYouSeed.aiPicksSeed] =
              recommendationStrength(rank: rank++);
        }
      }

      final exclude = <String>{
        for (final m in list)
          if (m.id != null) ...['al:${m.id}', m.id!],
        for (final f in favourites) ...['al:${f.id}', f.id],
        ...PlusTaste.hidden,
      };
      final result = rankPicks(
        seeds: allSeeds,
        candidates: candidates.values.toList(),
        genreWeights: genres,
        lessGenres: PlusTaste.lessGenresFor('anime'),
        exclude: exclude,
      );
      picks.assignAll(result);
      unawaited(StremioDiskCache.write(_diskKey, {
        'sig': sig,
        'picks': result.map((p) => p.toJson()).toList(),
      }));
      Logger.i('For you (anime): ${result.length} picks from ${seeds.length} seeds');
    } catch (e) {
      _signature = ''; // try again next time
      Logger.i('For you (anime) failed: $e');
    }
  }

  static const _query = r'''
query ($ids: [Int]) {
  Page(perPage: 10) {
    media(id_in: $ids, type: ANIME) {
      id
      recommendations(perPage: 8, sort: RATING_DESC) {
        nodes {
          rating
          mediaRecommendation {
            id type format status isAdult averageScore genres
            title { userPreferred english romaji }
            coverImage { large }
          }
        }
      }
    }
  }
}''';

  /// seed id → AniList recommendation nodes. Each seed's answer is saved
  /// on the device for [recsKeptFor]; only the rest is asked for, 8 at a
  /// time.
  static Future<Map<String, List<dynamic>>> _recommendationsFor(
      List<String> ids) async {
    final out = <String, List<dynamic>>{};
    final missing = <String>[];
    for (final id in ids) {
      final saved = await StremioDiskCache.read('foryou/al-rec/$id');
      if (saved?.value is List && saved!.isFresherThan(recsKeptFor)) {
        out[id] = saved.value as List;
      } else {
        missing.add(id);
      }
    }
    for (var i = 0; i < missing.length; i += 8) {
      final part = missing.sublist(i, math.min(i + 8, missing.length));
      try {
        final r = await http
            .post(Uri.parse('https://graphql.anilist.co'),
                headers: const {
                  'Content-Type': 'application/json',
                  'Accept': 'application/json',
                },
                body: jsonEncode({
                  'query': _query,
                  'variables': {'ids': part.map(int.parse).toList()},
                }))
            .timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) {
          Logger.i('For you: AniList HTTP ${r.statusCode}');
          continue;
        }
        final media =
            (jsonDecode(r.body)['data']?['Page']?['media'] as List?) ?? const [];
        for (final m in media.whereType<Map>()) {
          final id = '${m['id']}';
          final nodes = (m['recommendations']?['nodes'] as List?) ?? const [];
          out[id] = nodes;
          unawaited(StremioDiskCache.write('foryou/al-rec/$id', nodes));
        }
      } catch (e) {
        Logger.i('For you: AniList recommendations failed: $e');
      }
    }
    return out;
  }

  /// AnymeX's AI Picks (anime only); empty when it's unavailable.
  static Future<List<Media>> _aiPicks() async {
    try {
      return await getAiRecommendations(false, 1)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      Logger.i('For you: AI Picks unavailable: $e');
      return const [];
    }
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
