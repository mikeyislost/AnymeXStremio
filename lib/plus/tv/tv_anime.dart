import 'dart:async';
import 'dart:convert';

import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/controllers/source/source_controller.dart';
import 'package:anymex/database/data_keys/keys.dart';
import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/database/isar_models/video.dart' as hive;
import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/plus/custom_lists.dart';
import 'package:anymex/plus/for_you/anime_for_you.dart';
import 'package:anymex/plus/layout/page_rows.dart';
import 'package:anymex/plus/missed_sequels.dart';
import 'package:anymex/plus/tv/tv_link.dart';
import 'package:anymex/plus/tv/tv_play.dart';
import 'package:anymex/plus/tv/tv_sync.dart';
import 'package:anymex/screens/anime/details/controller/media_details_controller.dart';
import 'package:anymex/screens/anime/watch/controller/player_controller.dart';
import 'package:anymex/screens/anime/watch/watch_view.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/utils/logger.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// AnymeX+: anime on the TV app.
///
/// The TV shows your Home's anime rows (sent in the sync) and browses them
/// by itself. Episodes and video links come from the anime extensions, and
/// those only run here, so the TV asks this device:
///
///  * `anime {cmd: eps, id}`: the episode list of a show (found the same way
///    the details page finds it), answered with `animeEps`;
///  * `anime {cmd: play, id, n}`: play episode n. The servers are looked up,
///    one is picked (the one you used last for the show), and the player
///    opens here and goes straight to the TV (Play on TV). From there on it
///    is the same as starting Play on TV yourself: this device is the
///    remote and keeps your progress;
///  * `anime {cmd: server, i}`: switch to another server from the TV.
class PlusTvAnime {
  PlusTvAnime._();
  static final instance = PlusTvAnime._();

  static const _tag = 'plus-tv-anime';
  static const _kServers = 'plus_tv_anime_servers';
  static const maxCards = 30;

  bool _attached = false;
  MediaDetailsController? _details;
  String _detailsId = '';
  Worker? _coversWorker;
  int _playToken = 0;

  PlusTvLink get _link => PlusTvLink.instance;

  /// Starts listening (called when the link starts; safe to call again).
  /// [changed] is called when something the TV shows has changed here.
  void attach(void Function() changed) {
    if (_attached) return;
    _attached = true;
    _link.listeners.add(_onMessage);
    try {
      final auth = Get.find<AnilistAuth>();
      ever(auth.animeList, (_) => changed());
      ever(auth.isLoggedIn, (_) => changed());
      final data = Get.find<ServiceHandler>().anilistService;
      ever(data.trendingAnimes, (_) => changed());
      ever(data.popularAnimes, (_) => changed());
      ever(data.recentlyUpdatedAnimes, (_) => changed());
      ever(PlusCustomLists.lists, (_) => changed());
      ever(MissedSequels.candidates, (_) => changed());
      ever(AnimeForYou.picks, (_) => changed());
    } catch (e) {
      Logger.i('TV anime: attach: $e');
    }
  }

  // ---- what the TV's Home shows -------------------------------------------

  /// One anime card as the TV understands it.
  static Map<String, dynamic> card({
    required String id,
    required String name,
    String romaji = '',
    String poster = '',
    String sub = '',
    String rating = '',
    int at = 0,
  }) =>
      {
        'a': id,
        'name': name,
        if (romaji.isNotEmpty && romaji != '?' && romaji != name) 'romaji': romaji,
        if (poster.isNotEmpty && poster != '?') 'poster': poster,
        if (sub.isNotEmpty) 'sub': sub,
        if (rating.isNotEmpty && rating != '?' && rating != '0' && rating != '0.0') 'rating': rating,
        if (at > 0) 'at': at,
      };

