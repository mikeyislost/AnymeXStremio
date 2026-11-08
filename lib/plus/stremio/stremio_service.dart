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
import 'package:anymex/plus/stremio/stremio_api.dart';
import 'package:anymex/plus/stremio/stremio_disk_cache.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/watched_bitfield.dart';
import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/controllers/settings/settings.dart';
import 'package:anymex/database/data_keys/keys.dart' show AuthKeys;
import 'package:anymex/controllers/services/simkl/simkl_service.dart';
import 'package:anymex/plus/simkl_auth_v2.dart';
import 'package:anymex/models/Media/media.dart' as anymex;
import 'package:anymex/utils/logger.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

part 'stremio_service_sync.dart';
part 'stremio_service_playback.dart';
part 'stremio_service_anilist.dart';

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
/// The Stremio entry an anime's progress goes to (Watch tab).
class StremioSyncEntry {
  final String id; // tt… or kitsu:…
  final String name;
  final bool inLibrary;
  final bool chosenByYou;
  final String? otherId; // the entry it could switch to
  final String? otherName;
  final bool otherInLibrary;

  const StremioSyncEntry({
    required this.id,
    required this.name,
    required this.inLibrary,
    required this.chosenByYou,
    this.otherId,
    this.otherName,
    this.otherInLibrary = false,
  });

