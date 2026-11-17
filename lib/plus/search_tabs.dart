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
          child: Row(
            children: [
              for (final (i, label) in const [(0, 'Anime'), (1, 'Movies & TV')])
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() {
                    _tab = i;
                    _query = widget.controller.text.trim();
                  }),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 22),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 6),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight:
                                _tab == i ? FontWeight.w700 : FontWeight.w500,
                            color: _tab == i
                                ? colors.onSurface
                                : colors.onSurface.withOpacity(0.55),
                          ),
                        ),
                        const SizedBox(height: 5),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          height: 2.5,
                          width: _tab == i ? 22 : 0,
                          decoration: BoxDecoration(
                            color: colors.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
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
