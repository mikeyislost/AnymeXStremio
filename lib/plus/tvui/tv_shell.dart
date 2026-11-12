import 'dart:async';
import 'dart:io';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/plus/tvui/tv_categories.dart';
import 'package:anymex/plus/tvui/tv_home.dart';
import 'package:anymex/plus/tvui/tv_library.dart';
import 'package:anymex/plus/tvui/tv_search.dart';
import 'package:anymex/plus/tvui/tv_settings.dart';
import 'package:anymex/plus/tvui/tv_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// AnymeX+ on the TV: the TV layout (left tab rail, OLED black, remote
/// first). Built on the same app underneath; only the screens differ.
class PlusTvUi {
  PlusTvUi._();
  static const _kLayout = 'plus_tv_layout';

  /// The TV layout is on unless the Windows layout was picked in Settings.
  static bool get enabled {
    try {
      return KvHelper.get<String>(_kLayout, defaultVal: 'tv') != 'desktop';
    } catch (_) {
      return true;
    }
  }

  static set enabled(bool on) {
    try {
      KvHelper.set(_kLayout, on ? 'tv' : 'desktop');
    } catch (_) {}
  }

  /// The last remote keys, for Settings → About this TV. Kept across
  /// restarts, so a key that closes the app still shows next time.
  static final keyLog = ValueNotifier<List<String>>(_loadLog());
  static const _kLog = 'plus_tv_keylog';

  static List<String> _loadLog() {
    try {
      final raw = KvHelper.get<List<String>>(_kLog, defaultVal: const []);
      return List<String>.from(raw);
    } catch (_) {
      return const [];
    }
  }

  static void logKey(String k) {
    final t = DateTime.now();
    final stamp = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    final l = ['$stamp  $k', ...keyLog.value];
    keyLog.value = l.take(12).toList();
    try {
      KvHelper.set(_kLog, keyLog.value);
    } catch (_) {}
  }

  static ThemeData theme(BuildContext context) {
    final base = Theme.of(context);
    final accent = base.colorScheme.primary;
    return base.copyWith(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: TvStyle.bg,
      canvasColor: TvStyle.bg,
      colorScheme: base.colorScheme.copyWith(
        brightness: Brightness.dark,
        surface: TvStyle.bg,
        onSurface: Colors.white,
        primary: accent,
      ),
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      splashFactory: NoSplash.splashFactory,
      textTheme: base.textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
    );
  }
}

class PlusTvShell extends StatefulWidget {
  const PlusTvShell({super.key});

  @override
  State<PlusTvShell> createState() => _PlusTvShellState();
}

class _Tab {
  final String label;
  final IconData icon;
  const _Tab(this.label, this.icon);
}

class _PlusTvShellState extends State<PlusTvShell> {
  static const _tabs = [
    _Tab('Home', Icons.home_rounded),
    _Tab('Categories', Icons.grid_view_rounded),
    _Tab('Library', Icons.video_library_rounded),
    _Tab('Search', Icons.search_rounded),
    _Tab('Settings', Icons.settings_rounded),
  ];

