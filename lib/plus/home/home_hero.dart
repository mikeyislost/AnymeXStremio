// Yumori Home hero: a full-bleed Featured banner behind the header, mixing
// AniList trending anime with trending Movies & TV (TMDB / Stremio).

import 'dart:async';
import 'dart:convert';

import 'package:anymex/plus/categories/categories_data.dart';
import 'package:anymex/plus/categories/categories_page.dart';
import 'package:anymex/theme/yumori_tokens.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// Anime art from TMDB (same source as the Movies & TV cards), by title.
/// Falls back to AniList's own art when TMDB has no match.
class YumoriHeroArt {
  static final _poster = <String, String>{};
  static final _backdrop = <String, String>{};

  static String poster(CatItem it) =>
      _poster[it.key] ?? (it.poster.isNotEmpty ? it.poster : it.backdrop);
  static String backdrop(CatItem it) =>
      _backdrop[it.key] ?? (it.backdrop.isNotEmpty ? it.backdrop : it.poster);

  static Future<void> resolve(CatItem it) async {
    if (!it.isAnime || _poster.containsKey(it.key)) return;
    final key = (dotenv.maybeGet('TMDB_API_KEY') ?? '').trim();
    if (key.isEmpty) return;
    for (final kind in const ['tv', 'movie']) {
      try {
        final r = await http
            .get(Uri.https('api.themoviedb.org', '/3/search/$kind',
                {'api_key': key, 'query': it.title}))
            .timeout(const Duration(seconds: 8));
        if (r.statusCode != 200) continue;
        final res = (jsonDecode(r.body)['results'] as List?) ?? const [];
        for (final m in res) {
          if (m is! Map) continue;
          final p = '${m['poster_path'] ?? ''}';
          final b = '${m['backdrop_path'] ?? ''}';
          if (p.isEmpty && b.isEmpty) continue;
          _poster[it.key] = p.isNotEmpty
              ? 'https://image.tmdb.org/t/p/w780$p'
              : 'https://image.tmdb.org/t/p/w1280$b';
          _backdrop[it.key] = b.isNotEmpty
              ? 'https://image.tmdb.org/t/p/original$b'
              : 'https://image.tmdb.org/t/p/w780$p';
          return;
        }
      } catch (_) {}
    }
  }
}

/// The item the hero is showing, shared with the full-screen backdrop.
class YumoriHeroBus {
  static final current = ValueNotifier<CatItem?>(null);
}

/// PC / TV style: the art of the current Featured item fixed behind the
/// whole Home page; it darkens as the page scrolls.
class YumoriHeroBackdrop extends StatelessWidget {
  final ScrollController scroll;
  const YumoriHeroBackdrop({super.key, required this.scroll});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CatItem?>(
      valueListenable: YumoriHeroBus.current,
      builder: (context, it, _) {
        if (it == null) return const SizedBox.expand();
        final art = _YumoriHomeHeroState._sharp(YumoriHeroArt.backdrop(it));
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 700),
              child: SizedBox.expand(
                key: ValueKey(it.key),
                child: AnymeXImage(
                  imageUrl: art,
                  radius: 0,
                  fit: BoxFit.cover,
                  alignment: Alignment.centerRight,
                ),
              ),
            ),
            // Dark on the left (text) and at the bottom (rows).
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  stops: [0.0, 0.4, 0.8],
                  colors: [
                    Color(0xF20D0A16),
                    Color(0x990D0A16),
                    Color(0x000D0A16),
                  ],
                ),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.0, 0.18, 0.6, 1.0],
                  colors: [
                    Color(0xAA0D0A16),
                    Color(0x000D0A16),
                    Color(0x330D0A16),
                    Color(0xF20D0A16),
                  ],
                ),
              ),
            ),
            AnimatedBuilder(
              animation: scroll,
              builder: (context, _) {
                final off = scroll.hasClients ? scroll.offset : 0.0;
                final t = (off / 380).clamp(0.0, 1.0);
                return ColoredBox(
                    color: const Color(0xFF0D0A16).withOpacity(0.78 * t));
              },
            ),
          ],
        );
      },
    );
  }
}

class YumoriHomeHero extends StatefulWidget {
  /// Space the header takes at the top (status bar + bar), kept clear of text.
  final double topInset;
  final double height;

