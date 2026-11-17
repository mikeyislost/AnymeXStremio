// Yumori Categories tab: lists, genres and streaming services as tiles; a
// category opens one grid of anime + movies + series with All / Anime /
// Movies / Series filters, loading more as you scroll.

import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:path_provider/path_provider.dart';

import 'package:anymex/models/Media/media.dart';
import 'package:anymex/models/models_convertor/carousel/carousel_data.dart';
import 'package:anymex/plus/categories/categories_data.dart';
import 'package:anymex/plus/stremio/ui/stremio_widgets.dart';
import 'package:anymex/screens/anime/details_page.dart';
import 'package:anymex/theme/yumori_tokens.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_image.dart';
import 'package:anymex/widgets/anymex_widgets/yumori_loader.dart';
import 'package:anymex/widgets/common/anymex_pills.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:flutter/material.dart';
import 'package:anymex/screens/anime/misc/calendar.dart';
import 'package:anymex/screens/anime/misc/recommendation.dart';
import 'package:anymex/widgets/common/title_bar_inset.dart';

void openCatItem(CatItem it, String tag) {
  if (it.isAnime) {
    final media = Media.fromCarouselData(
      CarouselData(
        id: it.id,
        title: it.title,
        romajiTitle: it.title,
        englishTitle: it.title,
        poster: it.poster,
        extraData: it.rating.isEmpty ? '?' : it.rating,
        servicesType: ServicesType.anilist,
        releasing: false,
      ),
      ItemType.anime,
    );
    navigateWithAnimation(() => AnimeDetailsPage(media: media, tag: tag));
  } else {
    openStremioDetails(it.kind, it.id,
        tag: tag, title: it.title, poster: it.poster);
  }
}

/// The Categories tab.
class CategoriesPage extends StatelessWidget {
  const CategoriesPage({super.key});

  static const _groups = [
    ('lists', 'Lists'),
    ('genres', 'Genres'),
    ('services', 'Streaming services'),
  ];

  @override
  Widget build(BuildContext context) {
    final all = CatCategory.all();
    final top = MediaQuery.paddingOf(context).top;
    final width = MediaQuery.sizeOf(context).width;
    final cols = width > 900 ? 4 : (width > 600 ? 3 : 2);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, top + 22, 20, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text('DISCOVER',
                      style: YumoriText.ui(
                              size: 10,
                              weight: FontWeight.w600,
                              color: YumoriColors.text)
                          .copyWith(letterSpacing: 3.2)),
                  const SizedBox(width: 12),
                  Container(width: 36, height: 1, color: YumoriColors.lavender),
                ]),
                const SizedBox(height: 8),
                Text('Browse', style: YumoriText.title(size: 34)),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: _FeatureTile(
                    icon: Icons.calendar_month_rounded,
                    title: 'Calendar',
                    sub: 'Airing schedule',
                    onTap: () => navigate(() => const Calendar()),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _FeatureTile(
                    icon: Icons.auto_awesome,
                    title: 'AI Picks',
                    sub: 'Made for you',
                    onTap: () => navigate(
                        () => const AIRecommendation(isManga: false)),
                  ),
                ),
              ],
            ),
          ),
        ),
        for (final (key, label) in _groups)
          if (all.any((c) => c.group == key)) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
                child: Text(label,
                    style: YumoriText.ui(size: 16, weight: FontWeight.w700)),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid.count(
                crossAxisCount: cols,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 2.1,
                children: [
                  for (final c in all.where((c) => c.group == key))
                    _CategoryTile(category: c),
                ],
              ),
            ),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 140)),
      ],
    );
  }
}

