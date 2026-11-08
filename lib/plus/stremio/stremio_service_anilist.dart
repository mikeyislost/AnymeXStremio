// AnymeX+: part of StremioService. Stremio watches -> AniList and Simkl.

part of 'stremio_service.dart';

extension StremioServiceAnilist on StremioService {
  // ---- AniList sync for Stremio watches -----------------------------------

  /// When an anime episode/movie is watched from Movies & TV, update the
  /// AniList entry (progress only ever moves forward).
  /// A movie or episode from Movies & TV crossed the "watched" point: add it
  /// to your Simkl history. IMDb titles only (anime from Kitsu goes through
  /// AniList instead).
  Future<void> _syncToSimkl(StremioPlayback pb) async {
    if (!syncToSimkl.value || !simklLoggedIn) return;
    if (!pb.libraryId.startsWith('tt')) return;
    final imdb = pb.libraryId.split(':').first;
    final token = AuthKeys.simklAuthToken.get<String?>();
    final apiKey = SimklAuthV2.clientId;
    if (token == null || token.isEmpty || apiKey == null) return;
    final now = DateTime.now().toUtc().toIso8601String();
    final parts = pb.videoId.split(':');
    final Map<String, dynamic> body;
    if (parts.length >= 3) {
      final season = int.tryParse(parts[1]);
      final episode = int.tryParse(parts[2]);
      if (season == null || episode == null) return;
      body = {
        'shows': [
          {
            'ids': {'imdb': imdb},
            'seasons': [
              {
                'number': season,
                'episodes': [
                  {'number': episode, 'watched_at': now}
                ],
              }
            ],
          }
        ]
      };
    } else {
      body = {
        'movies': [
          {
            'ids': {'imdb': imdb},
            'watched_at': now,
          }
        ]
      };
    }
    final client = SimklHttpClient(http.Client());
    try {
      final r = await client
          .post(Uri.parse('https://api.simkl.com/sync/history'),
              headers: {
                ...SimklAuthV2.baseHeaders,
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
                'simkl-api-key': apiKey,
              },
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 15));
      Logger.i('Movies & TV → Simkl: ${pb.videoId} (HTTP ${r.statusCode})');
    } catch (e) {
      Logger.i('Movies & TV → Simkl failed for ${pb.videoId}: $e');
    } finally {
      client.close();
    }
  }

  Future<void> _syncToAnilist(StremioPlayback pb) async {
    if (!syncToAnilist.value) return;
    try {
      final handler = Get.find<ServiceHandler>();
      final anilist = handler.anilistService;
      if (!anilist.isLoggedIn.value) return;
      final target = await _anilistTargetFor(pb);
      if (target == null) return;
      final (anilistId, progress) = target;
      if (progress <= 0) return;

      final entry =
          anilist.animeList.firstWhereOrNull((m) => m.id == anilistId);
      final current = int.tryParse(entry?.episodeCount ?? '') ?? 0;
      if (entry != null && current >= progress) return;
      final total = int.tryParse(entry?.totalEpisodes ?? '');
      final repeating =
          (entry?.watchingStatus ?? '').toUpperCase() == 'REPEATING';
      final status = (total != null && total > 0 && progress >= total)
          ? 'COMPLETED'
          : (repeating ? 'REPEATING' : 'CURRENT');
      _suppressTrackerHook = true;
      try {
        await anilist.updateListEntry(UpdateListEntryParams(
          listId: anilistId,
          progress: progress,
          status: status,
          isAnime: true,
        ));
      } finally {
        _suppressTrackerHook = false;
      }
      Logger.i('Stremio → AniList: $anilistId progress $progress ($status)');
    } catch (e) {
      Logger.i('Stremio → AniList sync failed: $e');
    }
  }

  /// (AniList id, episode progress) for a Stremio video, or null when it
  /// isn't anime / can't be matched.
  Future<(String, int)?> _anilistTargetFor(StremioPlayback pb) async {
    final key = pb.videoId;
    if (_anilistTargets.containsKey(key)) return _anilistTargets[key];
    (String, int)? result;
    try {
      final isMovie = pb.type == 'movie' || pb.videoId == pb.libraryId;
      if (pb.libraryId.startsWith('kitsu:')) {
        final kitsuId = pb.libraryId.split(':')[1];
        final anilistId = await _anilistFromKitsu(kitsuId);
        if (anilistId != null) {
          final parts = pb.videoId.split(':');
          final ep = isMovie || parts.length < 3 ? 1 : int.tryParse(parts[2]);
          if (ep != null) result = (anilistId, ep);
        }
      } else if (pb.libraryId.startsWith('tt')) {
        final candidates = await _anilistFromImdb(pb.libraryId);
        if (candidates.isNotEmpty) {
          if (isMovie) {
            result = (candidates.first, 1);
          } else {
            final parts = pb.videoId.split(':');
            final s = parts.length >= 3 ? int.tryParse(parts[1]) : null;
            final e = parts.length >= 3 ? int.tryParse(parts[2]) : null;
            if (s != null && e != null) {
              for (final id in candidates.take(8)) {
                final eps = await _aniZipEpisodesFor(id);
                if (eps == null) continue;
                for (final entry in eps.entries) {
                  if (entry.value.$1 == s && entry.value.$2 == e) {
                    final n = int.tryParse(entry.key);
                    if (n != null) result = (id, n);
                    break;
                  }
                }
                if (result != null) break;
              }
              if (result == null && candidates.length == 1 && s == 1) {
                result = (candidates.first, e);
              }
            }
          }
        }
      }
    } catch (e) {
      Logger.i('Stremio → AniList mapping failed for ${pb.videoId}: $e');
    }
    _anilistTargets[key] = result;
    return result;
  }
}
