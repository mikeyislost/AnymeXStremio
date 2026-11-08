// AnymeX+: part of StremioService. Progress from AnymeX's trackers to
// Stremio: which Stremio entry an anime uses (and your pick), anime <->
// Kitsu/IMDb lookups, comment ids.
// uses (and your pick), anime ↔ Kitsu/IMDb lookups, comment ids.

part of 'stremio_service.dart';

extension StremioServiceSync on StremioService {
  // ---- playback sync --------------------------------------------------------

  /// Stremio's saved position for a Stremio-native item, from the cache that
  /// the details page fills. 0 when unknown.
  int resumePositionMs(anymex.Media media, Episode episode) {
    final parsed = StremioIds.parse(media.id);
    if (parsed == null) return 0;
    final item = _libraryCache[parsed.$2];
    if (item == null || item.timeOffset <= 1) return 0;
    final link = episode.link;
    final matches = item.videoId == null ||
        item.videoId == link ||
        (link == null && item.videoId == parsed.$2);
    if (!matches) return 0;
    if (item.duration > 0 && item.timeOffset > item.duration * StremioService.creditsThreshold) {
      return 0;
    }
    return item.timeOffset;
  }

  /// Resolves what [media]/[episode] correspond to in Stremio, or null when
  /// it can't be mapped (or syncing is off for that kind of media).
  Future<StremioPlayback?> playbackFor(
      anymex.Media media, Episode episode) async {
    final parsed = StremioIds.parse(media.id);
    if (parsed != null) {
      final (type, metaId) = parsed;
      final meta = await fetchMeta(type, metaId);
      final videoId = (episode.link != null && episode.link!.isNotEmpty)
          ? episode.link!
          : (meta?.singleVideoId ?? metaId);
      return StremioPlayback(
        libraryId: metaId,
        type: meta?.type ?? type,
        name: meta?.name ?? media.title,
        poster: meta?.poster ?? media.poster,
        videoId: videoId,
        videos: meta?.videos ?? const [],
      );
    }
    if (!syncAnime.value) return null;
    return _animePlayback(media, episode);
  }

