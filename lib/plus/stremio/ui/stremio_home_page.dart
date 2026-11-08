import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/stremio/ui/stremio_account_page.dart';
import 'package:anymex/plus/stremio/ui/stremio_widgets.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_chip.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_progress.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_section_builder.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_tile.dart';
import 'package:anymex/widgets/common/anymex_scaffold.dart';
import 'package:anymex/widgets/common/reusable_carousel.dart';
import 'package:anymex/widgets/common/scroll_aware_app_bar.dart';
import 'package:anymex/widgets/header/header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_iconly/flutter_iconly.dart';
import 'package:get/get.dart';

/// (addon, catalog, display title) for every board catalog, with titles made
/// unique when two addons have a catalog of the same name.
List<(StremioAddon, StremioCatalog, String)> _boardCatalogs(
    List<StremioAddon> addons,
    {bool searchable = false}) {
  final out = <(StremioAddon, StremioCatalog, String)>[];
  final seen = <String>{};
  for (final a in addons) {
    for (final c in a.catalogs) {
      final include = searchable
          ? c.supportsSearch
          : (c.isBoardCatalog && !c.isSearchOnly);
      if (!include) continue;
      final type = stremioTypeLabel(c.type);
      var title = type.isEmpty ? c.name : '${c.name} · $type';
      if (seen.contains(title)) title = '$title (${a.name})';
      seen.add(title);
      out.add((a, c, title));
    }
  }
  return out;
}

/// "Movies & TV" tab, laid out like AnymeX's Discover tab.
class StremioHomePage extends StatefulWidget {
  const StremioHomePage({super.key});

  @override
  State<StremioHomePage> createState() => _StremioHomePageState();
}

class _StremioHomePageState extends State<StremioHomePage> {
  final _service = StremioService.to;
  final _scroll = ScrollController();
  final _appBarVisible = ValueNotifier<bool>(true);
  int _reloadToken = 0;

