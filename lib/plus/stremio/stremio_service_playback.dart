// AnymeX+: part of StremioService. Anime streams and playback: matching
// anime to your stream addons, episode lists, playback progress reports to
// Stremio, Continue Watching.
// lists, playback progress reports to Stremio, Continue Watching.

part of 'stremio_service.dart';

extension StremioServicePlayback on StremioService {
  // ---- anime Watch tab → Stremio streams -----------------------------------

  void setAnimeStreamSource(String value) {
    animeStreamSource.value = value;
    KvHelper.set(StremioService._kAnimeStreamSource, value);
  }

  /// Whether any installed addon serves streams.
  bool get hasStreamAddons =>
      addons.any((a) => isAddonUsable(a) && a.hasResource('stream'));

  (String, String)? _mappingKey(anymex.Media media) {
    final service = media.serviceType;
    if (service == ServicesType.anilist && media.id.isNotEmpty) {
      return ('anilist_id', media.id);
    }
    if (service == ServicesType.mal && media.id.isNotEmpty) {
      return ('mal_id', media.id);
    }
    if (media.idMal.isNotEmpty && media.idMal != '0') {
      return ('mal_id', media.idMal);
    }
    return null;
  }

  /// Matches an anime to ids the user's stream addons accept and lists its
  /// episodes as Stremio video ids. Null when it can't be matched.
  Future<StremioAnimeTarget?> animeTarget(anymex.Media media,
      {bool refresh = false}) async {
    final key = _mappingKey(media);
    if (key == null) return null;
    final mapKey = '${key.$1}:${key.$2}';
    if (!refresh && _animeTargets.containsKey(mapKey)) {
      return _animeTargets[mapKey];
    }
    await ensureAddons();
    if (refresh || !_animeMappings.containsKey(mapKey)) {
      _animeMappings[mapKey] =
          await _fetchAnimeMapping(key.$1, key.$2, refresh: refresh);
    }
    final mapping = _animeMappings[mapKey];
    if (mapping == null) return null;

    final isMovieHint = mapping.isMovie ||
        media.format.toUpperCase() == 'MOVIE' ||
        (media.totalEpisodes == '1' &&
            media.format.toUpperCase() == 'SPECIAL');
    final streamAddons = addons
        .where((a) => isAddonUsable(a) && a.hasResource('stream'))
        .toList();

    List<String> acceptedBy(String id, String type) => streamAddons
        .where((a) =>
            a.supports('stream', type, id) || a.supports('stream', 'anime', id))
        .map((a) => a.name)
        .toList();

    StremioAnimeTarget? target;

    // Kitsu ids first: one id per AniList entry, episodes numbered the same.
    if (mapping.kitsuId != null) {
      final libId = 'kitsu:${mapping.kitsuId}';
      StremioMeta? meta;
      for (final t in isMovieHint
          ? ['movie', 'series', 'anime']
          : ['series', 'anime', 'movie']) {
        meta = await fetchMeta(t, libId);
        if (meta != null) break;
      }
      final isMovie = isMovieHint ||
          (meta != null && (meta.isSingleVideo || meta.type == 'movie'));
      final type = isMovie ? 'movie' : 'series';
      final names = acceptedBy(isMovie ? libId : '$libId:1', type);
      if (names.isNotEmpty) {
        target = StremioAnimeTarget(
          type: type,
          libraryId: libId,
          meta: meta,
          isMovie: isMovie,
          addonNames: names,
          episodes: isMovie
              ? [_movieEpisode(media, meta, meta?.defaultVideoId ?? libId)]
              : _kitsuEpisodes(media, meta, libId),
        );
      }
    }

    // Otherwise IMDb ids (season/episode from ani.zip).
    if (target == null && mapping.imdbId != null) {
      final libId = mapping.imdbId!;
      final isMovie = isMovieHint;
      final type = isMovie ? 'movie' : 'series';
      final meta = await fetchMeta(type, libId);
      final names = acceptedBy(isMovie ? libId : '$libId:1:1', type);
      if (names.isNotEmpty) {
        target = StremioAnimeTarget(
          type: type,
          libraryId: libId,
          meta: meta,
          isMovie: isMovie,
          addonNames: names,
          episodes: isMovie
              ? [_movieEpisode(media, meta, libId)]
              : _imdbEpisodes(media, meta, libId, mapping),
        );
      }
    }

    _animeTargets[mapKey] = target;
    return target;
  }

