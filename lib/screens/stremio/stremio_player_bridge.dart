// Glue between Stremio content and AnymeX's existing player (WatchScreen).

import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/services/stremio/stremio_models.dart';
import 'package:anymex/controllers/services/stremio/stremio_service.dart';
import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/database/isar_models/track.dart' as model;
import 'package:anymex/database/isar_models/video.dart' as model;
import 'package:anymex/models/Media/media.dart' as anymex;
import 'package:anymex/screens/anime/watch/watch_view.dart';
import 'package:anymex/utils/function.dart';

class StremioPlayerBridge {
  /// Remembers which Stremio stream each player track came from, so the
  /// next episode can auto-pick a stream from the same "binge group".
  static final Map<String, StremioStream> _streamByUrl = {};

  static const String torrentFileParam = 'anymex_fidx';

  static anymex.Media mediaFor(StremioMeta meta, {int? season}) {
    final poster = meta.poster ?? meta.background ?? '';
    return anymex.Media(
      id: StremioIds.mediaId(meta.type, meta.id,
          season: meta.isSingleVideo ? null : season),
      idMal: '0',
      title: meta.name,
      romajiTitle: meta.name,
      englishTitle: meta.name,
      description: meta.description ?? '',
      poster: poster,
      largePoster: poster,
      cover: meta.background ?? meta.poster,
      totalEpisodes: meta.isSingleVideo ? '1' : '${meta.videos.length}',
      type: 'ANIME',
      format: meta.type == 'movie' ? 'MOVIE' : 'TV',
      status: 'RELEASING',
      genres: meta.genres,
      rating: meta.imdbRating ?? '?',
      serviceType: ServicesType.extensions,
      sourceName: 'Stremio',
    );
  }

  static Episode episodeFor(StremioMeta meta, StremioVideo? video) {
    if (video == null) {
      return Episode(
        number: '1',
        title: meta.name,
        link: meta.singleVideoId,
        thumbnail: meta.background ?? meta.poster,
        desc: meta.description,
        source: 'Stremio',
      );
    }
    final season = video.season ?? 1;
    return Episode(
      number: '${video.episode ?? 1}',
      title: video.title.isNotEmpty
          ? video.title
          : 'S${season}E${video.episode ?? 1}',
      link: video.id,
      thumbnail: video.thumbnail,
      desc: video.overview,
      dateUpload: video.released?.toIso8601String(),
      sortKeys: const ['season'],
      sortVals: ['$season'],
      source: 'Stremio',
    );
  }

  /// Episodes of one season (or the single movie episode).
  static List<Episode> episodesFor(StremioMeta meta, int? season) {
    if (meta.isSingleVideo || season == null) {
      return [episodeFor(meta, null)];
    }
    return meta
        .videosForSeason(season)
        .map((v) => episodeFor(meta, v))
        .toList();
  }

  static model.Video videoFromStream(StremioStream s) {
    final url = s.playableUrl!;
    _streamByUrl[url] = s;
    return model.Video(
      url: url,
      originalUrl: url,
      quality: s.label,
      headerKeys: s.requestHeaders.keys.toList(),
      headerValues: s.requestHeaders.values.toList(),
      subtitles: s.subtitles
          .map((e) => model.Track(file: e['url'], label: e['lang']))
          .toList(),
      audios: const [],
    );
  }

  static List<model.Video> videosFromStreams(List<StremioStream> streams) =>
      streams.where((s) => s.isPlayable).map(videoFromStream).toList();

  /// Opens the AnymeX player for [selected].
  static Future<void> play({
    required StremioMeta meta,
    StremioVideo? video,
    required StremioStream selected,
    required List<StremioStream> allStreams,
  }) async {
    final season = video?.season ?? 1;
    final episodes = episodesFor(meta, video == null ? null : season);
    final current = video == null
        ? episodes.first
        : (episodes.firstWhereOrNull((e) => e.link == video.id) ??
            episodeFor(meta, video));
    final tracks = videosFromStreams(allStreams);
    final selectedTrack = videoFromStream(selected);
    if (!tracks.any((t) => t.url == selectedTrack.url)) {
      tracks.insert(0, selectedTrack);
    }
    await navigate(() => WatchScreen(
          episodeSrc: selectedTrack,
          currentEpisode: current,
          episodeList: episodes,
          anilistData: mediaFor(meta, season: video == null ? null : season),
          episodeTracks: tracks,
          shouldTrack: true,
        ));
  }

  /// Used by the player when switching episodes on Stremio media: fetches the
  /// new episode's streams and orders them so the best match comes first.
  static Future<List<model.Video>> videosForEpisode(
    anymex.Media media,
    Episode episode, {
    model.Video? previous,
  }) async {
    final parsed = StremioIds.parse(media.id);
    if (parsed == null) return [];
    final (type, metaId) = parsed;
    final videoId = (episode.link != null && episode.link!.isNotEmpty)
        ? episode.link!
        : metaId;
    final streams = await StremioService.to.fetchStreams(type, videoId);
    final playable = streams.where((s) => s.isPlayable).toList();
    if (playable.isEmpty) return [];

    final prev = previous?.url != null ? _streamByUrl[previous!.url!] : null;
    StremioStream? best;
    if (prev != null) {
      if (prev.bingeGroup != null) {
        best = playable.firstWhereOrNull((s) => s.bingeGroup == prev.bingeGroup);
      }
      best ??= playable.firstWhereOrNull(
          (s) => s.addonName == prev.addonName && s.name == prev.name);
      best ??= playable.firstWhereOrNull((s) => s.addonName == prev.addonName);
    }
    if (best != null) {
      playable
        ..remove(best)
        ..insert(0, best);
    }
    return videosFromStreams(playable);
  }

  /// Splits our private torrent file-index marker off a magnet link.
  /// Returns the clean magnet and the TorrServer file id to play. Stremio's
  /// `fileIdx` is 0-based; TorrServer file ids start at 1.
  static (String, int?) splitTorrentFileIndex(String url) {
    final match = RegExp('[?&]$torrentFileParam=(\\d+)').firstMatch(url);
    if (match == null) return (url, null);
    final fileIdx = int.tryParse(match.group(1)!);
    final idx = fileIdx == null ? null : fileIdx + 1;
    var cleaned = url.replaceFirst(match.group(0)!, '');
    if (!cleaned.contains('?') && cleaned.contains('&')) {
      cleaned = cleaned.replaceFirst('&', '?');
    }
    return (cleaned, idx);
  }
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
