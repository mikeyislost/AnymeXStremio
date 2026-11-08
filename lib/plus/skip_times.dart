// AnymeX+: skip intros, recaps and credits on Movies & TV. Times come from
// TheIntroDB (free, community-run; looked up by IMDb id + season/episode),
// or else from the video's own chapter marks. They fill the same skip
// times AniSkip fills for anime, so the player's Skip button and auto-skip
// settings work unchanged.

import 'dart:convert';

import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/screens/anime/watch/controller/player_controller.dart';
import 'package:anymex/screens/anime/watch/player/media_kit_player.dart';
import 'package:anymex/utils/aniskip.dart' as aniskip;
import 'package:anymex/utils/logger.dart';
import 'package:http/http.dart' as http;

/// What a Movies & TV playback is, for the lookup.
typedef PlusSkipTarget = ({String imdb, int? season, int? episode});

/// One chapter of the video (start in seconds).
typedef PlusChapter = ({String title, double start});

class PlusSkipTimes {
  PlusSkipTimes._();

  static const _api = 'https://api.theintrodb.org/v4/media';
  static final Map<String, aniskip.EpisodeSkipTimes?> _cache = {};

  /// The IMDb title (and episode) behind a Stremio playback, or null when
  /// it isn't one (anime keeps AniSkip).
  static PlusSkipTarget? targetFor(String mediaId, String? videoId) {
    final ref = StremioIds.parse(mediaId);
    if (ref == null) return null;
    final link = (videoId == null || videoId.isEmpty) ? ref.$2 : videoId;
    final parts = link.split(':');
    if (!parts.first.startsWith('tt')) return null;
    if (parts.length >= 3) {
      return (
        imdb: parts[0],
        season: int.tryParse(parts[1]),
        episode: int.tryParse(parts[2]),
      );
    }
    return (imdb: parts[0], season: null, episode: null);
  }

  /// Skip times for [target]: TheIntroDB first, then [chapters].
  static Future<aniskip.EpisodeSkipTimes?> load(
    PlusSkipTarget target, {
    int durationMs = 0,
    Future<List<PlusChapter>> Function()? chapters,
  }) async {
    final key = '${target.imdb}:${target.season}:${target.episode}';
    if (_cache.containsKey(key) && _cache[key] != null) return _cache[key];
    final fromDb = await _fromIntroDb(target, durationMs);
    if (fromDb != null) {
      _cache[key] = fromDb;
      return fromDb;
    }
    if (chapters == null) return null;
    try {
      return fromChapters(await chapters(), durationMs ~/ 1000);
    } catch (e) {
      Logger.i('Skip times: chapters unreadable: $e');
      return null;
    }
  }

  static Future<aniskip.EpisodeSkipTimes?> _fromIntroDb(
      PlusSkipTarget t, int durationMs) async {
    final q = <String, String>{
      'imdb_id': t.imdb,
      if (t.season != null) 'season': '${t.season}',
      if (t.episode != null) 'episode': '${t.episode}',
      if (durationMs > 0) 'duration_ms': '$durationMs',
    };
    try {
      final r = await http
          .get(Uri.parse(_api).replace(queryParameters: q))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      return fromIntroDbJson(jsonDecode(r.body), durationMs ~/ 1000);
    } catch (e) {
      Logger.i('Skip times: TheIntroDB failed: $e');
      return null;
    }
  }

  /// TheIntroDB's answer → skip times. Each of intro / recap / credits is
  /// a list (or a single entry) with start_ms / end_ms; a missing start
  /// means "from the beginning", a missing end "to the end".
  static aniskip.EpisodeSkipTimes? fromIntroDbJson(
      dynamic body, int durationSec) {
    if (body is! Map) return null;
    aniskip.SkipIntervals? pick(String name) {
      var v = body[name];
      if (v is List) v = v.isEmpty ? null : v.first;
      if (v is! Map) return null;
      final startMs = (v['start_ms'] as num?)?.toInt() ?? 0;
      final endMs = (v['end_ms'] as num?)?.toInt();
      final start = startMs ~/ 1000;
      final end = endMs != null
          ? (endMs / 1000).ceil()
          : (durationSec > 0 ? durationSec : null);
      if (end == null || end <= start) return null;
      return aniskip.SkipIntervals(start: start, end: end);
    }

    final op = pick('intro');
    final recap = pick('recap');
    final ed = pick('credits');
    if (op == null && recap == null && ed == null) return null;
    return aniskip.EpisodeSkipTimes(op: op, ed: ed, recap: recap);
  }