  /// IMDb (season, episode) for an AniList episode number. Episodes ani.zip
  /// doesn't list yet continue on from the last one it does.
  (int, int) _imdbEpisodeFor(_AnimeMapping mapping, String epNum) {
    final exact = mapping.imdbEpisodes[epNum];
    if (exact != null) return exact;
    final n = int.tryParse(epNum) ?? 1;
    var bestK = 0;
    (int, int)? best;
    for (final entry in mapping.imdbEpisodes.entries) {
      final kn = int.tryParse(entry.key) ?? 0;
      if (kn < n && kn > bestK) {
        bestK = kn;
        best = entry.value;
      }
    }
    if (best != null) return (best.$1, best.$2 + (n - bestK));
    return (1, n);
  }

  /// Released episode count for an anime from AniList/MAL data.
  int _releasedEpisodes(anymex.Media media) {
    final total = int.tryParse(media.totalEpisodes) ?? 0;
    final next = media.nextAiringEpisode?.episode;
    if (next != null && next > 1) {
      return total > 0 ? (next - 1).clamp(1, total) : next - 1;
    }
    return total;
  }

  Episode _movieEpisode(anymex.Media media, StremioMeta? meta, String videoId) {
    return Episode(
      number: '1',
      title: meta?.name ?? media.title,
      link: videoId,
      thumbnail: meta?.background ?? media.cover ?? media.poster,
      desc: meta?.description,
      source: 'Stremio',
    );
  }

  List<Episode> _kitsuEpisodes(
      anymex.Media media, StremioMeta? meta, String libId) {
    final byNumber = <int, StremioVideo>{};
    for (final v in meta?.videos ?? const <StremioVideo>[]) {
      final n = v.episode ?? int.tryParse(v.id.split(':').last);
      if (n != null) byNumber[n] = v;
    }
    var count = _releasedEpisodes(media);
    if (byNumber.isNotEmpty) {
      final released = byNumber.entries
          .where((e) => e.value.isReleased)
          .map((e) => e.key)
          .fold<int>(0, (a, b) => b > a ? b : a);
      if (count == 0 || released > count) count = released;
    }
    if (count <= 0) count = 1;
    return List.generate(count, (i) {
      final n = i + 1;
      final v = byNumber[n];
      return Episode(
        number: '$n',
        title: (v != null && v.title.isNotEmpty) ? v.title : 'Episode $n',
        link: v?.id ?? '$libId:$n',
        thumbnail: v?.thumbnail,
        desc: v?.overview,
        dateUpload: v?.released?.toIso8601String(),
        source: 'Stremio',
      );
    });
  }

  List<Episode> _imdbEpisodes(anymex.Media media, StremioMeta? meta,
      String libId, _AnimeMapping mapping) {
    var count = _releasedEpisodes(media);
    if (count <= 0) {
      count = mapping.imdbEpisodes.keys
          .map((k) => int.tryParse(k) ?? 0)
          .fold<int>(0, (a, b) => b > a ? b : a);
    }
    if (count <= 0) count = 1;
    final videos = <String, StremioVideo>{
      for (final v in meta?.videos ?? const <StremioVideo>[]) v.id: v
    };
    return List.generate(count, (i) {
      final n = i + 1;
      final se = _imdbEpisodeFor(mapping, '$n');
      final id = '$libId:${se.$1}:${se.$2}';
      final v = videos[id];
      return Episode(
        number: '$n',
        title: (v != null && v.title.isNotEmpty) ? v.title : 'Episode $n',
        link: id,
        thumbnail: v?.thumbnail,
        desc: v?.overview,
        dateUpload: v?.released?.toIso8601String(),
        source: 'Stremio',
      );
    });
  }

