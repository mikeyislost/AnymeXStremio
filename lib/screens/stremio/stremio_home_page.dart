import 'package:anymex/controllers/services/stremio/stremio_models.dart';
import 'package:anymex/controllers/services/stremio/stremio_service.dart';
import 'package:anymex/screens/stremio/stremio_account_page.dart';
import 'package:anymex/screens/stremio/stremio_widgets.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// "Movies & TV" tab: Stremio Continue Watching + addon catalogs.
class StremioHomePage extends StatefulWidget {
  const StremioHomePage({super.key});

  @override
  State<StremioHomePage> createState() => _StremioHomePageState();
}

class _StremioHomePageState extends State<StremioHomePage> {
  final _service = StremioService.to;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    await _service.refreshAddons();
    await _service.refreshContinueWatching();
    if (mounted) setState(() {});
  }

  void _openSearch(String query) {
    if (query.trim().isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StremioSearchPage(query: query.trim()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: Obx(() {
          final addons = _service.addons.toList();
          final cw = _service.continueWatching.toList();
          final rows = <(StremioAddon, StremioCatalog)>[];
          for (final a in addons) {
            for (final c in a.catalogs) {
              if (c.isBoardCatalog && !c.isSearchOnly) rows.add((a, c));
            }
          }
          return ListView(
            padding: EdgeInsets.only(top: top + 8, bottom: 140),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Movies & TV',
                          style: theme.textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ),
                    _accountButton(theme),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _openSearch,
                  decoration: InputDecoration(
                    hintText: 'Search movies & series',
                    prefixIcon: const Icon(Icons.search_rounded),
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              if (!_service.isLoggedIn.value)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Card(
                    child: ListTile(
                      leading: const Icon(Icons.login_rounded),
                      title: const Text('Connect your Stremio account'),
                      subtitle: const Text(
                          'Use your addons and sync Continue Watching'),
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const StremioAccountPage())),
                    ),
                  ),
                ),
              if (cw.isNotEmpty)
                StremioRow(
                  title: 'Continue Watching',
                  children: cw.take(30).map((item) {
                    return StremioPosterCard(
                      title: item.name,
                      poster: item.poster,
                      progress: item.progress,
                      subtitle: _episodeLabel(item.videoId),
                      onTap: () =>
                          openStremioDetails(context, item.type, item.id),
                    );
                  }).toList(),
                ),
              if (addons.isEmpty && _service.addonsLoading.value)
                const Padding(
                  padding: EdgeInsets.all(48),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (addons.isEmpty && !_service.addonsLoading.value)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    children: [
                      const Text('No addons loaded.'),
                      TextButton(
                          onPressed: _refresh, child: const Text('Retry')),
                    ],
                  ),
                ),
              ...rows.map((r) => _CatalogRow(
                    key: ValueKey(
                        '${r.$1.transportUrl}|${r.$2.type}|${r.$2.id}'),
                    addon: r.$1,
                    catalog: r.$2,
                  )),
            ],
          );
        }),
      ),
    );
  }

  Widget _accountButton(ThemeData theme) {
    final avatar = _service.userAvatar.value;
    return IconButton(
      tooltip: 'Stremio account & addons',
      onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const StremioAccountPage())),
      icon: _service.isLoggedIn.value && avatar.isNotEmpty
          ? CircleAvatar(
              radius: 16,
              backgroundImage: CachedNetworkImageProvider(avatar),
            )
          : const Icon(Icons.account_circle_outlined, size: 30),
    );
  }

  static String? _episodeLabel(String? videoId) {
    if (videoId == null) return null;
    final parts = videoId.split(':');
    if (parts.length >= 3) {
      final s = int.tryParse(parts[parts.length - 2]);
      final e = int.tryParse(parts.last);
      if (s != null && e != null) return 'S$s E$e';
    }
    if (parts.length == 3 && parts.first == 'kitsu') {
      return 'Episode ${parts.last}';
    }
    return null;
  }
}

class _CatalogRow extends StatefulWidget {
  final StremioAddon addon;
  final StremioCatalog catalog;

  const _CatalogRow({super.key, required this.addon, required this.catalog});

  @override
  State<_CatalogRow> createState() => _CatalogRowState();
}

class _CatalogRowState extends State<_CatalogRow> {
  late Future<List<StremioMetaPreview>> _future;

  @override
  void initState() {
    super.initState();
    _future = StremioService.to.api
        .catalog(widget.addon, widget.catalog)
        .catchError((_) => <StremioMetaPreview>[]);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<StremioMetaPreview>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 60,
            child: Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        final items = snap.data ?? const [];
        if (items.isEmpty) return const SizedBox.shrink();
        final label = typeLabel(widget.catalog.type);
        return StremioRow(
          title: label.isEmpty
              ? widget.catalog.name
              : '${widget.catalog.name} · $label',
          onMore: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => StremioCatalogPage(
                addon: widget.addon, catalog: widget.catalog),
          )),
          children: items
              .take(20)
              .map((m) => StremioPosterCard(
                    title: m.name,
                    poster: m.poster,
                    subtitle: m.releaseInfo,
                    onTap: () =>
                        openStremioDetails(context, m.type, m.id, preview: m),
                  ))
              .toList(),
        );
      },
    );
  }
}

