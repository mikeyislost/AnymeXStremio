// Stremio account + library sync for AnymeX.
//
// - Logs into a Stremio account (email/password or stremio.com/link code).
// - Uses the account's installed addons (or Cinemeta when logged out).
// - Writes playback progress back to the Stremio library, so anything
//   watched in AnymeX shows up in Stremio's Continue Watching and episode
//   watched marks. Progress rules mirror stremio-core src/models/player.rs.

import 'dart:async';
import 'dart:convert';

import 'package:anymex/controllers/service_handler/params.dart';
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

  /// Stremio content type for a bare video id: `kitsu:1:5` / `tt1:1:5` are
  /// series episodes, `kitsu:1` / `tt1` are movies.
  static String typeForVideoId(String videoId) {
    final parts = videoId.split(':');
    if (videoId.startsWith('kitsu:')) {
      return parts.length >= 3 ? 'series' : 'movie';
    }
    return parts.length >= 3 ? 'series' : 'movie';
  }

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

/// An AniList/MAL anime matched to Stremio, for playing it with the user's
/// Stremio stream addons from the anime Watch tab.
class StremioAnimeTarget {
  /// Stremio type to ask stream addons for (series / movie).
  final String type;

  /// kitsu:… or tt… id the stream addons understand.
  final String libraryId;
  final StremioMeta? meta;
  final bool isMovie;

  /// One per episode; `link` is the Stremio video id, `source` is 'Stremio'.
  final List<Episode> episodes;

  /// Names of the stream addons that accept these ids.
  final List<String> addonNames;

  const StremioAnimeTarget({
    required this.type,
    required this.libraryId,
    required this.meta,
    required this.isMovie,
    required this.episodes,
    required this.addonNames,
  });
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
  static const _kSyncToAnilist = 'stremio_sync_to_anilist';
  static const _kAnimeStreamSource = 'anymexplus_anime_stream_source';

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

  /// Anime watched from Movies & TV (Stremio) updates AniList progress.
  final RxBool syncToAnilist = true.obs;

  /// Where the anime Watch tab gets streams: 'extensions' or 'stremio'.
  final RxString animeStreamSource = 'extensions'.obs;

  /// The user's Stremio library (added items, newest first).
  final RxList<StremioLibraryItem> library = <StremioLibraryItem>[].obs;

  String? _authKey;
  String? get authKey => _authKey;

  final Map<String, StremioLibraryItem> _libraryCache = {};
  final Map<String, StremioMeta> _metaCache = {};
  final Map<String, _AnimeMapping?> _animeMappings = {};
  final Map<String, StremioPlayback?> _animePlaybackCache = {};
  final Map<String, bool> _animeRoutes = {}; // mapping → use IMDb id
  _Session? _session;

  // ---- lifecycle ----------------------------------------------------------

  @override
  void onInit() {
    super.onInit();
    try {
      syncEnabled.value = KvHelper.get<bool>(_kSyncEnabled, defaultVal: true);
      syncAnime.value = KvHelper.get<bool>(_kSyncAnime, defaultVal: true);
      syncToAnilist.value =
          KvHelper.get<bool>(_kSyncToAnilist, defaultVal: true);
      animeStreamSource.value = KvHelper.get<String>(_kAnimeStreamSource,
          defaultVal: 'extensions');
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

  void setSyncToAnilist(bool v) {
    syncToAnilist.value = v;
    KvHelper.set(_kSyncToAnilist, v);
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
    library.clear();
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
    final sources = addons.where((a) =>
        a.supports('stream', type, videoId) ||
        a.supports('stream', 'anime', videoId));
    final results = await Future.wait(sources.map((addon) async {
      try {
        final list = await api.streams(
            addon,
            addon.supports('stream', type, videoId) ? type : 'anime',
            videoId);
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
      _rebuildLists();
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
    var useImdb = _animeRoutes[mapKey];
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

  // ---- anime Watch tab → Stremio streams -----------------------------------

  void setAnimeStreamSource(String value) {
    animeStreamSource.value = value;
    KvHelper.set(_kAnimeStreamSource, value);
  }

  /// Whether any installed addon serves streams.
  bool get hasStreamAddons => addons.any((a) => a.hasResource('stream'));

  final Map<String, StremioAnimeTarget?> _animeTargets = {};

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
      _animeMappings[mapKey] = await _fetchAnimeMapping(key.$1, key.$2);
    }
    final mapping = _animeMappings[mapKey];
    if (mapping == null) return null;

    final isMovieHint = mapping.isMovie ||
        media.format.toUpperCase() == 'MOVIE' ||
        (media.totalEpisodes == '1' &&
            media.format.toUpperCase() == 'SPECIAL');
    final streamAddons = addons.where((a) => a.hasResource('stream')).toList();

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
    _recentPlayback[media.id] = DateTime.now();
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
        // Stremio-native titles (Movies & TV) → AniList. Anime opened from
        // AniList is already tracked by AnymeX itself.
        if (StremioIds.isStremioMediaId(media.id)) {
          unawaited(_syncToAnilist(pb));
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
    _libraryCache[item.id] = item;
    _rebuildLists();
  }

  /// Recomputes Continue Watching and the library from the local cache,
  /// with the same rules Stremio uses.
  void _rebuildLists() {
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

  // ---- AniList sync for Stremio watches -----------------------------------

  final Map<String, (String, int)?> _anilistTargets = {};
  final Map<String, Map<String, (int, int)>?> _aniZipEpisodes = {};

  /// When an anime episode/movie is watched from Movies & TV, update the
  /// AniList entry (progress only ever moves forward).
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

  // ---- AnymeX tracker progress → Stremio ------------------------------------

  final Map<String, DateTime> _recentPlayback = {};
  bool _suppressTrackerHook = false;

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
      await api.datastorePut(authKey, [item]);
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
    return '${pb.libraryId} → ${pb.videoId} ("${pb.name}", ${pb.type}, '
        '${pb.videos.length} videos in meta)';
  }

  /// For the self test: AniList id for a Kitsu id / IMDb id.
  Future<String?> debugAnilistFromKitsu(String kitsuId) =>
      _anilistFromKitsu(kitsuId);
  Future<List<String>> debugAnilistFromImdb(String imdbId) =>
      _anilistFromImdb(imdbId);

  /// Commentum (comments) id for a Stremio title: the AniList id when the
  /// title is anime and you comment as an AniList user (so it's the same
  /// thread as AnymeX's anime page), otherwise its IMDb/Stremio id.
  final Map<String, String> _commentIds = {};

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
    return out;
  }
}
