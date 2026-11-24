import 'dart:async';
import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/constants/contants.dart' show colorList;
import 'package:anymex/database/data_keys/keys.dart';
import 'package:anymex/plus/tvui/tv_data.dart';
import 'package:anymex/plus/tvui/tv_shell.dart' show PlusTvUi;
import 'package:anymex/theme/yumori_tokens.dart';
import 'package:anymex/widgets/common/cards/yumori_continue_card.dart' show YumoriProgressLine;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// AnymeX+ TV: colours and sizes (OLED black, no blur or shadows).
class TvStyle {
  // Yumori (Moonlit): night purple instead of OLED black.
  static const bg = YumoriColors.background;
  static const panel = YumoriColors.surface;
  static const chip = YumoriColors.card;
  static const button = YumoriColors.card;
  static const line = Color(0x29FFFFFF); // outlines on buttons and chips
  static const dim = Color(0xFF9C95B0);
  static const text2 = Color(0xFFC9C3D8);
  static const railW = 112.0;
  static const railOpenW = 360.0;
  static const pad = 72.0;

  static Color accent(BuildContext c) => vivid(c);

  /// Your accent colour at full strength. The dark theme's "primary" is a
  /// pale tint of it, which almost vanished next to white on the TV, so
  /// the TV uses the colour you picked, kept bright and saturated.
  /// Settings → Appearance → Palette: 'yumori' (lavender, the default) or
  /// 'default' (your accent colour from the app's theme).
  static final palette = ValueNotifier<String>(_loadPalette());
  static const _kPalette = 'plus_tv_palette';
  static String _loadPalette() {
    try {
      return KvHelper.get<String>(_kPalette, defaultVal: 'yumori');
    } catch (_) {
      return 'yumori';
    }
  }

  static void setPalette(String p) {
    palette.value = p;
    try {
      KvHelper.set(_kPalette, p);
    } catch (_) {}
  }

  static bool get yumori => palette.value == 'yumori';

  // Yumori colours (the app's tokens; cream stays the ring's second glint).
  static const yLavender = YumoriColors.lavender;
  static const yCream = Color(0xFFFDE4CA);

  /// Text on a lavender (or other light accent) fill.
  static const onAccent = YumoriColors.onLavender;

  static Color vivid(BuildContext c) {
    var seed = Theme.of(c).colorScheme.primary;
    if (yumori) return yLavender;
    try {
      final mode = ThemeKeys.themeMode.get<String>('default');
      if (mode == 'default') {
        seed = Colors.indigo;
      } else if (mode == 'custom') {
        final i = ThemeKeys.customColorIndex.get<int>(0);
        if (i == -1) {
          final hex = ThemeKeys.customHexColor.get<String>('#FFFFFF');
          seed = Color(int.parse(hex.replaceFirst('#', '0xff')));
        } else if (i >= 0 && i < colorList.length) {
          seed = colorList[i];
        }
      }
    } catch (_) {}
    return strong(seed);
  }

  /// [c] made bright and saturated enough to stand out on black and white.
  static Color strong(Color c) {
    final h = HSLColor.fromColor(c);
    if (h.saturation < 0.08) return c; // a grey / white pick stays as it is
    return h.withSaturation(h.saturation < 0.75 ? 0.85 : h.saturation).withLightness(h.lightness.clamp(0.5, 0.62)).toColor();
  }

  static const placeholders = [
    Color(0xFF221A36), Color(0xFF1C1830), Color(0xFF261C33), Color(0xFF1E1A2E),
    Color(0xFF241D38), Color(0xFF1B152A), Color(0xFF221B31), Color(0xFF1F1830),
  ];
  static Color placeholder(String key) => placeholders[key.hashCode.abs() % placeholders.length];
}

