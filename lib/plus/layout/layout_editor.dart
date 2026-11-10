// AnymeX+: "Edit layout" — one screen for every page and list. Pages (Home,
// Movies & TV, Manga): reorder, hide, rename and add rows; each row's card
// style and size, row or grid, how many items and their order. Library:
// default sort, order and columns per list type. Changes apply right away.

import 'package:anymex/controllers/settings/settings.dart';
import 'package:anymex/database/data_keys/keys.dart';
import 'package:anymex/plus/layout/layout_model.dart';
import 'package:anymex/plus/layout/layout_store.dart';
import 'package:anymex/plus/layout/page_rows.dart';
import 'package:anymex/plus/stremio/ui/stremio_home_page.dart'
    show stremioHomeRows;
import 'package:anymex/screens/library/controller/library_controller.dart';
import 'package:anymex/screens/settings/sub_settings/card_customizer_page.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/common/cards/media_card_registry.dart';
import 'package:anymex/widgets/common/cards/media_cards.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class PlusLayoutEditorPage extends StatefulWidget {
  /// The page to open on (null = Home).
  final PlusLayoutPage? page;
  const PlusLayoutEditorPage({super.key, this.page});

  @override
  State<PlusLayoutEditorPage> createState() => _PlusLayoutEditorPageState();
}

class _PlusLayoutEditorPageState extends State<PlusLayoutEditorPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 4,
    vsync: this,
    initialIndex: switch (widget.page) {
      PlusLayoutPage.movies => 1,
      PlusLayoutPage.manga => 2,
      _ => 0,
    },
  );

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit layout'),
        actions: [
          IconButton(
            tooltip: 'Card style for every row',
            icon: const Icon(Icons.style_outlined),
            onPressed: () => navigate(() => const CardCustomizerPage()),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Home'),
            Tab(text: 'Movies & TV'),
            Tab(text: 'Manga'),
            Tab(text: 'Library'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _PageEditor(page: PlusLayoutPage.home),
          _PageEditor(page: PlusLayoutPage.movies),
          _PageEditor(page: PlusLayoutPage.manga),
          _LibraryEditor(),
        ],
      ),
    );
  }
}

// ---- one page ----------------------------------------------------------------

class _PageEditor extends StatefulWidget {
  final PlusLayoutPage page;
  const _PageEditor({required this.page});

  @override
  State<_PageEditor> createState() => _PageEditorState();
}

