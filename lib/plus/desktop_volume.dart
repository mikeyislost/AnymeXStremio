// AnymeX+: volume and brightness on PC (Windows, macOS, Linux).
//
// AnymeX only has the phone's swipe gestures (click and drag on PC), and
// brightness does nothing on a PC screen. Here:
// - a small box with volume and brightness buttons in the player's bottom
//   bar; hovering it grows the box upwards with a slider above each button
//   (click: mute / back to 100%);
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

/// Volume and brightness for the player's bottom bar (PC only): two small
/// boxes of one button each, working on their own. Hover one and its box
/// grows upwards with a slider inside, then slides back down when the mouse
/// leaves. Click: volume = mute, brightness = back to 100%.
List<Widget> plusDesktopVolumeGroup(PlayerController c) {
  if (!PlusDesktopVolume.supported) return const [];
  return [
    PlusVolumeGroup(controller: c),
    const SizedBox(width: 8),
    PlusVolumeGroup(controller: c, brightness: true),
    const SizedBox(width: 8),
  ];
}

class PlusVolumeGroup extends StatefulWidget {
  final PlayerController controller;
  final bool brightness; // false = volume
  const PlusVolumeGroup({super.key, required this.controller, this.brightness = false});

  @override
  State<PlusVolumeGroup> createState() => _PlusVolumeGroupState();
}

class _PlusVolumeGroupState extends State<PlusVolumeGroup> with SingleTickerProviderStateMixin {
  static const _grow = 168.0; // how far the box grows upwards

  final _link = LayerLink();
  final _portal = OverlayPortalController();
  final _boxKey = GlobalKey();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    reverseDuration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _anim,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  bool _overBar = false, _overPop = false, _dragging = false;
  Size _size = const Size(56, 48);
  Timer? _close, _keepUp;

  PlayerController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.dismissed && _portal.isShowing) {
        _portal.hide();
        if (mounted) setState(() {});
      }
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
    if (_overBar || _overPop || _dragging) {
      _close?.cancel();
      _open();
    } else {
      _close?.cancel();
      _close = Timer(const Duration(milliseconds: 220), () {
        _keepUp?.cancel();
        _keepUp = null;
        if (mounted) _anim.reverse();
      });
    }
  }

  void _open() {
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) _size = box.size;
    if (!_portal.isShowing) {
      _portal.show();
      setState(() {});
    }
    _anim.forward();
    // Keep the player's controls up while the box is open.
    c.onUserInteraction();
    _keepUp ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) c.onUserInteraction();
    });
  }

  BoxDecoration _decoration(BuildContext context, double t) {
    final theme = context.theme;
    final isDark = theme.brightness == Brightness.dark;
    // Same look as the bar's other button groups, a little darker as it
    // opens so the sliders read well over the video.
    final base = isDark
        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2)
        : theme.colorScheme.surfaceContainerHighest;
    final open = isDark ? const Color(0xD9141418) : theme.colorScheme.surfaceContainerHighest;
    return BoxDecoration(
      color: Color.lerp(base, open, t),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: theme.colorScheme.outline.withValues(alpha: isDark ? 0.15 : 0.3),
        width: 0.5,
      ),
    );
  }

  Widget _buttons() {
    if (widget.brightness) {
      return ControlButton(
        icon: Icons.brightness_6_rounded,
        onPressed: () => PlusDesktopVolume.setBrightness(c, 1.0),
        compact: true,
      );
    }
    return Obx(() {
      final v = c.volume.value;
      return ControlButton(
        icon: v <= 0
            ? Icons.volume_off_rounded
            : (v < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
        onPressed: () => PlusDesktopVolume.toggleMute(c),
        compact: true,
      );
    });
  }

  Widget _slider(BuildContext context, double value, double min, double max, String pct,
      ValueChanged<double> onChanged, ValueChanged<double> onEnd) {
    return Expanded(
      child: Column(
        children: [
          Text(pct, style: const TextStyle(color: Colors.white, fontSize: 11)),
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
                  value: value.clamp(min, max).toDouble(),
                  min: min,
                  max: max,
                  onChangeStart: (_) {
                    _dragging = true;
                    _update();
                  },
                  onChanged: onChanged,
                  onChangeEnd: (x) {
                    _dragging = false;
                    onEnd(x);
                    _update();
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // The open box, drawn over the bar's own box (same spot, same width).
  Widget _popup(BuildContext context) {
    return Obx(() {
      if (!c.showControls.value) return const SizedBox.shrink();
      return CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.bottomLeft,
        followerAnchor: Alignment.bottomLeft,
        child: Align(
          alignment: Alignment.bottomLeft,
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
            child: AnimatedBuilder(
              animation: _t,
              builder: (context, _) {
                final t = _t.value;
                return Container(
                  width: _size.width,
                  height: _size.height + _grow * t,
                  decoration: _decoration(context, t),
                  clipBehavior: Clip.antiAlias,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Column(
                    children: [
                      if (t > 0.05)
                        Expanded(
                          child: Opacity(
                            opacity: ((t - 0.35) / 0.65).clamp(0.0, 1.0),
                            child: Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Obx(() => Row(
                                    children: [
                                      if (widget.brightness)
                                        _slider(context, c.brightness.value, PlusDesktopVolume.minBrightness, 1.0,
                                            '${(c.brightness.value * 100).round()}%',
                                            (x) => PlusDesktopVolume.setBrightness(c, x, save: false),
                                            (x) => PlusDesktopVolume.setBrightness(c, x))
                                      else
                                        _slider(context, c.volume.value, 0, PlusDesktopVolume.maxVolume,
                                            '${(c.volume.value * 100).round()}%',
                                            (x) => c.setVolume(PlusDesktopVolume.clampVolume(x), isDragging: true),
                                            (x) => c.setVolume(PlusDesktopVolume.clampVolume(x))),
                                    ],
                                  )),
                            ),
                          ),
                        ),
                      // Same buttons as in the bar, at the bottom of the box.
                      SizedBox(height: _size.height - 12, child: Center(child: _buttons())),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!PlusDesktopVolume.supported) return const SizedBox.shrink();
    final open = _portal.isShowing;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _popup,
      child: CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          onEnter: (_) {
            _overBar = true;
            _update();
          },
          onExit: (_) {
            _overBar = false;
            _update();
          },
          // While open, the box in the overlay stands in for this one.
          child: Opacity(
            opacity: open ? 0 : 1,
            child: Container(
              key: _boxKey,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: _decoration(context, 0),
              child: _buttons(),
            ),
          ),
        ),
      ),
    );
  }
}