  int _tab = 0;
  bool _railOpen = false;
  final _railNodes = List.generate(_tabs.length, (_) => FocusNode());
  final _railScope = FocusScopeNode(debugLabel: 'tv rail');
  final _contentScope = FocusScopeNode(debugLabel: 'tv content');

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_logKey);
    FocusManager.instance.addListener(_watchFocus);
    TvNav.openMenu = _toRail;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_logKey);
    FocusManager.instance.removeListener(_watchFocus);
    for (final n in _railNodes) {
      n.dispose();
    }
    _railScope.dispose();
    _contentScope.dispose();
    super.dispose();
  }

  bool _logKey(KeyEvent e) {
    if (e is KeyDownEvent || e is KeyRepeatEvent) TvPointer.keyPressed();
    if (e is KeyDownEvent) {
      final k = e.logicalKey;
      PlusTvUi.logKey('key ${k.keyLabel.isEmpty ? k.debugName : k.keyLabel} (0x${k.keyId.toRadixString(16)}, '
          'usb 0x${e.physicalKey.usbHidUsage.toRadixString(16)})');
    }
    return false;
  }

  /// Safety net: if the highlight ever ends up on nothing (a card vanished,
  /// a text box closed), put it back on the page.
  void _watchFocus() {
    final f = FocusManager.instance.primaryFocus;
    if (f == null || f is! FocusScopeNode) return;
    if (f != _contentScope && f != _railScope) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final now = FocusManager.instance.primaryFocus;
      if (!mounted || now != f) return;
      if (f == _railScope) {
        _toRail();
      } else {
        _contentScope.nextFocus();
      }
    });
  }

  /// OK on a menu item: open that tab and go into it.
  void _openTab(int i) {
    if (_tab != i) setState(() => _tab = i);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The new page's first item takes the highlight by itself; if it has
      // none, go to the page's first item.
      if (mounted && _railScope.hasFocus) _toContent();
    });
  }

  void _toRail() => _railNodes[_tab].requestFocus();

  void _toContent() {
    final had = _contentScope.focusedChild != null;
    _contentScope.requestFocus();
    if (!had) _contentScope.nextFocus();
  }

  int get _railIndex {
    for (var i = 0; i < _railNodes.length; i++) {
      if (_railNodes[i].hasFocus) return i;
    }
    return _tab;
  }

  /// The menu moves by itself: Up / Down along it, Right back into the page.
  KeyEventResult _railKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final i = _railIndex;
    if (k == LogicalKeyboardKey.arrowUp) {
      if (i > 0) _railNodes[i - 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (i < _railNodes.length - 1) _railNodes[i + 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _toContent();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  /// Back: from a page → the menu; from the menu → Home; on Home → leave.
  DateTime _lastBack = DateTime(2000);

  void _back() {
    // The TV can send Back twice (a key and the system's "go back"): one
    // press is one step.
    final now = DateTime.now();
    if (now.difference(_lastBack) < const Duration(milliseconds: 400)) {
      PlusTvUi.logKey('back (second signal, ignored)');
      return;
    }
    _lastBack = now;
    PlusTvUi.logKey(_railScope.hasFocus ? 'back → ${_tab == 0 ? 'leave?' : 'Home'}' : 'back → menu');
    if (!_railScope.hasFocus) {
      _toRail();
      return;
    }
    if (_tab != 0) {
      setState(() => _tab = 0);
      _railNodes[0].requestFocus();
      return;
    }
    unawaited(_confirmExit());
  }

  Future<void> _confirmExit() async {
    final leave = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.8),
      builder: (ctx) => Theme(
        data: PlusTvUi.theme(ctx),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (n, e) {
            if (e is KeyDownEvent && tvIsBack(e.logicalKey)) {
              Navigator.of(ctx).pop(false);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Center(
            child: Material(
              color: TvStyle.panel,
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.all(48),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Leave AnymeX+?', style: TextStyle(fontSize: 36, fontWeight: FontWeight.w800, color: Colors.white)),
                  const SizedBox(height: 32),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    TvButton(label: 'Stay', autofocus: true, onSelect: () => Navigator.of(ctx).pop(false)),
                    const SizedBox(width: 16),
                    TvButton(label: 'Leave', onSelect: () => Navigator.of(ctx).pop(true)),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
    if (leave == true) {
      await SystemNavigator.pop();
      Future.delayed(const Duration(milliseconds: 400), () => exit(0));
    }
  }

  Widget _page() {
    switch (_tab) {
      case 1:
        return const TvCategoriesPage(key: ValueKey('categories'));
      case 2:
        return const TvLibraryPage(key: ValueKey('library'));
      case 3:
        return const TvSearchPage(key: ValueKey('search'));
      case 4:
        return const TvSettingsPage(key: ValueKey('settings'));
    }
    return const TvHomePage(key: ValueKey('home'));
  }

  @override
  Widget build(BuildContext context) {
    final accent = TvStyle.accent(context);
    return Theme(
      data: PlusTvUi.theme(context),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          PlusTvUi.logKey('system Back');
          _back();
        },
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (n, e) {
            if (e is KeyDownEvent && tvIsBack(e.logicalKey)) {
              _back();
              return KeyEventResult.handled;
            }
            // Left in a page: the next item to the left, or the menu when
            // there is none (rows handle Left themselves first).
            if ((e is KeyDownEvent || e is KeyRepeatEvent) && e.logicalKey == LogicalKeyboardKey.arrowLeft && _contentScope.hasFocus) {
              final f = FocusManager.instance.primaryFocus;
              final editor = f?.context?.findAncestorWidgetOfExactType<EditableText>();
              if (editor != null) {
                // In a text box Left moves the cursor; at the start it leaves.
                if (editor.controller.selection.baseOffset > 0) return KeyEventResult.ignored;
                _toRail();
                return KeyEventResult.handled;
              }
              if (f == null) {
                _toRail();
              } else {
                TvNav.left(f, _contentScope);
              }
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Scaffold(
            backgroundColor: TvStyle.bg,
            body: Stack(children: [
              Positioned.fill(
                left: TvStyle.railW,
                child: FocusScope(node: _contentScope, child: FocusTraversalGroup(child: _page())),
              ),
              if (_railOpen)
                Positioned.fill(left: TvStyle.railW, child: IgnorePointer(child: Container(color: Colors.black.withValues(alpha: 0.6)))),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: FocusScope(
                  node: _railScope,
                  onFocusChange: (f) => setState(() => _railOpen = f),
                  onKeyEvent: _railKey,
                  child: FocusTraversalGroup(
                    child: MouseRegion(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        width: _railOpen ? TvStyle.railOpenW : TvStyle.railW,
                        decoration: const BoxDecoration(
                          color: TvStyle.bg,
                          border: Border(right: BorderSide(color: Color(0xFF161616))),
                        ),
                        padding: EdgeInsets.fromLTRB(_railOpen ? 24 : 24, 40, _railOpen ? 24 : 24, 48),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: EdgeInsets.only(left: _railOpen ? 18 : 8, bottom: 48),
                              child: Text.rich(
                                TextSpan(children: [
                                  TextSpan(text: _railOpen ? 'AnymeX' : 'A'),
                                  TextSpan(text: '+', style: TextStyle(color: accent)),
                                ]),
                                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white),
                                maxLines: 1,
                              ),
                            ),
                            for (var i = 0; i < _tabs.length - 1; i++) ...[_railItem(i), const SizedBox(height: 14)],
                            const Spacer(),
                            _railItem(_tabs.length - 1),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _railItem(int i) {
    final t = _tabs[i];
    final accent = TvStyle.accent(context);
    final current = i == _tab;
    return KeyedSubtree(
      child: TvFocusable(
        focusNode: _railNodes[i],
        onSelect: () => _openTab(i),
        builder: (context, f) {
          final fg = f ? Colors.black : (current ? accent : const Color(0xFF8A8A8A));
          return AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: _railOpen ? 72 : 64,
            width: _railOpen ? TvStyle.railOpenW - 48 : 64,
            padding: EdgeInsets.symmetric(horizontal: _railOpen ? 22 : 0),
            decoration: BoxDecoration(
              color: f ? Colors.white : (current ? accent.withValues(alpha: 0.18) : Colors.transparent),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              mainAxisAlignment: _railOpen ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                Icon(t.icon, size: 30, color: fg),
                if (_railOpen) ...[
                  const SizedBox(width: 22),
                  Flexible(
                    child: Text(t.label,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: f ? Colors.black : (current ? Colors.white : const Color(0xFF9A9A9A)))),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
