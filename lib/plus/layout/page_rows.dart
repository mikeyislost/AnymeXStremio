// AnymeX+: the rows of Home (AniList) and Manga as "Edit layout" sees
// them, and how each one is drawn. Home also holds the Anime tab's rows
// (Recently Updated, Trending, Popular, …), so they can be mixed with
// your lists.

import 'dart:convert';

import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/controllers/settings/settings.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/plus/continue_watching_row.dart';
import 'package:anymex/plus/custom_lists.dart';
import 'package:anymex/plus/layout/layout_model.dart';
import 'package:anymex/plus/layout/layout_store.dart';
import 'package:anymex/plus/layout/row_scope.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/stremio/ui/stremio_home_page.dart';
import 'package:anymex/plus/stremio/ui/stremio_widgets.dart' show stremioTypeLabel;
import 'package:anymex/utils/function.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/common/reusable_carousel.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// Row keys of the Anime tab's rows, in AniList's `animeWidgets` order.
const plusDiscoverRows = <(String, String)>[
  ('disc:carousel', 'Trending banner'),
  ('disc:recent', 'Recently Updated'),
  ('disc:trending', 'Trending Anime'),
  ('disc:popular', 'Popular Anime'),
  ('disc:completed', 'Recently Completed'),
  ('disc:upcoming', 'Upcoming Anime'),
  ('disc:community', 'Community Recommendations'),
];

/// Row keys of the Manga tab's rows (AniList `mangaWidgets`).
const plusMangaRows = <(String, String)>[
  ('m:carousel', 'Trending banner'),
  ('m:trending', 'Trending Manga'),
  ('m:latest', 'Latest Manga'),
  ('m:popular', 'Popular Manga'),
  ('m:more', 'More Popular Manga'),
  ('m:novels', 'Novels (your extensions)'),
  ('m:community', 'Community Recommendations'),
];

/// AniList list rows on Home ("Continue Watching", "Planning Animes"…)
/// follow AnymeX's own Home switches, so both stay in step.
String plusListLabel(String key) => key.substring('list:'.length);

class PlusPageRows {
  PlusPageRows._();

  static bool appliesTo(ServiceHandler handler) =>
      handler.serviceType.value == ServicesType.anilist;

  static bool get appliesToCurrent {
    try {
      return appliesTo(Get.find<ServiceHandler>());
    } catch (_) {
      return false;
    }
  }

  /// The Anime tab's rows show on Home unless an Anime / Discover tab is
  /// still in the nav bar.
  static bool get discoverByDefault {
    try {
      final tabs = Get.find<Settings>().navigationTabOrder;
      return !tabs.contains('Anime') && !tabs.contains('Discover');
    } catch (_) {
      return true;
    }
  }

  static Map<String, bool> get _homeCards {
    try {
      return Get.find<Settings>().homePageCards;
    } catch (_) {
      return const {};
    }
  }

  // ---- specs ----------------------------------------------------------------

  static List<PlusRowSpec> homeSpecs({required bool discoverByDefault}) {
    final cards = _homeCards;
    return [
      const PlusRowSpec('buttons', 'Anime list · Manga list · Other',
          styled: false),
      const PlusRowSpec('newEpisodes', 'New episodes', styled: false),
      for (final e in cards.entries)
        if (!e.key.startsWith('Recommended'))
          PlusRowSpec('list:${e.key}', e.key, shownByDefault: e.value),
      const PlusRowSpec('forYou', 'For you', styled: false),
      for (final (name, _) in PlusCustomLists.lists)
        PlusRowSpec('custom:$name', name),
      const PlusRowSpec('missedSequels', 'Missed sequels'),
      PlusRowSpec('rec:anime', 'Recommended Anime',
          shownByDefault: cards['Recommended Animes'] ?? false),
      PlusRowSpec('rec:manga', 'Recommended Manga',
          shownByDefault: cards['Recommended Mangas'] ?? false),
      for (final (key, title) in plusDiscoverRows)
        PlusRowSpec(key, title,
            shownByDefault: discoverByDefault,
            styled: key != 'disc:carousel' && key != 'disc:community'),
    ];
  }