/// Full catalog grid with paging (`skip` extra) and genre filter.
class StremioCatalogPage extends StatefulWidget {
  final StremioAddon addon;
  final StremioCatalog catalog;

  const StremioCatalogPage(
      {super.key, required this.addon, required this.catalog});

  @override
  State<StremioCatalogPage> createState() => _StremioCatalogPageState();
}

class _StremioCatalogPageState extends State<StremioCatalogPage> {
  final List<StremioMetaPreview> _items = [];
  final _scroll = ScrollController();
  bool _loading = false;
  bool _done = false;
  String? _genre;

  StremioExtraProp? get _genreProp =>
      widget.catalog.extra.firstWhereOrNull((e) => e.name == 'genre');
  bool get _supportsSkip =>
      widget.catalog.extra.any((e) => e.name == 'skip');

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels >
          _scroll.position.maxScrollExtent - 600) {
        _loadMore();
      }
    });
    _loadMore();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    try {
      final extra = <String, String>{
        if (_genre != null) 'genre': _genre!,
        if (_items.isNotEmpty) 'skip': '${_items.length}',
      };
      final page = await StremioService.to.api
          .catalog(widget.addon, widget.catalog, extra: extra);
      final seen = _items.map((e) => e.id).toSet();
      final fresh = page.where((m) => !seen.contains(m.id)).toList();
      _items.addAll(fresh);
      if (fresh.isEmpty || !_supportsSkip) _done = true;
    } catch (_) {
      _done = true;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setGenre(String? g) {
    setState(() {
      _genre = g;
      _items.clear();
      _done = false;
    });
    _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final genres = _genreProp?.options ?? const <String>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(
            '${widget.catalog.name} · ${typeLabel(widget.catalog.type)}'),
      ),
      body: Column(
        children: [
          if (genres.isNotEmpty)
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  if (!(_genreProp?.isRequired ?? false))
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: ChoiceChip(
                        label: const Text('All'),
                        selected: _genre == null,
                        onSelected: (_) => _setGenre(null),
                      ),
                    ),
                  ...genres.map((g) => Padding(
                        padding: const EdgeInsets.all(4),
                        child: ChoiceChip(
                          label: Text(g),
                          selected: _genre == g,
                          onSelected: (_) => _setGenre(g),
                        ),
                      )),
                ],
              ),
            ),
          Expanded(
            child: GridView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 120),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 130,
                childAspectRatio: 0.52,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: _items.length + (_loading ? 1 : 0),
              itemBuilder: (context, i) {
                if (i >= _items.length) {
                  return const Center(child: CircularProgressIndicator());
                }
                final m = _items[i];
                return StremioPosterCard(
                  title: m.name,
                  poster: m.poster,
                  subtitle: m.releaseInfo,
                  onTap: () =>
                      openStremioDetails(context, m.type, m.id, preview: m),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Searches every installed catalog that supports `search`.
class StremioSearchPage extends StatefulWidget {
  final String query;
  const StremioSearchPage({super.key, required this.query});

  @override
  State<StremioSearchPage> createState() => _StremioSearchPageState();
}

class _StremioSearchPageState extends State<StremioSearchPage> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.query);
  late String _query = widget.query;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = StremioService.to;
    final targets = <(StremioAddon, StremioCatalog)>[];
    for (final a in service.addons) {
      for (final c in a.catalogs) {
        if (c.supportsSearch) targets.add((a, c));
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: false,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search',
            border: InputBorder.none,
          ),
          onSubmitted: (q) {
            if (q.trim().isNotEmpty) setState(() => _query = q.trim());
          },
        ),
      ),
      body: targets.isEmpty
          ? const Center(
              child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                  'None of your addons support search. Install Cinemeta or '
                  'another catalog addon.',
                  textAlign: TextAlign.center),
            ))
          : ListView(
              padding: const EdgeInsets.only(bottom: 120),
              children: targets
                  .map((t) => _SearchRow(
                        key: ValueKey(
                            '$_query|${t.$1.transportUrl}|${t.$2.type}|${t.$2.id}'),
                        addon: t.$1,
                        catalog: t.$2,
                        query: _query,
                      ))
                  .toList(),
            ),
    );
  }
}

class _SearchRow extends StatefulWidget {
  final StremioAddon addon;
  final StremioCatalog catalog;
  final String query;

  const _SearchRow(
      {super.key,
      required this.addon,
      required this.catalog,
      required this.query});

  @override
  State<_SearchRow> createState() => _SearchRowState();
}

class _SearchRowState extends State<_SearchRow> {
  late final Future<List<StremioMetaPreview>> _future = StremioService.to.api
      .catalog(widget.addon, widget.catalog, extra: {'search': widget.query})
      .catchError((_) => <StremioMetaPreview>[]);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<StremioMetaPreview>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
              height: 60,
              child: Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))));
        }
        final items = snap.data ?? const [];
        if (items.isEmpty) return const SizedBox.shrink();
        return StremioRow(
          title:
              '${widget.addon.name} · ${typeLabel(widget.catalog.type)}',
          children: items
              .map((m) => StremioPosterCard(
                    title: m.name,
                    poster: m.poster,
                    subtitle: m.releaseInfo,
                    onTap: () =>
                        openStremioDetails(context, m.type, m.id, preview: m),
                  ))
              .toList(),
        );
      },
    );
  }
}