bool tvIsSelect(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.enter ||
    k == LogicalKeyboardKey.select ||
    k == LogicalKeyboardKey.numpadEnter ||
    k == LogicalKeyboardKey.gameButtonA ||
    k == LogicalKeyboardKey.space;

bool tvIsBack(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.goBack ||
    k == LogicalKeyboardKey.browserBack ||
    k == LogicalKeyboardKey.escape;

/// Moving left at the edge of the screen. LG doesn't hand the remote's Back
/// button to Flutter apps yet (the TV shows its own "exit app?" instead;
/// LG plans to change this), so Left at the left edge does Back's job:
/// it closes a page opened on top, or opens the menu.
class TvNav {
  static VoidCallback? openMenu;

  static bool edgeLeft(BuildContext context) {
    final route = ModalRoute.of(context);
    if (route != null && !route.isFirst) {
      Navigator.of(context).maybePop();
      return true;
    }
    if (openMenu != null) {
      openMenu!();
      return true;
    }
    return false;
  }

  /// Left from [node]: the nearest item to the left on the same line, else
  /// the edge (see [edgeLeft]). Flutter's own move would jump to another
  /// line when nothing is left of the highlight on this one.
  static void left(FocusNode node, FocusScopeNode scope) {
    final ctx = node.context;
    if (ctx == null) return;
    final here = node.rect;
    FocusNode? best;
    var bestGap = double.infinity;
    for (final n in scope.traversalDescendants) {
      if (n == node || !n.canRequestFocus || n.context == null) continue;
      final r = n.rect;
      if (r.right > here.left + 1) continue;
      final overlap = (r.bottom < here.bottom ? r.bottom : here.bottom) - (r.top > here.top ? r.top : here.top);
      if (overlap < 12) continue;
      final gap = here.left - r.right;
      if (gap < bestGap) {
        bestGap = gap;
        best = n;
      }
    }
    if (best != null) {
      best.requestFocus();
    } else {
      edgeLeft(ctx);
    }
  }
}

/// The Magic Remote's pointer only moves the highlight when it is really
/// being used: not right after arrow presses (the remote shakes a little in
/// the hand, which used to drag the highlight onto random cards).
class TvPointer {
  static DateTime _lastKey = DateTime(2000);
  static double _travel = 0;

  static void keyPressed() {
    _lastKey = DateTime.now();
    _travel = 0;
  }

  static bool mayTakeFocus(Offset delta) {
    if (DateTime.now().difference(_lastKey) < const Duration(milliseconds: 1500)) return false;
    _travel += delta.distance;
    return _travel > 12;
  }
}

/// Anything that can be highlighted with the remote: OK (or a click with the
/// Magic Remote) runs [onSelect]. Moving the highlight with the arrows
/// scrolls it into view; pointing at it with the Magic Remote doesn't.
class TvFocusable extends StatefulWidget {
  final Widget Function(BuildContext context, bool focused) builder;
  final VoidCallback? onSelect;

  /// Holding OK (about half a second). With it, a short press selects when
  /// OK is let go instead of when it goes down.
  final VoidCallback? onHold;
  final ValueChanged<bool>? onFocus;
  final bool autofocus;
  final FocusNode? focusNode;
  final double alignment;

  /// Scroll into view when highlighted (rows scroll their cards themselves).
  final bool autoScroll;

  const TvFocusable({
    super.key,
    required this.builder,
    this.onSelect,
    this.onHold,
    this.onFocus,
    this.autofocus = false,
    this.focusNode,
    this.alignment = 0.12,
    this.autoScroll = true,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  late FocusNode _node = widget.focusNode ?? FocusNode();
  bool _focused = false;
  bool _byPointer = false;
  Timer? _holdTimer;
  bool _down = false; // OK went down here (a hold can fire)
  bool _held = false;

  @override
  void didUpdateWidget(covariant TvFocusable old) {
    super.didUpdateWidget(old);
    if (widget.focusNode != null && widget.focusNode != _node) {
      if (old.focusNode == null) _node.dispose();
      _node = widget.focusNode!;
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    if (widget.focusNode == null) _node.dispose();
    super.dispose();
  }

  void _changed(bool f) {
    if (!mounted) return;
    if (!f) {
      _holdTimer?.cancel();
      _down = false;
    }
    setState(() => _focused = f);
    widget.onFocus?.call(f);
    if (f && !_byPointer && widget.autoScroll) {
      Scrollable.ensureVisible(context,
          alignment: widget.alignment,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit);
    }
    _byPointer = false;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onFocusChange: _changed,
      onKeyEvent: (node, e) {
        if (!tvIsSelect(e.logicalKey)) return KeyEventResult.ignored;
        if (widget.onHold == null) {
          if (e is KeyDownEvent && widget.onSelect != null) {
            widget.onSelect!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }
        if (e is KeyDownEvent) {
          _down = true;
          _held = false;
          _holdTimer?.cancel();
          _holdTimer = Timer(const Duration(milliseconds: 550), () {
            if (!mounted || !_down) return;
            _held = true;
            widget.onHold!();
          });
        } else if (e is KeyUpEvent) {
          _holdTimer?.cancel();
          if (_down && !_held) widget.onSelect?.call();
          _down = false;
        }
        return KeyEventResult.handled;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        // Only a real pointer move takes the highlight: a layout change
        // (the menu opening under a resting pointer) doesn't.
        onHover: (e) {
          if (_node.hasFocus || !TvPointer.mayTakeFocus(e.delta)) return;
          _byPointer = true;
          _node.requestFocus();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _byPointer = true;
            _node.requestFocus();
            widget.onSelect?.call();
          },
          onLongPress: widget.onHold == null
              ? null
              : () {
                  _byPointer = true;
                  _node.requestFocus();
                  widget.onHold!();
                },
          child: widget.builder(context, _focused),
        ),
      ),
    );
  }
}

/// A picture from the web, decoded at the size it's shown (keeps the TV fast).
class TvImage extends StatelessWidget {
  final String url;
  final double width;
  final double height;
  final String seed;
  final BoxFit fit;
  const TvImage({super.key, required this.url, required this.width, required this.height, this.seed = '', this.fit = BoxFit.cover});

  static const empty = Color(0xFF17121F);

  /// The picture as [TvImage] loads it (same size, so a warmed one is
  /// already in memory when the card shows).
  static ImageProvider provider(String url, double width, double dpr) =>
      ResizeImage(NetworkImage(url), width: (width * dpr).round().clamp(1, 1920));

  /// Loads pictures ahead (start-up waits for the first screen's).
  static Future<void> warm(BuildContext context, Iterable<(String, double)> pics, {Duration limit = const Duration(seconds: 4)}) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final jobs = [
      for (final (url, w) in pics)
        if (url.startsWith('http')) precacheImage(provider(url, w, dpr), context, onError: (_, __) {}),
    ];
    return Future.wait(jobs).timeout(limit, onTimeout: () => const []);
  }

  @override
  Widget build(BuildContext context) {
    final box = Container(width: width, height: height, color: empty);
    if (url.isEmpty || !url.startsWith('http')) return box;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Image(
      image: provider(url, width, dpr),
      width: width,
      height: height,
      fit: fit,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) => box,
      // Already loaded: shown at once. Otherwise a short fade from the
      // plain dark box (no more coloured blocks while loading).
      frameBuilder: (_, child, frame, sync) {
        if (sync) return child;
        return Stack(fit: StackFit.passthrough, children: [
          box,
          AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 220), curve: Curves.easeOut, child: child),
        ]);
      },
    );
  }
}