  /// PC / TV: no art here (the backdrop behind the page shows it); big
  /// title on the left and a strip of small posters to pick from.
  final bool fullScreen;
  const YumoriHomeHero(
      {super.key,
      required this.topInset,
      this.height = 560,
      this.fullScreen = false});

  @override
  State<YumoriHomeHero> createState() => _YumoriHomeHeroState();
}

class _YumoriHomeHeroState extends State<YumoriHomeHero> {
  static List<CatItem>? _cache;
  static DateTime? _at;

  final _page = PageController();
  List<CatItem> _items = const [];
  int _index = 0;
  Timer? _timer;
  Timer? _retry;
  int _tries = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _retry?.cancel();
    _page.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_cache != null &&
        _at != null &&
        DateTime.now().difference(_at!) < const Duration(minutes: 30)) {
      _set(_cache!);
      return;
    }
    Future<List<CatItem>> safe(Future<List<CatItem>> f) =>
        f.catchError((_) => <CatItem>[]);
    final parts = await Future.wait<List<CatItem>>([
      safe(CatAnilist.list({
        'sort': ['TRENDING_DESC'],
        'page': 1
      })),
      safe(CatMovies.row('trending-movies')),
      safe(CatMovies.row('trending-series')),
    ]);
    bool ok(CatItem i) => i.backdrop.isNotEmpty || i.poster.isNotEmpty;
    final mixed = CatCategory.interleave([
      parts[0].where(ok).take(6).toList(),
      parts[1].where(ok).take(3).toList(),
      parts[2].where(ok).take(3).toList(),
    ]);
    final complete = parts.every((p) => p.isNotEmpty);
    await Future.wait(mixed.map(YumoriHeroArt.resolve));
    if (mixed.isNotEmpty) {
      _set(mixed);
      // Only remember a result that has every source in it.
      if (complete) {
        _cache = mixed;
        _at = DateTime.now();
      }
    }
    // A source that was not ready yet (network, Stremio setup): try again.
    if (!complete && _tries < 5 && mounted) {
      _tries++;
      _retry?.cancel();
      _retry = Timer(const Duration(seconds: 8), _load);
    }
  }

  void _set(List<CatItem> items) {
    if (!mounted) return;
    setState(() {
      _items = items;
      if (_index >= items.length) _index = 0;
    });
    YumoriHeroBus.current.value = items[_index];
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || _items.length < 2) return;
      if (widget.fullScreen) {
        setState(() => _index = (_index + 1) % _items.length);
        YumoriHeroBus.current.value = _items[_index];
        return;
      }
      if (!_page.hasClients) return;
      _page.animateToPage((_index + 1) % _items.length,
          duration: const Duration(milliseconds: 800),
          curve: Curves.easeInOutCubic);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return SizedBox(height: widget.topInset + 20);
    }
    if (widget.fullScreen) return _fullScreen(context);
    final h = widget.height;
    return SizedBox(
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _page,
            itemCount: _items.length,
            onPageChanged: (i) {
              setState(() => _index = i);
              YumoriHeroBus.current.value = _items[i];
            },
            itemBuilder: (context, i) => _slide(context, _items[i], i),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 14,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _items.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    width: i == _index ? 19 : 13,
                    height: 2,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: i == _index
                          ? YumoriColors.lavender
                          : YumoriColors.text.withOpacity(0.3),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fullScreen(BuildContext context) {
    final it = _items[_index.clamp(0, _items.length - 1)];
    final meta = [
      it.kindLabel[0] + it.kindLabel.substring(1).toLowerCase(),
      if (it.genre.isNotEmpty) it.genre,
      if (it.year.isNotEmpty) it.year,
    ].join(' · ');
    final tag = 'hero-${it.key}-$_index';
    return SizedBox(
      height: widget.height,
      child: Padding(
        padding: EdgeInsets.fromLTRB(40, widget.topInset, 40, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Spacer(),
            Row(children: [
              Text(meta,
                  style: YumoriText.ui(
                      size: 13, color: YumoriColors.text.withOpacity(0.8))),
              if (it.rating.isNotEmpty) ...[
                const SizedBox(width: 14),
                const Icon(Icons.star_rounded,
                    size: 16, color: YumoriColors.firefly),
                const SizedBox(width: 4),
                Text(it.rating,
                    style: YumoriText.ui(
                        size: 13, color: YumoriColors.firefly)),
              ],
            ]),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Text(it.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: YumoriText.title(size: 56).copyWith(height: 1.05)),
            ),
            if (it.overview.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Text(it.overview,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: YumoriText.ui(
                            size: 14,
                            color: YumoriColors.text.withOpacity(0.85))
                        .copyWith(height: 1.5)),
              ),
            ],
            const SizedBox(height: 18),
            GestureDetector(
              onTap: () => openCatItem(it, tag),
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 26),
                decoration: BoxDecoration(
                  color: YumoriColors.lavender,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.play_arrow_rounded,
                      size: 20, color: YumoriColors.onLavender),
                  const SizedBox(width: 6),
                  Text('View details',
                      style: YumoriText.ui(
                          size: 14,
                          weight: FontWeight.w700,
                          color: YumoriColors.onLavender)),
                ]),
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              height: 84,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final t = _items[i];
                  final on = i == _index;
                  return GestureDetector(
                    onTap: () {
                      _timer?.cancel();
                      setState(() => _index = i);
                      YumoriHeroBus.current.value = t;
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 56,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: on
                                ? YumoriColors.lavender
                                : Colors.transparent,
                            width: 2),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Opacity(
                          opacity: on ? 1 : 0.6,
                          child: AnymeXImage(
                              imageUrl: YumoriHeroArt.poster(t),
                              radius: 0,
                              fit: BoxFit.cover),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The biggest copy of an image where the host offers one.
  static String _sharp(String url) {
    final tmdb = RegExp(r'(image\.tmdb\.org/t/p/)(w\d+|original)/');
    if (tmdb.hasMatch(url)) {
      return url.replaceFirstMapped(tmdb, (m) => '${m[1]}original/');
    }
    return url.replaceFirst('/poster/medium/', '/poster/large/');
  }

  Widget _slide(BuildContext context, CatItem it, int i) {
    // Wide screens use the wide art, phones the poster (sharper there).
    final wide = MediaQuery.of(context).size.width > widget.height * 1.15;
    final art = wide
        ? _sharp(YumoriHeroArt.backdrop(it))
        : YumoriHeroArt.poster(it); // phone: no oversized originals
    final meta = [
      it.kindLabel[0] + it.kindLabel.substring(1).toLowerCase(),
      if (it.genre.isNotEmpty) it.genre,
      if (it.year.isNotEmpty) it.year,
    ].join(' · ');
    final tag = 'hero-${it.key}-$i';
    return GestureDetector(
      onTap: () => openCatItem(it, tag),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The art fades out at the bottom so it blends into the page.
          ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0.0, 0.55, 1.0],
              colors: [Colors.black, Colors.black, Colors.transparent],
            ).createShader(r),
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnymeXImage(
                  imageUrl: art,
                  radius: 0,
                  width: MediaQuery.sizeOf(context).width,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.0, 0.22, 0.5, 1.0],
                      colors: [
                        Color(0xCC0D0A16),
                        Color(0x330D0A16),
                        Color(0x660D0A16),
                        Color(0xB30D0A16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 22,
            right: 22,
            bottom: 34,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('FEATURED',
                        style: YumoriText.ui(
                                size: 10,
                                weight: FontWeight.w600,
                                color: YumoriColors.text)
                            .copyWith(letterSpacing: 3.2)),
                    const SizedBox(width: 11),
                    Container(
                        width: 43, height: 1, color: YumoriColors.lavender),
                  ],
                ),
                const SizedBox(height: 8),
                Text(it.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: YumoriText.title(size: 32)),
                const SizedBox(height: 6),
                Text(meta,
                    style: YumoriText.ui(
                        size: 11,
                        color: YumoriColors.text.withOpacity(0.75))),
                if (it.overview.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Text(it.overview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: YumoriText.ui(
                                size: 12,
                                color: YumoriColors.text.withOpacity(0.85))
                            .copyWith(height: 1.45)),
                  ),
                ],
                if (it.rating.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.star_rounded,
                          size: 14, color: YumoriColors.firefly),
                      const SizedBox(width: 4),
                      Text(it.rating,
                          style: YumoriText.ui(
                              size: 11, color: YumoriColors.firefly)),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: YumoriColors.lavender,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.play_arrow_rounded,
                          size: 18, color: YumoriColors.onLavender),
                      const SizedBox(width: 6),
                      Text('View details',
                          style: YumoriText.ui(
                              size: 13,
                              weight: FontWeight.w700,
                              color: YumoriColors.onLavender)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
