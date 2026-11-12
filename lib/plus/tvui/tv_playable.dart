import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/models/Media/media.dart' as anymex;
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/stremio/ui/stremio_player_bridge.dart';
import 'package:anymex/plus/tvui/tv_data.dart';

/// One episode (or the film) the TV can play.
class TvEp {
  final String videoId; // what Stremio stream addons are asked for
  final int season;
  final int number;
  final String title;
  final String thumb;
  const TvEp({required this.videoId, required this.season, required this.number, required this.title, this.thumb = ''});

  String get label => season > 0 && season != 1 ? 'S$season E$number' : 'Episode $number';
}

/// Something to play on the TV: a film, a series or an anime, with its
/// episodes in order. Streams come from the user's Stremio addons (anime
/// is matched to Kitsu / IMDb ids the same way the phone's Watch tab does).
class TvPlayable {
  final TvItem item;
  final String type; // movie | series | anime (Stremio type for addons)
  final String metaId; // tt…, kitsu:…
  final StremioMeta? meta;
  final List<TvEp> eps;

  /// Anime: AniList's media and the matched Stremio episodes.
  final anymex.Media? anime;
  final List<Episode> animeEps;

  const TvPlayable._({
    required this.item,
    required this.type,
    required this.metaId,
    required this.meta,
    required this.eps,
    this.anime,
    this.animeEps = const [],
  });

  bool get isAnime => anime != null;
  bool get isMovie => type == 'movie';
  String get titleKey => StremioService.streamTitleKey(metaId, eps.isEmpty ? metaId : eps.first.videoId);

  factory TvPlayable.stremio(TvItem item, StremioMeta meta) {
    final videos = meta.videos.toList()
      ..sort((a, b) => ((a.season ?? 1) * 100000 + (a.episode ?? 0)).compareTo((b.season ?? 1) * 100000 + (b.episode ?? 0)));
    final eps = meta.isSingleVideo || videos.isEmpty
        ? [TvEp(videoId: meta.singleVideoId, season: 0, number: 1, title: meta.name)]
        : [
            for (final v in videos)
              TvEp(
                videoId: v.id,
                season: v.season ?? 1,
                number: v.episode ?? 0,
                title: v.title.isEmpty ? 'Episode ${v.episode ?? ''}' : v.title,
                thumb: v.thumbnail ?? '',
              ),
          ];
    return TvPlayable._(item: item, type: meta.type, metaId: meta.id, meta: meta, eps: eps);
  }

  /// An anime from AniList, matched to the user's Stremio addons; null when
  /// none of them has it.
  static Future<TvPlayable?> anime(TvItem item) async {
    final media = anymex.Media(
      id: item.id,
      idMal: item.idMal.isEmpty ? '0' : item.idMal,
      title: item.title,
      romajiTitle: item.title,
      englishTitle: item.title,
      poster: item.poster,
      largePoster: item.poster,
      cover: item.backdrop,
      description: item.description,
      totalEpisodes: item.episodes.isEmpty ? '?' : item.episodes,
      format: item.format.isEmpty ? '?' : item.format.replaceAll(' ', '_'),
      genres: item.genres,
      serviceType: ServicesType.anilist,
    );
    final target = await StremioService.to.animeTarget(media);
    if (target == null || target.episodes.isEmpty || target.addonNames.isEmpty) return null;
    final eps = [
      for (final e in target.episodes)
        TvEp(
          videoId: e.link ?? '',
          season: 1,
          number: int.tryParse(e.number) ?? 1,
          title: (e.title ?? '').isEmpty ? 'Episode ${e.number}' : e.title!,
          thumb: e.thumbnail ?? '',
        ),
    ];
    return TvPlayable._(
      item: item,
      type: target.type,
      metaId: target.libraryId,
      meta: target.meta,
      eps: eps,
      anime: media,
      animeEps: target.episodes,
    );
  }

  int indexOf(TvEp e) => eps.indexWhere((x) => x.videoId == e.videoId);

  TvEp? epFor({String? videoId, int? number}) {
    for (final e in eps) {
      if (videoId != null && videoId.isNotEmpty && e.videoId == videoId) return e;
    }
    if (number != null) {
      for (final e in eps) {
        if (e.number == number && e.season != 0) return e;
      }
    }
    return null;
  }

  /// The episode after [e], skipping specials.
  TvEp? next(TvEp e) {
    final i = indexOf(e);
    if (i < 0) return null;
    for (var j = i + 1; j < eps.length; j++) {
      if (eps[j].season == 0 && e.season != 0) continue;
      final v = meta?.videos.firstWhereOrNull((v) => v.id == eps[j].videoId);
      if (v != null && !v.isReleased) return null;
      return eps[j];
    }
    return null;
  }

  /// The media and episode progress is reported with (Stremio, AniList).
  (anymex.Media, Episode) reportFor(TvEp e) {
    if (anime != null) {
      final ep = animeEps.firstWhereOrNull((x) => x.link == e.videoId) ?? Episode(number: '${e.number}', link: e.videoId, title: e.title);
      return (anime!, ep);
    }
    final m = meta!;
    final video = m.videos.firstWhereOrNull((v) => v.id == e.videoId);
    return (StremioPlayerBridge.mediaFor(m, season: video?.season ?? 1), StremioPlayerBridge.episodeFor(m, video));
  }
}

extension<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final x in this) {
      if (test(x)) return x;
    }
    return null;
  }
}
