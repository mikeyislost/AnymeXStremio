// AnymeX+: volume and brightness on PC (Windows, macOS, Linux).
//
// AnymeX only has the phone's swipe gestures (click and drag on PC), and
// brightness does nothing on a PC screen. Here:
// - volume and brightness buttons in the player's bottom button group;
//   hover one and a slider pops up above it (click: mute / 100%);
// - mouse wheel over the video = volume, Shift + wheel = brightness;
// - Up / Down arrow keys = volume, M = mute;
// - brightness dims the picture (a dark layer over the video), remembered.

import 'dart:async';
import 'dart:io';

import 'package:anymex/database/kv_helper.dart';
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

/// The two buttons for the player's bottom button group (PC only): volume
/// and brightness. Hover one and its slider pops up above it.
List<Widget> plusDesktopVolumeButtons(PlayerController c) {
  if (!PlusDesktopVolume.supported) return const [];
  return [
    Obx(() {
      final v = c.volume.value;
      return PlusHoverSlider(
        controller: c,
        icon: v <= 0
            ? Icons.volume_off_rounded
            : (v < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
        label: 'Volume (click to mute)',
        value: v,
        min: 0,
        max: PlusDesktopVolume.maxVolume,
        onTap: () => PlusDesktopVolume.toggleMute(c),
        onChanged: (x) => c.setVolume(PlusDesktopVolume.clampVolume(x), isDragging: true),
        onEnd: (x) => c.setVolume(PlusDesktopVolume.clampVolume(x)),
      );
    }),
    Obx(() => PlusHoverSlider(
          controller: c,
          icon: Icons.brightness_6_rounded,
          label: 'Brightness (click for 100%)',
          value: c.brightness.value,
          min: PlusDesktopVolume.minBrightness,
          max: 1.0,
          onTap: () => PlusDesktopVolume.setBrightness(c, 1.0),
          onChanged: (x) => PlusDesktopVolume.setBrightness(c, x, save: false),
          onEnd: (x) => PlusDesktopVolume.setBrightness(c, x),
        )),
  ];
}

/// An icon button that pops a vertical slider up above itself on hover.
class PlusHoverSlider extends StatefulWidget {
  final PlayerController controller;
  final IconData icon;
  final String label;
  final double value, min, max;
  final VoidCallback onTap;
  final ValueChanged<double> onChanged, onEnd;

  const PlusHoverSlider({
    super.key,
    required this.controller,
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onTap,
    required this.onChanged,
    required this.onEnd,
  });

  @override
  State<PlusHoverSlider> createState() => _PlusHoverSliderState();
}

class _PlusHoverSliderState extends State<PlusHoverSlider> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  bool _overIcon = false, _overPop = false, _dragging = false;
  Timer? _hide, _keepUp;

  @override
  void dispose() {
    _hide?.cancel();
    _keepUp?.cancel();
    super.dispose();
  }

  void _update() {
    final want = _overIcon || _overPop || _dragging;
    if (want) {
      _hide?.cancel();
      if (!_portal.isShowing) _portal.show();
      // Keep the player's controls up while the slider is open.
      widget.controller.onUserInteraction();
      _keepUp ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) widget.controller.onUserInteraction();
      });
    } else {
      _hide?.cancel();
      _hide = Timer(const Duration(milliseconds: 250), () {
        _keepUp?.cancel();
        _keepUp = null;
        if (mounted && _portal.isShowing) _portal.hide();
      });
    }
  }

  Widget _popup(BuildContext context) {
    return Obx(() {
      // The bar went away: so does the slider.
      if (!widget.controller.showControls.value) return const SizedBox.shrink();
      return CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.topCenter,
        followerAnchor: Alignment.bottomCenter,
        offset: const Offset(0, -6),
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
            child: Material(
              color: const Color(0xE6101014),
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 46,
                height: 170,
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    Text('${(widget.value * 100).round()}%',
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
                            value: widget.value.clamp(widget.min, widget.max).toDouble(),
                            min: widget.min,
                            max: widget.max,
                            onChangeStart: (_) {
                              _dragging = true;
                              _update();
                            },
                            onChanged: widget.onChanged,
                            onChangeEnd: (x) {
                              _dragging = false;
                              widget.onEnd(x);
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
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _popup,
      child: CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          onEnter: (_) {
            _overIcon = true;
            _update();
          },
          onExit: (_) {
            _overIcon = false;
            _update();
          },
          child: Tooltip(
            message: widget.label,
            waitDuration: const Duration(milliseconds: 900),
            child: ControlButton(
              icon: widget.icon,
              onPressed: widget.onTap,
              compact: true,
            ),
          ),
        ),
      ),
    );
  }
}