class _FeatureTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback onTap;
  const _FeatureTile(
      {required this.icon,
      required this.title,
      required this.sub,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: YumoriColors.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0x1FF3F0FA)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: YumoriColors.lavender),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: YumoriText.ui(size: 14, weight: FontWeight.w700)),
                  Text(sub,
                      style: YumoriText.ui(
                          size: 11,
                          color: YumoriColors.text.withOpacity(0.65))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// First poster of each category. Fetched a few at a time (so AniList / TMDB
/// aren't hammered) and remembered on disk for a day, so the tiles are there
/// instantly the next time Browse opens.
class _TilePosters {
  static const _maxParallel = 4;
  static const _ttl = Duration(hours: 24);

  static final _cache = <String, Future<CatItem?>>{};
  static int _running = 0;
  static final _waiting = <Completer<void>>[];

  static Map<String, dynamic>? _disk;
  static Future<void>? _loading;
  static Timer? _saveTimer;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}browse_tiles.json');
  }

  static Future<void> _ensureDisk() => _loading ??= () async {
        try {
          final f = await _file();
          if (await f.exists()) {
            _disk = (jsonDecode(await f.readAsString()) as Map)
                .cast<String, dynamic>();
          }
        } catch (_) {}
        _disk ??= {};
      }();

  static CatItem? _fromDisk(String name) {
    final e = _disk?[name];
    if (e is! Map) return null;
    final t = DateTime.fromMillisecondsSinceEpoch((e['t'] as int?) ?? 0);
    if (DateTime.now().difference(t) > _ttl) return null;
    final poster = (e['poster'] as String?) ?? '';
    if (poster.isEmpty) return null;
    return CatItem(
      id: (e['id'] as String?) ?? '',
      kind: (e['kind'] as String?) ?? 'anime',
      title: (e['title'] as String?) ?? '',
      poster: poster,
    );
  }

  static void _remember(String name, CatItem it) {
    _disk?[name] = {
      'id': it.id,
      'kind': it.kind,
      'title': it.title,
      'poster': it.poster,
      't': DateTime.now().millisecondsSinceEpoch,
    };
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () async {
      try {
        await (await _file()).writeAsString(jsonEncode(_disk));
      } catch (_) {}
    });
  }

  static Future<void> _acquire() async {
    if (_running < _maxParallel) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiting.add(c);
    await c.future;
  }

  static void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else {
      _running--;
    }
  }

  static Future<CatItem?> of(CatCategory c) {
    return _cache.putIfAbsent(c.name, () async {
      await _ensureDisk();
      final saved = _fromDisk(c.name);
      if (saved != null) return saved;
      await _acquire();
      try {
        final items = await c.load(page: 1);
        for (final i in items) {
          if (i.poster.isNotEmpty) {
            _remember(c.name, i);
            return i;
          }
        }
      } catch (_) {
      } finally {
        _release();
      }
      return null;
    });
  }
}

class _CategoryTile extends StatelessWidget {
  final CatCategory category;
  const _CategoryTile({required this.category});