  bool get isImdb => !id.startsWith('kitsu:');
  static String label(String id) => id.startsWith('kitsu:') ? 'Kitsu' : 'IMDb';
}

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

  /// Where an episode counts as watched, from your "mark as watched"
  /// setting (Player settings), so Stremio and AniList agree.
  static double get watchedPoint {
    try {
      final pct = Get.find<Settings>().markAsCompleted;
      if (pct >= 50 && pct <= 99) return pct / 100;
    } catch (_) {}
    return creditsThreshold;
  }
  static const Duration reportInterval = Duration(seconds: 45);

  static const _kAuthKey = 'stremio_auth_key';
  static const _kUser = 'stremio_user';
  static const _kLocalAddons = 'stremio_local_addons';
  static const _kSyncAnime = 'stremio_sync_anime';
  static const _kSyncEnabled = 'stremio_sync_enabled';
  static const _kSyncToAnilist = 'stremio_sync_to_anilist';
  static const _kAnimeStreamSource = 'anymexplus_anime_stream_source';
  static const _kSyncToSimkl = 'anymexplus_stremio_sync_to_simkl';
  static const _kRowLayout = 'anymexplus_stremio_rows';
  static const _kStreamPrefs = 'anymexplus_stream_prefs';
  static const _kSyncRoutes = 'anymexplus_stremio_sync_routes';

  // On-device copies (see StremioDiskCache).
  static const _kDiskAddons = 'stremio/addons';
  static const _kDiskLibrary = 'stremio/library';

  /// Title details saved on the device are used without asking the addon
  /// again for this long; older copies are only used when offline.
  static const Duration metaFreshFor = Duration(hours: 12);
  static const int _metaMemoryLimit = 200;

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

  /// Movies and episodes watched from Movies & TV are added to your Simkl
  /// history (when you're logged in to Simkl).
  final RxBool syncToSimkl = true.obs;

  /// Home rows in your order (row keys, see [rowKey]) and the hidden ones.
  final RxList<String> rowOrder = <String>[].obs;
  final RxSet<String> hiddenRows = <String>{}.obs;

  /// Where the anime Watch tab gets streams: 'extensions' or 'stremio'.
  final RxString animeStreamSource = 'extensions'.obs;

  /// The user's Stremio library (added items, newest first).
  final RxList<StremioLibraryItem> library = <StremioLibraryItem>[].obs;

  /// Goes up whenever the library or watch history changes.
  final RxInt libraryRevision = 0.obs;

  /// Everything Stremio keeps for this account: library items and titles
  /// you only watched (used by "For you").
  Iterable<StremioLibraryItem> get allLibraryItems => _libraryCache.values;

  String? _authKey;
  String? get authKey => _authKey;

  final Map<String, StremioLibraryItem> _libraryCache = {};
  final Map<String, StremioMeta> _metaCache = {};
  final Map<String, _AnimeMapping?> _animeMappings = {};
  final Map<String, StremioPlayback?> _animePlaybackCache = {};
  final Map<String, bool> _animeRoutes = {}; // mapping → use IMDb id
  // Entries you picked yourself on the Watch tab (mapping → use IMDb id);
  // these win over the automatic choice and are kept between launches.
  final Map<String, bool> _routeChoices = {};
  _Session? _session;

  // ---- lifecycle ----------------------------------------------------------

  @override
  void onInit() {
    super.onInit();
    _readSettings();
    unawaited(_restoreFromDisk());
    unawaited(StremioDiskCache.prune());
  }

  /// Re-reads the saved settings (after AnymeX restores a backup).
  void reloadSettings() {
    _readSettings();
    libraryRevision.value++;
  }

  void _readSettings() {
    try {
      syncEnabled.value = KvHelper.get<bool>(_kSyncEnabled, defaultVal: true);
      syncAnime.value = KvHelper.get<bool>(_kSyncAnime, defaultVal: true);
      syncToAnilist.value =
          KvHelper.get<bool>(_kSyncToAnilist, defaultVal: true);
      syncToSimkl.value = KvHelper.get<bool>(_kSyncToSimkl, defaultVal: true);
      _loadRowLayout();
      _loadStreamPrefs();
      _loadRouteChoices();
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

  /// Library refreshed from Stremio this session (the device copy must not
  /// overwrite it).
  bool _libraryFresh = false;

  /// Shows the addons and library saved last time right away, so Movies &
  /// TV opens with its rows and Continue Watching filled while they refresh.
  Future<void> _restoreFromDisk() async {
    if (!isLoggedIn.value) return;
    try {
      final a = await StremioDiskCache.read(_kDiskAddons);
      if (addons.isEmpty && a?.value is List) {
        final list = (a!.value as List)
            .whereType<Map>()
            .map((e) =>
                StremioAddon.fromDescriptor(Map<String, dynamic>.from(e)))
            .where((x) => x.transportUrl.isNotEmpty)
            .toList();
        if (list.isNotEmpty && addons.isEmpty) addons.assignAll(list);
      }
      final l = await StremioDiskCache.read(_kDiskLibrary);
      if (!_libraryFresh && l?.value is List) {
        for (final e in (l!.value as List).whereType<Map>()) {
          final item = StremioLibraryItem(Map<String, dynamic>.from(e));
          if (item.id.isNotEmpty) _libraryCache.putIfAbsent(item.id, () => item);
        }
        _rebuildLists(save: false);
      }
    } catch (e) {
      Logger.i('Stremio: restoring saved data failed: $e');
    }
  }

  Timer? _librarySaveTimer;

  void _scheduleLibrarySave() {
    if (!isLoggedIn.value) return;
    _librarySaveTimer?.cancel();
    _librarySaveTimer = Timer(const Duration(seconds: 3), () {
      if (!isLoggedIn.value) return;
      unawaited(StremioDiskCache.write(_kDiskLibrary,
          _libraryCache.values.map((i) => i.toJson()).toList()));
    });
  }

  AppLifecycleListener? _lifecycle;
  DateTime _lastLibraryRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  /// For this long after the library was downloaded or checked for changes,
  /// a title that isn't in it is taken as not in your Stremio library,
  /// without asking Stremio about it again (saves up to 2 requests each
  /// time a new show or movie starts syncing). After that, Stremio is asked
  /// as before, in case it was added on another device since.
  static const trustLibraryFor = Duration(minutes: 10);
  DateTime? _libraryCheckedAt;
  bool get _libraryTrusted =>
      _libraryCheckedAt != null &&
      DateTime.now().difference(_libraryCheckedAt!) < trustLibraryFor;

  @override
  void onReady() {
    super.onReady();
    refreshAddons();
    if (isLoggedIn.value) {
      refreshContinueWatching();
      unawaited(flushPending());
    }
    _lifecycle = AppLifecycleListener(onResume: _onAppResume);
  }

  @override
  void onClose() {
    _lifecycle?.dispose();
    super.onClose();
  }

  /// Back in the app: pick up progress made on other devices (Continue
  /// Watching) and send anything that failed while offline.
  void _onAppResume() {
    if (!isLoggedIn.value) return;
    unawaited(flushPending());
    if (DateTime.now().difference(_lastLibraryRefresh) >
        const Duration(minutes: 2)) {
      unawaited(refreshContinueWatching());
    }
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

  void setSyncToSimkl(bool v) {
    syncToSimkl.value = v;
    KvHelper.set(_kSyncToSimkl, v);
  }

  bool get simklLoggedIn {
    try {
      return Get.find<SimklService>().isLoggedIn.value;
    } catch (_) {
      return false;
    }
  }

  // ---- home rows layout -----------------------------------------------------

  static String rowKey(StremioAddon addon, StremioCatalog catalog) =>
      '${addon.transportUrl}|${catalog.type}|${catalog.id}';

  void _loadRouteChoices() {
    try {
      final raw = KvHelper.get<String>(_kSyncRoutes, defaultVal: '');
      if (raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      m.forEach((k, v) {
        if (v is bool) _routeChoices['$k'] = v;
      });
    } catch (_) {}
  }

  void _loadRowLayout() {
    try {
      final raw = KvHelper.get<String>(_kRowLayout, defaultVal: '');
      if (raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      rowOrder.assignAll(
          (m['order'] is List ? m['order'] as List : const []).map((e) => '$e'));
      hiddenRows
        ..clear()
        ..addAll((m['hidden'] is List ? m['hidden'] as List : const [])
            .map((e) => '$e'));
    } catch (_) {}
  }

  /// Saves the home rows' order and which are hidden.
  void saveRowLayout(List<String> order, Set<String> hidden) {
    rowOrder.assignAll(order);
    hiddenRows
      ..clear()
      ..addAll(hidden);
    KvHelper.set(_kRowLayout,
        jsonEncode({'order': order, 'hidden': hidden.toList()}));
  }

  void resetRowLayout() => saveRowLayout(const [], const {});

  /// Puts rows in your order and drops hidden ones (unless
  /// [includeHidden]). Rows you haven't placed yet (e.g. from a new addon)
  /// keep the addon's order, after yours.
  List<T> arrangeRows<T>(List<T> rows, String Function(T) keyOf,
      {bool includeHidden = false}) {
    final index = <String, int>{
      for (var i = 0; i < rowOrder.length; i++) rowOrder[i]: i
    };
    final hidden = hiddenRows;
    final placed = <T>[], rest = <T>[];
    for (final r in rows) {
      final k = keyOf(r);
      if (!includeHidden && hidden.contains(k)) continue;
      (index.containsKey(k) ? placed : rest).add(r);
    }
    placed.sort((a, b) => index[keyOf(a)]!.compareTo(index[keyOf(b)]!));
    return [...placed, ...rest];
  }

  // ---- remembered stream choices -------------------------------------------

  /// Per title (and '*' for your last pick anywhere): addon name and quality.
  final Map<String, Map<String, String>> _streamPrefs = {};

  void _loadStreamPrefs() {
    try {
      final raw = KvHelper.get<String>(_kStreamPrefs, defaultVal: '');
      if (raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      m.forEach((k, v) {
        if (v is Map) {
          _streamPrefs['$k'] = v.map((a, b) => MapEntry('$a', '$b'));
        }
      });
    } catch (_) {}
  }

  /// The addon and quality you picked last time for [titleKey] (or, if
  /// never, your last pick anywhere).
  ({String? addon, String? quality}) streamPrefFor(String titleKey) {
    final p = _streamPrefs[titleKey] ?? _streamPrefs['*'];
    return (addon: p?['addon'], quality: p?['quality']);
  }

  void rememberStreamChoice(String titleKey, StremioStream stream) {
    final pref = {
      'addon': stream.addonName,
      'quality': stream.quality,
    };
    _streamPrefs[titleKey] = pref;
    _streamPrefs['*'] = pref;
    // Keep the most recent 300 titles.
    while (_streamPrefs.length > 301) {
      final first = _streamPrefs.keys.firstWhere((k) => k != '*');
      _streamPrefs.remove(first);
    }
    KvHelper.set(_kStreamPrefs, jsonEncode(_streamPrefs));
  }

  /// Key for remembering stream choices: the show/movie, not the episode.
  static String streamTitleKey(String? metaId, String videoId) {
    if (metaId != null && metaId.isNotEmpty) return metaId;
    final parts = videoId.split(':');
    if (parts.first == 'kitsu' && parts.length > 1) return 'kitsu:${parts[1]}';
    return parts.first;
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
    _libraryFresh = false;
    _libraryCheckedAt = null;
    _librarySaveTimer?.cancel();
    unawaited(StremioDiskCache.remove(_kDiskAddons));
    unawaited(StremioDiskCache.remove(_kDiskLibrary));
    _pending.clear();
    unawaited(StremioDiskCache.remove(_kDiskPending));
    KvHelper.remove(_kAuthKey);
    KvHelper.remove(_kUser);
    if (key != null) unawaited(api.logout(key));
    await refreshAddons();
  }

  // ---- addons -------------------------------------------------------------

  // ---- addon health ----------------------------------------------------------

  /// AnymeX+: addons whose manifest answered with an HTTP error this session
  /// (dead on their end), or local-only addons this device can't reach.
  /// They're skipped for streams and metadata. transportUrl → reason.
  final RxMap<String, String> unreachableAddons = <String, String>{}.obs;

  bool isAddonUsable(StremioAddon a) =>
      !unreachableAddons.containsKey(a.transportUrl);

  /// Checks every addon's manifest once (in the background after loading).
  Future<void> checkAddonHealth() async {
    await Future.wait(addons.toList().map((a) async {
      final host = Uri.tryParse(a.transportUrl)?.host ?? '';
      final local = host == '127.0.0.1' || host == 'localhost';
      try {
        final r = await http
            .get(Uri.parse(a.transportUrl))
            .timeout(const Duration(seconds: 12));
        if (r.statusCode >= 400) {
          unreachableAddons[a.transportUrl] = 'not responding (HTTP ${r.statusCode})';
        } else {
          unreachableAddons.remove(a.transportUrl);
        }
      } on TimeoutException {
        // Slow isn't dead; leave it in.
      } catch (_) {
        if (local) {
          unreachableAddons[a.transportUrl] =
              'needs the Stremio desktop app running on this device';
        }
      }
    }));
  }

  Future<void> refreshAddons() async {
    addonsLoading.value = true;
    try {
      if (_authKey != null) {
        final list = await api.addonCollectionGet(_authKey!);
        addons.assignAll(list);
        unawaited(StremioDiskCache.write(
            _kDiskAddons, list.map((a) => a.toDescriptor()).toList()));
      } else {
        addons.assignAll(await _loadLocalAddons());
      }
      unawaited(checkAddonHealth());
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
      unawaited(StremioDiskCache.write(
          _kDiskAddons, list.map((a) => a.toDescriptor()).toList()));
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
  /// A copy saved on the device in the last [metaFreshFor] is used as is;
  /// an older one only when no addon answers (offline).
  Future<StremioMeta?> fetchMeta(String type, String id) async {
    final cacheKey = '$type|$id';
    final cached = _metaCache[cacheKey];
    if (cached != null) return cached;
    final diskKey = 'meta|$cacheKey';
    final saved = await StremioDiskCache.read(diskKey);
    StremioMeta? savedMeta;
    if (saved?.value is Map) {
      try {
        savedMeta =
            StremioMeta.fromJson(Map<String, dynamic>.from(saved!.value));
        if (savedMeta.id.isEmpty) savedMeta = null;
      } catch (_) {}
    }
    if (savedMeta != null && saved!.isFresherThan(metaFreshFor)) {
      _rememberMeta(cacheKey, savedMeta);
      return savedMeta;
    }
    await ensureAddons();
    for (final addon in addons
        .where((a) => isAddonUsable(a) && a.supports('meta', type, id))) {
      try {
        final meta = await api.meta(addon, type, id);
        if (meta != null && meta.id.isNotEmpty) {
          _rememberMeta(cacheKey, meta);
          unawaited(StremioDiskCache.write(diskKey, meta.raw));
          return meta;
        }
      } catch (e) {
        Logger.i('Stremio meta from ${addon.name} failed: $e');
      }
    }
    if (savedMeta != null) _rememberMeta(cacheKey, savedMeta);
    return savedMeta;
  }

  /// Keeps the in-memory title details to the most recent few hundred.
  void _rememberMeta(String key, StremioMeta meta) {
    _metaCache.remove(key);
    _metaCache[key] = meta;
    while (_metaCache.length > _metaMemoryLimit) {
      _metaCache.remove(_metaCache.keys.first);
    }
  }

  static String _catalogKey(StremioAddon addon, StremioCatalog catalog,
      Map<String, String> extra) {
    final keys = extra.keys.toList()..sort();
    final ex = keys.map((k) => '$k=${extra[k]}').join('&');
    return 'catalog|${addon.transportUrl}|${catalog.type}|${catalog.id}|$ex';
  }

  /// The copy of a home row saved last time it loaded, if any.
  Future<List<StremioMetaPreview>?> savedCatalog(StremioAddon addon,
      StremioCatalog catalog, {Map<String, String> extra = const {}}) async {
    final entry = await StremioDiskCache.read(_catalogKey(addon, catalog, extra));
    if (entry?.value is! List) return null;
    return (entry!.value as List)
        .whereType<Map>()
        .map((e) => StremioMetaPreview.fromJson(Map<String, dynamic>.from(e)))
        .where((m) => m.id.isNotEmpty)
        .toList();
  }

  /// Loads a home row from its addon and saves it on the device. Falls back
  /// to the saved copy when the addon doesn't answer.
  Future<List<StremioMetaPreview>> catalogWithSave(
      StremioAddon addon, StremioCatalog catalog,
      {Map<String, String> extra = const {}}) async {
    try {
      final items = await api.catalog(addon, catalog, extra: extra);
      if (items.isNotEmpty) {
        unawaited(StremioDiskCache.write(_catalogKey(addon, catalog, extra),
            items.take(40).map((m) => m.toJson()).toList()));
      }
      return items;
    } catch (e) {
      Logger.i('Stremio catalog ${catalog.id} from ${addon.name} failed: $e');
      return await savedCatalog(addon, catalog, extra: extra) ?? const [];
    }
  }

  /// Streams for one video from every addon that serves streams for it.
  /// [onAddonResult] is called as each addon answers, for progressive UIs.
  /// How long stream results are reused (reopening the list, or the next
  /// episode found early while the current one plays).
  static const Duration streamResultsFor = Duration(minutes: 10);
  final Map<String, (DateTime, Map<String, List<StremioStream>>)>
      _streamResults = {};
  final Map<String, Future<List<StremioStream>>> _streamsInFlight = {};

  Future<List<StremioStream>> fetchStreams(
    String type,
    String videoId, {
    void Function(StremioAddon addon, List<StremioStream> streams)?
        onAddonResult,
    bool refresh = false,
  }) async {
    await ensureAddons();
    final sources = addons
        .where((a) =>
            isAddonUsable(a) &&
            (a.supports('stream', type, videoId) ||
                a.supports('stream', 'anime', videoId)))
        .toList();
    final key = '$type|$videoId';
    final cached = _streamResults[key];
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.$1) < streamResultsFor) {
      final out = <StremioStream>[];
      for (final addon in sources) {
        final list = cached.$2[addon.transportUrl];
        if (list == null) continue;
        onAddonResult?.call(addon, list);
        out.addAll(list);
      }
      if (out.isNotEmpty) return out;
    }
    // Found early in the background and still loading: wait for it.
    final pending = _streamsInFlight[key];
    if (!refresh && pending != null && onAddonResult == null) {
      return pending;
    }

    final byAddon = <String, List<StremioStream>>{};
    final future = Future.wait(sources.map((addon) async {
      try {
        final list = await api.streams(
            addon,
            addon.supports('stream', type, videoId) ? type : 'anime',
            videoId);
        byAddon[addon.transportUrl] = list;
        onAddonResult?.call(addon, list);
        return list;
      } catch (e) {
        Logger.i('Stremio streams from ${addon.name} failed: $e');
        onAddonResult?.call(addon, const []);
        return <StremioStream>[];
      }
    })).then((results) {
      final all = results.expand((e) => e).toList();
      if (all.isNotEmpty) {
        _streamResults[key] = (DateTime.now(), byAddon);
        // Keep only recent lookups.
        _streamResults.removeWhere((_, v) =>
            DateTime.now().difference(v.$1) >= streamResultsFor);
      }
      return all;
    });
    _streamsInFlight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_streamsInFlight[key], future)) {
        _streamsInFlight.remove(key);
      }
    }
  }

  /// Looks up a video's streams in the background so they're ready when
  /// it starts (used for the next episode while the current one plays).
  void prefetchStreams(String type, String videoId) {
    final key = '$type|$videoId';
    final cached = _streamResults[key];
    if (_streamsInFlight.containsKey(key)) return;
    if (cached != null &&
        DateTime.now().difference(cached.$1) < streamResultsFor) {
      return;
    }
    unawaited(fetchStreams(type, videoId).catchError((_) => <StremioStream>[]));
  }

  // ---- library ------------------------------------------------------------

  Future<void> refreshContinueWatching() async {
    final key = _authKey;
    if (key == null) return;
    libraryLoading.value = true;
    _lastLibraryRefresh = DateTime.now();
    try {
      if (_libraryCache.isEmpty || !await _refreshLibraryChanges(key)) {
        final items = await api.datastoreGet(key, all: true);
        for (final item in items) {
          _libraryCache[item.id] = item;
        }
      }
      _libraryFresh = true;
      _libraryCheckedAt = DateTime.now();
      _rebuildLists();
    } catch (e) {
      Logger.e('Stremio: failed to load library: $e');
    } finally {
      libraryLoading.value = false;
    }
  }

  /// Asks Stremio when each library item last changed and downloads only
  /// the ones that changed since the copy on the phone (instead of the
  /// whole library). False when that isn't possible; the caller then
  /// downloads everything.
  Future<bool> _refreshLibraryChanges(String key) async {
    try {
      final remote = await api.datastoreMeta(key);
      if (remote.isEmpty) return false;
      final changed = <String>[];
      remote.forEach((id, mtime) {
        final local = _libraryCache[id]?.mtime;
        if (local == null || mtime.isAfter(local)) changed.add(id);
      });
      // Gone from Stremio entirely.
      _libraryCache.removeWhere((id, _) => !remote.containsKey(id));
      for (var i = 0; i < changed.length; i += 100) {
        final end = i + 100 < changed.length ? i + 100 : changed.length;
        final items = await api.datastoreGet(key, ids: changed.sublist(i, end));
        for (final item in items) {
          _libraryCache[item.id] = item;
        }
      }
      Logger.i('Stremio: library refresh, ${changed.length} of '
          '${remote.length} items changed');
      return true;
    } catch (e) {
      Logger.i('Stremio: quick library refresh failed, loading all: $e');
      return false;
    }
  }

  // ---- updates made while offline -------------------------------------------

  static const _kDiskPending = 'stremio/pending';
  final Map<String, Map<String, dynamic>> _pending = {};
  bool _pendingLoaded = false;
  bool _flushing = false;

  /// Saves a library item to Stremio. If that fails (offline, server down)
  /// the item is kept on the phone and sent later. True when it got there.
  Future<bool> _putOrQueue(String authKey, StremioLibraryItem item) async {
    try {
      await api.datastorePut(authKey, [item]);
      await _loadPending();
      if (_pending.remove(item.id) != null) _savePending();
      if (_pending.isNotEmpty) unawaited(flushPending());
      return true;
    } catch (e) {
      await _loadPending();
      _pending[item.id] = Map<String, dynamic>.from(item.toJson());
      _savePending();
      Logger.i('Stremio: keeping ${item.id} to send later ($e)');
      return false;
    }
  }

  Future<void> _loadPending() async {
    if (_pendingLoaded) return;
    _pendingLoaded = true;
    final saved = await StremioDiskCache.read(_kDiskPending);
    if (saved?.value is! List) return;
    for (final e in (saved!.value as List).whereType<Map>()) {
      final m = Map<String, dynamic>.from(e);
      final id = m['_id']?.toString() ?? '';
      if (id.isNotEmpty) _pending.putIfAbsent(id, () => m);
    }
  }

  void _savePending() {
    unawaited(StremioDiskCache.write(_kDiskPending, _pending.values.toList()));
  }

  /// Updates waiting to be sent (for the self test).
  Future<int> pendingCount() async {
    await _loadPending();
    return _pending.length;
  }

  /// Sends updates that failed earlier. If Stremio already has a newer copy
  /// of an item (changed on another device since), that copy wins.
  Future<void> flushPending() async {
    final authKey = _authKey;
    if (authKey == null || _flushing) return;
    await _loadPending();
    if (_pending.isEmpty) return;
    _flushing = true;
    try {
      final ids = _pending.keys.toList();
      final remote = await api.datastoreGet(authKey, ids: ids);
      final remoteMtime = {for (final r in remote) r.id: r.mtime};
      final toSend = <StremioLibraryItem>[];
      for (final id in ids) {
        final local = StremioLibraryItem(_pending[id]!);
        final theirs = remoteMtime[id];
        final mine = local.mtime;
        if (theirs == null || mine == null || mine.isAfter(theirs)) {
          toSend.add(local);
        }
      }
      if (toSend.isNotEmpty) await api.datastorePut(authKey, toSend);
      for (final id in ids) {
        _pending.remove(id);
      }
      _savePending();
      Logger.i('Stremio: sent ${toSend.length} update(s) saved while offline');
    } catch (e) {
      Logger.i('Stremio: offline updates still waiting: $e');
    } finally {
      _flushing = false;
    }
  }

  Future<StremioLibraryItem?> getLibraryItem(String id,
      {bool refresh = false}) async {
    if (!refresh && _libraryCache.containsKey(id)) return _libraryCache[id];
    if (!refresh && _libraryTrusted) return null;
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
    await _putOrQueue(key, item);
    if (watched) {
      unawaited(_syncToSimkl(StremioPlayback(
          libraryId: meta.id,
          type: meta.type,
          name: meta.name,
          videoId: video.id)));
    }
  }

  // ---- playback sync --------------------------------------------------------

  /// Bumped when more anime → Stremio matches are known (Home's Continue
  /// Watching row rebuilds to drop doubles).
  final RxInt animeMatchesVersion = 0.obs;
  final Set<String> _warming = {};

  // ---- anime Watch tab → Stremio streams -----------------------------------

  final Map<String, StremioAnimeTarget?> _animeTargets = {};

  // ---- AniList sync for Stremio watches -----------------------------------

  final Map<String, (String, int)?> _anilistTargets = {};
  final Map<String, Map<String, (int, int)>?> _aniZipEpisodes = {};

  // ---- AnymeX tracker progress → Stremio ------------------------------------

  final Map<String, DateTime> _recentPlayback = {};
  bool _suppressTrackerHook = false;

  /// Commentum (comments) id for a Stremio title: the AniList id when the
  /// title is anime and you comment as an AniList user (so it's the same
  /// thread as AnymeX's anime page), otherwise its IMDb/Stremio id.
  final Map<String, String> _commentIds = {};
}
