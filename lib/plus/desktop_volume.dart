// AnymeX+: volume and brightness on PC (Windows, macOS, Linux).
//
// AnymeX only has the phone's swipe gestures (click and drag on PC), and
// brightness does nothing on a PC screen. Here:
// - "volume" and "brightness" buttons in the player's bottom bar (editable
//   in Settings → Player → Bottom controls); hovering one swells its box and
//   grows it upwards with a slider inside (click: mute / back to 100%);
// - mouse wheel over the video = volume, Shift + wheel = brightness;
// - Up / Down arrow keys = volume, M = mute;
// - brightness dims the picture (a dark layer over the video), remembered.

import 'dart:async';
import 'dart:io';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/plus/focus_watch.dart';
import 'package:anymex/screens/anime/watch/controller/player_controller.dart';
import 'package:anymex/screens/anime/watch/controls/widgets/control_button.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class PlusDesktopVolume {
  PlusDesktopVolume._();

  static bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static const _kBrightness = 'plus_desktop_brightness';
  static const step = 0.05;
  static const maxVolume = 2.0; // same top as AnymeX's swipe (200%)
  static const minBrightness = 0.2;

  static double _beforeMute = 1.0;

  static double clampVolume(double v) => double.parse(v.clamp(0.0, maxVolume).toStringAsFixed(2));
  static double clampBrightness(double v) =>
      double.parse(v.clamp(minBrightness, 1.0).toStringAsFixed(2));

  /// How dark the layer over the video is for [brightness] (1 = none).
  static double dimFor(double brightness) =>
      ((1.0 - clampBrightness(brightness)) * 0.9).clamp(0.0, 0.9).toDouble();

  static void changeVolume(PlayerController c, double by) =>
      c.setVolume(clampVolume(c.volume.value + by));

  static void toggleMute(PlayerController c) {
    if (c.volume.value > 0) {
      _beforeMute = c.volume.value;
      c.setVolume(0);
    } else {
      c.setVolume(_beforeMute > 0 ? _beforeMute : 1.0);
    }
  }

  static void setBrightness(PlayerController c, double v, {bool save = true}) {
    v = clampBrightness(v);
    c.setBrightness(v);
    if (save) KvHelper.set(_kBrightness, v);
  }

  /// On PC the controller starts brightness at 0: use the saved one (or full).
  static void start(PlayerController c) {
    double saved = 1.0;
    try {
      saved = KvHelper.get<double>(_kBrightness, defaultVal: 1.0);
    } catch (_) {}
    c.brightness.value = clampBrightness(saved);
  }
}

/// The dark layer over the video for brightness. Put it right above the
/// video. Lets every click through.
class PlusDesktopDim extends StatelessWidget {
  final PlayerController controller;
  const PlusDesktopDim({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    if (!PlusDesktopVolume.supported) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: Obx(() {
          final a = PlusDesktopVolume.dimFor(controller.brightness.value);
          if (a <= 0) return const SizedBox.shrink();
          return ColoredBox(color: Colors.black.withValues(alpha: a));
        }),
      ),
    );
  }
}

/// Mouse wheel over the video. Put it above the tap/drag layer and below the
/// controls and menus, so lists in menus still scroll.
class PlusDesktopWheel extends StatelessWidget {
  final PlayerController controller;
  const PlusDesktopWheel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    if (!PlusDesktopVolume.supported) return const SizedBox.shrink();
    return Positioned.fill(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerSignal: (e) {
          if (e is! PointerScrollEvent || e.scrollDelta.dy == 0) return;
          GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
            final up = (ev as PointerScrollEvent).scrollDelta.dy < 0;
            final by = up ? PlusDesktopVolume.step : -PlusDesktopVolume.step;
            if (HardwareKeyboard.instance.isShiftPressed) {
              PlusDesktopVolume.setBrightness(controller, controller.brightness.value + by);
            } else {
              PlusDesktopVolume.changeVolume(controller, by);
            }
          });
        },
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Up / Down = volume, M = mute, while the player is open. Draws nothing.
class PlusDesktopKeys extends StatefulWidget {
  final PlayerController controller;
  const PlusDesktopKeys({super.key, required this.controller});

  @override
  State<PlusDesktopKeys> createState() => _PlusDesktopKeysState();
}