/// A poster card (2:3), or a wide card (16:9) for Continue Watching.
class TvCard extends StatelessWidget {
  final TvItem item;
  final bool wide;
  final bool showKind;
  final VoidCallback onSelect;
  final ValueChanged<TvItem>? onFocusItem;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool autoScroll;

  /// Home: small cards with no title under them (the banner shows it).
  final bool compact;

  const TvCard({
    super.key,
    required this.item,
    required this.onSelect,
    this.wide = false,
    this.showKind = false,
    this.onFocusItem,
    this.autofocus = false,
    this.focusNode,
    this.autoScroll = true,
    this.compact = false,
  });

  static const posterW = 168.0, posterH = 252.0, wideW = 320.0, wideH = 180.0;
  // Home's short rows (compact).
  static const smallW = 132.0, smallH = 186.0, smallWideW = 248.0, smallWideH = 140.0;

  static double widthFor({required bool wide, required bool compact}) =>
      compact ? (wide ? smallWideW : smallW) : (wide ? wideW : posterW);
  static double heightFor({required bool wide, required bool compact}) =>
      compact ? (wide ? smallWideH : smallH) : (wide ? wideH : posterH);

  @override
  Widget build(BuildContext context) {
    final w = widthFor(wide: wide, compact: compact);
    final h = heightFor(wide: wide, compact: compact);
    return TvFocusable(
      autofocus: autofocus,
      focusNode: focusNode,
      autoScroll: autoScroll,
      onSelect: onSelect,
      onFocus: (f) {
        if (f) onFocusItem?.call(item);
      },
      builder: (context, focused) => RepaintBoundary(
        child: AnimatedScale(
          scale: focused ? (compact ? 1.08 : 1.06) : 1.0,
          duration: const Duration(milliseconds: 120),
          alignment: compact ? Alignment.center : Alignment.topCenter,
          child: SizedBox(
            width: w,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                TvRing(
                  on: focused,
                  radius: wide ? 16 : 14,
                  gap: 1,
                  child: Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(wide ? 16 : 14),
                    border: Border.all(color: Colors.transparent, width: 4),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(wide ? 12 : 10),
                    child: Stack(children: [
                      TvImage(url: wide && item.backdrop.isNotEmpty ? item.backdrop : item.poster, width: w, height: h, seed: item.key),
                      if (showKind)
                        Positioned(
                          left: 8,
                          top: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(color: TvStyle.bg.withValues(alpha: 0.78), borderRadius: BorderRadius.circular(999)),
                            child: Text(item.kindLabel, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: YumoriColors.lavender)),
                          ),
                        ),
                      if (item.progress > 0) ...[
                        // Yumori: a soft shade under the line, then the
                        // lavender line with a firefly at its tip.
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: 40,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.transparent, TvStyle.bg.withValues(alpha: 0.7)],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 10,
                          right: 10,
                          bottom: 10,
                          child: YumoriProgressLine(progress: item.progress.clamp(0.0, 1.0)),
                        ),
                      ],
                    ]),
                  ),
                ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 10),
                  Text(item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: wide ? 21 : 19, fontWeight: FontWeight.w600, color: focused ? YumoriColors.text : TvStyle.text2)),
                  if (item.sub.isNotEmpty)
                    Text(item.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, color: TvStyle.dim)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row: title and a line of cards. Left / Right move along the row and
