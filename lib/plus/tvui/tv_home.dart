import 'dart:async';

import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/plus/continue_watching_row.dart' show normalizeTitle;
import 'package:anymex/plus/for_you/anime_for_you.dart';
import 'package:anymex/plus/for_you/movies_for_you.dart';
import 'package:anymex/plus/for_you/ranking.dart';
import 'package:anymex/plus/for_you/taste.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/tvui/tv_data.dart';
import 'package:anymex/plus/tvui/tv_home_rows.dart';
import 'package:anymex/plus/tvui/tv_details.dart';
import 'package:anymex/plus/tvui/tv_shell.dart';
import 'package:anymex/plus/tvui/tv_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:anymex/theme/yumori_tokens.dart';
import 'package:get/get.dart';

/// Opens a card's details page.
void tvOpen(BuildContext context, TvItem item) {
  Navigator.of(context).push(tvRoute(TvDetailsPage(item: item)));
}

/// The TV's Home: a banner for the highlighted card, then rows of anime and
/// Movies & TV together (Continue Watching, For you, then the lists).
class TvHomePage extends StatefulWidget {
  /// Edit rows: every row with its cards (hidden ones dimmed), to move or
  /// hide right where you see them (Settings → Home rows → Edit rows).
  final bool editing;
  const TvHomePage({super.key, this.editing = false});

  @override
  State<TvHomePage> createState() => _TvHomePageState();
}

class _TvHomePageState extends State<TvHomePage> {
  final _hero = ValueNotifier<TvItem?>(null);
  final _extra = <String, TvItem>{}; // details fetched for the banner
  Timer? _heroTimer;
  final _movieRows = <String, List<TvItem>>{};
  final _rowKeys = <String, GlobalKey<TvRowState>>{};
  final _born = DateTime.now();
  bool _warming = false;
  final _startTimers = <Timer>[];

  // The banner's buttons (Watch now, Details): Up from the first row.
  final _watchNode = FocusNode(debugLabel: 'home watch');
  final _infoNode = FocusNode(debugLabel: 'home details');
  GlobalKey<TvRowState>? _firstRow;