class _PlusDesktopKeysState extends State<PlusDesktopKeys> {
  PlayerController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    if (!PlusDesktopVolume.supported) return;
    PlusDesktopVolume.start(c);
    PlusFocusWatch.start(); // AnymeX+: logs focus changes (Windows), for the focus bug
    PlusFocusWatch.watchControls(c.showControls);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return false;
    if (!mounted) return false;
    // Typing somewhere (search, a text box in a menu): leave the keys alone.
    final focus = FocusManager.instance.primaryFocus?.context?.widget;
    if (focus is EditableText) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp) {
      PlusDesktopVolume.changeVolume(c, PlusDesktopVolume.step);
      return true;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      PlusDesktopVolume.changeVolume(c, -PlusDesktopVolume.step);
      return true;
    }
    if (k == LogicalKeyboardKey.keyM && e is KeyDownEvent && !HardwareKeyboard.instance.isControlPressed) {
      PlusDesktopVolume.toggleMute(c);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Puts "volume" and "brightness" at the start of the right side when the
/// saved layout doesn't have them yet (PC only; never on phones).
void plusAddVolumeButtonIds(List<String> left, List<String> right, List<String> hidden) {
  const ids = ['volume', 'brightness'];
  if (!PlusDesktopVolume.supported) {
    left.removeWhere(ids.contains);
    right.removeWhere(ids.contains);
    return;
  }
  var at = 0;
  for (final id in ids) {
    if (left.contains(id) || right.contains(id) || hidden.contains(id)) continue;
    right.insert(at++, id);
  }
}

/// The bar buttons "volume" and "brightness" (PC only; ids in the bottom
/// controls settings). Each is an ordinary button in the bar's button group;
/// hover it and its own little box swells a few pixels all round, then grows
/// upwards with a slider inside. Leaving plays the same motion backwards.
/// Click: volume = mute, brightness = back to 100%.
class PlusSliderButton extends StatefulWidget {
  final PlayerController controller;
  final bool brightness; // false = volume
  const PlusSliderButton({super.key, required this.controller, this.brightness = false});

  @override
  State<PlusSliderButton> createState() => _PlusSliderButtonState();
}

class _PlusSliderButtonState extends State<PlusSliderButton> with SingleTickerProviderStateMixin {
  static const _btn = 36.0; // ControlButton's compact box
  static const _swell = 4.0; // grows this much on every side first
  static const _rise = 150.0; // then this much upwards
  static const _split = 0.28; // share of the motion spent swelling

  final _link = LayerLink();
  final _portal = OverlayPortalController();
  // One straight timeline; the easing is done per part, so going back is the
  // exact same path in reverse (no jump at the end).
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );
  bool _overBar = false, _overPop = false, _dragging = false;
  Timer? _close, _keepUp;

  PlayerController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.dismissed && _portal.isShowing) _portal.hide();
    });
  }

  @override
  void dispose() {
    _close?.cancel();
    _keepUp?.cancel();
    _anim.dispose();
    super.dispose();
  }

  void _update() {
    _close?.cancel();
    if (_overBar || _overPop || _dragging) {
      if (!_portal.isShowing) _portal.show();
      _anim.forward();
      c.onUserInteraction();
      _keepUp ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) c.onUserInteraction();
      });
    } else {
      _close = Timer(const Duration(milliseconds: 180), () {
        _keepUp?.cancel();
        _keepUp = null;
        if (mounted) _anim.reverse();
      });
    }
  }

  IconData get _icon {
    if (widget.brightness) return Icons.brightness_6_rounded;
    final v = c.volume.value;
    if (v <= 0) return Icons.volume_off_rounded;
    return v < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded;
  }

  double get _value => widget.brightness ? c.brightness.value : c.volume.value;
  double get _min => widget.brightness ? PlusDesktopVolume.minBrightness : 0;
  double get _max => widget.brightness ? 1.0 : PlusDesktopVolume.maxVolume;

  void _tap() => widget.brightness
      ? PlusDesktopVolume.setBrightness(c, 1.0)
      : PlusDesktopVolume.toggleMute(c);

  void _change(double x) => widget.brightness
      ? PlusDesktopVolume.setBrightness(c, x, save: false)
      : c.setVolume(PlusDesktopVolume.clampVolume(x), isDragging: true);

  void _end(double x) => widget.brightness
      ? PlusDesktopVolume.setBrightness(c, x)
      : c.setVolume(PlusDesktopVolume.clampVolume(x));

  // The hovered button's own colours (as in ControlButton), and the colours
  // of the open box.
  ({Color bg, Color border}) _colors(BuildContext context, double open) {
    final theme = context.theme;
    final dark = theme.brightness == Brightness.dark;
    final p = theme.colorScheme.primary;
    final hoverBg = dark ? p.withValues(alpha: 0.1) : theme.colorScheme.surfaceContainerHigh;
    final hoverBorder = dark ? p.withValues(alpha: 0.3) : theme.colorScheme.outline.withValues(alpha: 0.4);
    final openBg = dark
        ? Color.alphaBlend(p.withValues(alpha: 0.12), const Color(0xF0141418))
        : theme.colorScheme.surfaceContainerHigh;
    return (bg: Color.lerp(hoverBg, openBg, open)!, border: hoverBorder);
  }

  Widget _popup(BuildContext context) {
    return Obx(() {
      if (!c.showControls.value) return const SizedBox.shrink();
      final iconColor = context.theme.brightness == Brightness.dark
          ? context.theme.colorScheme.primary
          : context.theme.colorScheme.onSurface;
      final icon = _icon, value = _value;
      return AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          final t = _anim.value;
          final swell = Curves.easeOutCubic.transform((t / _split).clamp(0.0, 1.0));
          final rise = Curves.easeInOutCubic.transform(((t - _split) / (1 - _split)).clamp(0.0, 1.0));
          final grow = _swell * swell;
          final w = _btn + grow * 2, h = _btn + grow * 2 + _rise * rise;
          final col = _colors(context, swell);
          return CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment.bottomCenter,
            followerAnchor: Alignment.bottomCenter,
            offset: Offset(0, grow), // swells downwards too
            child: Align(
              alignment: Alignment.bottomCenter,
              widthFactor: 1,
              heightFactor: 1,
              child: MouseRegion(
                onEnter: (_) {
                  _overPop = true;
                  _update();
                },
                onExit: (_) {
                  _overPop = false;
                  _update();
                },
                child: Container(
                  width: w,
                  height: h,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: col.bg,
                    borderRadius: BorderRadius.circular(12 + grow),
                    border: Border.all(color: col.border, width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35 * swell),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      if (rise > 0.02)
                        Expanded(
                          child: Opacity(
                            opacity: ((rise - 0.3) / 0.7).clamp(0.0, 1.0),
                            child: OverflowBox(
                              alignment: Alignment.bottomCenter,
                              minHeight: _rise,
                              maxHeight: _rise,
                              child: Column(
                                children: [
                                  const SizedBox(height: 8),
                                  Text('${(value * 100).round()}%',
                                      style: const TextStyle(color: Colors.white, fontSize: 11)),
                                  Expanded(
                                    child: RotatedBox(
                                      quarterTurns: 3,
                                      child: SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          trackHeight: 4,
                                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                          activeTrackColor: Colors.white,
                                          inactiveTrackColor: Colors.white24,
                                          thumbColor: Colors.white,
                                        ),
                                        child: Slider(
                                          value: value.clamp(_min, _max).toDouble(),
                                          min: _min,
                                          max: _max,
                                          onChangeStart: (_) {
                                            _dragging = true;
                                            _update();
                                          },
                                          onChanged: _change,
                                          onChangeEnd: (x) {
                                            _dragging = false;
                                            _end(x);
                                            _update();
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      // The button itself, at the bottom of the box.
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _tap,
                        child: SizedBox(
                          width: w,
                          height: _btn + grow * 2 - 2,
                          child: Center(child: Icon(icon, size: 20, color: iconColor)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!PlusDesktopVolume.supported) return const SizedBox.shrink();
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _popup,
      child: MouseRegion(
        onEnter: (_) {
          _overBar = true;
          _update();
        },
        onExit: (_) {
          _overBar = false;
          _update();
        },
        child: Padding(
          // ControlButton's own side margin, outside the link so the box
          // lines up with the button's box.
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: CompositedTransformTarget(
            link: _link,
            child: SizedBox(
              width: _btn,
              height: _btn,
              child: widget.brightness
                  ? OverflowBox(
                      maxWidth: _btn + 6,
                      child: ControlButton(icon: _icon, onPressed: _tap, compact: true),
                    )
                  : Obx(() => OverflowBox(
                        maxWidth: _btn + 6,
                        child: ControlButton(icon: _icon, onPressed: _tap, compact: true),
                      )),
            ),
          ),
        ),
      ),
    );
  }
}