  static List<PlusRowSpec> mangaSpecs() {
    final cards = _homeCards;
    return [
      for (final (key, title) in plusMangaRows)
        PlusRowSpec(key, title,
            styled: key != 'm:carousel' &&
                key != 'm:novels' &&
                key != 'm:community'),
      // Your manga lists, off until you turn them on here.
      for (final label in cards.keys)
        if (label.contains('Manga') || label.contains('Reading'))
          PlusRowSpec('list:$label', label, shownByDefault: false),
    ];
  }

  /// Home rows in your order; list rows take their on/off from AnymeX's
  /// Home switches.
  static List<PlusPlacedRow> homeRows({required bool discoverByDefault}) {
    final cards = _homeCards;
    return PlusLayout.arrange(homeSpecs(discoverByDefault: discoverByDefault),
            PlusLayoutStore.saved(PlusLayoutPage.home))
        .map((r) {
      final k = r.key;
      bool? on;
      if (k.startsWith('list:')) on = cards[plusListLabel(k)] ?? false;
      if (k == 'rec:anime') on = cards['Recommended Animes'] ?? false;
      if (k == 'rec:manga') on = cards['Recommended Mangas'] ?? false;
      return on == null
          ? r
          : PlusPlacedRow(r.spec, r.config.copyWith(hidden: !on));
    }).toList();
  }

  static List<PlusPlacedRow> mangaRows() => PlusLayout.arrange(
      mangaSpecs(), PlusLayoutStore.saved(PlusLayoutPage.manga));

  /// AnymeX's Home switch behind a Home row, if it has one.
  static String? homeSwitchFor(String key) {
    if (key.startsWith('list:')) return plusListLabel(key);
    if (key == 'rec:anime') return 'Recommended Animes';
    if (key == 'rec:manga') return 'Recommended Mangas';
    return null;
  }

  // ---- drawing ---------------------------------------------------------------

  /// A row with its Edit layout settings around it.
  static Widget scoped(PlusPlacedRow row, Widget child) => PlusRowScope(
        key: ValueKey('plus-row-${row.key}'),
        style: row.config.style,
        title: row.config.name,
        child: RepaintBoundary(child: child),
      );

  static Widget listRow(String label, {required bool home}) {
    final auth = Get.find<AnilistAuth>();
    return Obx(() {
      if (!auth.isLoggedIn.value) return const SizedBox.shrink();
      final manga = label.contains('Manga') || label.contains('Reading');
      final source =
          manga ? auth.mangaList.removeDupes() : auth.animeList.removeDupes();
      final data = filterListByLabel(source, label);
      if (label == 'Continue Watching') {
        return PlusContinueWatchingRow(anime: data);
      }
      return ReusableCarousel(
        data: data,
        title: label,
        variant: DataVariant.anilist,
        type: manga ? ItemType.manga : ItemType.anime,
      );
    });
  }

  static Widget customListRow(String name) {
    return Obx(() {
      for (final (n, entries) in PlusCustomLists.lists) {
        if (n == name) {
          return ReusableCarousel(
            data: entries,
            title: name,
            variant: DataVariant.anilist,
            type: ItemType.anime,
          );
        }
      }
      return const SizedBox.shrink();
    });
  }