  /// Chapter marks → skip times, by chapter name ("Intro", "Opening",
  /// "Recap", "Previously", "Credits", "Ending", "Outro").
  static aniskip.EpisodeSkipTimes? fromChapters(
      List<PlusChapter> chapters, int durationSec) {
    if (chapters.length < 2) return null;
    final sorted = [...chapters]..sort((a, b) => a.start.compareTo(b.start));
    aniskip.SkipIntervals? op, recap, ed;
    for (var i = 0; i < sorted.length; i++) {
      final c = sorted[i];
      final kind = chapterKind(c.title);
      if (kind == null) continue;
      final start = c.start.floor();
      final end = i + 1 < sorted.length
          ? sorted[i + 1].start.ceil()
          : (durationSec > 0 ? durationSec : null);
      if (end == null || end <= start) continue;
      final interval = aniskip.SkipIntervals(start: start, end: end);
      switch (kind) {
        case 'intro':
          op ??= interval;
        case 'recap':
          recap ??= interval;
        case 'credits':
          ed ??= interval;
      }
    }
    if (op == null && recap == null && ed == null) return null;
    return aniskip.EpisodeSkipTimes(op: op, ed: ed, recap: recap);
  }

  /// intro | recap | credits for a chapter name, else null.
  static String? chapterKind(String title) {
    final t = title.toLowerCase().trim();
    if (t.isEmpty) return null;
    bool has(List<String> words) => words.any((w) =>
        RegExp('(^|[^a-z])${RegExp.escape(w)}([^a-z]|\$)').hasMatch(t));
    if (has(['recap', 'previously', 'previously on'])) return 'recap';
    if (has(['intro', 'opening', 'op', 'opening credits', 'theme song'])) {
      return 'intro';
    }
    if (has(['credits', 'end credits', 'ending', 'ed', 'outro', 'closing'])) {
      return 'credits';
    }
    return null;
  }
}

/// Fills [PlayerController.skipTimes] for a Movies & TV playback once the
/// video has loaded (its length picks the right cut on TheIntroDB, and its
/// chapters are only known then).
Future<void> plusAttachSkipTimes(
    PlayerController c, PlusSkipTarget target) async {
  final link = c.currentEpisode.value.link;
  for (var i = 0; i < 60 && c.episodeDuration.value.inSeconds < 5; i++) {
    await Future.delayed(const Duration(milliseconds: 500));
    if (c.currentEpisode.value.link != link) return;
  }
  final result = await PlusSkipTimes.load(
    target,
    durationMs: c.episodeDuration.value.inMilliseconds,
    chapters: () => _mpvChapters(c),
  );
  if (c.currentEpisode.value.link != link) return;
  c.skipTimes = result;
  if (result != null) {
    Logger.i('Skip times for ${target.imdb}: intro ${result.op != null}, '
        'recap ${result.recap != null}, credits ${result.ed != null}');
  }
}

Future<List<PlusChapter>> _mpvChapters(PlayerController c) async {
  final base = c.basePlayer;
  if (base is! MediaKitPlayer) return const [];
  final dynamic mpv = base.nativePlayer.platform; // mpv (NativePlayer)
  if (mpv == null) return const [];
  Future<String> prop(String name) async => '${await mpv.getProperty(name)}';
  final count = int.tryParse(await prop('chapter-list/count')) ?? 0;
  final out = <PlusChapter>[];
  for (var i = 0; i < count && i < 64; i++) {
    final title = await prop('chapter-list/$i/title');
    final time = double.tryParse(await prop('chapter-list/$i/time'));
    if (time != null) out.add((title: title, start: time));
  }
  return out;
}