/// wrap from the last card to the first (Netflix style); Left on the first
/// card goes on to the menu. Up / Down call [onUp] / [onDown] (the page
/// moves to the next row at the card that row last had), else the usual
/// move.
class TvRow extends StatefulWidget {
  final String title;
  final List<TvItem> items;
  final bool wide;
  final bool showKind;
  final void Function(TvItem) onOpen;
  final ValueChanged<TvItem>? onFocusItem;
  final bool autofocusFirst;
  final bool Function()? onUp;
  final bool Function()? onDown;

  /// Home's short rows: small cards, no titles, a slider under the row.
  final bool compact;

  const TvRow({
    super.key,
    required this.title,
    required this.items,
    required this.onOpen,
    this.wide = false,
    this.showKind = false,
    this.onFocusItem,
    this.autofocusFirst = false,
    this.onUp,
    this.onDown,
    this.compact = false,
  });

  @override
  State<TvRow> createState() => TvRowState();
}

class TvRowState extends State<TvRow> {
  final _nodes = <FocusNode>[];
  final _scroll = ScrollController();
  int _index = 0;

  double get _step => TvCard.widthFor(wide: widget.wide, compact: widget.compact) + _gap;
  double get _gap => widget.compact ? 18 : 24;

  /// Compact rows: where you are in the row (the slider under it).
  final _at = ValueNotifier<int>(0);
  final _hasFocus = ValueNotifier<bool>(false);