  Future<StremioPlayback?> _animePlayback(
      anymex.Media media, Episode episode) async {
    final service = media.serviceType;
    String? param;
    String? id;
    if (service == ServicesType.anilist) {
      param = 'anilist_id';
      id = media.id;
    } else if (service == ServicesType.mal) {
      param = 'mal_id';
      id = media.id;
    } else if (media.idMal.isNotEmpty && media.idMal != '0') {
      param = 'mal_id';
      id = media.idMal;
    }
    if (param == null || id == null || id.isEmpty) return null;
    final epNum = episode.number.split('.').first;
    final cacheKey = '$param:$id:$epNum';
    if (_animePlaybackCache.containsKey(cacheKey)) {
      return _animePlaybackCache[cacheKey];
    }

    final mapKey = '$param:$id';
    if (!_animeMappings.containsKey(mapKey)) {
      _animeMappings[mapKey] = await _fetchAnimeMapping(param, id);
    }
    final mapping = _animeMappings[mapKey];
    if (mapping == null) return null;

    final isMovie = mapping.isMovie || media.format.toUpperCase() == 'MOVIE';
    final kitsuLib =
        mapping.kitsuId != null ? 'kitsu:${mapping.kitsuId}' : null;
    final imdbLib = mapping.imdbId;
    final kitsuOk = kitsuLib != null &&
        addons.any((a) =>
            a.supports('meta', 'series', kitsuLib) ||
            a.supports('meta', 'movie', kitsuLib) ||
            a.supports('meta', 'anime', kitsuLib));
    // IMDb ids only when ani.zip says which season/episode is which.
    final imdbOk = imdbLib != null &&
        (isMovie || mapping.imdbEpisodes.isNotEmpty);

    // AnymeX+: use the entry the Stremio library already has for this show
    // (watched in Stremio under its IMDb or Kitsu id), so progress lands on
    // the same title instead of a second copy. New entries prefer the
    // IMDb/Cinemeta title Stremio itself shows, else Kitsu. Decided once per
    // show so every episode goes to the same entry.
    final existingImdb = imdbOk ? await getLibraryItem(imdbLib) : null;
    final existingKitsu =
        kitsuLib != null ? await getLibraryItem(kitsuLib) : null;
    var useImdb = _routeChoices[mapKey] ?? _animeRoutes[mapKey];
    // A choice that no longer works (ids changed) falls back to automatic.
    if (useImdb == true && !imdbOk) useImdb = null;
    if (useImdb == false && kitsuLib == null) useImdb = null;
    if (useImdb == null) {
      if (existingImdb != null && existingKitsu != null) {
        final a = existingImdb.lastWatched ?? existingImdb.mtime;
        final b = existingKitsu.lastWatched ?? existingKitsu.mtime;
        useImdb = b == null || (a != null && !a.isBefore(b));
      } else if (existingImdb != null) {
        useImdb = true;
      } else if (existingKitsu != null) {
        useImdb = false;
      } else {
        useImdb = imdbOk || !kitsuOk;
      }
      _animeRoutes[mapKey] = useImdb;
    }

    StremioPlayback? playback;
    if (!useImdb && kitsuLib != null) {
      final libId = kitsuLib;
      StremioMeta? meta;
      for (final t in isMovie
          ? ['movie', 'series', 'anime']
          : ['series', 'anime', 'movie']) {
        meta = await fetchMeta(t, libId);
        if (meta != null) break;
      }
      final type = existingKitsu?.type ??
          meta?.type ??
          (isMovie ? 'movie' : 'series');
      final single = isMovie || (meta?.isSingleVideo ?? false);
      playback = StremioPlayback(
        libraryId: libId,
        type: type,
        name: meta?.name ?? existingKitsu?.name ?? media.title,
        poster: meta?.poster ?? existingKitsu?.poster ?? media.poster,
        videoId: single ? (meta?.defaultVideoId ?? libId) : '$libId:$epNum',
        videos: meta?.videos ?? const [],
      );
    } else if (imdbLib != null) {
      final libId = imdbLib;
      final type = existingImdb?.type ?? (isMovie ? 'movie' : 'series');
      final meta = await fetchMeta(type, libId);
      String videoId;
      if (isMovie) {
        videoId = libId;
      } else {
        final se = _imdbEpisodeFor(mapping, epNum);
        videoId = '$libId:${se.$1}:${se.$2}';
      }
      playback = StremioPlayback(
        libraryId: libId,
        type: meta?.type ?? type,
        name: meta?.name ?? existingImdb?.name ?? media.title,
        poster: meta?.poster ?? existingImdb?.poster ?? media.poster,
        videoId: videoId,
        videos: meta?.videos ?? const [],
      );
    }
    _animePlaybackCache[cacheKey] = playback;
    return playback;
  }

  /// Which Stremio entry an anime's progress syncs to, and the other one
  /// it could use instead (for the Watch tab). Null when it has no match.
  Future<StremioSyncEntry?> syncEntryFor(anymex.Media media) async {
    final key = _mappingKey(media);
    if (key == null) return null;
    final mapKey = '${key.$1}:${key.$2}';
    final pb = await _animePlayback(media, Episode(number: '1'));
    if (pb == null) return null;
    final mapping = _animeMappings[mapKey];
    final isMovie =
        (mapping?.isMovie ?? false) || media.format.toUpperCase() == 'MOVIE';
    final imdbOk = mapping?.imdbId != null &&
        (isMovie || (mapping?.imdbEpisodes.isNotEmpty ?? false));
    final kitsuId =
        mapping?.kitsuId != null ? 'kitsu:${mapping!.kitsuId}' : null;
    final isImdb = !pb.libraryId.startsWith('kitsu:');
    final otherId = isImdb ? kitsuId : (imdbOk ? mapping?.imdbId : null);
    String? otherName;
    if (otherId != null) {
      final cached = _libraryCache[otherId];
      otherName = cached?.name;
      if (otherName == null || otherName.isEmpty) {
        final types = otherId.startsWith('kitsu:')
            ? (isMovie ? ['movie', 'series', 'anime'] : ['series', 'anime', 'movie'])
            : [isMovie ? 'movie' : 'series'];
        for (final t in types) {
          final m = await fetchMeta(t, otherId);
          if (m != null) {
            otherName = m.name;
            break;
          }
        }
      }
    }
    return StremioSyncEntry(
      id: pb.libraryId,
      name: pb.name,
      inLibrary: _libraryCache.containsKey(pb.libraryId),
      chosenByYou: _routeChoices.containsKey(mapKey),
      otherId: otherId,
      otherName: otherName,
      otherInLibrary: otherId != null && _libraryCache.containsKey(otherId),
    );
  }

