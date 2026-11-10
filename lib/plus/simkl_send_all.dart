// AnymeX+: "Send everything to Simkl" (Settings → Accounts). Sends your
// whole Movies & TV watch history from Stremio (episodes in progress
// included) and your AniList anime list (status, episode progress, scores)
// to Simkl. Simkl matches by IMDb / AniList / MAL id and only updates what
// is already there, so running it twice is harmless.

import 'dart:convert';

import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/controllers/services/simkl/simkl_service.dart';
import 'package:anymex/database/data_keys/keys.dart' show AuthKeys;
import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:anymex/plus/simkl_auth_v2.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/stremio/watched_bitfield.dart';
import 'package:anymex/utils/logger.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_tile.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// What one run sent.
class SimklSendSummary {
  int movies = 0;
  int shows = 0;
  int episodes = 0;
  int anime = 0;
  int ratings = 0;
  int failedRequests = 0;

  String get text {
    final parts = <String>[
      if (movies > 0) '$movies movies',
      if (shows > 0) '$shows shows ($episodes episodes)',
      if (anime > 0) '$anime anime',
      if (ratings > 0) '$ratings scores',
    ];
    final sent = parts.isEmpty ? 'Nothing to send' : 'Sent ${parts.join(', ')}';
    return failedRequests > 0
        ? '$sent · $failedRequests part(s) failed, run it again'
        : sent;
  }
}

class PlusSimklSendAll {
  PlusSimklSendAll._();

  static final RxBool running = false.obs;
  static final RxString progress = ''.obs;

  static const _batch = 100;

  // ---- pure helpers (unit-tested) -----------------------------------------

  /// AniList list status → Simkl watchlist status.
  static String? simklStatus(String? anilistStatus) {
    switch ((anilistStatus ?? '').toUpperCase()) {
      case 'CURRENT':
      case 'REPEATING':
        return 'watching';
      case 'COMPLETED':
        return 'completed';
      case 'PAUSED':
        return 'hold';
      case 'DROPPED':
        return 'dropped';
      case 'PLANNING':
        return 'plantowatch';
    }
    return null;
  }

  /// An AniList score (0–100 or 0–10) as Simkl's 1–10, or null when unscored.
  static int? simklRating(String? score) {
    final v = double.tryParse(score ?? '');
    if (v == null || v <= 0) return null;
    final ten = v > 10 ? v / 10 : v;
    return ten.round().clamp(1, 10).toInt();
  }

  /// Simkl ids for an AniList entry.
  static Map<String, dynamic>? animeIds(TrackedMedia m) {
    final al = int.tryParse(m.id ?? '');
    if (al == null) return null;
    final mal = int.tryParse(m.idMal ?? '');
    return {'anilist': al, if (mal != null) 'mal': mal};
  }

  /// Episodes 1..n (anime use flat numbering on Simkl).
  static List<Map<String, int>> episodesUpTo(int n) =>
      [for (var i = 1; i <= n.clamp(0, 3000).toInt(); i++) {'number': i}];

  /// "tt123:2:5" → (2, 5); null for anything else.
  static (int, int)? seasonEpisode(String videoId) {
    final p = videoId.split(':');
    if (p.length < 3) return null;
    final s = int.tryParse(p[1]), e = int.tryParse(p[2]);
    if (s == null || e == null) return null;
    return (s, e);
  }

  /// Simkl `seasons` for these watched episodes, seasons and episodes in order.
  static List<Map<String, dynamic>> seasonsFor(Iterable<(int, int)> eps) {
    final bySeason = <int, Set<int>>{};
    for (final (s, e) in eps) {
      bySeason.putIfAbsent(s, () => <int>{}).add(e);
    }
    final seasons = bySeason.keys.toList()..sort();
    return [
      for (final s in seasons)
        {
          'number': s,
          'episodes': [
            for (final e in (bySeason[s]!.toList()..sort())) {'number': e}
          ],
        }
    ];
  }

  // ---- the run --------------------------------------------------------------