class _PageEditorState extends State<_PageEditor>
    with AutomaticKeepAliveClientMixin {
  late List<PlusPlacedRow> _rows = _load();

  @override
  bool get wantKeepAlive => true;

  List<PlusPlacedRow> _load() => switch (widget.page) {
        PlusLayoutPage.home =>
          PlusPageRows.homeRows(discoverByDefault: PlusPageRows.discoverByDefault),
        PlusLayoutPage.manga => PlusPageRows.mangaRows(),
        PlusLayoutPage.movies => stremioHomeRows(),
      };

  void _save() {
    PlusLayoutStore.save(widget.page,
        PlusLayout.toSave(_rows, PlusLayoutStore.saved(widget.page)));
  }

  void _update(int i, PlusRowConfig c) {
    setState(() => _rows[i] = PlusPlacedRow(_rows[i].spec, c));
    _save();
  }

  void _setVisible(int i, bool on) {
    final r = _rows[i];
    // Home's list rows are AnymeX's own Home switches too.
    if (widget.page == PlusLayoutPage.home) {
      final sw = PlusPageRows.homeSwitchFor(r.key);
      if (sw != null) Get.find<Settings>().updateHomePageCard(sw, on);
    }
    _update(i, r.config.copyWith(hidden: !on));
  }

  static List<String> get _styleNames {
    registerBuiltInMediaCardStyles();
    return MediaCardRegistry.styles.map((s) => s.displayName).toList();
  }

  String _subtitle(PlusPlacedRow r) {
    final parts = <String>[];
    if (r.config.added) {
      final p = r.config.params;
      parts.add(p['kind'] == 'anilist'
          ? 'Filtered · ${PlusFilterRow.describe(p)}'
          : (p['genre'] != null ? 'Catalog · ${p['genre']}' : 'Catalog'));
    } else if (r.config.name != null && r.spec != null) {
      parts.add(r.spec!.title);
    }
    final style = r.config.style.summary(_styleNames);
    if (style.isNotEmpty) parts.add(style);
    if (!r.styled) parts.add('Move or hide only');
    return parts.join(' · ');
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset this page?'),
        content: const Text(
            'Rows go back to their usual order, names and look. Rows you '
            'added are removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    PlusLayoutStore.reset(widget.page);
    setState(() => _rows = _load());
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = context.colors;
    final shown = _rows.where((r) => !r.config.hidden).length;
    final note = switch (widget.page) {
      PlusLayoutPage.home => PlusPageRows.appliesToCurrent
          ? null
          : 'Home follows this layout when AniList is your service.',
      PlusLayoutPage.manga => PlusPageRows.appliesToCurrent
          ? null
          : 'Manga follows this layout when AniList is your service.',
      PlusLayoutPage.movies =>
        _rows.length <= 2 ? 'Your Stremio addons\' rows show here once they load.' : null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$shown of ${_rows.length} rows shown · drag to reorder, '
                  'tap a row for its look',
                  style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                ),
              ),
              TextButton(onPressed: _reset, child: const Text('Reset')),
              FilledButton.tonalIcon(
                onPressed: _addRow,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add row'),
              ),
            ],
          ),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(note,
                style: TextStyle(fontSize: 12, color: colors.primary)),
          ),
        const Divider(height: 1),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.only(bottom: 40),
            itemCount: _rows.length,
            onReorder: (from, to) {
              setState(() {
                if (to > from) to--;
                _rows.insert(to, _rows.removeAt(from));
              });
              _save();
            },
            itemBuilder: (context, i) {
              final r = _rows[i];
              final visible = !r.config.hidden;
              final sub = _subtitle(r);
              return ListTile(
                key: ValueKey(r.key),
                contentPadding: const EdgeInsets.only(left: 8, right: 4),
                leading: Checkbox(
                  value: visible,
                  onChanged: (v) => _setVisible(i, v == true),
                ),
                title: Text(
                  r.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: visible ? null : colors.onSurfaceVariant,
                  ),
                ),
                subtitle: sub.isEmpty
                    ? null
                    : Text(sub,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: colors.onSurfaceVariant)),
                onTap: r.styled || r.config.added ? () => _editRow(i) : null,
                trailing: ReorderableDragStartListener(
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(Icons.drag_handle_rounded,
                        color: colors.onSurfaceVariant),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---- row settings ----------------------------------------------------------

  Future<void> _editRow(int at) async {
    final names = _styleNames;
    final rowKey = _rows[at].key;
    final index = at;
    final nameCtrl = TextEditingController(text: _rows[index].config.name ?? '');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final index = _rows.indexWhere((e) => e.key == rowKey);
        if (index < 0) return const SizedBox.shrink();
        final r = _rows[index];
        final st = r.config.style;
        void setStyle(PlusRowStyle s) {
          _update(index, r.config.copyWith(style: s));
          setSheet(() {});
        }

        Widget chips<T>(String label, List<T> values, T selected,
            String Function(T) text, void Function(T) onPick) {
          return Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final v in values)
                      ChoiceChip(
                        label: Text(text(v)),
                        selected: v == selected,
                        showCheckmark: false,
                        onSelected: (_) => onPick(v),
                      ),
                  ],
                ),
              ],
            ),
          );
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(
              20, 0, 20, MediaQuery.viewInsetsOf(ctx).bottom + 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(r.title,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    hintText: r.spec?.title ?? r.title,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => _update(
                      index,
                      _rows[index].config.copyWith(
                          name: () => v.trim().isEmpty ? null : v.trim())),
                ),
                if (r.styled) ...[
                  chips<int?>('Card style', [null, ...List.generate(names.length, (i) => i)],
                      st.cardStyle, (v) => v == null ? 'App default' : names[v],
                      (v) => setStyle(st.copyWith(cardStyle: () => v))),
                  chips<double>('Card size', plusRowSizes.values.toList(), st.size,
                      (v) => plusRowSizes.entries
                          .firstWhere((e) => e.value == v,
                              orElse: () => MapEntry('${v}x', v))
                          .key,
                      (v) => setStyle(st.copyWith(size: v))),
                  chips<PlusRowView>('Show as', PlusRowView.values, st.view,
                      (v) => v == PlusRowView.row ? 'Row' : 'Grid',
                      (v) => setStyle(st.copyWith(view: v))),
                  chips<int>('Items', plusRowCounts, st.count,
                      (v) => v == 0 ? 'All' : '$v',
                      (v) => setStyle(st.copyWith(count: v))),
                  chips<PlusRowSort>('Order', PlusRowSort.values, st.sort,
                      (v) => switch (v) {
                            PlusRowSort.normal => 'Default',
                            PlusRowSort.title => 'Title',
                            PlusRowSort.score => 'Score',
                            PlusRowSort.year => 'Newest',
                          },
                      (v) => setStyle(st.copyWith(sort: v))),
                ],
                if (r.config.added) ...[
                  const SizedBox(height: 18),
                  if (r.config.params['kind'] == 'anilist')
                    OutlinedButton.icon(
                      onPressed: () async {
                        final p = await _filterForm(
                            r.config.params['type'] == 'MANGA',
                            initial: r.config.params);
                        if (p == null) return;
                        _update(index, _rows[index].config.copyWith(params: p));
                        setSheet(() {});
                      },
                      icon: const Icon(Icons.filter_alt_outlined),
                      label: const Text('Edit filters'),
                    ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                        foregroundColor: Theme.of(ctx).colorScheme.error),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      setState(() => _rows.removeAt(index));
                      _save();
                    },
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove this row'),
                  ),
                ],
              ],
            ),
          ),
        );
      }),
    );
    nameCtrl.dispose();
  }

  // ---- adding rows -------------------------------------------------------------

  void _addConfig(String title, Map<String, dynamic> params) {
    final key = 'add:${DateTime.now().microsecondsSinceEpoch}';
    setState(() => _rows.add(PlusPlacedRow(
        null,
        PlusRowConfig(
            key: key,
            added: true,
            params: {...params, 'title': title}))));
    _save();
  }

  Future<void> _addRow() async {
    final options = <(IconData, String, String, Future<void> Function())>[
      if (widget.page != PlusLayoutPage.movies) ...[
        if (widget.page == PlusLayoutPage.home)
          (Icons.filter_alt_outlined, 'Filtered anime row',
              'Genres, year, minimum score, sort', () async {
            final p = await _filterForm(false);
            if (p != null) _addConfig(p['title'] as String, p);
          }),
        (Icons.filter_alt_outlined, 'Filtered manga row',
            'Genres, year, minimum score, sort', () async {
          final p = await _filterForm(true);
          if (p != null) _addConfig(p['title'] as String, p);
        }),
      ],
      if (widget.page != PlusLayoutPage.manga)
        (Icons.live_tv_rounded,
            widget.page == PlusLayoutPage.home
                ? 'A Movies & TV catalog'
                : 'A catalog by genre',
            widget.page == PlusLayoutPage.home
                ? 'Any row from your Stremio addons, optionally one genre'
                : 'One of your catalogs, filtered to a genre', () async {
          final picked = await _pickCatalog(
              requireGenre: widget.page == PlusLayoutPage.movies);
          if (picked == null) return;
          final (rowKey, title, genre) = picked;
          _addConfig(genre == null ? title : '$title · $genre', {
            'kind': 'stremio',
            'rowKey': rowKey,
            if (genre != null) 'genre': genre,
          });
        }),
    ];
    final hidden = _rows.where((r) => r.config.hidden).length;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in options)
              ListTile(
                leading: Icon(o.$1),
                title: Text(o.$2),
                subtitle: Text(o.$3),
                onTap: () {
                  Navigator.of(ctx).pop();
                  o.$4();
                },
              ),
            if (hidden > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  '$hidden hidden row${hidden == 1 ? '' : 's'} on this page: '
                  'tick them in the list to show them again.',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Picks a Stremio catalog (and a genre). Null when cancelled.
  Future<(String, String, String?)?> _pickCatalog(
      {required bool requireGenre}) async {
    final all = plusStremioCatalogChoices()
        .where((c) => !requireGenre || c.$3.isNotEmpty)
        .toList();
    if (all.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(requireGenre
              ? 'None of your Stremio catalogs can be filtered by genre.'
              : 'No Stremio catalogs yet. Connect Stremio or wait for your '
                  'addons to load.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK')),
          ],
        ),
      );
      return null;
    }
    final catalog = await showModalBottomSheet<(String, String, List<String>)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.7,
        child: ListView(
          children: [
            for (final c in all)
              ListTile(
                title: Text(c.$2, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: c.$3.isEmpty ? null : Text('${c.$3.length} genres'),
                onTap: () => Navigator.of(ctx).pop(c),
              ),
          ],
        ),
      ),
    );
    if (catalog == null || !mounted) return null;
    if (catalog.$3.isEmpty) return (catalog.$1, catalog.$2, null);
    final genre = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.7,
        child: ListView(
          children: [
            if (!requireGenre)
              ListTile(
                title: const Text('All (no genre filter)'),
                onTap: () => Navigator.of(ctx).pop(''),
              ),
            for (final g in catalog.$3)
              ListTile(title: Text(g), onTap: () => Navigator.of(ctx).pop(g)),
          ],
        ),
      ),
    );
    if (genre == null) return null;
    return (catalog.$1, catalog.$2, genre.isEmpty ? null : genre);
  }

  /// The filtered-row form. Returns its params (with 'title'), or null.
  Future<Map<String, dynamic>?> _filterForm(bool manga,
      {Map<String, dynamic>? initial}) {
    final name = TextEditingController(
        text: initial?['title']?.toString() ?? '');
    final year = TextEditingController(
        text: initial?['year']?.toString() ?? '');
    final genres = <String>{
      ...((initial?['genres'] as List?) ?? const []).map((e) => '$e')
    };
    int minScore = (initial?['minScore'] as num?)?.toInt() ?? 0;
    String sort = initial?['sort']?.toString() ?? 'POPULARITY_DESC';
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
              20, 0, 20, MediaQuery.viewInsetsOf(ctx).bottom + 20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(manga ? 'Filtered manga row' : 'Filtered anime row',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'Row name',
                    hintText: 'e.g. Romance from 2024',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 14),
                const Text('Genres (any of)',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final g in plusAnilistGenres)
                      FilterChip(
                        label: Text(g),
                        selected: genres.contains(g),
                        onSelected: (on) =>
                            set(() => on ? genres.add(g) : genres.remove(g)),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: year,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Year (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 14),
                const Text('Minimum score',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final s in const [0, 60, 70, 80, 85])
                      ChoiceChip(
                        label: Text(s == 0 ? 'Any' : '$s+'),
                        selected: minScore == s,
                        showCheckmark: false,
                        onSelected: (_) => set(() => minScore = s),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                const Text('Sort',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final e in plusAnilistSorts.entries)
                      ChoiceChip(
                        label: Text(e.value),
                        selected: sort == e.key,
                        showCheckmark: false,
                        onSelected: (_) => set(() => sort = e.key),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () {
                    final y = int.tryParse(year.text.trim());
                    final title = name.text.trim().isNotEmpty
                        ? name.text.trim()
                        : [
                            if (genres.isNotEmpty) genres.join(', '),
                            if (y != null) '$y',
                            manga ? 'Manga' : 'Anime',
                          ].join(' · ');
                    Navigator.of(ctx).pop(<String, dynamic>{
                      'kind': 'anilist',
                      'type': manga ? 'MANGA' : 'ANIME',
                      'title': title,
                      if (genres.isNotEmpty) 'genres': genres.toList(),
                      if (y != null) 'year': y,
                      if (minScore > 0) 'minScore': minScore,
                      'sort': sort,
                    });
                  },
                  child: Text(initial == null ? 'Add row' : 'Save'),
                ),
              ],
            ),
          ),
        );
      }),
    ).whenComplete(() {
      name.dispose();
      year.dispose();
    });
  }
}

