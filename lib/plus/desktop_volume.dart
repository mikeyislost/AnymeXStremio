// AnymeX+: volume and brightness on PC (Windows, macOS, Linux).
//
// AnymeX only has the phone's swipe gestures (click and drag on PC), and
// brightness does nothing on a PC screen. Here:
// - a small pill at the top right while the controls show: volume button
//   (click = mute) with a slider, brightness with a slider;
// - mouse wheel over the video = volume, Shift + wheel = brightness;
// - Up / Down arrow keys = volume, M = mute;
// - brightness dims the picture (a dark layer over the video), remembered.

import 'dart:io';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/screens/anime/watch/controller/player_controller.dart';
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

/// The pill with volume and brightness (top right, while the controls show)
/// and the Up / Down / M keys.
class PlusDesktopVolumeBar extends StatefulWidget {
  final PlayerController controller;
  const PlusDesktopVolumeBar({super.key, required this.controller});

  @override
  State<PlusDesktopVolumeBar> createState() => _PlusDesktopVolumeBarState();
}

class _PlusDesktopVolumeBarState extends State<PlusDesktopVolumeBar> {
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

  IconData _volumeIcon(double v) {
    if (v <= 0) return Icons.volume_off_rounded;
    if (v < 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  Widget _slider(double value, double min, double max, ValueChanged<double> onChanged,
      {ValueChanged<double>? onEnd}) {
    return SizedBox(
      width: 110,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
          activeTrackColor: Colors.white,
          inactiveTrackColor: Colors.white24,
          thumbColor: Colors.white,
        ),
        child: Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          onChanged: onChanged,
          onChangeEnd: onEnd,
        ),
      ),
    );
  }

  Widget _icon(IconData icon, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 20, color: Colors.white),
          ),
        ),
      );

  Widget _pct(double v) => SizedBox(
        width: 40,
        child: Text('${(v * 100).round()}%',
            textAlign: TextAlign.right, style: const TextStyle(color: Colors.white, fontSize: 12)),
      );

  @override
  Widget build(BuildContext context) {
    if (!PlusDesktopVolume.supported) return const SizedBox.shrink();
    return Obx(() {
      if (!c.showControls.value) return const SizedBox.shrink();
      final v = c.volume.value, b = c.brightness.value;
      return Align(
        alignment: Alignment.topRight,
        child: Padding(
          // Left of the mini player button (top 64, right 16).
          padding: EdgeInsets.only(top: 64, right: Platform.isWindows ? 72 : 16),
          child: Material(
            color: const Color(0x99000000),
            borderRadius: BorderRadius.circular(22),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _icon(_volumeIcon(v), v > 0 ? 'Mute (M)' : 'Unmute (M)', () => PlusDesktopVolume.toggleMute(c)),
                  _slider(v, 0, PlusDesktopVolume.maxVolume,
                      (x) => c.setVolume(PlusDesktopVolume.clampVolume(x), isDragging: true),
                      onEnd: (x) => c.setVolume(PlusDesktopVolume.clampVolume(x))),
                  _pct(v),
                  const SizedBox(width: 10),
                  Tooltip(
                    message: 'Brightness (Shift + wheel)',
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(Icons.brightness_6_rounded, size: 20, color: Colors.white),
                    ),
                  ),
                  _slider(b, PlusDesktopVolume.minBrightness, 1.0,
                      (x) => PlusDesktopVolume.setBrightness(c, x, save: false),
                      onEnd: (x) => PlusDesktopVolume.setBrightness(c, x)),
                  _pct(b),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}