  /// The Stremio entries (IMDb and Kitsu ids) of these AniList anime, as far
  /// as they're matched already. The rest are matched in the background
  /// (from the phone's cache first) and [animeMatchesVersion] goes up.
  Set<String> stremioIdsForAnilist(Iterable<String> anilistIds) {
    final out = <String>{};
    final missing = <String>[];
    for (final id in anilistIds) {
      final key = 'anilist_id:$id';
      if (_animeMappings.containsKey(key)) {
        final m = _animeMappings[key];
        if (m?.imdbId != null) out.add(m!.imdbId!);
        if (m?.kitsuId != null) out.add('kitsu:${m!.kitsuId}');
      } else {
        missing.add(id);
      }
    }
    if (missing.isNotEmpty) unawaited(_warmMappings(missing));
    return out;
  }

  Future<void> _warmMappings(List<String> ids) async {
    final todo = ids.where(_warming.add).take(40).toList();
    var found = false;
    for (final id in todo) {
      final key = 'anilist_id:$id';
      if (_animeMappings.containsKey(key)) continue;
      try {
        final m = await _fetchAnimeMapping('anilist_id', id);
        // Only real matches are kept, so a failed lookup (offline) is tried
        // again by sync later.
        if (m != null) {
          _animeMappings[key] = m;
          found = true;
        }
      } catch (_) {}
    }
    if (found) animeMatchesVersion.value++;
  }

  /// Sends this anime's progress to its IMDb ([useImdb]) or Kitsu entry
  /// from now on.
  void setSyncEntry(anymex.Media media, {required bool useImdb}) {
    final key = _mappingKey(media);
    if (key == null) return;
    final mapKey = '${key.$1}:${key.$2}';
    _routeChoices[mapKey] = useImdb;
    _animeRoutes[mapKey] = useImdb;
    _animePlaybackCache.removeWhere((k, _) => k.startsWith('$mapKey:'));
    KvHelper.set(StremioService._kSyncRoutes, jsonEncode(_routeChoices));
  }

  // ---- AnymeX tracker progress → Stremio ------------------------------------

  /// Called whenever AnymeX updates AniList / MyAnimeList progress (player,
  /// +1 buttons, list editor). Marks those episodes watched in Stremio and,
  /// when nothing is playing, moves Continue Watching to the next episode.
  void onTrackerProgress({
    required ServicesType service,
    required String mediaId,
    int? progress,
    String? status,
    String? title,
    String? poster,
  }) {
    if (_suppressTrackerHook) return;
    if (!isLoggedIn.value || !syncEnabled.value || !syncAnime.value) return;
    if (progress == null || progress <= 0) return;
    unawaited(_applyTrackerProgress(
        service, mediaId, progress, status, title, poster));
  }