// ---- Library ---------------------------------------------------------------------

class _LibraryEditor extends StatefulWidget {
  const _LibraryEditor();

  @override
  State<_LibraryEditor> createState() => _LibraryEditorState();
}

class _LibraryEditorState extends State<_LibraryEditor> {
  static const _types = [
    (ItemType.anime, 'Anime'),
    (ItemType.manga, 'Manga'),
    (ItemType.novel, 'Novels'),
  ];

  static String _sortLabel(SortType s) => switch (s) {
        SortType.title => 'Title',
        SortType.lastAdded => 'Last added',
        SortType.lastRead => 'Last watched / read',
        SortType.rating => 'Score',
        SortType.popularity => 'Popularity',
        SortType.progress => 'Progress',
        SortType.aired => 'Release date',
      };

  LibraryController? get _live =>
      Get.isRegistered<LibraryController>() ? Get.find<LibraryController>() : null;

  void _setSort(ItemType t, SortType s, bool asc) {
    DynamicKeys.librarySortType.set(t.name, s.index);
    DynamicKeys.librarySortOrder.set(t.name, asc);
    final c = _live;
    if (c != null && c.type.value == t && c.selectedListIndex.value != -1) {
      c.currentSort.value = s;
      c.isAscending.value = asc;
    }
    setState(() {});
  }

