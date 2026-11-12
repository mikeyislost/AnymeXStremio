import 'dart:async';

import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/plus/for_you/anime_for_you.dart';
import 'package:anymex/plus/for_you/movies_for_you.dart';
import 'package:anymex/plus/for_you/ranking.dart';
import 'package:anymex/plus/for_you/taste.dart';
import 'package:anymex/plus/stremio/builtin_rows.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/tvui/tv_data.dart';
import 'package:anymex/plus/tvui/tv_details.dart';
import 'package:anymex/plus/tvui/tv_widgets.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Opens a card's details page.
void tvOpen(BuildContext context, TvItem item) {
  Navigator.of(context).push(tvRoute(TvDetailsPage(item: item)));
}

/// The TV's Home: a banner for the highlighted card, then rows of anime and
/// Movies & TV together (Continue Watching, For you, then the lists).
class TvHomePage extends StatefulWidget {
  const TvHomePage({super.key});

  @override
  State<TvHomePage> createState() => _TvHomePageState();
}

class _TvHomePageState extends State<TvHomePage> {
  final _hero = ValueNotifier<TvItem?>(null);
  final _extra = <String, TvItem>{}; // details fetched for the banner
  Timer? _heroTimer;
  final _movieRows = <String, List<TvItem>>{};
  final _rowKeys = <String, GlobalKey<TvRowState>>{};

  static const _movieRowIds = [
    'trending-movies', 'trending-series', 'popular-movies', 'popular-series', 'airing', 'theaters',
    'top-movies', 'top-series', 'netflix', 'disney', 'prime', 'max', 'appletv', 'upcoming',
  ];

  @override
  void initState() {
    super.initState();
    try {
      final data = Get.find<ServiceHandler>().anilistService;
      if (data.trendingAnimes.isEmpty) unawaited(data.fetchAnilistHomepage());
    } catch (_) {}
    for (final id in _movieRowIds) {
      TvMovies.row(id).then((items) {
        if (mounted && items.isNotEmpty) setState(() => _movieRows[id] = items);
      });
    }
  }

  @override
  void dispose() {
    _heroTimer?.cancel();
    _hero.dispose();
    super.dispose();
  }

  /// A card got the highlight: show it in the banner, and fill in what the
  /// card doesn't carry (banner picture, description) a moment later.
  void _focus(TvItem item) {
    _hero.value = _extra[item.key] ?? item;
    _heroTimer?.cancel();
    if (item.description.isNotEmpty && item.backdrop.isNotEmpty) return;
    if (_extra.containsKey(item.key)) return;
    _heroTimer = Timer(const Duration(milliseconds: 350), () async {
      TvItem? full;
      if (item.isAnime) {
        full = (await TvAnilist.details(item.id))?.$1;
      } else {
        try {
          final id = await TvMovies.stremioId(item);
          final meta = id == null ? null : await StremioService.to.fetchMeta(item.kind, id);
          if (meta != null) full = TvItem.fromStremio(meta);
        } catch (_) {}
      }
      if (full == null) return;
      final merged = TvItem(
        id: item.id,
        kind: item.kind,
        title: item.title,
        poster: item.poster.isNotEmpty ? item.poster : full.poster,
        backdrop: full.backdrop,
        description: full.description,
        year: full.year,
        rating: item.rating.isNotEmpty ? item.rating : full.rating,
        format: full.format,
        episodes: full.episodes,
        genres: full.genres,
        sub: item.sub,
        progress: item.progress,
        videoId: item.videoId,
      );
      _extra[item.key] = merged;
      if (mounted && _hero.value?.key == item.key) _hero.value = merged;
    });
  }

  List<TvItem> _continue() {
    final out = <(int, TvItem)>[];
    try {
      final auth = Get.find<AnilistAuth>();
      if (auth.isLoggedIn.value) {
        for (final t in auth.animeList) {
          final s = (t.watchingStatus ?? '').toUpperCase();
          if (s == 'CURRENT' || s == 'REPEATING') out.add(((t.updatedAt ?? 0) * 1000, TvItem.fromTracked(t)));
        }
      }
    } catch (_) {}
    try {
      for (final i in StremioService.to.continueWatching) {
        out.add((i.lastWatched?.millisecondsSinceEpoch ?? 0, TvItem.fromLibrary(i)));
      }
    } catch (_) {}
    out.sort((a, b) => b.$1.compareTo(a.$1));
    return [for (final e in out.take(30)) e.$2];
  }