  static bool get canRun {
    try {
      return Get.find<SimklService>().isLoggedIn.value;
    } catch (_) {
      return false;
    }
  }

  static Future<SimklSendSummary> run() async {
    final summary = SimklSendSummary();
    if (running.value) return summary;
    running.value = true;
    final client = SimklHttpClient(http.Client());
    try {
      await _sendMoviesAndTv(client, summary);
      await _sendAnime(client, summary);
    } finally {
      client.close();
      running.value = false;
      progress.value = '';
    }
    Logger.i('Send everything to Simkl: ${summary.text}');
    return summary;
  }

  static Future<bool> _post(
      SimklHttpClient client, String path, Map<String, dynamic> body) async {
    final token = AuthKeys.simklAuthToken.get<String?>();
    final apiKey = SimklAuthV2.clientId;
    if (token == null || token.isEmpty || apiKey == null) return false;
    try {
      final r = await client
          .post(Uri.parse('https://api.simkl.com$path'),
              headers: {
                ...SimklAuthV2.baseHeaders,
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
                'simkl-api-key': apiKey,
              },
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 40));
      final ok = r.statusCode >= 200 && r.statusCode < 300;
      if (!ok) Logger.i('Simkl $path: HTTP ${r.statusCode}');
      return ok;
    } catch (e) {
      Logger.i('Simkl $path failed: $e');
      return false;
    }
  }

  /// Sends [items] under [key] in batches.
  static Future<void> _postBatched(SimklHttpClient client, String path,
      String key, List<Map<String, dynamic>> items, SimklSendSummary summary,
      {Map<String, dynamic> extra = const {}}) async {
    for (var i = 0; i < items.length; i += _batch) {
      final part = items.sublist(
          i, i + _batch > items.length ? items.length : i + _batch);
      final ok = await _post(client, path, {...extra, key: part});
      if (!ok) summary.failedRequests++;
    }
  }

  static Future<void> _sendMoviesAndTv(
      SimklHttpClient client, SimklSendSummary summary) async {
    if (!Get.isRegistered<StremioService>()) return;
    final service = StremioService.to;
    if (!service.isLoggedIn.value) return;
    progress.value = 'Reading your Stremio library…';
    final items = service.allLibraryItems
        .where((i) => i.id.startsWith('tt') && i.type != 'other')
        .toList();

    final movies = <Map<String, dynamic>>[];
    final shows = <Map<String, dynamic>>[];
    final watching = <Map<String, dynamic>>[];
    final planned = <String, List<Map<String, dynamic>>>{
      'movies': [],
      'shows': [],
    };

    final series = items.where((i) => i.type == 'series').toList();
    for (final item in items.where((i) => i.type == 'movie')) {
      final ids = {'imdb': item.id};
      final watched = item.timesWatched > 0 || item.flaggedWatched > 0;
      if (watched) {
        movies.add({
          'ids': ids,
          if (item.lastWatched != null)
            'watched_at': item.lastWatched!.toUtc().toIso8601String(),
        });
      } else if (item.isInLibrary) {
        planned['movies']!.add({'ids': ids});
      }
    }

    for (var n = 0; n < series.length; n++) {
      final item = series[n];
      progress.value = 'Movies & TV: show ${n + 1} of ${series.length}…';
      final ids = {'imdb': item.id};
      final eps = <(int, int)>{};
      if ((item.watchedField ?? '').isNotEmpty) {
        try {
          final meta = await service.fetchMeta('series', item.id);
          if (meta != null && meta.videos.isNotEmpty) {
            final order = WatchedBitField.orderedVideoIds(meta.videos);
            final field = WatchedBitField.construct(item.watchedField, order);
            for (final v in order) {
              if (!field.getVideo(v)) continue;
              final se = seasonEpisode(v);
              if (se != null && se.$1 > 0) eps.add(se);
            }
          }
        } catch (_) {}
      }
      final current = item.videoId;
      final inProgress = item.isInContinueWatching && current != null;
      if (eps.isNotEmpty) {
        shows.add({'ids': ids, 'seasons': seasonsFor(eps)});
        summary.episodes += eps.length;
      }
      if (inProgress) {
        watching.add({'ids': ids});
      } else if (eps.isEmpty && item.isInLibrary) {
        planned['shows']!.add({'ids': ids});
      }
    }

    progress.value = 'Sending Movies & TV to Simkl…';
    await _postBatched(client, '/sync/history', 'movies', movies, summary);
    await _postBatched(client, '/sync/history', 'shows', shows, summary);
    await _postBatched(client, '/sync/add-to-list', 'shows', watching, summary,
        extra: {'to': 'watching'});
    for (final e in planned.entries) {
      await _postBatched(client, '/sync/add-to-list', e.key, e.value, summary,
          extra: {'to': 'plantowatch'});
    }
    summary.movies = movies.length;
    summary.shows = {
      ...shows.map((s) => (s['ids'] as Map)['imdb']),
      ...watching.map((s) => (s['ids'] as Map)['imdb']),
    }.length;
  }

  static Future<void> _sendAnime(
      SimklHttpClient client, SimklSendSummary summary) async {
    if (!Get.isRegistered<AnilistAuth>()) return;
    final auth = Get.find<AnilistAuth>();
    if (!auth.isLoggedIn.value) return;
    progress.value = 'Sending your AniList anime to Simkl…';
    final byStatus = <String, List<Map<String, dynamic>>>{};
    final history = <Map<String, dynamic>>[];
    final ratings = <Map<String, dynamic>>[];
    final seen = <int>{};
    for (final m in auth.animeList) {
      if ((m.type ?? 'ANIME').toUpperCase() == 'MANGA') continue;
      final ids = animeIds(m);
      if (ids == null || !seen.add(ids['anilist'] as int)) continue;
      final status = simklStatus(m.watchingStatus);
      if (status == null) continue;
      byStatus.putIfAbsent(status, () => []).add({'ids': ids});
      final progressEps = m.userProgress ??
          int.tryParse(m.episodeCount ?? '') ??
          0;
      if (status != 'plantowatch' && progressEps > 0) {
        history.add({'ids': ids, 'episodes': episodesUpTo(progressEps)});
      }
      final rating = simklRating(m.score);
      if (rating != null) ratings.add({'ids': ids, 'rating': rating});
    }
    // Episodes first, then the status (so "watching" isn't turned into
    // "completed" by the history), then scores.
    await _postBatched(client, '/sync/history', 'anime', history, summary);
    for (final e in byStatus.entries) {
      await _postBatched(client, '/sync/add-to-list', 'anime', e.value, summary,
          extra: {'to': e.key});
    }
    await _postBatched(client, '/sync/ratings', 'anime', ratings, summary);
    summary.anime = seen.length;
    summary.ratings = ratings.length;
  }
}

