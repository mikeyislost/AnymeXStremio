// Stremio account + library sync for AnymeX.
//
// - Logs into a Stremio account (email/password or stremio.com/link code).
// - Uses the account's installed addons (or Cinemeta when logged out).
// - Writes playback progress back to the Stremio library, so anything
//   watched in AnymeX shows up in Stremio's Continue Watching and episode
//   watched marks. Progress rules mirror stremio-core src/models/player.rs.

import 'dart:async';
import 'dart:convert';

import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/services/stremio/stremio_api.dart';
import 'package:anymex/controllers/services/stremio/stremio_models.dart';
import 'package:anymex/controllers/services/stremio/watched_bitfield.dart';
import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/models/Media/media.dart' as anymex;
import 'package:anymex/utils/logger.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// Encodes Stremio items as AnymeX media ids:
/// `stremio|<type>|<metaId>` plus `|s<season>` for series, so AnymeX's local
/// per-episode-number history doesn't mix up seasons.
class StremioIds {
  static const String prefix = 'stremio|';

  static String mediaId(String type, String metaId, {int? season}) =>
      '$prefix$type|$metaId${season != null ? '|s$season' : ''}';

  static bool isStremioMediaId(String? id) =>
      id != null && id.startsWith(prefix);

  /// Returns (type, metaId) or null.
  static (String, String)? parse(String id) {
    if (!isStremioMediaId(id)) return null;
    final parts = id.substring(prefix.length).split('|');
    if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
    return (parts[0], parts[1]);
  }
}

/// What is being played, in Stremio terms.
class StremioPlayback {
  final String libraryId; // meta id (tt…, kitsu:…)
  final String type; // movie / series / …
  final String name;
  final String? poster;
  final String videoId;
  final List<StremioVideo> videos; // may be empty when meta is unknown

  const StremioPlayback({
    required this.libraryId,
    required this.type,
    required this.name,
    this.poster,
    required this.videoId,
    this.videos = const [],
  });

  StremioVideo? get nextVideo {
    if (videos.isEmpty) return null;
    final ordered = List<StremioVideo>.from(videos)
      ..sort((a, b) {
        final s = (a.season ?? 0).compareTo(b.season ?? 0);
        if (s != 0) return s;
        return (a.episode ?? 0).compareTo(b.episode ?? 0);
      });
    final idx = ordered.indexWhere((v) => v.id == videoId);
    if (idx == -1) return null;
    for (var i = idx + 1; i < ordered.length; i++) {
      final v = ordered[i];
      // Don't jump into specials or unreleased episodes.
      if ((v.season ?? 1) == 0) continue;
      if (!v.isReleased) return null;
      return v;
    }
    return null;
  }
}

class _AnimeMapping {
  final String? kitsuId;
  final String? imdbId;
  final bool isMovie;
  final Map<String, (int, int)> imdbEpisodes; // ep -> (season, episode)

  _AnimeMapping(this.kitsuId, this.imdbId, this.isMovie, this.imdbEpisodes);
}

class _Session {
  final String key;
  DateTime lastReport = DateTime.fromMillisecondsSinceEpoch(0);
  int lastPositionMs = 0;
  bool reporting = false;
  _Session(this.key);
}

class StremioService extends GetxController {
  static StremioService get to => Get.isRegistered<StremioService>()
      ? Get.find<StremioService>()
      : Get.put(StremioService());

  static const String cinemetaUrl =
      'https://v3-cinemeta.strem.io/manifest.json';
  static const double watchedThreshold = 0.7; // WATCHED_THRESHOLD_COEF
  static const double creditsThreshold = 0.9; // CREDITS_THRESHOLD_COEF
  static const Duration reportInterval = Duration(seconds: 45);

  static const _kAuthKey = 'stremio_auth_key';
  static const _kUser = 'stremio_user';
  static const _kLocalAddons = 'stremio_local_addons';
  static const _kSyncAnime = 'stremio_sync_anime';
  static const _kSyncEnabled = 'stremio_sync_enabled';

  final api = StremioApi();

  final RxBool isLoggedIn = false.obs;
  final RxString userEmail = ''.obs;
  final RxString userAvatar = ''.obs;
  final RxList<StremioAddon> addons = <StremioAddon>[].obs;
  final RxBool addonsLoading = false.obs;
  final RxList<StremioLibraryItem> continueWatching =
      <StremioLibraryItem>[].obs;
  final RxBool libraryLoading = false.obs;