  /// Highlights card [i]; a card scrolled far out of view isn't built, so the
  /// row jumps there first.
  void _go(int i) {
    _index = i;
    final node = _nodes[i];
    if (node.context != null) {
      node.requestFocus();
      return;
    }
    if (_scroll.hasClients) {
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo((i * _step - 40).clamp(0.0, max).toDouble());
    }
    _later(i, 10);
  }

  /// The highlighted card sits at the left edge (Netflix style), and the
  /// page scrolls so the whole row is in view.
  void _reveal(int i) {
    if (_scroll.hasClients) {
      final max = _scroll.position.maxScrollExtent;
      final target = (i * _step).clamp(0.0, max).toDouble();
      if ((target - _scroll.offset).abs() > 1) {
        _scroll.animateTo(target, duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
      }
    }
    Scrollable.ensureVisible(context, alignment: 0.02, duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
  }

  // The card is built a frame after the jump; try a few frames.
  void _later(int i, int tries) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || i >= _nodes.length || _index != i) return;
      if (_nodes[i].context != null) {
        _nodes[i].requestFocus();
      } else if (tries > 0) {
        _later(i, tries - 1);
        WidgetsBinding.instance.scheduleFrame();
      }
    });
  }

  bool get isEmpty => widget.items.isEmpty;

  void _sync() {
    while (_nodes.length < widget.items.length) {
      _nodes.add(FocusNode());
    }
    while (_nodes.length > widget.items.length) {
      _nodes.removeLast().dispose();
    }
    if (_index >= widget.items.length) _index = 0;
  }

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    _scroll.dispose();
    _at.dispose();
    _hasFocus.dispose();
    super.dispose();
  }

  /// Puts the highlight on the card this row had last (the first at first).
  bool focus() {
    if (widget.items.isEmpty) return false;
    _sync();
    _go(_index.clamp(0, _nodes.length - 1).toInt());
    return true;
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final n = widget.items.length;
    if (n == 0) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight) {
      _go((_index + 1) % n);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (_index == 0) return TvNav.edgeLeft(context) ? KeyEventResult.handled : KeyEventResult.ignored;
      _go(_index - 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown && widget.onDown != null) {
      return widget.onDown!() ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.arrowUp && widget.onUp != null) {
      return widget.onUp!() ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    final items = widget.items;
    if (items.isEmpty) return const SizedBox.shrink();
    final wide = widget.wide;
    final compact = widget.compact;
    final h = TvCard.heightFor(wide: wide, compact: compact) + (compact ? 22 : 78);
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 14 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(left: TvStyle.pad, bottom: compact ? 6 : 14),
            child: Text(widget.title,
                style: TextStyle(fontSize: compact ? 23 : 28, fontWeight: FontWeight.w700, color: YumoriColors.text)),
          ),
          SizedBox(
            height: h,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: (f) => _hasFocus.value = f,
              onKeyEvent: _key,
              child: ListView.separated(
                controller: _scroll,
                cacheExtent: 1600,
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                padding: EdgeInsets.symmetric(horizontal: TvStyle.pad, vertical: compact ? 11 : 6),
                itemCount: items.length,
                separatorBuilder: (_, __) => SizedBox(width: _gap),
                itemBuilder: (context, i) => TvKeepFocused(
                  node: _nodes[i],
                  child: TvCard(
                    item: items[i],
                    wide: wide,
                    compact: compact,
                    showKind: widget.showKind,
                    focusNode: _nodes[i],
                    autoScroll: false,
                    autofocus: widget.autofocusFirst && i == 0,
                    onSelect: () => widget.onOpen(items[i]),
                    onFocusItem: (it) {
                      _index = i;
                      _at.value = i;
                      _reveal(i);
                      widget.onFocusItem?.call(it);
                    },
                  ),
                ),
              ),
            ),
          ),
          if (compact) _slider(items.length),
        ],
      ),
    );
  }

  /// A short track under the row with your place in it (shown while the
  /// row has the highlight).
  Widget _slider(int count) {
    const trackW = 110.0;
    return Padding(
      padding: const EdgeInsets.only(left: TvStyle.pad, top: 2),
      child: ValueListenableBuilder<bool>(
        valueListenable: _hasFocus,
        builder: (context, on, _) => AnimatedOpacity(
          opacity: on && count > 1 ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: ValueListenableBuilder<int>(
            valueListenable: _at,
            builder: (context, at, _) {
              final seg = (trackW / count).clamp(18.0, trackW);
              final x = count <= 1 ? 0.0 : (trackW - seg) * (at / (count - 1));
              return SizedBox(
                width: trackW,
                height: 4,
                child: Stack(children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 140),
                    left: x,
                    top: 0,
                    bottom: 0,
                    width: seg,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: TvStyle.accent(context), borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Keeps a card alive while it has the highlight, even when its row scrolls
/// it out of view (a card that disappears takes the highlight with it).
class TvKeepFocused extends StatefulWidget {
  final FocusNode node;
  final Widget child;
  const TvKeepFocused({super.key, required this.node, required this.child});

  @override
  State<TvKeepFocused> createState() => _TvKeepFocusedState();
}

class _TvKeepFocusedState extends State<TvKeepFocused> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.node.hasFocus;

  void _changed() {
    if (mounted) updateKeepAlive();
  }

  @override
  void initState() {
    super.initState();
    widget.node.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant TvKeepFocused old) {
    super.didUpdateWidget(old);
    if (old.node != widget.node) {
      old.node.removeListener(_changed);
      widget.node.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.node.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// A button: white when highlighted.
class TvButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onSelect;
  final bool primary;
  final bool autofocus;
  final FocusNode? focusNode;
  const TvButton({super.key, required this.label, required this.onSelect, this.icon, this.primary = false, this.autofocus = false, this.focusNode});

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onSelect: onSelect,
      alignment: 0.5,
      builder: (context, f) => AnimatedScale(
        scale: f ? 1.05 : 1,
        duration: const Duration(milliseconds: 120),
        child: TvRing(
          on: f,
          radius: 32,
          gap: 4,
          width: 3,
          child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 30),
          // Yumori: lavender pill for the main action and the highlight,
          // an outlined pill otherwise.
          decoration: BoxDecoration(
            color: f || primary ? TvStyle.accent(context) : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: f || primary ? Colors.transparent : TvStyle.line, width: 1.5),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 26, color: f || primary ? TvStyle.onAccent : YumoriColors.text), const SizedBox(width: 12)],
            Text(label,
                style: TextStyle(fontSize: 22, fontWeight: primary ? FontWeight.w700 : FontWeight.w600, color: f || primary ? TvStyle.onAccent : YumoriColors.text)),
          ]),
        ),
        ),
      ),
    );
  }
}

