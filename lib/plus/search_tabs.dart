// AnymeX+: a Movies & TV tab on the anime search page. The anime results
// are AnymeX's own, untouched; the second tab searches your Stremio addons
// for the same words.

import 'package:anymex/plus/stremio/ui/stremio_home_page.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:flutter/material.dart';

class PlusSearchTabs extends StatefulWidget {
  /// AnymeX's search results (shown as they are on the Anime tab).
  final Widget anime;

  /// The search box; its text is searched when the page rebuilds after
  /// you press enter (or clear it).
  final TextEditingController controller;

  /// False for manga, novels and extension searches: only [anime] shows.
  final bool enabled;

  const PlusSearchTabs({
    super.key,
    required this.anime,
    required this.controller,
    this.enabled = true,
  });

  @override
  State<PlusSearchTabs> createState() => _PlusSearchTabsState();
}

class _PlusSearchTabsState extends State<PlusSearchTabs> {
  int _tab = 0;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _query = widget.controller.text.trim();
  }

  @override
  void didUpdateWidget(covariant PlusSearchTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The search page rebuilds when a search starts or the box is cleared.
    _query = widget.controller.text.trim();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.anime;
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              selectedBackgroundColor: colors.primaryContainer,
            ),
            segments: const [
              ButtonSegment(value: 0, label: Text('Anime')),
              ButtonSegment(value: 1, label: Text('Movies & TV')),
            ],
            selected: {_tab},
            onSelectionChanged: (v) => setState(() {
              _tab = v.first;
              _query = widget.controller.text.trim();
            }),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              widget.anime,
              _tab == 1
                  ? StremioSearchResults(
                      key: ValueKey('plus-search-$_query'),
                      query: _query,
                      padding: EdgeInsets.only(
                          bottom: MediaQuery.paddingOf(context).bottom + 32),
                    )
                  : const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    );
  }
}