  /// Push progress for everything played in AnymeX to Stremio.
  final RxBool syncEnabled = true.obs;

  /// Also push anime watched through AniList / MyAnimeList.
  final RxBool syncAnime = true.obs;

  String? _authKey;
  String? get authKey => _authKey;

  final Map<String, StremioLibraryItem> _libraryCache = {};
  final Map<String, StremioMeta> _metaCache = {};
  final Map<String, _AnimeMapping?> _animeMappings = {};
  final Map<String, StremioPlayback?> _animePlaybackCache = {};
  _Session? _session;

  // ---- lifecycle ----------------------------------------------------------

  @override
  void onInit() {
    super.onInit();
    try {
      syncEnabled.value = KvHelper.get<bool>(_kSyncEnabled, defaultVal: true);
      syncAnime.value = KvHelper.get<bool>(_kSyncAnime, defaultVal: true);
      final key = KvHelper.get<String?>(_kAuthKey);
      if (key != null && key.isNotEmpty) {
        _authKey = key;
        isLoggedIn.value = true;
        final user = KvHelper.get<String?>(_kUser);
        if (user != null && user.isNotEmpty) _applyUser(jsonDecode(user));
      }
    } catch (e) {
      Logger.e('Stremio: failed to restore session: $e');
    }
  }

  @override
  void onReady() {
    super.onReady();
    refreshAddons();
    if (isLoggedIn.value) refreshContinueWatching();
  }

  void setSyncEnabled(bool v) {
    syncEnabled.value = v;
    KvHelper.set(_kSyncEnabled, v);
  }

  void setSyncAnime(bool v) {
    syncAnime.value = v;
    KvHelper.set(_kSyncAnime, v);
  }

  void _applyUser(dynamic user) {
    if (user is! Map) return;
    userEmail.value = user['email']?.toString() ?? '';
    userAvatar.value = user['avatar']?.toString() ?? '';
  }

  // ---- auth ---------------------------------------------------------------

  Future<void> login(String email, String password) async {
    final res = await api.login(email.trim(), password);
    await _completeLogin(res.authKey, res.user);
  }

  Future<StremioLinkCode> createLinkCode() => api.createLinkCode();