/// A round-ended chip (filters, seasons): white when on or highlighted.
class TvChip extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback onSelect;
  final bool autofocus;
  const TvChip({super.key, required this.label, required this.on, required this.onSelect, this.autofocus = false});

  @override
  Widget build(BuildContext context) {
    final accent = TvStyle.accent(context);
    return TvFocusable(
      autofocus: autofocus,
      onSelect: onSelect,
      alignment: 0.5,
      builder: (context, f) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        decoration: BoxDecoration(
          color: f || on ? accent : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: f ? Colors.white : (on ? Colors.transparent : TvStyle.line), width: f ? 3 : 1.5),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: f || on ? TvStyle.onAccent : TvStyle.text2)),
      ),
    );
  }
}

/// A short message at the bottom of the screen.
void tvToast(BuildContext context, String text) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(text, style: const TextStyle(fontSize: 20, color: Colors.white)),
    backgroundColor: YumoriColors.card,
    behavior: SnackBarBehavior.floating,
    width: 900,
    duration: const Duration(seconds: 3),
  ));
}

/// A screen opened on top (details, a category): Back closes it.
class TvPage extends StatelessWidget {
  final Widget child;
  const TvPage({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, e) {
        if (e is KeyDownEvent && tvIsBack(e.logicalKey)) {
          Navigator.of(context).maybePop();
          return KeyEventResult.handled;
        }
        if ((e is KeyDownEvent || e is KeyRepeatEvent) && e.logicalKey == LogicalKeyboardKey.arrowLeft) {
          final f = FocusManager.instance.primaryFocus;
          final scope = f?.nearestScope;
          if (f != null && scope != null && f.context?.findAncestorWidgetOfExactType<EditableText>() == null) {
            TvNav.left(f, scope);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(backgroundColor: TvStyle.bg, body: child),
    );
  }
}

Route<T> tvRoute<T>(Widget page) => PageRouteBuilder<T>(
      pageBuilder: (ctx, __, ___) => Theme(data: PlusTvUi.theme(ctx), child: TvPage(child: page)),
      transitionDuration: const Duration(milliseconds: 150),
      reverseTransitionDuration: const Duration(milliseconds: 120),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    );

/// The highlight around the focused box: a white ring a few pixels out from
/// the box, with a glint in your accent colour that keeps travelling round
/// it (like the Switch 2's). Off in Settings → Appearance it's a still ring.
///
/// Drawn as a foreground paint outside the child's own size, so the layout
/// doesn't move when focus does. Only the focused box animates.
class TvRing extends StatefulWidget {
  final bool on;
  final double radius; // the box's corner radius
  final Widget child;
  final double gap;
  final double width;
  const TvRing({super.key, required this.on, required this.radius, required this.child, this.gap = 5, this.width = 4});

  /// Settings → Appearance → Moving highlight (default on).
  static final animated = ValueNotifier<bool>(_load());
  static const _kAnimated = 'plus_tv_ring_moving';
  static bool _load() {
    try {
      return KvHelper.get<bool>(_kAnimated, defaultVal: true);
    } catch (_) {
      return true;
    }
  }

  /// Settings → Appearance → Glint speed: seconds for one lap (default 6,
  /// like the Switch 2's unhurried glints).
  static final lap = ValueNotifier<double>(_loadLap());
  static const _kLap = 'plus_tv_ring_lap';
  static const lapMin = 2.0, lapMax = 14.0, lapDefault = 6.0;
  static double _loadLap() {
    try {
      return KvHelper.get<double>(_kLap, defaultVal: lapDefault).clamp(lapMin, lapMax).toDouble();
    } catch (_) {
      return lapDefault;
    }
  }

  static void setLap(double s) {
    lap.value = s.clamp(lapMin, lapMax).toDouble();
    try {
      KvHelper.set(_kLap, lap.value);
    } catch (_) {}
  }

  static Duration get lapDuration => Duration(milliseconds: (lap.value * 1000).round());

  /// Settings → Appearance → Second colour: -1 = auto (a hue next to the
  /// accent), else an index into AnymeX's colours.
  static final second = ValueNotifier<int>(_loadSecond());
  static const _kSecond = 'plus_tv_ring_second';
  static int _loadSecond() {
    try {
      return KvHelper.get<int>(_kSecond, defaultVal: -1);
    } catch (_) {
      return -1;
    }
  }

  static void setSecond(int i) {
    second.value = i;
    try {
      KvHelper.set(_kSecond, i);
    } catch (_) {}
  }

  /// The glint's second colour for [accent].
  static Color secondFor(Color accent) {
    final i = second.value;
    if (i >= 0 && i < colorList.length) return TvStyle.strong(colorList[i]);
    if (TvStyle.yumori) return TvStyle.yCream;
    final h = HSLColor.fromColor(accent);
    return h.withHue((h.hue + 40) % 360).toColor();
  }

  static set moving(bool on) {
    animated.value = on;
    try {
      KvHelper.set(_kAnimated, on);
    } catch (_) {}
  }

  @override
  State<TvRing> createState() => _TvRingState();
}

class _TvRingState extends State<TvRing> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: TvRing.lapDuration);