  @override
  Widget build(BuildContext context) {
    // A steady tint per category, from its name (shows until the poster loads).
    final hue = (category.name.hashCode.abs() % 60) + 250.0; // purples → pinks
    final tint = HSLColor.fromAHSL(1, hue % 360, 0.45, 0.22).toColor();
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => CategoryPage(category: category))),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [tint, YumoriColors.card],
                ),
              ),
            ),
            FutureBuilder<CatItem?>(
              future: _TilePosters.of(category),
              builder: (context, snap) {
                final first = snap.data;
                if (first == null) return const SizedBox.shrink();
                return AnymeXImage(
                  imageUrl: first.poster,
                  radius: 0,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                );
              },
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xE60D0A16)],
                  stops: [0.35, 1],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0x1FF3F0FA)),
              ),
            ),
            Positioned(
              top: 10,
              left: 10,
              right: 10,
              child: FutureBuilder<CatItem?>(
                future: _TilePosters.of(category),
                builder: (context, snap) {
                  final first = snap.data;
                  if (first == null) return const SizedBox.shrink();
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 150),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xB30D0A16),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('#1 ${first.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: YumoriText.ui(
                              size: 10, color: YumoriColors.lavender)),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(category.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: YumoriText.title(size: 18)),
                  const SizedBox(height: 2),
                  Text(category.sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: YumoriText.ui(
                          size: 11,
                          color: YumoriColors.text.withOpacity(0.75))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One category: a mixed grid with All / Anime / Movies / Series filters.
class CategoryPage extends StatefulWidget {
  final CatCategory category;
  const CategoryPage({super.key, required this.category});

  @override
  State<CategoryPage> createState() => _CategoryPageState();
}

class _CategoryPageState extends State<CategoryPage> {
  final _scroll = ScrollController();
  final _items = <CatItem>[];
  final _seen = <String>{};
  int _page = 0;
  bool _loading = false;
  bool _done = false;
  String _filter = 'all'; // all | anime | movie | series

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 900) _more();
    });
    _more();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _more() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    final next = _page + 1;
    final batch = await widget.category.load(page: next);
    if (!mounted) return;
    var added = 0;
    for (final it in batch) {
      if (_seen.add(it.key)) {
        _items.add(it);
        added++;
      }
    }
    setState(() {
      _page = next;
      _loading = false;
      if (added == 0 || next >= 25) _done = true;
    });
  }

  List<CatItem> get _shown =>
      _filter == 'all' ? _items : _items.where((i) => i.kind == _filter).toList();

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final width = MediaQuery.sizeOf(context).width;
    final cols = math.max(2, (width / 170).floor());
    final shown = _shown;
    return TitleBarInset(child: Scaffold(
      backgroundColor: YumoriColors.background,
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, top + 10, 20, 0),
              child: Row(children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                ),
                Expanded(
                  child: Text(widget.category.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: YumoriText.title(size: 28)),
                ),
              ]),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: AnymeXPills(
                style: PillStyle.standalone,
                items: [
                  for (final (k, label) in const [
                    ('all', 'All'),
                    ('anime', 'Anime'),
                    ('movie', 'Movies'),
                    ('series', 'Series'),
                  ])
                    PillItem(
                      label: label,
                      isSelected: _filter == k,
                      onTap: () => setState(() => _filter = k),
                    ),
                ],
              ),
            ),
          ),
          if (shown.isEmpty && !_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: Text('Nothing here yet')),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: 14,
                crossAxisSpacing: 12,
                childAspectRatio: 0.58,
              ),
              itemCount: shown.length,
              itemBuilder: (context, i) => _CatCard(item: shown[i], index: i),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: _loading
                    ? const YumoriLoader(tree: false, size: 160)
                    : const SizedBox.shrink(),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    ));
  }
}

class _CatCard extends StatelessWidget {
  final CatItem item;
  final int index;
  const _CatCard({required this.item, required this.index});

  @override
  Widget build(BuildContext context) {
    final tag = 'cat-${item.key}-$index';
    return GestureDetector(
      onTap: () => openCatItem(item, tag),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AnymeXImage(
                    imageUrl: item.poster,
                    radius: 0,
                    fit: BoxFit.cover,
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0x2EFFFFFF)),
                  ),
                ),
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xB313101C),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(item.kindLabel,
                        style: YumoriText.ui(
                                size: 9,
                                weight: FontWeight.w700,
                                color: YumoriColors.firefly)
                            .copyWith(letterSpacing: 1.4)),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
            child: Text(item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: YumoriText.ui(size: 13, weight: FontWeight.w600)),
          ),
          if (item.rating.isNotEmpty || item.year.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 1, 2, 0),
              child: Text(
                [if (item.rating.isNotEmpty) '★ ${item.rating}', item.year]
                    .where((e) => e.isNotEmpty)
                    .join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: YumoriText.ui(
                    size: 11, color: YumoriColors.text.withOpacity(0.65)),
              ),
            ),
        ],
      ),
    );
  }
}