  /// Polls a link code until the user confirms it on stremio.com/link.
  /// Returns true once logged in; false if [isCancelled] fires or it expires.
  Future<bool> waitForLinkCode(String code,
      {required bool Function() isCancelled}) async {
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled()) return false;
      await Future.delayed(const Duration(seconds: 3));
      if (isCancelled()) return false;
      try {
        final key = await api.readLinkCode(code);
        if (key != null) {
          final user = await api.getUser(key);
          await _completeLogin(key, user);
          return true;
        }
      } catch (e) {
        Logger.i('Stremio link poll: $e');
      }
    }
    return false;
  }

  Future<void> _completeLogin(String key, Map<String, dynamic> user) async {
    _authKey = key;
    KvHelper.set(_kAuthKey, key);
    KvHelper.set(_kUser, jsonEncode({
      'email': user['email'],
      'avatar': user['avatar'],
      '_id': user['_id'],
    }));
    _applyUser(user);
    isLoggedIn.value = true;
    _libraryCache.clear();
    await refreshAddons();
    unawaited(refreshContinueWatching());
  }

  Future<void> logout() async {
    final key = _authKey;
    _authKey = null;
    isLoggedIn.value = false;
    userEmail.value = '';
    userAvatar.value = '';
    continueWatching.clear();
    _libraryCache.clear();
    KvHelper.remove(_kAuthKey);
    KvHelper.remove(_kUser);
    if (key != null) unawaited(api.logout(key));
    await refreshAddons();
  }

  // ---- addons -------------------------------------------------------------

  Future<void> refreshAddons() async {
    addonsLoading.value = true;
    try {
      if (_authKey != null) {
        final list = await api.addonCollectionGet(_authKey!);
        addons.assignAll(list);
      } else {
        addons.assignAll(await _loadLocalAddons());
      }
    } catch (e) {
      Logger.e('Stremio: failed to load addons: $e');
      if (e is StremioApiException && e.code == 1) {
        // Session expired / invalid auth key.
        await logout();
      }
    } finally {
      addonsLoading.value = false;
    }
  }

  Future<List<StremioAddon>> _loadLocalAddons() async {
    final raw = KvHelper.get<String?>(_kLocalAddons);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        final parsed = list
            .whereType<Map>()
            .map((e) =>
                StremioAddon.fromDescriptor(Map<String, dynamic>.from(e)))
            .toList();
        if (parsed.isNotEmpty) return parsed;
      } catch (_) {}
    }
    final cinemeta = await api.fetchManifest(cinemetaUrl);
    cinemeta.flags['official'] = true;
    cinemeta.flags['protected'] = true;
    _saveLocalAddons([cinemeta]);
    return [cinemeta];
  }

  void _saveLocalAddons(List<StremioAddon> list) {
    KvHelper.set(
        _kLocalAddons, jsonEncode(list.map((a) => a.toDescriptor()).toList()));
  }

  Future<void> _saveAddons(List<StremioAddon> list) async {
    if (_authKey != null) {
      await api.addonCollectionSet(_authKey!, list);
    } else {
      _saveLocalAddons(list);
    }
    addons.assignAll(list);
  }

  /// Installs an addon from its manifest URL (also accepts stremio:// links).
  Future<StremioAddon> installAddon(String url) async {
    final addon = await api.fetchManifest(url);
    final list = List<StremioAddon>.from(addons)
      ..removeWhere((a) => a.id == addon.id);
    list.add(addon);
    await _saveAddons(list);
    return addon;
  }

  Future<void> uninstallAddon(StremioAddon addon) async {
    if (addon.isProtected) return;
    final list = List<StremioAddon>.from(addons)
      ..removeWhere((a) => a.transportUrl == addon.transportUrl);
    await _saveAddons(list);
  }

  // ---- content ------------------------------------------------------------

  Future<void> ensureAddons() async {
    if (addons.isNotEmpty) return;
    if (addonsLoading.value) {
      // Wait for the in-flight load.
      for (var i = 0; i < 100 && addonsLoading.value; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (addons.isNotEmpty) return;
    }
    await refreshAddons();
  }

  /// Fetches full meta from the first installed addon that supports it.
  Future<StremioMeta?> fetchMeta(String type, String id) async {
    final cacheKey = '$type|$id';
    final cached = _metaCache[cacheKey];
    if (cached != null) return cached;
    await ensureAddons();
    for (final addon in addons.where((a) => a.supports('meta', type, id))) {
      try {
        final meta = await api.meta(addon, type, id);
        if (meta != null && meta.id.isNotEmpty) {
          _metaCache[cacheKey] = meta;
          return meta;
        }
      } catch (e) {
        Logger.i('Stremio meta from ${addon.name} failed: $e');
      }
    }
    return null;
  }

  /// Streams for one video from every addon that serves streams for it.
  /// [onAddonResult] is called as each addon answers, for progressive UIs.
  Future<List<StremioStream>> fetchStreams(
    String type,
    String videoId, {
    void Function(StremioAddon addon, List<StremioStream> streams)?
        onAddonResult,
  }) async {
    await ensureAddons();
    final sources = addons.where((a) => a.supports('stream', type, videoId));
    final results = await Future.wait(sources.map((addon) async {
      try {
        final list = await api.streams(addon, type, videoId);
        onAddonResult?.call(addon, list);
        return list;
      } catch (e) {
        Logger.i('Stremio streams from ${addon.name} failed: $e');
        onAddonResult?.call(addon, const []);
        return <StremioStream>[];
      }
    }));
    return results.expand((e) => e).toList();
  }

  // ---- library ------------------------------------------------------------

  Future<void> refreshContinueWatching() async {
    final key = _authKey;
    if (key == null) return;
    libraryLoading.value = true;
    try {
      final items = await api.datastoreGet(key, all: true);
      for (final item in items) {
        _libraryCache[item.id] = item;
      }
      final cw = items.where((i) => i.isInContinueWatching).toList()
        ..sort((a, b) {
          final at = a.lastWatched ?? a.mtime ?? DateTime(1970);
          final bt = b.lastWatched ?? b.mtime ?? DateTime(1970);
          return bt.compareTo(at);
        });
      continueWatching.assignAll(cw);
    } catch (e) {
      Logger.e('Stremio: failed to load library: $e');
    } finally {
      libraryLoading.value = false;
    }
  }

  Future<StremioLibraryItem?> getLibraryItem(String id,
      {bool refresh = false}) async {
    if (!refresh && _libraryCache.containsKey(id)) return _libraryCache[id];
    final key = _authKey;
    if (key == null) return null;
    try {
      final items = await api.datastoreGet(key, ids: [id]);
      if (items.isNotEmpty) {
        _libraryCache[id] = items.first;
        return items.first;
      }
    } catch (e) {
      Logger.i('Stremio: datastoreGet $id failed: $e');
    }
    return null;
  }

  /// Watched state of each video of [meta], from the Stremio library.
  Future<WatchedBitField?> watchedFor(StremioMeta meta) async {
    final item = await getLibraryItem(meta.id);
    if (item == null) return null;
    return WatchedBitField.construct(
      item.watchedField,
      WatchedBitField.orderedVideoIds(meta.videos),
    );
  }

  /// Marks a single video watched/unwatched in the Stremio library.
  Future<void> setVideoWatched(
      StremioMeta meta, StremioVideo video, bool watched) async {
    final key = _authKey;
    if (key == null) return;
    final item = await getLibraryItem(meta.id) ??
        StremioLibraryItem.create(
            id: meta.id, type: meta.type, name: meta.name, poster: meta.poster);
    final wb = WatchedBitField.construct(
        item.watchedField, WatchedBitField.orderedVideoIds(meta.videos));
    wb.setVideo(video.id, watched);
    item.watchedField = wb.serialize();
    if (watched) item.lastWatched = DateTime.now();
    item.touch();
    _libraryCache[item.id] = item;
    await api.datastorePut(key, [item]);
  }

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
    if (item.duration > 0 && item.timeOffset > item.duration * creditsThreshold) {
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
    final useKitsu = mapping.kitsuId != null &&
        addons.any((a) =>
            a.supports('meta', 'series', 'kitsu:${mapping.kitsuId}') ||
            a.supports('meta', 'movie', 'kitsu:${mapping.kitsuId}') ||
            a.supports('meta', 'anime', 'kitsu:${mapping.kitsuId}'));

    StremioPlayback? playback;
    if (useKitsu) {
      final libId = 'kitsu:${mapping.kitsuId}';
      StremioMeta? meta;
      for (final t in isMovie
          ? ['movie', 'series', 'anime']
          : ['series', 'anime', 'movie']) {
        meta = await fetchMeta(t, libId);
        if (meta != null) break;
      }
      final type = meta?.type ?? (isMovie ? 'movie' : 'series');
      final single = meta != null ? meta.isSingleVideo : isMovie;
      playback = StremioPlayback(
        libraryId: libId,
        type: type,
        name: meta?.name ?? media.title,
        poster: meta?.poster ?? media.poster,
        videoId: single ? (meta?.singleVideoId ?? libId) : '$libId:$epNum',
        videos: meta?.videos ?? const [],
      );
    } else if (mapping.imdbId != null) {
      final libId = mapping.imdbId!;
      final type = isMovie ? 'movie' : 'series';
      final meta = await fetchMeta(type, libId);
      String videoId;
      if (isMovie) {
        videoId = libId;
      } else {
        final se = mapping.imdbEpisodes[epNum];
        videoId = se != null
            ? '$libId:${se.$1}:${se.$2}'
            : '$libId:1:$epNum';
      }
      playback = StremioPlayback(
        libraryId: libId,
        type: meta?.type ?? type,
        name: meta?.name ?? media.title,
        poster: meta?.poster ?? media.poster,
        videoId: videoId,
        videos: meta?.videos ?? const [],
      );
    }
    _animePlaybackCache[cacheKey] = playback;
    return playback;
  }

  Future<_AnimeMapping?> _fetchAnimeMapping(String param, String id) async {
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
  /// [reportInterval]. Never throws.
  void onPlaybackProgress({
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
    if (DateTime.now().difference(session.lastReport) < reportInterval) return;
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

      final watchedEnough = item.flaggedWatched == 0 &&
          item.duration > 0 &&
          (item.timeWatched > item.duration * watchedThreshold ||
              posMs > item.duration * creditsThreshold);
      if (watchedEnough) {
        item.flaggedWatched = 1;
        item.timesWatched = item.timesWatched + 1;
        if (wb != null) {
          wb.setVideo(pb.videoId, true);
          item.watchedField = wb.serialize();
        }
      }

      if (isFinal && posMs > durMs * creditsThreshold) {
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
      await api.datastorePut(authKey, [item]);

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
    final list = List<StremioLibraryItem>.from(continueWatching)
      ..removeWhere((i) => i.id == item.id);
    if (item.isInContinueWatching) list.insert(0, item);
    continueWatching.assignAll(list);
  }
}