  @override
  void initState() {
    super.initState();
    if (!TvStart.ready.value) {
      // Never keep the splash longer than this.
      _startTimers.add(Timer(const Duration(seconds: 9), () => TvStart.ready.value = true));
      // Look again once the slower rows had a moment.
      _startTimers.add(Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() {});
      }));
    }
    try {
      final data = Get.find<ServiceHandler>().anilistService;
      if (data.trendingAnimes.isEmpty) unawaited(data.fetchAnilistHomepage());
    } catch (_) {}
    _loadMovieRows();
    TvHomeRows.version.addListener(_layoutChanged);
  }

  /// The Movies & TV rows you show (Settings → Home rows); all of them
  /// while editing.
  void _loadMovieRows() {
    for (final r in TvHomeRows.load()) {
      if ((!r.on && !widget.editing) || !r.key.startsWith('m:')) continue;
      final id = r.key.substring(2);
      if (_movieRows.containsKey(id)) continue;
      TvMovies.row(id).then((items) {
        if (mounted && items.isNotEmpty) setState(() => _movieRows[id] = items);
      });
    }
  }

  void _layoutChanged() {
    if (!mounted) return;
    _loadMovieRows();
    setState(() {});
  }

  @override
  void dispose() {
    TvHomeRows.version.removeListener(_layoutChanged);
    for (final n in _moveNodes.values) {
      n.dispose();
    }
    _heroTimer?.cancel();
    for (final t in _startTimers) {
      t.cancel();
    }
    _hero.dispose();
    _watchNode.dispose();
    _infoNode.dispose();
    super.dispose();
  }

  /// Start-up: once the first rows are known, load the pictures of the
  /// first screen, then let the splash go.
  void _maybeWarm(List<(String, List<TvItem>, bool, bool)> specs) {
    if (_warming || TvStart.ready.value) return;
    final waited = DateTime.now().difference(_born) > const Duration(seconds: 3);
    if (specs.isEmpty || (specs.length < 3 && !waited)) return;
    _warming = true;
    final pics = <(String, double)>[];
    final first = specs.first.$2.first;
    pics.add((first.backdrop.isNotEmpty ? first.backdrop : first.poster, 1920));
    for (final r in specs.take(2)) {
      for (final it in r.$2.take(8)) {
        pics.add((r.$3 && it.backdrop.isNotEmpty ? it.backdrop : it.poster, r.$3 ? TvCard.smallWideW : TvCard.smallW));
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await TvImage.warm(context, pics);
      TvStart.ready.value = true;
    });
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

  /// AniList anime and Stremio items, newest first, without doubles (the
  /// same show from AniList and Stremio, or as two Stremio entries: an
  /// anime under its Kitsu id and its IMDb id).
  List<TvItem> _continue() {
    final out = <(int, TvItem)>[];
    final titles = <String>{};
    final ids = <String>[];
    try {
      final auth = Get.find<AnilistAuth>();
      if (auth.isLoggedIn.value) {
        for (final t in auth.animeList) {
          final s = (t.watchingStatus ?? '').toUpperCase();
          if (s != 'CURRENT' && s != 'REPEATING') continue;
          out.add(((t.updatedAt ?? 0) * 1000, TvItem.fromTracked(t)));
          if (t.id != null) ids.add(t.id!);
          for (final n in [t.title, t.romajiTitle]) {
            final k = normalizeTitle(n);
            if (k.isNotEmpty) titles.add(k);
          }
        }
      }
    } catch (_) {}
    try {
      final st = StremioService.to;
      final synced = ids.isEmpty ? const <String>{} : st.stremioIdsForAnilist(ids);
      final items = st.continueWatching.toList()
        ..sort((a, b) => (b.lastWatched?.millisecondsSinceEpoch ?? 0).compareTo(a.lastWatched?.millisecondsSinceEpoch ?? 0));
      for (final i in items) {
        if (synced.contains(i.id)) continue;
        final k = normalizeTitle(i.name);
        if (k.isNotEmpty && !titles.add(k)) continue;
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

  // ---- editing --------------------------------------------------------------

  String? _lifted; // the row being moved
  final _moveNodes = <String, FocusNode>{};
  final _editKeys = <String, GlobalKey>{};

  FocusNode _moveNode(String k) => _moveNodes.putIfAbsent(k, () => FocusNode(debugLabel: 'move $k'));

  void _reveal(String k) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _editKeys[k]?.currentContext;
      if (c != null) Scrollable.ensureVisible(c, alignment: 0.3, duration: const Duration(milliseconds: 160));
      _moveNodes[k]?.requestFocus();
    });
  }

  KeyEventResult _editKey(FocusNode _, KeyEvent e) {
    final k = _lifted;
    if (k == null || e is KeyUpEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      final rows = TvHomeRows.load();
      final i = rows.indexWhere((r) => r.key == k);
      TvHomeRows.save(TvHomeRows.move(rows, i, key == LogicalKeyboardKey.arrowUp ? -1 : 1));
      _reveal(k);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.handled; // stay on the row while moving it
    }
    return KeyEventResult.ignored;
  }

  Widget _editBody(List<TvItem> Function(String) itemsFor) {
    final rows = TvHomeRows.load();
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _editKey,
      child: ListView(
        cacheExtent: 3000,
        padding: const EdgeInsets.fromLTRB(0, 56, 0, 400),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: TvStyle.pad),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              const Text('Edit Home rows', style: TextStyle(fontSize: 48, fontWeight: FontWeight.w800, color: Colors.white)),
              const SizedBox(width: 28),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                      _lifted == null
                          ? 'Move: pick a row up, then Up / Down to carry it, OK to put it down. Hide keeps it off Home.'
                          : 'Moving ${TvHomeRows.title(_lifted!)}: Up / Down, then OK to put it down.',
                      style: const TextStyle(fontSize: 20, color: TvStyle.dim)),
                ),
              ),
              TvButton(label: 'Reset', onSelect: () {
                setState(() => _lifted = null);
                TvHomeRows.reset();
              }),
              const SizedBox(width: 16),
              TvButton(label: 'Done', primary: true, onSelect: () => Navigator.of(context).maybePop()),
            ]),
          ),
          const SizedBox(height: 28),
          for (final r in rows)
            KeyedSubtree(
              key: ValueKey('edit-${r.key}'),
              child: Container(
                key: _editKeys.putIfAbsent(r.key, () => GlobalKey()),
                margin: const EdgeInsets.fromLTRB(TvStyle.pad - 24, 0, TvStyle.pad - 24, 26),
                child: TvRing(
                  on: _lifted == r.key,
                  radius: 22,
                  gap: 2,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(24, 18, 0, 8),
                    decoration: BoxDecoration(
                      color: _lifted == r.key ? const Color(0xFF151515) : Colors.transparent,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text(TvHomeRows.title(r.key),
                            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: r.on ? Colors.white : TvStyle.dim)),
                        if (!r.on) ...[
                          const SizedBox(width: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(color: TvStyle.chip, borderRadius: BorderRadius.circular(8)),
                            child: const Text('Hidden', style: TextStyle(fontSize: 17, color: TvStyle.text2)),
                          ),
                        ],
                        const SizedBox(width: 28),
                        TvButton(
                          label: _lifted == r.key ? 'Put down' : 'Move',
                          icon: _lifted == r.key ? Icons.check_rounded : Icons.swap_vert_rounded,
                          primary: _lifted == r.key,
                          focusNode: _moveNode(r.key),
                          autofocus: r.key == rows.first.key,
                          onSelect: () {
                            setState(() => _lifted = _lifted == r.key ? null : r.key);
                            _reveal(r.key);
                          },
                        ),
                        const SizedBox(width: 14),
                        if (_lifted != r.key)
                          TvButton(
                            label: r.on ? 'Hide' : 'Show',
                            icon: r.on ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                            onSelect: () {
                              final all = TvHomeRows.load();
                              TvHomeRows.save([for (final x in all) x.key == r.key ? x.shown(!x.on) : x]);
                              _reveal(r.key);
                            },
                          ),
                      ]),
                      const SizedBox(height: 4),
                      ExcludeFocus(
                        child: Opacity(
                          opacity: r.on ? 1 : 0.35,
                          child: itemsFor(r.key).isEmpty
                              ? const Padding(
                                  padding: EdgeInsets.fromLTRB(0, 18, 0, 24),
                                  child: Text('Nothing in this row right now (it shows on Home when it has something).',
                                      style: TextStyle(fontSize: 19, color: TvStyle.dim)),
                                )
                              : Transform.translate(
                                  offset: const Offset(-TvStyle.pad, 0),
                                  child: TvRow(
                                    title: '',
                                    items: itemsFor(r.key),
                                    wide: r.key == 'continue',
                                    showKind: r.key == 'forYou',
                                    onOpen: (_) {},
                                  ),
                                ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.editing) {
      return Obx(() {
        final data = Get.find<ServiceHandler>().anilistService;
        final cw = _continue();
        final fy = _forYou();
        List<TvItem> media(List l) => [for (final m in l.take(30)) TvItem.fromMedia(m)];
        List<TvItem> itemsFor(String k) => switch (k) {
              'continue' => cw,
              'forYou' => fy,
              'trending' => media(data.trendingAnimes),
              'popular' => media(data.popularAnimes),
              'recent' => media(data.recentlyUpdatedAnimes),
              'upcoming' => media(data.upcomingAnimes),
              _ => k.startsWith('m:') ? (_movieRows[k.substring(2)] ?? const <TvItem>[]) : const <TvItem>[],
            };
        return _editBody(itemsFor);
      });
    }
    return Stack(children: [
      Positioned.fill(
        child: _Banner(
          hero: _hero,
          watchNode: _watchNode,
          infoNode: _infoNode,
          onWatch: (i) => Navigator.of(context).push(tvRoute(TvDetailsPage(item: i, autoPlay: true))),
          onInfo: (i) => tvOpen(context, i),
          onDown: () => _firstRow?.currentState?.focus() ?? false,
        ),
      ),
      Positioned.fill(
        top: 580,
        child: Obx(() {
          final data = Get.find<ServiceHandler>().anilistService;
          final cw = _continue();
          final fy = _forYou();
          final trending = [for (final m in data.trendingAnimes.take(30)) TvItem.fromMedia(m)];
          final popular = [for (final m in data.popularAnimes.take(30)) TvItem.fromMedia(m)];
          final recent = [for (final m in data.recentlyUpdatedAnimes.take(30)) TvItem.fromMedia(m)];
          final upcoming = [for (final m in data.upcomingAnimes.take(30)) TvItem.fromMedia(m)];
          List<TvItem> itemsFor(String k) => switch (k) {
                'continue' => cw,
                'forYou' => fy,
                'trending' => trending,
                'popular' => popular,
                'recent' => recent,
                'upcoming' => upcoming,
                _ => k.startsWith('m:') ? (_movieRows[k.substring(2)] ?? const <TvItem>[]) : const <TvItem>[],
              };
          // (title, items, wide, show kind), in your order (Settings → Home rows).
          final specs = <(String, List<TvItem>, bool, bool)>[
            for (final r in TvHomeRows.load())
              if (r.on) (TvHomeRows.title(r.key), itemsFor(r.key), r.key == 'continue', r.key == 'forYou'),
          ].where((r) => r.$2.isNotEmpty).toList();
          final keys = [for (final r in specs) _rowKeys.putIfAbsent(r.$1, () => GlobalKey<TvRowState>())];
          _firstRow = keys.isEmpty ? null : keys.first;
          bool move(int from, int step) {
            // Up from the first row: the banner's buttons.
            if (from == 0 && step < 0) {
              if (_hero.value != null && _watchNode.context != null) _watchNode.requestFocus();
              return true;
            }
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
                compact: true,
                autofocusFirst: r == 0,
                onOpen: (i) => tvOpen(context, i),
                onFocusItem: _focus,
                onUp: () => move(r, -1),
                onDown: () => move(r, 1),
              ),
          ];
          _maybeWarm(specs);
          if (_hero.value == null) {
            final first = cw.isNotEmpty ? cw.first : (fy.isNotEmpty ? fy.first : (trending.isNotEmpty ? trending.first : null));
            if (first != null) WidgetsBinding.instance.addPostFrameCallback((_) => _focus(first));
          }
          return ListView(
            // Rows next to the highlighted one must exist for Up / Down.
            cacheExtent: 2400,
            padding: const EdgeInsets.only(top: 0, bottom: 400),
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
  final FocusNode watchNode;
  final FocusNode infoNode;
  final ValueChanged<TvItem> onWatch;
  final ValueChanged<TvItem> onInfo;
  final bool Function() onDown;
  const _Banner({
    required this.hero,
    required this.watchNode,
    required this.infoNode,
    required this.onWatch,
    required this.onInfo,
    required this.onDown,
  });

  /// Down from the buttons goes to the rows; Left/Right between the two.
  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) return onDown() ? KeyEventResult.handled : KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.arrowUp) return KeyEventResult.handled;
    if (k == LogicalKeyboardKey.arrowRight && node == watchNode) {
      infoNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft && node == infoNode) {
      watchNode.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final accent = TvStyle.accent(context);
    return ValueListenableBuilder<TvItem?>(
      valueListenable: hero,
      builder: (context, item, _) {
        if (item == null) return const SizedBox.shrink();
        final pic = item.backdrop.isNotEmpty ? item.backdrop : item.poster;
        // Small lavender line above the title: why it's here, or its kind and genres.
        final eyebrow = item.sub.isNotEmpty
            ? item.sub
            : [item.kindLabel, if (item.genres.isNotEmpty) item.genres.take(2).join(', ')].join('  ·  ');
        final meta = <String>[
          if (item.year.isNotEmpty) item.year,
          if (item.episodes.isNotEmpty && item.kind != 'movie') '${item.episodes} episodes',
          if (item.rating.isNotEmpty) '★ ${item.rating}',
          if (item.sub.isNotEmpty && item.genres.isNotEmpty) item.genres.take(3).join(', '),
        ];
        final resume = item.progress > 0;
        return Stack(children: [
          // The picture fills the whole screen behind everything.
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: TvImage(key: ValueKey(pic), url: pic, width: 1920, height: 1080, seed: item.key),
            ),
          ),
          // Night on the left (text) ...
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xF20D0A16), Color(0xC00D0A16), Color(0x330D0A16), Color(0x000D0A16)],
                  stops: [0.0, 0.32, 0.6, 0.78],
                ),
              ),
            ),
          ),
          // ... and at the bottom (rows), so the picture melts into the page.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x000D0A16), Color(0x000D0A16), Color(0xB30D0A16), Color(0xF20D0A16)],
                  stops: [0.0, 0.45, 0.7, 1.0],
                ),
              ),
            ),
          ),
          Positioned(
            left: TvStyle.pad,
            top: 80,
            width: 900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(eyebrow.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 3, color: accent)),
                const SizedBox(height: 14),
                Text(item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 78, height: 1.0, fontWeight: FontWeight.w800, letterSpacing: -1.5, color: YumoriColors.text)),
                const SizedBox(height: 18),
                if (meta.isNotEmpty) ...[
                  Text(meta.join('   ·   '), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: TvStyle.text2)),
                  const SizedBox(height: 12),
                ],
                Text(item.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 21, height: 1.5, color: TvStyle.dim)),
                const SizedBox(height: 26),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: (_, e) => _key(watchNode, e),
                    child: TvButton(
                      label: resume ? 'Resume' : 'Watch now',
                      icon: Icons.play_arrow_rounded,
                      primary: true,
                      focusNode: watchNode,
                      onSelect: () => onWatch(item),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: (_, e) => _key(infoNode, e),
                    child: TvButton(
                      label: 'Details',
                      icon: Icons.info_outline_rounded,
                      focusNode: infoNode,
                      onSelect: () => onInfo(item),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ]);
      },
    );
  }
}
