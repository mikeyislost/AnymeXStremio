import 'package:anymex/plus/tvui/tv_data.dart';
import 'package:anymex/plus/tvui/tv_home.dart';
import 'package:anymex/plus/tvui/tv_widgets.dart';
import 'package:flutter/material.dart';

/// The Categories tab: lists, genres and streaming services, each one anime
/// (AniList) and Movies & TV (the built-in lists) together.
class TvCategoriesPage extends StatelessWidget {
  const TvCategoriesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final all = TvCategory.all();
    final accent = TvStyle.accent(context);
    Widget group(String id, String title, {bool small = false, bool first = false}) {
      final list = all.where((c) => c.group == id).toList();
      if (list.isEmpty) return const SizedBox.shrink();
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 28, bottom: 16),
          child: Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: 3, color: accent)),
        ),
        Wrap(spacing: 24, runSpacing: 24, children: [
          for (var i = 0; i < list.length; i++)
            TvFocusable(
              autofocus: first && i == 0,
              alignment: 0.3,
              onSelect: () => Navigator.of(context).push(tvRoute(TvCategoryPage(category: list[i]))),
              builder: (context, f) => AnimatedScale(
                scale: f ? 1.05 : 1,
                duration: const Duration(milliseconds: 120),
                child: Container(
                  width: small ? 300 : 316,
                  height: small ? 100 : 150,
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  alignment: small ? Alignment.center : Alignment.bottomLeft,
                  decoration: BoxDecoration(
                    color: small ? const Color(0xFF141414) : TvStyle.placeholder(list[i].name),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: f ? Colors.white : Colors.transparent, width: 4),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: small ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                    children: [
                      Text(list[i].name, style: TextStyle(fontSize: small ? 22 : 26, fontWeight: FontWeight.w700, color: Colors.white)),
                      if (!small) Text(list[i].sub, style: const TextStyle(fontSize: 17, color: TvStyle.text2)),
                    ],
                  ),
                ),
              ),
            ),
        ]),
      ]);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(TvStyle.pad, 64, TvStyle.pad, 200),
      clipBehavior: Clip.none,
      children: [
        const Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('Categories', style: TextStyle(fontSize: 48, fontWeight: FontWeight.w800, color: Colors.white)),
          SizedBox(width: 24),
          Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Anime from AniList and Movies & TV together', style: TextStyle(fontSize: 20, color: TvStyle.dim)),
          ),
        ]),
        group('lists', 'LISTS', first: true),
        group('genres', 'GENRES'),
        group('services', 'STREAMING SERVICES', small: true),
      ],
    );
  }
}

/// One category opened: everything in it as a grid, with filters.
class TvCategoryPage extends StatefulWidget {
  final TvCategory category;
  const TvCategoryPage({super.key, required this.category});

  @override
  State<TvCategoryPage> createState() => _TvCategoryPageState();
}

class _TvCategoryPageState extends State<TvCategoryPage> {
  List<TvItem>? _items;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    widget.category.load().then((v) {
      if (mounted) setState(() => _items = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.category;
    final items = (_items ?? const <TvItem>[]).where((i) => _filter == 'all' || i.kind == _filter).toList();
    final kinds = {for (final i in _items ?? const <TvItem>[]) i.kind};
    return TvGrid(
        header: [
          const Text('Categories ›', style: TextStyle(fontSize: 20, color: TvStyle.dim)),
          Text(c.name, style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 20),
          if (kinds.length > 1)
            FocusTraversalGroup(
              child: Wrap(spacing: 12, children: [
                TvChip(label: 'All', on: _filter == 'all', onSelect: () => setState(() => _filter = 'all')),
                if (kinds.contains('anime')) TvChip(label: 'Anime', on: _filter == 'anime', onSelect: () => setState(() => _filter = 'anime')),
                if (kinds.contains('movie')) TvChip(label: 'Movies', on: _filter == 'movie', onSelect: () => setState(() => _filter = 'movie')),
                if (kinds.contains('series')) TvChip(label: 'Series', on: _filter == 'series', onSelect: () => setState(() => _filter = 'series')),
              ]),
            ),
        ],
        items: items,
        empty: _items == null ? 'Loading…' : 'Nothing here.',
        showKind: kinds.length > 1,
    );
  }
}

/// A grid of posters under a header (categories, library, search).
class TvGrid extends StatelessWidget {
  final List<Widget> header;
  final List<TvItem> items;
  final String empty;
  final bool showKind;
  const TvGrid({super.key, required this.header, required this.items, this.empty = '', this.showKind = false});

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      clipBehavior: Clip.none,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(TvStyle.pad, 56, TvStyle.pad, 28),
          sliver: SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: header)),
        ),
        if (items.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: TvStyle.pad),
            sliver: SliverToBoxAdapter(child: Text(empty, style: const TextStyle(fontSize: 22, color: TvStyle.dim))),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(TvStyle.pad, 0, TvStyle.pad, 300),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: TvCard.posterW + 28,
                mainAxisExtent: TvCard.posterH + 90,
                crossAxisSpacing: 24,
                mainAxisSpacing: 20,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => Align(
                  alignment: Alignment.topLeft,
                  child: TvCard(item: items[i], showKind: showKind, onSelect: () => tvOpen(context, items[i])),
                ),
                childCount: items.length,
              ),
            ),
          ),
      ],
    );
  }
}
