// Yumori Home hero: a full-bleed Featured banner behind the header, mixing
// AniList trending anime with trending Movies & TV (TMDB / Stremio).

import 'dart:async';

import 'package:anymex/plus/categories/categories_data.dart';
import 'package:anymex/plus/categories/categories_page.dart';
import 'package:anymex/theme/yumori_tokens.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_image.dart';
import 'package:flutter/material.dart';

class YumoriHomeHero extends StatefulWidget {
  /// Space the header takes at the top (status bar + bar), kept clear of text.
  final double topInset;
  final double height;
  const YumoriHomeHero({super.key, required this.topInset, this.height = 560});

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
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
    final parts = await Future.wait<List<CatItem>>([
      CatAnilist.list({
        'sort': ['TRENDING_DESC'],
        'page': 1
      }),
      CatMovies.row('trending-movies'),
      CatMovies.row('trending-series'),
    ]);
    bool ok(CatItem i) => i.backdrop.isNotEmpty || i.poster.isNotEmpty;
    final mixed = CatCategory.interleave([
      parts[0].where(ok).take(6).toList(),
      parts[1].where(ok).take(3).toList(),
      parts[2].where(ok).take(3).toList(),
    ]);
    if (mixed.isEmpty) return;
    _cache = mixed;
    _at = DateTime.now();
    _set(mixed);
  }

  void _set(List<CatItem> items) {
    if (!mounted) return;
    setState(() => _items = items);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || !_page.hasClients || _items.length < 2) return;
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
    final h = widget.height;
    return SizedBox(
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _page,
            itemCount: _items.length,
            onPageChanged: (i) => setState(() => _index = i),
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

  Widget _slide(BuildContext context, CatItem it, int i) {
    final art = it.backdrop.isNotEmpty ? it.backdrop : it.poster;
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
          AnymeXImage(
            imageUrl: art,
            radius: 0,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          ),
          // Dark at the top (so the header reads) and at the bottom (text).
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
                  Color(0xFF0D0A16),
                ],
              ),
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
                    boxShadow: [
                      BoxShadow(
                        color: YumoriColors.lavender.withOpacity(0.5),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                        spreadRadius: -6,
                      ),
                    ],
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
