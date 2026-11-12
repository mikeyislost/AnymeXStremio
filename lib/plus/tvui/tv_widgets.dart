import 'package:anymex/plus/tvui/tv_data.dart';
import 'package:anymex/plus/tvui/tv_shell.dart' show PlusTvUi;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// AnymeX+ TV: colours and sizes (OLED black, no blur or shadows).
class TvStyle {
  static const bg = Color(0xFF000000);
  static const panel = Color(0xFF111111);
  static const chip = Color(0xFF1A1A1A);
  static const button = Color(0xFF1D1D1D);
  static const dim = Color(0xFF8D8D8D);
  static const text2 = Color(0xFFBDBDBD);
  static const railW = 112.0;
  static const railOpenW = 360.0;
  static const pad = 72.0;

  static Color accent(BuildContext c) => Theme.of(c).colorScheme.primary;

  static const placeholders = [
    Color(0xFF2A2140), Color(0xFF1D2B3A), Color(0xFF3A2228), Color(0xFF203628),
    Color(0xFF33301C), Color(0xFF2B2B2B), Color(0xFF24203A), Color(0xFF1E3236),
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
    if (widget.focusNode == null) _node.dispose();
    super.dispose();
  }

  void _changed(bool f) {
    if (!mounted) return;
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
        if (e is KeyDownEvent && tvIsSelect(e.logicalKey) && widget.onSelect != null) {
          widget.onSelect!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
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

  @override
  Widget build(BuildContext context) {
    final box = Container(width: width, height: height, color: TvStyle.placeholder(seed.isEmpty ? url : seed));
    if (url.isEmpty || !url.startsWith('http')) return box;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Image.network(
      url,
      width: width,
      height: height,
      fit: fit,
      cacheWidth: (width * dpr).round().clamp(1, 1920),
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) => box,
      frameBuilder: (_, child, frame, sync) => frame == null && !sync ? box : child,
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
  });

  static const posterW = 200.0, posterH = 300.0, wideW = 380.0, wideH = 214.0;

  @override
  Widget build(BuildContext context) {
    final w = wide ? wideW : posterW;
    final h = wide ? wideH : posterH;
    final accent = TvStyle.accent(context);
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
          scale: focused ? 1.06 : 1.0,
          duration: const Duration(milliseconds: 120),
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: w,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(wide ? 16 : 14),
                    border: Border.all(color: focused ? Colors.white : Colors.transparent, width: 4),
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
                            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(8)),
                            child: Text(item.kindLabel, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
                          ),
                        ),
                      if (item.progress > 0)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            height: 6,
                            color: const Color(0xFF333333),
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(widthFactor: item.progress, child: Container(color: accent)),
                          ),
                        ),
                    ]),
                  ),
                ),
                ...[
                  const SizedBox(height: 10),
                  Text(item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: wide ? 21 : 19, fontWeight: FontWeight.w600, color: focused ? Colors.white : const Color(0xFFBDBDBD))),
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
  });

  @override
  State<TvRow> createState() => TvRowState();
}

class TvRowState extends State<TvRow> {
  final _nodes = <FocusNode>[];
  final _scroll = ScrollController();
  int _index = 0;

  double get _step => (widget.wide ? TvCard.wideW : TvCard.posterW) + 24;

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
      if (_index == 0) return KeyEventResult.ignored; // on to the menu
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
    final h = (wide ? TvCard.wideH : TvCard.posterH) + 78;
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: TvStyle.pad, bottom: 14),
            child: Text(widget.title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
          SizedBox(
            height: h,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _key,
              child: ListView.separated(
                controller: _scroll,
                cacheExtent: 1600,
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                padding: const EdgeInsets.symmetric(horizontal: TvStyle.pad, vertical: 6),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 24),
                itemBuilder: (context, i) => TvKeepFocused(
                  node: _nodes[i],
                  child: TvCard(
                    item: items[i],
                    wide: wide,
                    showKind: widget.showKind,
                    focusNode: _nodes[i],
                    autoScroll: false,
                    autofocus: widget.autofocusFirst && i == 0,
                    onSelect: () => widget.onOpen(items[i]),
                    onFocusItem: (it) {
                      _index = i;
                      _reveal(i);
                      widget.onFocusItem?.call(it);
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
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
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 30),
          decoration: BoxDecoration(
            color: f || primary ? Colors.white : TvStyle.button,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: f && !primary ? Colors.white : Colors.transparent, width: 3),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 26, color: f || primary ? Colors.black : Colors.white), const SizedBox(width: 12)],
            Text(label,
                style: TextStyle(fontSize: 22, fontWeight: primary ? FontWeight.w700 : FontWeight.w600, color: f || primary ? Colors.black : Colors.white)),
          ]),
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
          color: f ? Colors.white : (on ? accent.withValues(alpha: 0.22) : TvStyle.chip),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: f ? Colors.black : (on ? accent : const Color(0xFFCFCFCF)))),
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
    backgroundColor: const Color(0xFF1D1D1D),
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
