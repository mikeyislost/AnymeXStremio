// AnymeX+: the Info tab on Stremio title pages, built from AnymeX's own
// info sections. Anime is looked up on AniList (same data as AnymeX's anime
// pages); movies and TV come from Simkl when a Simkl client id is set, and
// otherwise from the addon's metadata (Cinemeta) plus TVmaze for shows.

import 'dart:convert';

import 'package:anymex/controllers/service_handler/params.dart';
import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/services/anilist/anilist_data.dart';
import 'package:anymex/controllers/services/simkl/simkl_auth_v2.dart';
import 'package:anymex/controllers/services/stremio/stremio_models.dart';
import 'package:anymex/controllers/services/stremio/stremio_service.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/screens/anime/details/media_details_page.dart';
import 'package:anymex/screens/anime/details/widgets/media_characters_section.dart';
import 'package:anymex/screens/anime/details/widgets/media_stats_section.dart';
import 'package:anymex/screens/anime/widgets/movie_watch_card.dart'
    show formatMovieRuntime;
import 'package:anymex/screens/anime/widgets/voice_actor.dart';
import 'package:anymex/screens/stremio/stremio_widgets.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/utils/logger.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/utils/ui_extensions/sizing.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_image.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_progress.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/common/reusable_carousel.dart';
import 'package:anymex/widgets/helper/tv_wrapper.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart'
    show ItemType;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

enum StremioInfoSource { anilist, simkl, stremio }

class _CastMember {
  final String name;
  final String? role;
  final String? photo;
  const _CastMember(this.name, this.role, this.photo);
}

class _Trailer {
  final String label;
  final String ytId;
  const _Trailer(this.label, this.ytId);
}

/// Everything the Info tab shows for one title.
class StremioInfo {
  final StremioInfoSource source;
  final Media media;

  /// Only for [StremioInfoSource.stremio]: label → value facts.
  final List<MapEntry<String, String>> facts;
  final List<_CastMember> cast;
  final List<_Trailer> trailers;
  final String? awards;
  final String? imdbId;

  const StremioInfo({
    required this.source,
    required this.media,
    this.facts = const [],
    this.cast = const [],
    this.trailers = const [],
    this.awards,
    this.imdbId,
  });

  int get castCount =>
      (media.characters ?? const []).isNotEmpty ? media.characters!.length : cast.length;

  bool get castHasPhotos => cast.any((c) => (c.photo ?? '').isNotEmpty) ||
      (media.characters ?? const []).any((c) => (c.image ?? '').isNotEmpty);

  String get sourceLabel => switch (source) {
        StremioInfoSource.anilist => 'AniList',
        StremioInfoSource.simkl => 'Simkl',
        StremioInfoSource.stremio => 'Cinemeta',
      };
}

class StremioInfoLoader {
  static final Map<String, StremioInfo> _cache = {};

  /// AniList (anime) → Simkl (needs a client id) → addon metadata.
  static Future<StremioInfo> load(StremioMeta meta, {int? season}) async {
    final key = '${meta.id}|${season ?? 0}';
    final cached = _cache[key];
    if (cached != null) return cached;
    StremioInfo? info;
    try {
      info = await _fromAnilist(meta, season);
    } catch (e) {
      Logger.i('Stremio info: AniList lookup failed: $e');
    }
    if (info == null) {
      try {
        info = await _fromSimkl(meta);
      } catch (e) {
        Logger.i('Stremio info: Simkl lookup failed: $e');
      }
    }
    info ??= await _fromStremio(meta);
    _cache[key] = info;
    return info;
  }

  static Future<StremioInfo?> _fromAnilist(StremioMeta meta, int? season) async {
    final id = await StremioService.to.anilistIdFor(meta, season: season);
    if (id == null) return null;
    final media = await Get.find<AnilistData>()
        .fetchDetails(FetchDetailsParams(id: id));
    if (media.title.isEmpty || media.title == '?') return null;
    return StremioInfo(source: StremioInfoSource.anilist, media: media);
  }