  Future<void> _applyTrackerProgress(ServicesType service, String mediaId,
      int progress, String? status, String? title, String? poster) async {
    final authKey = _authKey;
    if (authKey == null) return;
    try {
      final media = anymex.Media(
        id: mediaId,
        title: title ?? '?',
        poster: poster ?? '',
        serviceType: service,
      );
      final pb = await _animePlayback(media, Episode(number: '$progress'));
      if (pb == null) {
        Logger.i('AnymeX → Stremio: no Stremio match for $mediaId');
        return;
      }
      final item = await getLibraryItem(pb.libraryId) ??
          StremioLibraryItem.create(
            id: pb.libraryId,
            type: pb.type,
            name: pb.name,
            poster: pb.poster,
          );
      if (item.name.isEmpty || item.name == '?') item.raw['name'] = pb.name;

      // Mark every episode up to `progress` as watched.
      if (pb.videos.isNotEmpty) {
        final wb = WatchedBitField.construct(
            item.watchedField, WatchedBitField.orderedVideoIds(pb.videos));
        for (var n = 1; n <= progress; n++) {
          final epPb = await _animePlayback(media, Episode(number: '$n'));
          if (epPb != null) wb.setVideo(epPb.videoId, true);
        }
        item.watchedField = wb.serialize();
      }
      item.lastWatched = DateTime.now();

      // Don't move Continue Watching while the player is reporting itself.
      final recent = _recentPlayback[mediaId];
      final playing = recent != null &&
          DateTime.now().difference(recent) < const Duration(minutes: 3);
      if (!playing) {
        final completed = (status ?? '').toUpperCase() == 'COMPLETED';
        final next = await _animePlayback(media, Episode(number: '${progress + 1}'));
        final nextExists = next != null &&
            next.videoId != pb.videoId &&
            (pb.videos.isEmpty ||
                pb.videos.any((v) => v.id == next.videoId && v.isReleased));
        if (!completed && nextExists) {
          item.videoId = next.videoId;
          item.overallTimeWatched = item.overallTimeWatched + item.timeWatched;
          item.timeWatched = 0;
          item.flaggedWatched = 0;
          item.timeOffset = 1;
        } else {
          item.timeOffset = 0;
        }
      }
      item.touch();
      _libraryCache[item.id] = item;
      _rebuildLists();
      await _putOrQueue(authKey, item);
      Logger.i('AnymeX → Stremio: ${pb.libraryId} watched up to $progress');
    } catch (e) {
      Logger.i('AnymeX → Stremio sync failed for $mediaId: $e');
    }
  }

  /// For the self test: what an AniList/MAL anime maps to in Stremio.
  Future<String> describeAnimeMapping(
      ServicesType service, String mediaId, int episode) async {
    final media = anymex.Media(id: mediaId, serviceType: service);
    final pb = await _animePlayback(media, Episode(number: '$episode'));
    if (pb == null) {
      throw Exception('no Stremio match (no Kitsu/IMDb mapping for $mediaId)');
    }
    final existing =
        isLoggedIn.value ? await getLibraryItem(pb.libraryId) != null : false;
    return '${pb.libraryId} → ${pb.videoId} ("${pb.name}", ${pb.type}, '
        '${pb.videos.length} videos in meta, '
        '${existing ? 'your existing Stremio entry' : 'new Stremio entry'})';
  }

  /// For the self test: AniList id for a Kitsu id / IMDb id.
  Future<String?> debugAnilistFromKitsu(String kitsuId) =>
      _anilistFromKitsu(kitsuId);

  Future<List<String>> debugAnilistFromImdb(String imdbId) =>
      _anilistFromImdb(imdbId);

  Future<String> commentMediaId(StremioMeta meta, {int? season}) async {
    final cacheKey = '${meta.id}|${season ?? 0}';
    final cached = _commentIds[cacheKey];
    if (cached != null) return cached;
    String id = meta.id.replaceAll(':', '_');
    try {
      final handler = Get.find<ServiceHandler>();
      final usesAnilist = handler.serviceType.value == ServicesType.anilist ||
          (handler.serviceType.value == ServicesType.extensions &&
              handler.anilistService.isLoggedIn.value);
      if (usesAnilist) {
        String? anilistId;
        if (meta.id.startsWith('kitsu:')) {
          anilistId = await _anilistFromKitsu(meta.id.split(':')[1]);
        } else if (meta.id.startsWith('tt')) {
          final candidates = await _anilistFromImdb(meta.id);
          if (candidates.length == 1 || (candidates.isNotEmpty && season == null)) {
            anilistId = candidates.first;
          } else if (candidates.isNotEmpty) {
            for (final c in candidates.take(8)) {
              final eps = await _aniZipEpisodesFor(c);
              if (eps != null && eps.values.any((v) => v.$1 == season)) {
                anilistId = c;
                break;
              }
            }
            anilistId ??= candidates.first;
          }
        }
        if (anilistId != null) id = anilistId;
      }
    } catch (e) {
      Logger.i('Stremio comment id lookup failed: $e');
    }
    _commentIds[cacheKey] = id;
    return id;
  }