  static Widget recommendedRow({required bool manga}) {
    final data = Get.find<ServiceHandler>().anilistService;
    final auth = Get.find<AnilistAuth>();
    return Obx(() {
      final recs = manga
          ? [...data.popularMangas, ...data.topOngoingMangas, ...data.topRatedMangas]
              .removeDupes()
          : [...data.popularAnimes, ...data.trendingAnimes, ...data.latestAnimes]
              .removeDupes();
      final mine = (manga ? auth.mangaList : auth.animeList)
          .map((e) => e.id)
          .toSet();
      final shown = auth.isLoggedIn.value
          ? recs.where((e) => !mine.contains(e.id)).toList()
          : recs;
      return ReusableCarousel(
        title: manga ? 'Recommended Manga' : 'Recommended Anime',
        data: shown,
        type: manga ? ItemType.manga : ItemType.anime,
      );
    });
  }

  /// A Stremio catalog (key from StremioService.rowKey) as a row; [genre]
  /// filters it when the catalog supports genres.
  static Widget stremioRow(String rowKey, String title, {String? genre}) {
    if (!Get.isRegistered<StremioService>()) return const SizedBox.shrink();
    final service = StremioService.to;
    return Obx(() {
      for (final a in service.addons) {
        for (final c in a.catalogs) {
          if (StremioService.rowKey(a, c) != rowKey) continue;
          return StremioCatalogCarousel(
            key: ValueKey('plus-$rowKey|${genre ?? ''}'),
            addon: a,
            catalog: c,
            title: title,
            extra: genre == null ? const {} : {'genre': genre},
          );
        }
      }
      return const SizedBox.shrink();
    });
  }

  /// Rows you added (filtered rows, catalogs from Movies & TV).
  static Widget? addedRow(PlusPlacedRow row) {
    final p = row.config.params;
    final title = row.title;
    switch (p['kind']) {
      case 'anilist':
        return PlusFilterRow(params: p, title: title);
      case 'stremio':
        final key = p['rowKey'];
        if (key is! String) return null;
        final genre = p['genre'];
        return stremioRow(key, title, genre: genre is String ? genre : null);
    }
    return null;
  }

  /// "Edit layout" at the end of a page.
  static Widget editButton(BuildContext context, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Center(
        child: TextButton.icon(
          onPressed: onTap,
          icon: Icon(Icons.dashboard_customize_outlined,
              size: 18, color: context.colors.primary),
          label: const Text('Edit layout'),
        ),
      ),
    );
  }
}

// ---- filtered rows (AniList) -------------------------------------------------

/// AniList sorts offered for filtered rows.
const plusAnilistSorts = <String, String>{
  'TRENDING_DESC': 'Trending',
  'POPULARITY_DESC': 'Popular',
  'SCORE_DESC': 'Top rated',
  'START_DATE_DESC': 'Newest',
};

/// AniList's genres.
const plusAnilistGenres = [
  'Action', 'Adventure', 'Comedy', 'Drama', 'Ecchi', 'Fantasy', 'Horror',
  'Mahou Shoujo', 'Mecha', 'Music', 'Mystery', 'Psychological', 'Romance',
  'Sci-Fi', 'Slice of Life', 'Sports', 'Supernatural', 'Thriller',
];

/// A row of AniList titles matching your filters (genres, year, minimum
/// score, sort). params: type ANIME|MANGA, genres, year, minScore, sort.
class PlusFilterRow extends StatefulWidget {
  final Map<String, dynamic> params;
  final String title;
  const PlusFilterRow({super.key, required this.params, required this.title});

  /// Variables for the AniList query (unit-tested).
  static Map<String, dynamic> variablesFor(Map<String, dynamic> p) {
    final genres = (p['genres'] is List ? p['genres'] as List : const [])
        .map((e) => '$e')
        .where((e) => e.isNotEmpty)
        .toList();
    final year = (p['year'] as num?)?.toInt();
    final minScore = (p['minScore'] as num?)?.toInt();
    final sort = plusAnilistSorts.containsKey(p['sort'])
        ? p['sort'] as String
        : 'POPULARITY_DESC';
    return {
      'type': p['type'] == 'MANGA' ? 'MANGA' : 'ANIME',
      'sort': [sort],
      if (genres.isNotEmpty) 'genres': genres,
      if (year != null && year > 1900) ...{
        'from': year * 10000,
        'to': (year + 1) * 10000,
      },
      if (minScore != null && minScore > 0) 'minScore': minScore - 1,
    };
  }