  /// IMDb id → (kind, Simkl id), read from the Location header of Simkl's
  /// /redirect endpoint. Works without a Simkl login (search needs one for
  /// apps registered with Simkl's newer AUTH V2).
  static Future<(String, String)?> simklIdForImdb(String imdb) async {
    final client = http.Client();
    try {
      final req = http.Request(
          'GET',
          SimklAuthV2.withAppParams(Uri.parse(
              'https://api.simkl.com/redirect?to=simkl&imdb=$imdb')))
        ..followRedirects = false
        ..headers.addAll(SimklAuthV2.baseHeaders);
      final resp = await client.send(req).timeout(const Duration(seconds: 15));
      final loc = resp.headers['location'];
      await resp.stream.drain<void>();
      if (loc == null) return null;
      final m = RegExp(r'/(movies|tv|anime)/(\d+)').firstMatch(loc);
      if (m == null) return null;
      return (m.group(1)!, m.group(2)!);
    } finally {
      client.close();
    }
  }

  static Future<StremioInfo?> _fromSimkl(StremioMeta meta) async {
    if (SimklAuthV2.clientId == null) return null;
    final imdb = _imdbIdOf(meta);
    if (imdb == null) return null;
    final found = await simklIdForImdb(imdb);
    if (found == null) return null;
    final (kind, simklId) = found;
    if (kind == 'anime') return null; // anime info comes from AniList
    final isMovie = kind == 'movies';
    final resp = await http
        .get(
            SimklAuthV2.withAppParams(Uri.parse(
                'https://api.simkl.com/${isMovie ? 'movies' : 'tv'}/$simklId?extended=full')),
            headers: SimklAuthV2.baseHeaders)
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      Logger.i('Stremio info: Simkl details HTTP ${resp.statusCode}');
      return null;
    }
    final data = Map<String?, dynamic>.from(jsonDecode(resp.body) as Map);
    data['id'] = '$simklId*${isMovie ? 'MOVIE' : 'SERIES'}';
    data['__isMovie'] = isMovie;
    final media = Media.fromSimkl(data, isMovie);
    if (media.title.isEmpty || media.title == '?') return null;
    return StremioInfo(
      source: StremioInfoSource.simkl,
      media: media,
      imdbId: imdb,
      cast: await _castFor(meta, isMovie: isMovie),
    );
  }

  static String? get _tmdbKey {
    final k = dotenv.env['TMDB_API_KEY'];
    return (k == null || k.trim().isEmpty) ? null : k.trim();
  }

  /// Cast with photos from TMDB (needs TMDB_API_KEY), found by IMDb id.
  static Future<List<_CastMember>> _tmdbCast(String imdb, bool isMovie) async {
    final key = _tmdbKey;
    if (key == null) return const [];
    final find = await http
        .get(Uri.parse('https://api.themoviedb.org/3/find/$imdb'
            '?api_key=$key&external_source=imdb_id'))
        .timeout(const Duration(seconds: 12));
    if (find.statusCode != 200) return const [];
    final data = jsonDecode(find.body);
    if (data is! Map) return const [];
    final movies = data['movie_results'] is List ? data['movie_results'] as List : const [];
    final shows = data['tv_results'] is List ? data['tv_results'] as List : const [];
    final useMovie = isMovie ? movies.isNotEmpty : shows.isEmpty && movies.isNotEmpty;
    final hit = useMovie
        ? (movies.isNotEmpty ? movies.first : null)
        : (shows.isNotEmpty ? shows.first : null);
    if (hit is! Map || hit['id'] == null) return const [];
    final path = useMovie
        ? 'movie/${hit['id']}/credits'
        : 'tv/${hit['id']}/aggregate_credits';
    final credits = await http
        .get(Uri.parse('https://api.themoviedb.org/3/$path?api_key=$key'))
        .timeout(const Duration(seconds: 12));
    if (credits.statusCode != 200) return const [];
    final c = jsonDecode(credits.body);
    final list = c is Map && c['cast'] is List ? c['cast'] as List : const [];
    final out = <_CastMember>[];
    for (final e in list.whereType<Map>().take(25)) {
      final name = e['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      String? role = e['character']?.toString();
      if ((role == null || role.isEmpty) && e['roles'] is List) {
        final roles = (e['roles'] as List).whereType<Map>();
        if (roles.isNotEmpty) role = roles.first['character']?.toString();
      }
      final photo = e['profile_path']?.toString();
      out.add(_CastMember(
          name,
          role,
          (photo == null || photo.isEmpty)
              ? null
              : 'https://image.tmdb.org/t/p/w185$photo'));
    }
    return out;
  }

  /// Best available cast for a movie/show: TMDB, then the addon's own list
  /// (Cinemeta has photos), then TVmaze for shows, then names only.
  static Future<List<_CastMember>> _castFor(StremioMeta meta,
      {required bool isMovie}) async {
    final imdb = _imdbIdOf(meta);
    if (imdb != null) {
      try {
        final tmdb = await _tmdbCast(imdb, isMovie);
        if (tmdb.isNotEmpty) return tmdb;
      } catch (e) {
        Logger.i('Stremio info: TMDB cast failed: $e');
      }
    }
    final extras = meta.raw['app_extras'] is Map
        ? Map<String, dynamic>.from(meta.raw['app_extras'] as Map)
        : const <String, dynamic>{};
    final cast = <_CastMember>[];
    if (extras['cast'] is List) {
      for (final c in (extras['cast'] as List).whereType<Map>()) {
        final name = c['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        cast.add(_CastMember(
            name, c['character']?.toString(), c['photo']?.toString()));
      }
    }
    if (cast.isNotEmpty) return cast;
    if (!isMovie && imdb != null) {
      try {
        final r = await http
            .get(Uri.parse('https://api.tvmaze.com/lookup/shows?imdb=$imdb'))
            .timeout(const Duration(seconds: 12));
        if (r.statusCode == 200) {
          final show = jsonDecode(r.body);
          if (show is Map && show['id'] != null) {
            cast.addAll(await _tvmazeCast(show['id']));
          }
        }
      } catch (_) {}
      if (cast.isNotEmpty) return cast;
    }
    return meta.cast.take(15).map((c) => _CastMember(c, null, null)).toList();
  }

  static Future<List<_CastMember>> _tvmazeCast(dynamic showId) async {
    final out = <_CastMember>[];
    final c = await http
        .get(Uri.parse('https://api.tvmaze.com/shows/$showId/cast'))
        .timeout(const Duration(seconds: 12));
    if (c.statusCode != 200) return out;
    for (final e in (jsonDecode(c.body) as List).whereType<Map>()) {
      final person = e['person'] is Map ? e['person'] as Map : {};
      final character = e['character'] is Map ? e['character'] as Map : {};
      final name = person['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final img = person['image'] is Map
          ? (person['image'] as Map)['medium']?.toString()
          : null;
      out.add(_CastMember(name, character['name']?.toString(), img));
    }
    return out;
  }

  static String? _imdbIdOf(StremioMeta meta) {
    if (meta.id.startsWith('tt')) return meta.id.split(':').first;
    final raw = meta.raw['imdb_id']?.toString();
    return (raw != null && raw.startsWith('tt')) ? raw : null;
  }

  static List<String> _strs(dynamic v) {
    if (v is List) {
      return v
          .map((e) => e is Map ? (e['name'] ?? '').toString() : e.toString())
          .where((s) => s.trim().isNotEmpty)
          .toList();
    }
    if (v is String && v.trim().isNotEmpty) {
      return v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
    return const [];
  }

  static String _date(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  /// Built from the addon's own metadata, plus TVmaze for shows.
  static Future<StremioInfo> _fromStremio(StremioMeta meta) async {
    final raw = meta.raw;
    final extras = raw['app_extras'] is Map
        ? Map<String, dynamic>.from(raw['app_extras'] as Map)
        : const <String, dynamic>{};
    final isSeries = !meta.isSingleVideo;
    final imdb = _imdbIdOf(meta);

    var directors = _strs(raw['director']);
    if (directors.isEmpty) directors = _strs(extras['directors']);
    var writers = _strs(raw['writer']);
    if (writers.isEmpty) writers = _strs(extras['writers']);
    final country = raw['country']?.toString();
    final awards = raw['awards']?.toString();

    final cast = await _castFor(meta, isMovie: !isSeries);

    final trailers = <_Trailer>[];
    if (raw['trailers'] is List) {
      for (final t in (raw['trailers'] as List).whereType<Map>()) {
        final id = t['source']?.toString() ?? '';
        if (id.isNotEmpty) {
          trailers.add(_Trailer(t['type']?.toString() ?? 'Trailer', id));
        }
      }
    }
    if (trailers.isEmpty && raw['trailerStreams'] is List) {
      for (final t in (raw['trailerStreams'] as List).whereType<Map>()) {
        final id = t['ytId']?.toString() ?? '';
        if (id.isNotEmpty) {
          trailers.add(_Trailer(t['title']?.toString() ?? 'Trailer', id));
        }
      }
    }

    // TVmaze (no key needed): status, network and dates for shows.
    Map<String, dynamic>? show;
    if (isSeries && imdb != null) {
      try {
        final r = await http
            .get(Uri.parse('https://api.tvmaze.com/lookup/shows?imdb=$imdb'))
            .timeout(const Duration(seconds: 12));
        if (r.statusCode == 200) {
          show = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
        }
      } catch (e) {
        Logger.i('Stremio info: TVmaze lookup failed: $e');
      }
    }

    final seasons = meta.seasons.where((s) => s != 0).length;
    final episodes = meta.videos.where((v) => (v.season ?? 1) != 0).length;
    final network = show == null
        ? null
        : ((show['network'] is Map ? show['network']['name'] : null) ??
                (show['webChannel'] is Map ? show['webChannel']['name'] : null))
            ?.toString();
    final status = show?['status']?.toString();
    final premiered = _date(show?['premiered']?.toString());
    final ended = _date(show?['ended']?.toString());
    final released = _date(raw['released']?.toString());

    final facts = <MapEntry<String, String>>[
      MapEntry('Type', stremioTypeLabel(meta.type, plural: false)),
      if (status != null && status.isNotEmpty) MapEntry('Status', status),
      if (network != null && network.isNotEmpty) MapEntry('Network', network),
      if (!isSeries && released.isNotEmpty)
        MapEntry('Released', released)
      else if (premiered.isNotEmpty)
        MapEntry('Aired',
            ended.isNotEmpty ? '$premiered – $ended' : 'Since $premiered')
      else if ((meta.releaseInfo ?? '').isNotEmpty)
        MapEntry('Released', meta.releaseInfo!),
      if ((meta.runtime ?? '').isNotEmpty)
        MapEntry(isSeries ? 'Episode length' : 'Runtime',
            formatMovieRuntime(meta.runtime!)),
      if (isSeries && seasons > 0) MapEntry('Seasons', '$seasons'),
      if (isSeries && episodes > 0) MapEntry('Episodes', '$episodes'),
      if (directors.isNotEmpty)
        MapEntry(directors.length > 1 ? 'Directors' : 'Director',
            directors.take(3).join(', ')),
      if (writers.isNotEmpty) MapEntry('Writers', writers.take(3).join(', ')),
      if (country != null && country.isNotEmpty) MapEntry('Country', country),
      if ((meta.imdbRating ?? '').isNotEmpty)
        MapEntry('IMDb', '★ ${meta.imdbRating}'),
    ];

    final poster = meta.poster ?? meta.background ?? '';
    final media = Media(
      id: meta.id,
      title: meta.name,
      romajiTitle: meta.name,
      description: meta.description ?? '',
      poster: poster,
      largePoster: poster,
      cover: meta.background,
      genres: meta.genres,
      format: meta.type == 'movie' ? 'Movie' : 'TV',
      rating: meta.imdbRating ?? '?',
      serviceType: ServicesType.extensions,
    );
    return StremioInfo(
      source: StremioInfoSource.stremio,
      media: media,
      facts: facts,
      cast: cast,
      trailers: trailers.take(4).toList(),
      awards: (awards != null && awards.isNotEmpty) ? awards : null,
      imdbId: imdb,
    );
  }
}

/// The Info tab content (a box widget, put it in a SliverToBoxAdapter).
class StremioInfoTab extends StatefulWidget {
  final StremioMeta meta;

  /// Selected season, for shows with one AniList entry per season.
  final int? season;

  const StremioInfoTab({super.key, required this.meta, this.season});

  @override
  State<StremioInfoTab> createState() => _StremioInfoTabState();
}

class _StremioInfoTabState extends State<StremioInfoTab> {
  StremioInfo? _info;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant StremioInfoTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.meta.id != widget.meta.id ||
        oldWidget.season != widget.season) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _info = null);
    final info =
        await StremioInfoLoader.load(widget.meta, season: widget.season);
    if (mounted) setState(() => _info = info);
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: AnymeXProgressIndicator()),
      );
    }
    return info.source == StremioInfoSource.stremio
        ? _addonInfo(context, info)
        : _trackerInfo(context, info);
  }

  // ---- shared pieces ---------------------------------------------------------

  Widget _section(BuildContext context, String title, List<Widget> children) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.opaque(0.3, iReallyMeanIt: true),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colors.onSurface.opaque(0.08, iReallyMeanIt: true),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnymeXText(title, size: 14, variant: TextVariant.bold),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget _synopsis(BuildContext context, String text) {
    final clean = text.replaceAll(RegExp(r'<[^>]*>'), '').trim();
    if (clean.isEmpty || clean == '?') return const SizedBox.shrink();
    return _section(context, 'Synopsis', [
      AnymeXText(clean,
          size: 13, maxLines: 9999, overflow: TextOverflow.ellipsis),
    ]);
  }

  Widget _sourceLine(BuildContext context, StremioInfo info,
      {Widget? action}) {
    final colors = context.colors;
    return Row(
      children: [
        Icon(Icons.info_outline_rounded,
            size: 14, color: colors.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: AnymeXText('Info from ${info.sourceLabel}',
              size: 11, color: colors.onSurfaceVariant),
        ),
        if (action != null) action,
      ],
    );
  }

  Widget _spaced(List<Widget> children) {
    final visible = children
        .where((w) => !(w is SizedBox && w.child == null && w.height == 0))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < visible.length; i++) ...[
          visible[i],
          if (i < visible.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }

  // ---- AniList / Simkl: AnymeX's own sections ---------------------------------

  Widget _trackerInfo(BuildContext context, StremioInfo info) {
    final media = info.media;
    final isAnilist = info.source == StremioInfoSource.anilist;
    final rels = media.relations ?? const [];
    final staff = media.staff ?? const [];
    final colors = context.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: _spaced([
            _sourceLine(
              context,
              info,
              action: isAnilist
                  ? AnymexOnTap(
                      onTap: () => navigate(() => MediaDetailsPage(
                            media: Media(
                              id: media.id,
                              title: media.title,
                              poster: media.poster,
                              serviceType: ServicesType.anilist,
                              mediaType: ItemType.anime,
                            ),
                            tag: 'stremio-info-${media.id}',
                          )),
                      child: AnymeXText('Open in Anime',
                          size: 12,
                          variant: TextVariant.bold,
                          color: colors.primary),
                    )
                  : null,
            ),
            _synopsis(context, media.description),
            buildStatsGrid(context, media),
            buildAlternativeTitles(context, media),
            if (media.genres.isNotEmpty)
              _section(context, 'Genres', [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: media.genres
                      .map((g) => isAnilist
                          ? buildGenreChip(context, g, media.mediaType)
                          : StremioChip(g))
                      .toList(),
                ),
              ]),
            if (media.tags.isNotEmpty)
              _section(context, 'Tags', [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: media.tags
                      .map((t) => buildTagChip(context, t, media.mediaType))
                      .toList(),
                ),
              ]),
            if (isAnilist) buildSeasonsSection(context, media),
          ]),
        ),
        if ((media.characters ?? const []).isNotEmpty)
          buildCharactersSection(context, media)
        else if (info.cast.isNotEmpty)
          _castCarousel(context, info.cast),
        if (isAnilist && rels.isNotEmpty)
          ReusableCarousel(
            data: rels,
            title: 'Relations',
            variant: DataVariant.relation,
          ).bottomSpacing(16),
        if (staff.isNotEmpty) StaffCarousel(staff: staff).bottomSpacing(16),
        if (isAnilist && media.recommendations.isNotEmpty)
          ReusableCarousel(
            data: media.recommendations,
            title: 'Recommended Anime',
            variant: DataVariant.recommendation,
            type: ItemType.anime,
          ),
      ],
    );
  }

  // ---- Movies & TV from the addon (Cinemeta) + TVmaze ------------------------

  Widget _addonInfo(BuildContext context, StremioInfo info) {
    final media = info.media;
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: _spaced([
            _sourceLine(
              context,
              info,
              action: info.imdbId == null
                  ? null
                  : AnymexOnTap(
                      onTap: () => launchUrl(
                          Uri.parse('https://www.imdb.com/title/${info.imdbId}/'),
                          mode: LaunchMode.externalApplication),
                      child: AnymeXText('IMDb',
                          size: 12,
                          variant: TextVariant.bold,
                          color: colors.primary),
                    ),
            ),
            _synopsis(context, media.description),
            if (info.facts.isNotEmpty) _factsGrid(context, info.facts),
            if (media.genres.isNotEmpty)
              _section(context, 'Genres', [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: media.genres.map((g) => StremioChip(g)).toList(),
                ),
              ]),
            if (info.trailers.isNotEmpty)
              _section(context, 'Trailers', [
                for (final t in info.trailers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: AnymexOnTap(
                      onTap: () => launchUrl(
                          Uri.parse('https://www.youtube.com/watch?v=${t.ytId}'),
                          mode: LaunchMode.externalApplication),
                      child: Row(
                        children: [
                          Icon(Icons.play_circle_fill_rounded,
                              color: colors.primary, size: 22),
                          const SizedBox(width: 8),
                          Expanded(
                            child: AnymeXText(t.label,
                                size: 13, variant: TextVariant.semiBold),
                          ),
                          Icon(Icons.open_in_new_rounded,
                              size: 16, color: colors.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),
              ]),
            if (info.awards != null)
              _section(context, 'Awards', [
                AnymeXText(info.awards!, size: 13, maxLines: 6),
              ]),
          ]),
        ),
        if (info.cast.isNotEmpty) _castCarousel(context, info.cast),
      ],
    );
  }

  Widget _factsGrid(BuildContext context, List<MapEntry<String, String>> facts) {
    final colors = context.colors;
    return LayoutBuilder(builder: (context, constraints) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color:
              colors.surfaceContainerHighest.opaque(0.3, iReallyMeanIt: true),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: colors.onSurface.opaque(0.08, iReallyMeanIt: true),
          ),
        ),
        child: Wrap(
          spacing: 20,
          runSpacing: 12,
          children: facts
              .map((e) => ConstrainedBox(
                    constraints:
                        BoxConstraints(maxWidth: constraints.maxWidth - 28),
                    child: buildStatCard(context, e.key, e.value),
                  ))
              .toList(),
        ),
      );
    });
  }

  Widget _castCarousel(BuildContext context, List<_CastMember> cast) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: AnymeXText('Cast',
              size: 16, variant: TextVariant.bold, color: colors.primary),
        ),
        SizedBox(
          height: 84,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: cast.length,
            itemBuilder: (context, i) {
              final c = cast[i];
              return Container(
                width: 220,
                margin: const EdgeInsets.only(right: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest
                      .opaque(0.3, iReallyMeanIt: true),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: colors.onSurface.opaque(0.08, iReallyMeanIt: true),
                  ),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(30),
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: (c.photo != null && c.photo!.isNotEmpty)
                            ? AnymeXImage(
                                imageUrl: c.photo!, radius: 0, fit: BoxFit.cover)
                            : Container(
                                color: colors.primaryContainer
                                    .opaque(0.4, iReallyMeanIt: true),
                                child: Icon(Icons.person_rounded,
                                    color: colors.primary),
                              ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AnymeXText(c.name,
                              size: 13,
                              variant: TextVariant.semiBold,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          if (c.role != null && c.role!.isNotEmpty)
                            AnymeXText(c.role!,
                                size: 11,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                color: colors.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