  /// AniList id for a Stremio title (Kitsu or IMDb id), or null when it
  /// isn't anime. For IMDb series with one AniList entry per season,
  /// [season] picks the matching one.
  Future<String?> anilistIdFor(StremioMeta meta, {int? season}) async {
    if (meta.id.startsWith('kitsu:')) {
      return _anilistFromKitsu(meta.id.split(':')[1]);
    }
    if (!meta.id.startsWith('tt')) return null;
    final candidates = await _anilistFromImdb(meta.id);
    if (candidates.isEmpty) return null;
    if (candidates.length == 1 || season == null) return candidates.first;
    for (final c in candidates.take(8)) {
      final eps = await _aniZipEpisodesFor(c);
      if (eps != null && eps.values.any((v) => v.$1 == season)) return c;
    }
    return candidates.first;
  }

  /// ani.zip ids for an anime. Saved on the device for 30 days (a miss
  /// for a day), since they rarely change.
  Future<_AnimeMapping?> _fetchAnimeMapping(String param, String id,
      {bool refresh = false}) async {
    final diskKey = 'anizip|$param=$id';
    if (!refresh) {
      final saved = await StremioDiskCache.read(diskKey);
      final v = saved?.value;
      if (v is Map) {
        if (v['none'] == true) {
          if (saved!.isFresherThan(const Duration(days: 1))) return null;
        } else if (saved!.isFresherThan(const Duration(days: 30))) {
          final eps = <String, (int, int)>{};
          if (v['e'] is Map) {
            (v['e'] as Map).forEach((k, x) {
              if (x is List && x.length == 2 && x[0] is int && x[1] is int) {
                eps[k.toString()] = (x[0] as int, x[1] as int);
              }
            });
          }
          return _AnimeMapping(v['k']?.toString(), v['i']?.toString(),
              v['m'] == true, eps);
        }
      }
    }
    final mapping = await _fetchAnimeMappingNetwork(param, id);
    unawaited(StremioDiskCache.write(
        diskKey,
        mapping == null
            ? {'none': true}
            : {
                'k': mapping.kitsuId,
                'i': mapping.imdbId,
                'm': mapping.isMovie,
                'e': mapping.imdbEpisodes
                    .map((k, v) => MapEntry(k, [v.$1, v.$2])),
              }));
    return mapping;
  }

