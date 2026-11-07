// AnymeX+: one search for anime, manga and Movies & TV, opened from the
// search bar on Home. Results show as rows; each row links to the full
// search (with filters) for that kind.

import 'dart:async';

import 'package:anymex/controllers/service_handler/params.dart';
import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/services/stremio/stremio_service.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/screens/search/search_view.dart';
import 'package:anymex/screens/stremio/stremio_home_page.dart';
import 'package:anymex/screens/stremio/stremio_widgets.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/common/anymex_pills.dart';
import 'package:anymex/widgets/common/anymex_scaffold.dart';
import 'package:anymex/widgets/common/reusable_carousel.dart';
import 'package:anymex/widgets/header/header.dart';
import 'package:anymex/widgets/helper/tv_wrapper.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class EverythingSearchPage extends StatefulWidget {
  final String initialQuery;
  const EverythingSearchPage({super.key, this.initialQuery = ''});

  @override
  State<EverythingSearchPage> createState() => _EverythingSearchPageState();
}

enum _Filter { all, anime, manga, stremio }

class _EverythingSearchPageState extends State<EverythingSearchPage> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialQuery);
  late String _query = widget.initialQuery.trim();
  Timer? _debounce;
  _Filter _filter = _Filter.all;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 650), () {
      final q = value.trim();
      if (mounted && q != _query) setState(() => _query = q);
    });
  }

  bool _shows(_Filter f) => _filter == _Filter.all || _filter == f;

  @override
  Widget build(BuildContext context) {
    final handler = Get.find<ServiceHandler>();
    final isSimkl = handler.serviceType.value == ServicesType.simkl;
    final animeLabel = isSimkl ? 'Movies' : 'Anime';
    final mangaLabel = isSimkl ? 'Series' : 'Manga';
    final stremio = StremioService.to;
    final targets = [
      for (final a in stremio.addons.where(stremio.isAddonUsable))
        for (final c in a.catalogs.where((c) => c.supportsSearch)) (a, c)
    ].take(4).toList();
    final colors = context.colors;

    return AnymeXScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: HeaderSearchBar(
                controller: _controller,
                onChanged: _onChanged,
                onClose: () => Navigator.of(context).maybePop(),
                hintText: isSimkl
                    ? 'Search movies, series & more…'
                    : 'Search anime, manga, movies & TV…',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: AnymeXPills(
                scrollPadding: EdgeInsets.zero,
                items: [
                  PillItem(
                    label: 'All',
                    isSelected: _filter == _Filter.all,
                    onTap: () => setState(() => _filter = _Filter.all),
                  ),
                  PillItem(
                    label: animeLabel,
                    isSelected: _filter == _Filter.anime,
                    onTap: () => setState(() => _filter = _Filter.anime),
                  ),
                  PillItem(
                    label: mangaLabel,
                    isSelected: _filter == _Filter.manga,
                    onTap: () => setState(() => _filter = _Filter.manga),
                  ),
                  if (targets.isNotEmpty)
                    PillItem(
                      label: 'Movies & TV',
                      isSelected: _filter == _Filter.stremio,
                      onTap: () => setState(() => _filter = _Filter.stremio),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: _query.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: AnymeXText(
                          'Start typing to search everything at once.',
                          textAlign: TextAlign.center,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.only(bottom: 120),
                      children: [
                        if (_shows(_Filter.anime))
                          _TrackerResults(
                            key: ValueKey('anime|$_query'),
                            query: _query,
                            isManga: false,
                            title: animeLabel,
                          ),
                        if (_shows(_Filter.manga))
                          _TrackerResults(
                            key: ValueKey('manga|$_query'),
                            query: _query,
                            isManga: true,
                            title: mangaLabel,
                          ),
                        if (_shows(_Filter.stremio) && targets.isNotEmpty) ...[
                          for (final (a, c) in targets)
                            StremioCatalogCarousel(
                              key: ValueKey(
                                  '$_query|${a.transportUrl}|${c.type}|${c.id}'),
                              addon: a,
                              catalog: c,
                              title: '${stremioTypeLabel(c.type)} · ${a.name}',
                              extra: {'search': _query},
                            ),
                          _MoreLink(
                            label: 'More in Movies & TV',
                            onTap: () => navigate(
                                () => StremioSearchPage(initialQuery: _query)),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Anime or manga results from the active tracker (AniList / MAL / Simkl).
class _TrackerResults extends StatefulWidget {
  final String query;
  final bool isManga;
  final String title;

  const _TrackerResults({
    super.key,
    required this.query,
    required this.isManga,
    required this.title,
  });

  @override
  State<_TrackerResults> createState() => _TrackerResultsState();
}

class _TrackerResultsState extends State<_TrackerResults> {
  List<Media>? _results;

  @override
  void initState() {
    super.initState();
    Get.find<ServiceHandler>()
        .search(SearchParams(query: widget.query, isManga: widget.isManga))
        .then((r) => r ?? <Media>[], onError: (_) => <Media>[])
        .then((r) {
      if (mounted) setState(() => _results = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    if (results != null && results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: AnymeXText('No ${widget.title.toLowerCase()} found',
            size: 13, color: context.colors.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ReusableCarousel(
          data: results ?? const <Media>[],
          title: widget.title,
          type: widget.isManga ? ItemType.manga : ItemType.anime,
          isLoading: results == null,
        ),
        if (results != null)
          _MoreLink(
            label: 'More ${widget.title.toLowerCase()} results & filters',
            onTap: () => navigate(() => SearchPage(
                  searchTerm: widget.query,
                  isManga: widget.isManga,
                )),
          ),
      ],
    );
  }
}

class _MoreLink extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _MoreLink({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: AnymexOnTap(
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnymeXText(label,
                size: 13, variant: TextVariant.semiBold, color: colors.primary),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 18, color: colors.primary),
          ],
        ),
      ),
    );
  }
}