  @override
  void dispose() {
    _scroll.dispose();
    _appBarVisible.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    await _service.refreshAddons();
    await _service.refreshContinueWatching();
    if (mounted) setState(() => _reloadToken++);
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.sizeOf(context).width > 600;
    final statusBarHeight = MediaQuery.paddingOf(context).top;
    const appBarHeight = kToolbarHeight + 20;
    final bottomNavBarHeight =
        isDesktop ? 20.0 : (MediaQuery.paddingOf(context).bottom + 65.0);
    final brightness = Theme.of(context).brightness;

    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refresh,
            edgeOffset: statusBarHeight + appBarHeight,
            child: Obx(() {
              final addons = _service.addons.toList();
              final cw = _service.continueWatching.toList();
              final loggedIn = _service.isLoggedIn.value;
              final loading = _service.addonsLoading.value;
              // Rows from addons already marked as not responding are
              // skipped instead of asked (and failing) every time.
              final rows = _boardCatalogs(
                  addons.where(_service.isAddonUsable).toList());
              return CustomScrollView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                cacheExtent: 400,
                slivers: [
                  SliverToBoxAdapter(
                    child:
                        SizedBox(height: statusBarHeight + appBarHeight + 10),
                  ),
                  if (!loggedIn)
                    SliverToBoxAdapter(child: _connectCard(context)),
                  if (cw.isNotEmpty)
                    SliverToBoxAdapter(
                      child: ReusableCarousel(
                        key: ValueKey('stremio-cw-$_reloadToken'),
                        data: cw.take(30).map(stremioContinueItem).toList(),
                        title: 'Continue Watching',
                        variant: DataVariant.offline,
                      ),
                    ),
                  if (addons.isEmpty && loading)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(48),
                        child: Center(child: AnymeXProgressIndicator()),
                      ),
                    ),
                  if (addons.isEmpty && !loading)
                    SliverToBoxAdapter(child: _emptyState(context)),
                  SliverList.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final (addon, catalog, title) = rows[i];
                      return RepaintBoundary(
                        child: StremioCatalogCarousel(
                          key: ValueKey(
                              '${addon.transportUrl}|${catalog.type}|${catalog.id}|$_reloadToken'),
                          addon: addon,
                          catalog: catalog,
                          title: title,
                        ),
                      );
                    },
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(height: bottomNavBarHeight + 150),
                  ),
                ],
              );
            }),
          ),
          Obx(() {
            final email = _service.userEmail.value;
            final loggedIn = _service.isLoggedIn.value;
            return CustomAnimatedAppBar(
              isVisible: _appBarVisible,
              scrollController: _scroll,
              headerContent: Header(
                title: 'Movies & TV',
                subtitle: loggedIn
                    ? (email.isEmpty ? 'Stremio' : 'Stremio · $email')
                    : 'Stremio · not connected',
                actions: [
                  HeaderActionButton(
                    icon: IconlyLight.search,
                    onTap: () => navigate(() => const StremioSearchPage()),
                  ),
                  HeaderActionButton(
                    icon: IconlyLight.category,
                    onTap: () => navigate(() => const StremioBrowsePage()),
                  ),
                  HeaderActionButton(
                    icon: IconlyLight.profile,
                    onTap: () => navigate(() => const StremioAccountPage()),
                  ),
                ],
              ),
              visibleStatusBarStyle: SystemUiOverlayStyle(
                statusBarIconBrightness: brightness == Brightness.light
                    ? Brightness.dark
                    : Brightness.light,
                statusBarBrightness: brightness,
                statusBarColor: Colors.transparent,
              ),
              hiddenStatusBarStyle: SystemUiOverlayStyle(
                statusBarIconBrightness: brightness == Brightness.light
                    ? Brightness.light
                    : Brightness.dark,
                statusBarBrightness: brightness == Brightness.light
                    ? Brightness.dark
                    : Brightness.light,
                statusBarColor: Colors.transparent,
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _connectCard(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: AnymeXSectionBuilder(
        children: [
          AnymeXTile(
            icon: Icons.live_tv_rounded,
            title: 'Connect your Stremio account',
            subtitle: 'Use your addons and sync Continue Watching',
            showChevron: true,
            onTap: () => navigate(() => const StremioAccountPage()),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Icon(Icons.extension_off_rounded,
              size: 40, color: context.colors.onSurfaceVariant),
          const SizedBox(height: 12),
          const AnymeXText('No addons loaded',
              variant: TextVariant.semiBold, size: 15),
          const SizedBox(height: 4),
          AnymeXText('Pull down to retry, or add addons in your account.',
              size: 12, color: context.colors.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// One catalog as an AnymeX carousel (uses the user's card style).
class StremioCatalogCarousel extends StatefulWidget {
  final StremioAddon addon;
  final StremioCatalog catalog;
  final String title;
  final Map<String, String> extra;

  const StremioCatalogCarousel({
    super.key,
    required this.addon,
    required this.catalog,
    required this.title,
    this.extra = const {},
  });

  @override
  State<StremioCatalogCarousel> createState() => _StremioCatalogCarouselState();
}

class _StremioCatalogCarouselState extends State<StremioCatalogCarousel> {
  List<StremioMetaPreview>? _items;

  bool _fresh = false;

  @override
  void initState() {
    super.initState();
    final service = StremioService.to;
    // Show the row saved last time straight away, then the fresh one.
    service
        .savedCatalog(widget.addon, widget.catalog, extra: widget.extra)
        .then((saved) {
      if (mounted && !_fresh && saved != null && saved.isNotEmpty) {
        setState(() => _items = saved);
      }
    }, onError: (_) {});
    service
        .catalogWithSave(widget.addon, widget.catalog, extra: widget.extra)
        .then((v) => v, onError: (_) => <StremioMetaPreview>[])
        .then((v) {
      if (!mounted) return;
      _fresh = true;
      // Keep the saved row if the addon came back empty this time.
      if (v.isEmpty && (_items?.isNotEmpty ?? false)) return;
      setState(() => _items = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items != null && items.isEmpty) return const SizedBox.shrink();
    return ReusableCarousel(
      data: (items ?? const <StremioMetaPreview>[])
          .take(25)
          .map(stremioMediaFromPreview)
          .toList(),
      title: widget.title,
      isLoading: items == null,
    );
  }
}

/// Browse one catalog at a time as a full grid, with genre filters.
class StremioBrowsePage extends StatefulWidget {
  const StremioBrowsePage({super.key});

  @override
  State<StremioBrowsePage> createState() => _StremioBrowsePageState();
}

class _StremioBrowsePageState extends State<StremioBrowsePage> {
  final _service = StremioService.to;
  final _scroll = ScrollController();
  final List<StremioMetaPreview> _items = [];
  int _selected = 0;
  String? _genre;
  bool _loading = false;
  bool _done = false;
  int _generation = 0;

  List<(StremioAddon, StremioCatalog, String)> get _catalogs =>
      _boardCatalogs(_service.addons.toList());

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
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
    final cats = _catalogs;
    if (_loading || _done || cats.isEmpty) return;
    final (addon, catalog, _) = cats[_selected.clamp(0, cats.length - 1)];
    final generation = _generation;
    setState(() => _loading = true);
    try {
      final supportsSkip = catalog.extra.any((e) => e.name == 'skip');
      final page = await _service.api.catalog(addon, catalog, extra: {
        if (_genre != null) 'genre': _genre!,
        if (_items.isNotEmpty) 'skip': '${_items.length}',
      });
      if (generation != _generation) return;
      final seen = _items.map((e) => e.id).toSet();
      final fresh = page.where((m) => !seen.contains(m.id)).toList();
      _items.addAll(fresh);
      if (fresh.isEmpty || !supportsSkip) _done = true;
    } catch (_) {
      if (generation == _generation) _done = true;
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _reset({int? catalog, String? genre, bool clearGenre = false}) {
    setState(() {
      _generation++;
      if (catalog != null) _selected = catalog;
      if (clearGenre) _genre = null;
      if (genre != null) _genre = genre;
      _items.clear();
      _done = false;
      _loading = false;
    });
    _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final cats = _catalogs;
    final current = cats.isEmpty ? null : cats[_selected.clamp(0, cats.length - 1)];
    final genreProp = current?.$2.extra.firstWhereOrNull((e) => e.name == 'genre');
    final genres = genreProp?.options ?? const <String>[];

    return AnymeXScaffold(
      showHeader: true,
      headerTitle: 'Browse',
      headerSubtitle: current?.$1.name,
      headerBottom: cats.isEmpty
          ? null
          : SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: cats.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) => AnymeXChip(
                  label: cats[i].$3,
                  isSelected: i == _selected,
                  showCheck: false,
                  onSelected: (_) =>
                      _reset(catalog: i, clearGenre: true),
                ),
              ),
            ),
      headerBottomHeight: 50,
      body: Builder(builder: (ctx) {
        return CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(
                child: SizedBox(height: AnymeXHeaderScope.of(ctx))),
            if (genres.isNotEmpty)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 46,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      if (!(genreProp?.isRequired ?? false))
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: AnymeXChip(
                            label: 'All',
                            isSelected: _genre == null,
                            showCheck: false,
                            onSelected: (_) => _reset(clearGenre: true),
                          ),
                        ),
                      ...genres.map((g) => Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: AnymeXChip(
                              label: g,
                              isSelected: _genre == g,
                              showCheck: false,
                              onSelected: (_) => _reset(genre: g),
                            ),
                          )),
                    ],
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              sliver: SliverGrid.builder(
                gridDelegate: stremioGridDelegate(context),
                itemCount: _items.length,
                itemBuilder: (context, i) => StremioGridCard(
                  item: _items[i],
                  tagPrefix: 'stremio-browse',
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 120),
                child: _loading
                    ? const Center(child: AnymeXProgressIndicator())
                    : (_items.isEmpty
                        ? Center(
                            child: AnymeXText(
                              cats.isEmpty
                                  ? 'No catalogs in your addons.'
                                  : 'Nothing here.',
                              color: context.colors.onSurfaceVariant,
                            ),
                          )
                        : const SizedBox.shrink()),
              ),
            ),
          ],
        );
      }),
    );
  }
}

/// Searches every installed catalog that supports search.
class StremioSearchPage extends StatefulWidget {
  final String initialQuery;
  const StremioSearchPage({super.key, this.initialQuery = ''});

  @override
  State<StremioSearchPage> createState() => _StremioSearchPageState();
}

class _StremioSearchPageState extends State<StremioSearchPage> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialQuery);
  late String _query = widget.initialQuery;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final targets =
        _boardCatalogs(StremioService.to.addons.toList(), searchable: true);
    return AnymeXScaffold(
      showHeader: true,
      headerTitle: 'Search',
      headerSubtitle: 'Movies & series from your Stremio addons',
      headerEnableSearch: true,
      headerSearchController: _controller,
      headerSearchHint: 'Search movies & series...',
      onHeaderSearchSubmitted: (q) {
        final t = q.trim();
        if (t.isNotEmpty) setState(() => _query = t);
      },
      onHeaderSearchClear: () => setState(() => _query = ''),
      body: Builder(builder: (ctx) {
        return ListView(
          padding: EdgeInsets.only(top: AnymeXHeaderScope.of(ctx), bottom: 120),
          children: [
            if (targets.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: AnymeXText(
                  'None of your addons support search. Install Cinemeta or '
                  'another catalog addon.',
                  textAlign: TextAlign.center,
                  color: context.colors.onSurfaceVariant,
                ),
              )
            else if (_query.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: AnymeXText(
                  'Type a title and press enter.',
                  textAlign: TextAlign.center,
                  color: context.colors.onSurfaceVariant,
                ),
              )
            else
              ...targets.map((t) => StremioCatalogCarousel(
                    key: ValueKey(
                        '$_query|${t.$1.transportUrl}|${t.$2.type}|${t.$2.id}'),
                    addon: t.$1,
                    catalog: t.$2,
                    title: '${stremioTypeLabel(t.$2.type)} · ${t.$1.name}',
                    extra: {'search': _query},
                  )),
          ],
        );
      }),
    );
  }
}