/// The Settings → Accounts tile.
class PlusSimklSendAllTile extends StatelessWidget {
  const PlusSimklSendAllTile({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final busy = PlusSimklSendAll.running.value;
      final status = PlusSimklSendAll.progress.value;
      final can = PlusSimklSendAll.canRun;
      return AnymeXTile(
        icon: Icons.cloud_upload_rounded,
        title: 'Send everything to Simkl',
        subtitle: busy
            ? (status.isEmpty ? 'Working…' : status)
            : can
                ? 'Your Movies & TV history and AniList anime list. Safe to '
                    'run again'
                : 'Log in to Simkl above to use this',
        subtitleStyle: busy ? TextStyle(color: context.colors.primary) : null,
        showChevron: false,
        onTap: (!can || busy)
            ? null
            : () async {
                final go = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Send everything to Simkl?'),
                    content: const Text(
                        'Sends your whole Movies & TV watch history (episodes '
                        'in progress included) and your AniList anime list '
                        '(status, episode progress, scores). Anything already '
                        'on Simkl is just updated. Big libraries take a few '
                        'minutes.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: const Text('Send')),
                    ],
                  ),
                );
                if (go != true) return;
                final summary = await PlusSimklSendAll.run();
                snackBar(summary.text, duration: 4000);
              },
      );
    });
  }
}