  void _setColumns(ItemType t, int n) {
    DynamicKeys.libraryGridSize.set(t.name, n);
    final c = _live;
    if (c != null && c.type.value == t) c.gridCount.value = n;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      children: [
        Text(
          'How each Library list opens. You can still change them from the '
          'Library\'s sort button.',
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
        for (final (type, label) in _types) ...[
          const SizedBox(height: 18),
          Text(label,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          () {
            final idx = DynamicKeys.librarySortType
                .get<int>(type.name, SortType.lastAdded.index);
            final sort =
                SortType.values[idx.clamp(0, SortType.values.length - 1)];
            final asc = DynamicKeys.librarySortOrder.get<bool>(type.name, false);
            final cols = DynamicKeys.libraryGridSize.get<int>(type.name, 0);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Sort by', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in SortType.values)
                      ChoiceChip(
                        label: Text(_sortLabel(s)),
                        selected: s == sort,
                        showCheckmark: false,
                        onSelected: (_) => _setSort(type, s, asc),
                      ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Ascending', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                      asc ? 'A→Z, lowest / oldest first' : 'Z→A, highest / newest first',
                      style: const TextStyle(fontSize: 12)),
                  value: asc,
                  onChanged: (v) => _setSort(type, sort, v),
                ),
                const Text('Columns', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final n in const [0, 1, 2, 3, 4, 5, 6])
                      ChoiceChip(
                        label: Text(n == 0 ? 'Auto' : '$n'),
                        selected: n == cols,
                        showCheckmark: false,
                        onSelected: (_) => _setColumns(type, n),
                      ),
                  ],
                ),
              ],
            );
          }(),
        ],
      ],
    );
  }
}