  static List<Map<String, dynamic>> _fromTracked(Iterable<TrackedMedia> list, {bool withTime = false}) {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final a in list) {
      final id = a.id;
      if (id == null || id.isEmpty || !seen.add(id)) continue;
      out.add(card(
        id: id,
        name: a.title ?? a.romajiTitle ?? '?',
        romaji: a.romajiTitle ?? '',
        poster: a.poster ?? '',
        sub: a.formattedProgress,
        at: withTime ? (a.updatedAt ?? 0) * 1000 : 0,
      ));
      if (out.length >= maxCards) break;
    }
    return out;
  }

  static List<Map<String, dynamic>> _fromMedia(Iterable<Media> list) {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final m in list) {
      if (m.id.isEmpty || m.id == '0' || m.isAdult == true || !seen.add(m.id)) continue;
      out.add(card(id: m.id, name: m.title, romaji: m.romajiTitle, poster: m.poster, rating: m.rating));
      if (out.length >= maxCards) break;
    }
    return out;
  }

  /// Two rows are the same row when this is equal.
  static String rowSignature(Map<String, dynamic> r) {
    switch (r['kind']) {
      case 'cw':
        return 'cw';
      case 'tmdb':
        return 'tmdb|${r['path']}|${r['query']}';
      case 'cat':
        return 'cat|${r['base']}|${r['type']}|${r['id']}|${r['extra'] ?? ''}';
      case 'alq':
        return 'alq|${jsonEncode(r['vars'])}';
    }
    return '${r['kind']}|${r['title']}';
  }

  /// [home] rows first, then the [movies] rows that aren't among them yet.
  static List<Map<String, dynamic>> mergeRows(
      List<Map<String, dynamic>> home, List<Map<String, dynamic>> movies) {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final r in [...home, ...movies]) {
      if (seen.add(rowSignature(r))) out.add(r);
    }
    return out;
  }

  /// The TV's Home: the rows of this device's Home in your order (anime
  /// lists, discover rows, your filtered rows, Movies & TV rows), followed
  /// by the rest of the Movies & TV page. Without AniList it is the Movies
  /// & TV page alone, as before.
  static List<Map<String, dynamic>> homeRows() {
    final movies = PlusTvSync.tvRows();
    if (!PlusPageRows.appliesToCurrent) return movies;
    try {
      return mergeRows(_homeRows(), movies);
    } catch (e) {
      Logger.i('TV anime: rows: $e');
      return movies;
    }
  }

  static List<Map<String, dynamic>> _homeRows() {
    final auth = Get.find<AnilistAuth>();
    final data = Get.find<ServiceHandler>().anilistService;
    final loggedIn = auth.isLoggedIn.value;
    final mine = auth.animeList.toList();
    final out = <Map<String, dynamic>>[];

    void anime(String title, List<Map<String, dynamic>> cards) {
      if (cards.isNotEmpty) out.add({'kind': 'anime', 'title': title, 'cards': cards});
    }

    for (final r in PlusPageRows.homeRows(discoverByDefault: PlusPageRows.discoverByDefault)) {
      if (r.config.hidden) continue;
      final k = r.key;
      final title = r.title;
      if (r.config.added) {
        final p = r.config.params;
        if (p['kind'] == 'anilist' && p['type'] != 'MANGA') {
          out.add({'kind': 'alq', 'title': title, 'vars': PlusFilterRow.variablesFor(p)});
        } else if (p['kind'] == 'stremio' && p['rowKey'] is String) {
          final row = PlusTvSync.catalogRow(p['rowKey'] as String, title,
              genre: p['genre'] is String ? p['genre'] as String : null);
          if (row != null) out.add(row);
        }
      } else if (k.startsWith('list:')) {
        final label = plusListLabel(k);
        if (!loggedIn || label.contains('Manga') || label.contains('Reading')) continue;
        final list = filterListByLabel(mine, label);
        if (label == 'Continue Watching') {
          // One Continue Watching row, as on this device: the TV mixes in
          // your Movies & TV by itself.
          out.add({'kind': 'cw', 'title': title, 'anime': _fromTracked(list, withTime: true)});
        } else {
          anime(title, _fromTracked(list));
        }
      } else if (k.startsWith('custom:')) {
        final name = k.substring('custom:'.length);
        for (final (n, entries) in PlusCustomLists.lists) {
          if (n == name) anime(title, _fromTracked(entries));
        }
      } else if (k == 'missedSequels') {
        if (!loggedIn) continue;
        final onList = mine.map((m) => m.id).whereType<String>().toSet();
        anime(title, [
          for (final c in MissedSequels.visible(MissedSequels.candidates.toList(), onList).take(maxCards))
            card(id: '${c.id}', name: c.title, poster: c.poster, rating: c.averageScore),
        ]);
      } else if (k == 'forYou') {
        anime(title == k ? 'For you' : title, [
          for (final p in AnimeForYou.picks.where((p) => p.kind == 'anime').take(maxCards))
            card(id: p.id, name: p.title, poster: p.poster, rating: p.rating),
        ]);
      } else if (k == 'rec:anime') {
        final ids = mine.map((e) => e.id).toSet();
        final recs = [...data.popularAnimes, ...data.trendingAnimes, ...data.latestAnimes];
        anime(title, _fromMedia(loggedIn ? recs.where((e) => !ids.contains(e.id)) : recs));
      } else if (k == 'disc:recent') {
        anime(title, _fromMedia(data.recentlyUpdatedAnimes));
      } else if (k == 'disc:trending') {
        anime(title, _fromMedia(data.trendingAnimes));
      } else if (k == 'disc:popular') {
        anime(title, _fromMedia(data.popularAnimes));
      } else if (k == 'disc:completed') {
        anime(title, _fromMedia(data.latestAnimes));
      } else if (k == 'disc:upcoming') {
        anime(title, _fromMedia(data.upcomingAnimes));
      } else if (k.startsWith(plusHomeMoviesPrefix)) {
        final row = PlusTvSync.builtinRow(k.substring(plusHomeMoviesPrefix.length), title);
        if (row != null) out.add(row);
      }
    }
    return out;
  }

  // ---- the server to play ---------------------------------------------------

  /// Which of the servers to play: the one saved for the show (by its name
  /// or address), else the first with the same language (dub / sub) as the
  /// saved one, else the first. -1 when [exactOnly] and the saved one isn't
  /// there (yet).
  static int pickServer(List<String> names, List<String> urls, String? saved, {bool exactOnly = false}) {
    if (names.isEmpty) return -1;
    final want = (saved ?? '').trim();
    if (want.isNotEmpty) {
      for (var i = 0; i < names.length; i++) {
        if (names[i].toUpperCase() == want.toUpperCase() || (i < urls.length && urls[i] == want)) return i;
      }
      if (exactOnly) return -1;
      final dub = hive.isDubLabel(want);
      for (var i = 0; i < names.length; i++) {
        if (hive.isDubLabel(names[i]) == dub) return i;
      }
    }
    return exactOnly ? -1 : 0;
  }

  static Map<String, String> _savedServers() {
    try {
      final raw = KvHelper.get<String>(_kServers, defaultVal: '');
      if (raw.isNotEmpty) return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {}
    return <String, String>{};
  }

  /// The server last played on the TV for this show.
  static void rememberServer(String mediaId, String name) {
    if (mediaId.isEmpty || name.isEmpty) return;
    final all = _savedServers();
    all.remove(mediaId);
    all[mediaId] = name;
    while (all.length > 300) {
      all.remove(all.keys.first);
    }
    try {
      KvHelper.set(_kServers, jsonEncode(all));
    } catch (_) {}
  }

  static String? _serverFor(String mediaId) {
    String? sticky;
    try {
      sticky = DynamicKeys.stickyServer.get<String?>(mediaId);
    } catch (_) {}
    if (sticky != null && sticky.isNotEmpty) return sticky;
    return _savedServers()[mediaId];
  }

  // ---- what the TV asks -----------------------------------------------------

  void _onMessage(Map<String, dynamic> m) {
    if (m['t'] != 'anime') return;
    switch (m['cmd']) {
      case 'eps':
        unawaited(_episodes(m));
      case 'play':
        unawaited(_play(m));
      case 'server':
        final i = (m['i'] as num?)?.toInt() ?? -1;
        PlusTvPlay.instance.pickServer(i);
    }
  }

  Media _mediaFor(String id, Map<String, dynamic> m) {
    var name = '${m['name'] ?? ''}';
    var romaji = '${m['romaji'] ?? ''}';
    var poster = '${m['poster'] ?? ''}';
    try {
      final mine = Get.find<AnilistAuth>().animeList.firstWhereOrNull((a) => a.id == id);
      if (mine != null) {
        name = mine.title ?? name;
        romaji = mine.romajiTitle ?? romaji;
        poster = mine.poster ?? poster;
      }
    } catch (_) {}
    if (name.isEmpty) name = romaji;
    if (romaji.isEmpty) romaji = name;
    return Media(
      id: id,
      title: name.isEmpty ? '?' : name,
      romajiTitle: romaji.isEmpty ? '?' : romaji,
      englishTitle: name.isEmpty ? null : name,
      poster: poster.isEmpty ? '?' : poster,
      mediaType: ItemType.anime,
      serviceType: ServicesType.anilist,
    );
  }

  /// The show's details, loaded the way the details page loads them (the
  /// extension is searched, episodes get their names and pictures). One
  /// show is kept at a time.
  MediaDetailsController _detailsFor(String id, Map<String, dynamic> m) {
    final have = _details;
    if (have != null && _detailsId == id && !have.isClosed) return have;
    _dropDetails();
    _detailsId = id;
    final c = Get.put(MediaDetailsController(initialMedia: _mediaFor(id, m), tag: _tag), tag: _tag);
    _details = c;
    return c;
  }

  void _dropDetails() {
    _coversWorker?.dispose();
    _coversWorker = null;
    _details = null;
    _detailsId = '';
    try {
      Get.delete<MediaDetailsController>(tag: _tag, force: true);
    } catch (_) {}
  }

  static Future<void> _waitLoaded(MediaDetailsController c, Duration limit) async {
    final until = DateTime.now().add(limit);
    while (c.isLoading.value && !c.isClosed && DateTime.now().isBefore(until)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  static String _problem(MediaDetailsController c) {
    if (c.isLoading.value) return 'Your phone is still looking for this show. Try again in a moment.';
    switch (c.errorType.value) {
      case 'no_source':
        return 'No anime extension is set up in AnymeX+ on your phone.';
      case 'no_match':
        return "Your phone's extension (${c.activeSource.value?.name ?? '?'}) doesn't have this show. "
            'Open it on the phone to pick another source or match it by hand.';
      case 'empty':
        return 'No episodes found in ${c.activeSource.value?.name ?? 'the extension'}.';
    }
    final e = c.errorMessage.value;
    return e.isEmpty ? "Couldn't load the episodes." : (e.length > 160 ? '${e.substring(0, 160)}…' : e);
  }

  static int _progressOf(String id) {
    try {
      return Get.find<AnilistAuth>().animeList.firstWhereOrNull((a) => a.id == id)?.effectiveProgress ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// The answer to `eps` (also unit-tested).
  static Map<String, dynamic> episodesMessage({
    required String q,
    required String id,
    required List<Episode> episodes,
    required String source,
    required int progress,
    required String next,
    String error = '',
  }) =>
      {
        't': 'animeEps',
        'q': q,
        'id': id,
        'ok': error.isEmpty && episodes.isNotEmpty,
        if (error.isNotEmpty) 'err': error,
        'source': source,
        'progress': progress,
        'next': next,
        'eps': [
          for (final e in episodes)
            {
              'n': e.number,
              if ((e.title ?? '').isNotEmpty) 'title': e.title,
              if ((e.thumbnail ?? '').isNotEmpty) 'thumb': e.thumbnail,
              if (e.filler == true) 'filler': true,
            },
        ],
      };

  void _sendEpisodes(String q, MediaDetailsController c) {
    final id = c.media.value.id;
    final failed = c.isLoading.value || c.episodeError.value || c.episodeList.isEmpty;
    String next = '';
    try {
      next = c.getContinueEpisode()?.number ?? '';
    } catch (_) {}
    _link.send(episodesMessage(
      q: q,
      id: id,
      episodes: failed ? const [] : c.episodeList.toList(),
      source: c.activeSource.value?.name ?? '',
      progress: _progressOf(id),
      next: next,
      error: failed ? _problem(c) : '',
    ));
  }

  Future<void> _episodes(Map<String, dynamic> m) async {
    final q = '${m['q'] ?? ''}';
    final id = '${m['id'] ?? ''}';
    if (id.isEmpty) return;
    try {
      final c = _detailsFor(id, m);
      if (m['again'] == true && !c.isLoading.value && c.episodeError.value) c.retryFetch();
      await _waitLoaded(c, const Duration(seconds: 60));
      if (!identical(_details, c)) return; // the TV moved on to another show
      _sendEpisodes(q, c);
      // Names and pictures arrive a little later: send the list once more.
      _coversWorker?.dispose();
      _coversWorker = ever(c.episodeList, (_) {
        if (identical(_details, c) && !c.isLoading.value) _sendEpisodes(q, c);
      });
    } catch (e) {
      Logger.i('TV anime: episodes: $e');
      _link.send(episodesMessage(
          q: q, id: id, episodes: const [], source: '', progress: 0, next: '', error: _clean(e)));
    }
  }

  static String _clean(Object e) {
    final s = e.toString().replaceFirst('Exception: ', '');
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  Future<List<hive.Video>> _servers(Source source, Episode ep, String? saved) async {
    final episode = DEpisode(
      episodeNumber: ep.number,
      url: ep.link,
      sortMap: ep.sortMap.isEmpty ? null : ep.sortMap,
    );
    final params = SourceParams(cancelToken: 'tv_${DateTime.now().millisecondsSinceEpoch}_${ep.number}');
    final stream = source.methods.getVideoListStream(episode, parameters: params);
    if (stream == null) {
      final list =
          await source.methods.getVideoList(episode, parameters: params).timeout(const Duration(seconds: 45));
      return list.map((e) => hive.Video.fromVideo(e)).toList();
    }
    // Servers come in one by one. Enough: the saved one is there, or a
    // while has passed since the first one, or the extension is done.
    final out = <hive.Video>[];
    final done = Completer<void>();
    Timer? settle;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final sub = stream.listen(
      (data) {
        final v = hive.Video.fromVideo(data);
        if (out.any((x) => x.quality == v.quality && x.originalUrl == v.originalUrl)) return;
        out.add(v);
        final names = [for (final x in out) x.quality ?? ''];
        final urls = [for (final x in out) x.originalUrl ?? ''];
        if (pickServer(names, urls, saved, exactOnly: true) >= 0) finish();
        settle ??= Timer(const Duration(seconds: 10), finish);
      },
      onError: (Object e) {
        if (out.isEmpty && !done.isCompleted) {
          done.completeError(e);
        } else {
          finish();
        }
      },
      onDone: finish,
    );
    try {
      await done.future.timeout(const Duration(seconds: 45), onTimeout: () {});
    } finally {
      settle?.cancel();
      await sub.cancel();
    }
    return out;
  }

  Future<void> _play(Map<String, dynamic> m) async {
    final q = '${m['q'] ?? ''}';
    final id = '${m['id'] ?? ''}';
    final n = '${m['n'] ?? ''}';
    if (id.isEmpty || n.isEmpty) return;
    final my = ++_playToken;
    void say(String state, [String msg = '']) =>
        _link.send({'t': 'animePlay', 'q': q, 'id': id, 'n': n, 'state': state, 'msg': msg});
    try {
      final c = _detailsFor(id, m);
      if (c.isLoading.value) {
        say('wait', 'Your phone is finding the show…');
        await _waitLoaded(c, const Duration(seconds: 60));
      }
      if (my != _playToken) return;
      final ep = c.episodeList.firstWhereOrNull((e) => e.number == n);
      if (ep == null) {
        say('fail', c.episodeError.value || c.isLoading.value ? _problem(c) : "Episode $n isn't in the list on your phone.");
        return;
      }
      final sources = Get.find<SourceController>();
      final source = c.activeSource.value ?? sources.activeSource.value;
      if (source == null) {
        say('fail', 'No anime extension is set up in AnymeX+ on your phone.');
        return;
      }
      // The player looks up the next episode with the app's active source.
      if (sources.activeSource.value?.id != source.id) sources.setActiveSource(source, mediaId: id);

      // A player this device opened by itself is in the way; one you opened
      // yourself is yours.
      if (Get.isRegistered<PlayerController>()) {
        if (!await PlusTvPlay.instance.closeTvPlayer()) {
          say('fail', 'A video is open in AnymeX+ on your phone. Close it there first.');
          return;
        }
      }

      say('servers', 'Finding servers for episode $n…');
      final saved = _serverFor(id);
      final videos = await _servers(source, ep, saved);
      if (my != _playToken) return;
      if (videos.isEmpty) {
        say('fail', 'No servers found for episode $n.');
        return;
      }
      final pick = pickServer(
          [for (final v in videos) v.quality ?? ''], [for (final v in videos) v.originalUrl ?? ''], saved);
      final video = videos[pick < 0 ? 0 : pick];
      if ((video.url ?? '').isEmpty) {
        say('fail', "That server didn't give a video. Try again.");
        return;
      }

      final media = c.media.value;
      final handler = Get.find<ServiceHandler>();
      final online = handler.isLoggedIn.value && handler.serviceType.value != ServicesType.extensions;
      var track = online;
      if (online) {
        try {
          final dbId = '${media.id}_${media.serviceType.name}_${media.type}';
          track = DynamicKeys.trackingPermission.get<bool?>(dbId) ?? true;
        } catch (_) {}
      }
      final context = Get.context;
      if (context == null) {
        say('fail', 'Open AnymeX+ on your phone and try again.');
        return;
      }
      say('opening', 'Starting episode $n…');
      final route = MaterialPageRoute<void>(
        builder: (_) => WatchScreen(
          episodeSrc: video,
          episodeList: c.episodeList.toList(),
          anilistData: media,
          currentEpisode: ep,
          episodeTracks: videos,
          shouldTrack: track,
        ),
      );
      PlusTvPlay.instance.expectFromTv(media.id, route, onFailed: (why) => say('fail', why));
      unawaited(Navigator.of(context).push(route));
    } catch (e) {
      Logger.i('TV anime: play: $e');
      if (my == _playToken) say('fail', _clean(e));
    }
  }
}
