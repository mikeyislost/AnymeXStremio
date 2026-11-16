import 'package:anymex/theme/yumori_tokens.dart';
import 'package:anymex/widgets/anymex_widgets/yumori_orbit.dart';
import 'package:anymex/widgets/common/navbar.dart';
import 'package:flutter/material.dart';

/// Yumori's desktop navigation: wordmark on the left, text pills in the
/// middle (the selected one has a firefly orbiting its outline), the profile
/// bubble on the right. A tab's sub-controls (e.g. Library's toggle) show in a
/// slim row under the bar.
///
/// [items] is the same list the side rail used: item 0 = profile, the rest =
/// tabs; [currentIndex] indexes into it.
class YumoriTopBar extends StatelessWidget {
  final List<NavItem> items;
  final int currentIndex;
  final VoidCallback? onSearch;

  const YumoriTopBar({
    super.key,
    required this.items,
    required this.currentIndex,
    this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final profile = items.isNotEmpty ? items.first : null;
    final selected =
        (currentIndex > 0 && currentIndex < items.length) ? items[currentIndex] : null;
    final sub = selected?.subWidget;

    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 14, 28, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  _Wordmark(color: primary),
                  const SizedBox(width: 72),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var i = 1; i < items.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _TabPill(
                                label: items[i].label,
                                selected: i == currentIndex,
                                color: primary,
                                onTap: () => items[i].onTap(i),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (onSearch != null) ...[
                    Tooltip(
                      message: 'Search',
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: onSearch,
                        child: Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: YumoriColors.card.withValues(alpha: 0.7),
                            border: Border.all(
                              color: primary.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Icon(Icons.search_rounded,
                              size: 22, color: primary),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (profile != null)
                    Tooltip(
                      message: 'Profile & settings',
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => profile.onTap(0),
                        child: Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: YumoriColors.card.withValues(alpha: 0.7),
                            border: Border.all(
                              color: primary.withValues(alpha: 0.25),
                            ),
                          ),
                          child: ClipOval(
                            child: profile.altIcon ??
                                Icon(profile.selectedIcon, size: 20),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOutCubic,
              child: sub == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Align(alignment: Alignment.centerLeft, child: sub),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  final Color color;
  const _Wordmark({required this.color});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/yumori/wordmark.png',
      height: 40,
      filterQuality: FilterQuality.high,
    );
  }
}

class _TabPill extends StatelessWidget {
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _TabPill({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      maxLines: 1,
      style: YumoriText.ui(
        size: 14,
        weight: selected ? FontWeight.w700 : FontWeight.w500,
        color: selected
            ? color
            : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
      ),
    );
    final pill = AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        color: selected ? color.withValues(alpha: 0.14) : Colors.transparent,
      ),
      child: text,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: selected
            ? YumoriOrbit(
                radius: 30,
                outline: color.withValues(alpha: 0.35),
                tail: color,
                child: pill,
              )
            : pill,
      ),
    );
  }
}