  List<TvItem> _forYou() {
    try {
      final auth = Get.find<AnilistAuth>();
      if (auth.isLoggedIn.value && auth.animeList.isNotEmpty) {
        final list = auth.animeList.toList();
        final favourites = <AnimeFavourite>[
          for (final f in auth.profileData.value.favourites?.anime ?? const [])
            if (f.id != null) (id: f.id!, title: f.title ?? '?', genres: f.genres),
        ];
        Future.microtask(() => AnimeForYou.ensure(list, favourites));
      }
      final svc = StremioService.to;
      if (MoviesForYou.tmdbKey != null && !svc.libraryLoading.value) {
        PlusTaste.ensureLoaded();
        final items = svc.allLibraryItems.toList();
        final marks = Map<String, TasteMark>.of(PlusTaste.marks);
        Future.microtask(() => MoviesForYou.ensure(items, marks));
      }
    } catch (_) {}
    return TvCategory.interleave([
      [for (final p in AnimeForYou.picks.where((p) => p.kind == 'anime')) TvItem.fromPick(p)],
      [for (final p in MoviesForYou.picks) TvItem.fromPick(p)],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned(left: 0, right: 0, top: 0, height: 640, child: _Banner(hero: _hero)),
      Positioned.fill(
        top: 548,
        child: Obx(() {
          final data = Get.find<ServiceHandler>().anilistService;
          final cw = _continue();
          final fy = _forYou();
          final trending = [for (final m in data.trendingAnimes.take(30)) TvItem.fromMedia(m)];
          final popular = [for (final m in data.popularAnimes.take(30)) TvItem.fromMedia(m)];
          final recent = [for (final m in data.recentlyUpdatedAnimes.take(30)) TvItem.fromMedia(m)];
          final upcoming = [for (final m in data.upcomingAnimes.take(30)) TvItem.fromMedia(m)];
          String rowTitle(String id) {
            for (final r in PlusBuiltinRows.all) {
              if (r.id == id) return r.title;
            }
            return id;
          }

          final specs = <(String, List<TvItem>, bool, bool)>[
            // (title, items, wide, show kind)
            ('Continue Watching', cw, true, false),
            ('For you', fy, false, true),
            ('Trending Anime', trending, false, false),
            for (final id in _movieRowIds.take(2))
              if (_movieRows[id] != null) (rowTitle(id), _movieRows[id]!, false, false),
            ('Popular Anime', popular, false, false),
            ('Recently Updated', recent, false, false),
            for (final id in _movieRowIds.skip(2))
              if (_movieRows[id] != null) (rowTitle(id), _movieRows[id]!, false, false),
            ('Upcoming Anime', upcoming, false, false),
          ].where((r) => r.$2.isNotEmpty).toList();
          final keys = [for (final r in specs) _rowKeys.putIfAbsent(r.$1, () => GlobalKey<TvRowState>())];
          bool move(int from, int step) {
            for (var j = from + step; j >= 0 && j < keys.length; j += step) {
              if (keys[j].currentState?.focus() == true) return true;
            }
            return true; // nothing further that way: stay put
          }

          final rows = <Widget>[
            for (var r = 0; r < specs.length; r++)
              TvRow(
                key: keys[r],
                title: specs[r].$1,
                items: specs[r].$2,
                wide: specs[r].$3,
                showKind: specs[r].$4,
                autofocusFirst: r == 0,
                onOpen: (i) => tvOpen(context, i),
                onFocusItem: _focus,
                onUp: () => move(r, -1),
                onDown: () => move(r, 1),
              ),
          ];
          if (_hero.value == null) {
            final first = cw.isNotEmpty ? cw.first : (fy.isNotEmpty ? fy.first : (trending.isNotEmpty ? trending.first : null));
            if (first != null) WidgetsBinding.instance.addPostFrameCallback((_) => _focus(first));
          }
          return ListView(
            // Rows next to the highlighted one must exist for Up / Down.
            cacheExtent: 2400,
            padding: const EdgeInsets.only(top: 40, bottom: 400),
            // Rows scrolled up must not draw over the banner.
            clipBehavior: Clip.hardEdge,
            children: rows,
          );
        }),
      ),
    ]);
  }
}

class _Banner extends StatelessWidget {
  final ValueNotifier<TvItem?> hero;
  const _Banner({required this.hero});

  @override
  Widget build(BuildContext context) {
    final accent = TvStyle.accent(context);
    return ValueListenableBuilder<TvItem?>(
      valueListenable: hero,
      builder: (context, item, _) {
        if (item == null) return const SizedBox.shrink();
        final pic = item.backdrop.isNotEmpty ? item.backdrop : item.poster;
        final meta = <String>[
          if (item.year.isNotEmpty) item.year,
          item.kindLabel,
          if (item.episodes.isNotEmpty && item.kind != 'movie') '${item.episodes} episodes',
          if (item.rating.isNotEmpty) '★ ${item.rating}',
          if (item.genres.isNotEmpty) item.genres.take(3).join(', '),
        ];
        return Stack(children: [
          Positioned(
            right: 0,
            top: 0,
            width: 1240,
            height: 640,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: TvImage(key: ValueKey(pic), url: pic, width: 1240, height: 640, seed: item.key),
            ),
          ),
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black, Color(0xD9000000), Color(0x00000000)],
                  stops: [0.0, 0.42, 0.75],
                ),
              ),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 240,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black, Color(0x00000000)]),
              ),
            ),
          ),
          Positioned(
            left: TvStyle.pad,
            top: 88,
            width: 880,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.sub.isNotEmpty)
                  Text(item.sub.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: 3, color: accent)),
                const SizedBox(height: 14),
                Text(item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 64, height: 1.05, fontWeight: FontWeight.w800, color: Colors.white)),
                const SizedBox(height: 18),
                Text(meta.join('   •   '), style: const TextStyle(fontSize: 22, color: Color(0xFFCFCFCF))),
                const SizedBox(height: 16),
                Text(item.description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 22, height: 1.5, color: Color(0xFFA9A9A9))),
              ],
            ),
          ),
        ]);
      },
    );
  }
}