  Future<String?> _anilistFromKitsu(String kitsuId) async {
    final diskKey = 'kitsu2anilist|$kitsuId';
    final saved = await StremioDiskCache.read(diskKey);
    if (saved != null) {
      final v = saved.value;
      if (v is String && v.isNotEmpty && saved.isFresherThan(const Duration(days: 30))) {
        return v;
      }
      if (v == null && saved.isFresherThan(const Duration(days: 1))) return null;
    }
    final id = await _anilistFromKitsuNetwork(kitsuId);
    unawaited(StremioDiskCache.write(diskKey, id));
    return id;
  }

  Future<String?> _anilistFromKitsuNetwork(String kitsuId) async {
    try {
      final resp = await http
          .get(Uri.parse(
              'https://arm.haglund.dev/api/v2/ids?source=kitsu&id=$kitsuId'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200 && resp.body.isNotEmpty) {
        final data = jsonDecode(resp.body);
        final id = data is Map ? data['anilist'] : null;
        if (id != null) return id.toString();
      }
    } catch (_) {}
    try {
      final resp = await http
          .get(Uri.parse('https://api.ani.zip/mappings?kitsu_id=$kitsuId'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final id = data is Map && data['mappings'] is Map
            ? (data['mappings'] as Map)['anilist_id']
            : null;
        if (id != null) return id.toString();
      }
    } catch (_) {}
    return null;
  }

  /// AniList ids that share this IMDb id (one per season/part), or empty
  /// when the title isn't anime.
  Future<List<String>> _anilistFromImdb(String imdbId) async {
    final diskKey = 'imdb2anilist|$imdbId';
    final saved = await StremioDiskCache.read(diskKey);
    if (saved != null && saved.value is List) {
      final ids = (saved.value as List).map((e) => e.toString()).toList();
      final maxAge =
          ids.isEmpty ? const Duration(days: 1) : const Duration(days: 30);
      if (saved.isFresherThan(maxAge)) return ids;
    }
    final ids = await _anilistFromImdbNetwork(imdbId);
    unawaited(StremioDiskCache.write(diskKey, ids));
    return ids;
  }

  Future<List<String>> _anilistFromImdbNetwork(String imdbId) async {
    try {
      final resp = await http
          .get(Uri.parse('https://arm.haglund.dev/api/v2/imdb?id=$imdbId'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200 || resp.body.isEmpty) return const [];
      final data = jsonDecode(resp.body);
      final list = data is List ? data : (data is Map ? [data] : const []);
      return list
          .whereType<Map>()
          .map((m) => m['anilist']?.toString())
          .whereType<String>()
          .where((s) => s.isNotEmpty && s != 'null')
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, (int, int)>?> _aniZipEpisodesFor(String anilistId) async {
    if (_aniZipEpisodes.containsKey(anilistId)) {
      return _aniZipEpisodes[anilistId];
    }
    final diskKey = 'anizip-eps|$anilistId';
    final saved = await StremioDiskCache.read(diskKey);
    if (saved != null && saved.value is Map &&
        saved.isFresherThan(const Duration(days: 30))) {
      final eps = <String, (int, int)>{};
      (saved.value as Map).forEach((k, x) {
        if (x is List && x.length == 2 && x[0] is int && x[1] is int) {
          eps[k.toString()] = (x[0] as int, x[1] as int);
        }
      });
      return _aniZipEpisodes[anilistId] = eps;
    }
    Map<String, (int, int)>? out;
    try {
      final resp = await http
          .get(Uri.parse('https://api.ani.zip/mappings?anilist_id=$anilistId'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is Map && data['episodes'] is Map) {
          out = {};
          (data['episodes'] as Map).forEach((k, v) {
            if (v is Map) {
              final s = int.tryParse('${v['seasonNumber'] ?? ''}');
              final e = int.tryParse('${v['episodeNumber'] ?? ''}');
              if (s != null && e != null) out![k.toString()] = (s, e);
            }
          });
        }
      }
    } catch (_) {}
    _aniZipEpisodes[anilistId] = out;
    if (out != null) {
      unawaited(StremioDiskCache.write(
          diskKey, out.map((k, v) => MapEntry(k, [v.$1, v.$2]))));
    }
    return out;
  }
}