  @override
  void initState() {
    super.initState();
    TvRing.animated.addListener(_sync);
    TvRing.second.addListener(_sync);
    TvRing.lap.addListener(_lapChanged);
    _sync();
  }

  @override
  void didUpdateWidget(TvRing old) {
    super.didUpdateWidget(old);
    if (old.on != widget.on) _sync();
  }

  void _lapChanged() {
    _spin.duration = TvRing.lapDuration;
    if (_spin.isAnimating) _spin.repeat(); // keep going at the new speed
  }

  void _sync() {
    if (widget.on && TvRing.animated.value) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    TvRing.animated.removeListener(_sync);
    TvRing.second.removeListener(_sync);
    TvRing.lap.removeListener(_lapChanged);
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.on) return widget.child;
    return CustomPaint(
      foregroundPainter: _RingPainter(
        spin: _spin,
        accent: TvStyle.vivid(context),
        radius: widget.radius,
        gap: widget.gap,
        width: widget.width,
        moving: TvRing.animated.value,
        second: TvRing.second.value,
      ),
      child: widget.child,
    );
  }
}

class _RingPainter extends CustomPainter {
  final Animation<double> spin;
  final Color accent;
  final double radius, gap, width;
  final bool moving;
  final int second; // only to repaint when it changes
  _RingPainter({required this.spin, required this.accent, required this.radius, required this.gap, required this.width, required this.moving, required this.second})
      : super(repaint: spin);