  Future<_AnimeMapping?> _fetchAnimeMappingNetwork(
      String param, String id) async {
    try {
      final resp = await http
          .get(Uri.parse('https://api.ani.zip/mappings?$param=$id'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200 || resp.body.isEmpty) return null;
      final data = jsonDecode(resp.body);
      if (data is! Map) return null;
      final mappings = data['mappings'] is Map
          ? Map<String, dynamic>.from(data['mappings'] as Map)
          : <String, dynamic>{};
      final kitsu = mappings['kitsu_id']?.toString();
      final imdb = mappings['imdb_id']?.toString();
      final type = mappings['type']?.toString().toUpperCase() ?? '';
      final episodes = <String, (int, int)>{};
      if (data['episodes'] is Map) {
        (data['episodes'] as Map).forEach((k, v) {
          if (v is Map) {
            final s = int.tryParse('${v['seasonNumber'] ?? ''}');
            final e = int.tryParse('${v['episodeNumber'] ?? ''}');
            if (s != null && e != null && s > 0) {
              episodes[k.toString()] = (s, e);
            }
          }
        });
      }
      return _AnimeMapping(
        (kitsu != null && kitsu.isNotEmpty && kitsu != 'null') ? kitsu : null,
        (imdb != null && imdb.startsWith('tt')) ? imdb : null,
        type == 'MOVIE',
        episodes,
      );
    } catch (e) {
      Logger.i('Stremio: anime mapping failed for $param=$id: $e');
      return null;
    }
  }

  /// Called often by the player; reports to Stremio at most every
  /// [StremioService.reportInterval]. Never throws.
  void onPlaybackProgress({
    required anymex.Media media,
    required Episode episode,
    required Duration position,
    required Duration duration,
  }) {
    if (!isLoggedIn.value || !syncEnabled.value) return;
    if (duration.inMilliseconds < 1000 || position.inMilliseconds <= 0) return;
    _recentPlayback[media.id] = DateTime.now();
    final key = '${media.id}#${episode.link ?? episode.number}';
    final session =
        (_session?.key == key) ? _session! : (_session = _Session(key));
    if (session.reporting) return;
    if (DateTime.now().difference(session.lastReport) < StremioService.reportInterval) return;
    unawaited(_report(session, media, episode, position, duration,
        isFinal: false));
  }

  /// The app is going to the background: send the current position now
  /// instead of waiting for the next [StremioService.reportInterval] report, so nothing
  /// is lost if the app is then closed.
  void flushPlayback({
    required anymex.Media media,
    required Episode episode,
    required Duration position,
    required Duration duration,
  }) {
    if (!isLoggedIn.value || !syncEnabled.value) return;
    if (duration.inMilliseconds < 1000 || position.inMilliseconds <= 0) return;
    final key = '${media.id}#${episode.link ?? episode.number}';
    final session =
        (_session?.key == key) ? _session! : (_session = _Session(key));
    if (session.reporting) return;
    if (DateTime.now().difference(session.lastReport) <
        const Duration(seconds: 5)) {
      return;
    }
    unawaited(_report(session, media, episode, position, duration,
        isFinal: false));
  }

  /// Called when an episode is closed or switched. Applies the "finished"
  /// rules (advance Continue Watching to the next episode).
  void onPlaybackStopped({
    required anymex.Media media,
    required Episode episode,
    required Duration position,
    required Duration duration,
  }) {
    if (!isLoggedIn.value || !syncEnabled.value) return;
    if (duration.inMilliseconds < 1000) return;
    final key = '${media.id}#${episode.link ?? episode.number}';
    final session = (_session?.key == key) ? _session! : _Session(key);
    _session = null;
    unawaited(_report(session, media, episode, position, duration,
        isFinal: true));
  }

  Future<void> _report(
    _Session session,
    anymex.Media media,
    Episode episode,
    Duration position,
    Duration duration, {
    required bool isFinal,
  }) async {
    final authKey = _authKey;
    if (authKey == null) return;
    session.reporting = true;
    try {
      final pb = await playbackFor(media, episode);
      if (pb == null) return;

      final posMs = position.inMilliseconds;
      final durMs = duration.inMilliseconds;

      final item = await getLibraryItem(pb.libraryId) ??
          StremioLibraryItem.create(
            id: pb.libraryId,
            type: pb.type,
            name: pb.name,
            poster: pb.poster,
          );
      if (item.name.isEmpty) item.raw['name'] = pb.name;
      if (item.poster == null && pb.poster != null) {
        item.raw['poster'] = pb.poster;
      }

      item.lastWatched = DateTime.now();
      if (item.videoId != pb.videoId) {
        // Switched to a different video (e.g. next episode).
        item.videoId = pb.videoId;
        item.overallTimeWatched = item.overallTimeWatched + item.timeWatched;
        item.timeWatched = 0;
        item.flaggedWatched = 0;
        session.lastPositionMs = posMs;
      } else {
        // Count real watch time since the last report; ignore seeks.
        final elapsed = DateTime.now().difference(session.lastReport);
        var delta = posMs - session.lastPositionMs;
        final maxDelta = session.lastReport.millisecondsSinceEpoch == 0
            ? 0
            : (elapsed.inMilliseconds * 4);
        if (delta < 0 || delta > maxDelta) delta = 0;
        item.timeWatched = item.timeWatched + delta;
        item.overallTimeWatched = item.overallTimeWatched + delta;
      }
      item.timeOffset = posMs < 1 ? 1 : posMs;
      item.duration = durMs;

      WatchedBitField? wb;
      if (pb.videos.isNotEmpty) {
        wb = WatchedBitField.construct(
            item.watchedField, WatchedBitField.orderedVideoIds(pb.videos));
      }

      // AnymeX+: "watched" at the same point as AniList (your "mark as
      // watched" setting in Player settings) instead of Stremio's own 70%.
      final point = StremioService.watchedPoint;
      final watchedEnough = item.flaggedWatched == 0 &&
          item.duration > 0 &&
          (item.timeWatched > item.duration * point ||
              posMs > item.duration * point);
      if (watchedEnough) {
        item.flaggedWatched = 1;
        item.timesWatched = item.timesWatched + 1;
        if (wb != null) {
          wb.setVideo(pb.videoId, true);
          item.watchedField = wb.serialize();
        }
        // Stremio-native titles (Movies & TV) → AniList. Anime opened from
        // AniList is already tracked by AnymeX itself.
        if (StremioIds.isStremioMediaId(media.id)) {
          unawaited(_syncToAnilist(pb));
          unawaited(_syncToSimkl(pb));
        }
      }

      if (isFinal && posMs > durMs * point) {
        // Finished: move Continue Watching to the next episode, or clear it.
        item.timeOffset = 0;
        final next = pb.nextVideo;
        if (next != null) {
          item.videoId = next.id;
          item.overallTimeWatched = item.overallTimeWatched + item.timeWatched;
          item.timeWatched = 0;
          item.flaggedWatched = 0;
          item.timeOffset = 1;
        }
      }

      item.touch();
      _libraryCache[item.id] = item;
      await _putOrQueue(authKey, item);

      session.lastReport = DateTime.now();
      session.lastPositionMs = posMs;
      _updateContinueWatching(item);
    } catch (e) {
      Logger.i('Stremio: progress sync failed: $e');
      // Back off a little before retrying.
      session.lastReport = DateTime.now();
    } finally {
      session.reporting = false;
    }
  }

  void _updateContinueWatching(StremioLibraryItem item) {
    _libraryCache[item.id] = item;
    _rebuildLists();
  }

  /// Recomputes Continue Watching and the library from the local cache,
  /// with the same rules Stremio uses.
  void _rebuildLists({bool save = true}) {
    if (save) _scheduleLibrarySave();
    final all = _libraryCache.values.toList();
    DateTime watched(StremioLibraryItem i) =>
        i.lastWatched ?? i.mtime ?? DateTime(1970);
    DateTime modified(StremioLibraryItem i) => i.mtime ?? DateTime(1970);
    continueWatching.assignAll(all.where((i) => i.isInContinueWatching).toList()
      ..sort((a, b) => watched(b).compareTo(watched(a))));
    library.assignAll(all.where((i) => i.isInLibrary).toList()
      ..sort((a, b) => modified(b).compareTo(modified(a))));
  }

  Future<void> refreshLibrary() => refreshContinueWatching();

  StremioLibraryItem? cachedLibraryItem(String id) => _libraryCache[id];

  bool isInLibrary(String id) => _libraryCache[id]?.isInLibrary ?? false;

  bool isInContinueWatching(String id) =>
      _libraryCache[id]?.isInContinueWatching ?? false;

  Future<void> _putItem(StremioLibraryItem item) async {
    final key = _authKey;
    if (key == null) throw StremioApiException('Log in to Stremio first');
    item.touch();
    _libraryCache[item.id] = item;
    _rebuildLists();
    await api.datastorePut(key, [item]);
  }

  /// Stremio "Add to library".
  Future<void> addToLibrary({
    required String id,
    required String type,
    required String name,
    String? poster,
  }) async {
    final item = await getLibraryItem(id) ??
        StremioLibraryItem.create(
            id: id, type: type, name: name, poster: poster);
    if (item.name.isEmpty) item.raw['name'] = name;
    if (item.poster == null && poster != null) item.raw['poster'] = poster;
    item.raw['removed'] = false;
    item.raw['temp'] = false;
    await _putItem(item);
  }

  /// Stremio "Remove from library" (also drops it from Continue Watching).
  Future<void> removeFromLibrary(String id) async {
    final item = await getLibraryItem(id);
    if (item == null) return;
    item.raw['removed'] = true;
    item.raw['temp'] = false;
    await _putItem(item);
  }

  /// Stremio's Continue Watching "dismiss": items only kept for Continue
  /// Watching are removed; items in your library are rewound instead.
  Future<void> dismissFromContinueWatching(String id) async {
    final item = await getLibraryItem(id);
    if (item == null) return;
    if (item.temp || item.removed) {
      item.raw['removed'] = true;
      item.raw['temp'] = false;
    } else {
      item.timeOffset = 0;
    }
    await _putItem(item);
  }
}