  /// A short description of the filters, e.g. "Romance · 2024 · 70+".
  static String describe(Map<String, dynamic> p) {
    final v = variablesFor(p);
    final parts = <String>[
      if (v['genres'] is List) (v['genres'] as List).join(', '),
      if (p['year'] != null) '${p['year']}',
      if (p['minScore'] != null && (p['minScore'] as num) > 0)
        'score ${p['minScore']}+',
      plusAnilistSorts[(v['sort'] as List).first] ?? '',
    ];
    return parts.where((e) => e.isNotEmpty).join(' · ');
  }

  @override
  State<PlusFilterRow> createState() => _PlusFilterRowState();
}

class _PlusFilterRowState extends State<PlusFilterRow> {
  static final Map<String, List<Media>> _cache = {};

  List<Media>? _items;

  static const _query = r'''
query ($type: MediaType, $genres: [String], $from: FuzzyDateInt, $to: FuzzyDateInt, $minScore: Int, $sort: [MediaSort]) {
  Page(perPage: 40) {
    media(type: $type, genre_in: $genres, startDate_greater: $from, startDate_lesser: $to, averageScore_greater: $minScore, sort: $sort, isAdult: false) {
      id idMal type episodes chapters status averageScore seasonYear bannerImage
      startDate { year }
      title { english romaji native userPreferred }
      coverImage { large extraLarge color }
    }
  }
}''';

  String get _key => jsonEncode(PlusFilterRow.variablesFor(widget.params));

  @override
  void initState() {
    super.initState();
    _items = _cache[_key];
    if (_items == null) _load();
  }

  @override
  void didUpdateWidget(covariant PlusFilterRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (jsonEncode(PlusFilterRow.variablesFor(oldWidget.params)) != _key) {
      _items = _cache[_key];
      if (_items == null) _load();
    }
  }

  Future<void> _load() async {
    final key = _key;
    try {
      final resp = await http
          .post(
            Uri.parse('https://graphql.anilist.co'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'query': _query,
              'variables': PlusFilterRow.variablesFor(widget.params),
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final list = (jsonDecode(resp.body)['data']?['Page']?['media'] as List?) ??
          const [];
      final manga = widget.params['type'] == 'MANGA';
      final media = list
          .whereType<Map>()
          .map((m) => Media.fromSmallJson(Map<String, dynamic>.from(m), manga))
          .toList();
      _cache[key] = media;
      if (mounted && key == _key) setState(() => _items = media);
    } catch (_) {
      if (mounted) setState(() => _items = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items != null && items.isEmpty) return const SizedBox.shrink();
    return ReusableCarousel(
      data: items ?? const <Media>[],
      title: widget.title,
      isLoading: items == null,
      type: widget.params['type'] == 'MANGA' ? ItemType.manga : ItemType.anime,
    );
  }
}

/// (rowKey, display title, genres it can filter by) for every Movies & TV
/// home catalog from your addons.
List<(String, String, List<String>)> plusStremioCatalogChoices() {
  if (!Get.isRegistered<StremioService>()) return const [];
  final out = <(String, String, List<String>)>[];
  for (final a in StremioService.to.addons) {
    for (final c in a.catalogs) {
      if (!c.isBoardCatalog || c.isSearchOnly) continue;
      final type = stremioTypeLabel(c.type);
      final genres = <String>[];
      for (final e in c.extra) {
        if (e.name == 'genre') genres.addAll(e.options);
      }
      out.add((
        StremioService.rowKey(a, c),
        type.isEmpty ? '${c.name} (${a.name})' : '${c.name} · $type (${a.name})',
        genres,
      ));
    }
  }
  return out;
}