  /// The accent with its hue turned by [deg] (each glint's second colour).
  static Color _turn(Color c, double deg) {
    final h = HSLColor.fromColor(c);
    return h.withHue((h.hue + deg) % 360).toColor();
  }

  /// One glint: a short arc of solid colour (it replaces the white where
  /// it passes, so it never blends into it), fading in and out.
  static Shader _glint(Rect r, Color a, Color b, double turn) => SweepGradient(
        colors: [a.withValues(alpha: 0), a, b, b.withValues(alpha: 0), b.withValues(alpha: 0)],
        stops: const [0.0, 0.07, 0.16, 0.24, 1.0],
        transform: GradientRotation(turn),
      ).createShader(r);

  @override
  void paint(Canvas canvas, Size size) {
    final r = (Offset.zero & size).inflate(gap + width / 2);
    final rr = RRect.fromRectAndRadius(r, Radius.circular(radius + gap + width / 2));
    // The white ring.
    canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = Colors.white);
    if (!moving) return;
    // Two glints (like the Switch 2): accent → your second colour, solid
    // over the white, with a glow.
    const full = 6.283185307;
    final t = spin.value * full;
    final area = r.inflate(width * 3);
    final second = TvRing.secondFor(accent);
    // Two glints on opposite sides, going round the same way.
    for (final shader in [
      _glint(area, accent, second, t),
      _glint(area, accent, second, t + full / 2),
    ]) {
      canvas.drawRRect(
          rr.inflate(width * 0.4),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = width * 2.6
            ..shader = shader
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      canvas.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = width + 0.5
            ..shader = shader);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.accent != accent || old.radius != radius || old.moving != moving || old.gap != gap || old.width != width || old.second != second;
}
