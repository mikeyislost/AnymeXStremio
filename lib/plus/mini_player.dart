// AnymeX+: mini player on Windows. Shrinks the window to a small video
// that stays on top of other windows (bottom-right of the screen); drag it
// anywhere, double-click or the expand button to go back. Leaving the
// player always restores the window. If the window gets big some other way
// (Windows snaps it to maximized when dragged to the top of the screen,
// Win+Up, the taskbar), the mini player ends too, so the player's controls
// come back. A slider (on hover) makes the mini window see-through.

import 'dart:io';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/screens/anime/watch/controller/player_controller.dart';
import 'package:anymex/utils/logger.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_titlebar.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

class PlusMiniPlayer {
  PlusMiniPlayer._();

  static final RxBool active = false.obs;
  static const miniSize = Size(480, 270);

  static Rect? _bounds;
  static bool _wasMaximized = false;
  static bool _wasFullScreen = false;
  static bool _switching = false;

  static bool get supported => Platform.isWindows;

  static const _kOpacity = 'plus_mini_opacity';
  static final RxDouble opacity = 1.0.obs;
  static final _watcher = _MiniWindowWatcher();

  /// Window opacity of the mini player (0.3 to 1), remembered.
  static Future<void> setOpacity(double v, {bool save = true}) async {
    v = v.clamp(0.3, 1.0).toDouble();
    opacity.value = v;
    if (save) KvHelper.set(_kOpacity, v);
    if (!active.value) return;
    try {
      await windowManager.setOpacity(v);
    } catch (e) {
      Logger.i('Mini player opacity: $e');
    }
  }

  static Future<void> toggle() => active.value ? exit() : enter();

  static Future<void> enter() async {
    if (!supported || active.value || _switching) return;
    _switching = true;
    try {
      _wasFullScreen = AnymeXTitleBar.isFullScreen.value;
      if (_wasFullScreen) await windowManager.setFullScreen(false);
      _wasMaximized = await windowManager.isMaximized();
      if (_wasMaximized) await windowManager.unmaximize();
      _bounds = await windowManager.getBounds();
      // The title bar hides while this is true (as in full screen).
      AnymeXTitleBar.isFullScreen.value = true;
      active.value = true;
      await windowManager.setMinimumSize(const Size(240, 135));
      await windowManager.setSize(miniSize);
      await windowManager.setAlignment(Alignment.bottomRight);
      await windowManager.setAlwaysOnTop(true);
      double saved = 1.0;
      try {
        saved = KvHelper.get<double>(_kOpacity, defaultVal: 1.0);
      } catch (_) {}
      await setOpacity(saved, save: false);
      windowManager.removeListener(_watcher);
      windowManager.addListener(_watcher);
    } catch (e) {
      Logger.i('Mini player: $e');
    } finally {
      _switching = false;
    }
  }

  /// The window got big without our button (snap, Win+Up, taskbar…): end
  /// the mini player where the window is now.
  static Future<void> grown() async {
    if (!active.value) return;
    if (_switching) {
      // Mid-switch: look again once it's done.
      Future.delayed(const Duration(milliseconds: 400), grown);
      return;
    }
    _switching = true;
    try {
      // Only when it really is big now (layout can run mid-shrink).
      final size = await windowManager.getSize();
      final big = size.width >= 1000 ||
          size.height >= 600 ||
          await windowManager.isMaximized() ||
          await windowManager.isFullScreen();
      if (!big) return;
      windowManager.removeListener(_watcher);
      active.value = false;
      await windowManager.setOpacity(1.0);
      await windowManager.setAlwaysOnTop(false);
      AnymeXTitleBar.isFullScreen.value = await windowManager.isFullScreen();
      AnymeXTitleBar.isMaximized.value = await windowManager.isMaximized();
    } catch (e) {
      Logger.i('Mini player: $e');
    } finally {
      _switching = false;
    }
  }

  static Future<void> exit() async {
    if (!active.value) return;
    if (_switching) {
      // Pressed while it was still shrinking: do it right after.
      Future.delayed(const Duration(milliseconds: 300), exit);
      return;
    }
    _switching = true;
    try {
      windowManager.removeListener(_watcher);
      active.value = false;
      await windowManager.setOpacity(1.0);
      await windowManager.setAlwaysOnTop(false);
      final b = _bounds;
      if (b != null) await windowManager.setBounds(b);
      if (_wasMaximized) await windowManager.maximize();
      if (_wasFullScreen) {
        await AnymeXTitleBar.setFullScreen(true);
      } else {
        AnymeXTitleBar.isFullScreen.value = false;
      }
    } catch (e) {
      Logger.i('Mini player: $e');
    } finally {
      _switching = false;
    }
  }
}

class _MiniWindowWatcher extends WindowListener {
  @override
  void onWindowMaximize() => PlusMiniPlayer.grown();

  @override
  void onWindowEnterFullScreen() => PlusMiniPlayer.grown();

  @override
  void onWindowResized() async {
    try {
      final s = await windowManager.getSize();
      if (s.width >= 1000 || s.height >= 600) PlusMiniPlayer.grown();
    } catch (_) {}
  }
}

/// In the player: a small "mini player" button (Windows, while the
/// controls show), and the mini player's own controls while it's on.
class PlusMiniPlayerOverlay extends StatefulWidget {
  final PlayerController controller;

  const PlusMiniPlayerOverlay({super.key, required this.controller});

  @override
  State<PlusMiniPlayerOverlay> createState() => _PlusMiniPlayerOverlayState();
}

class _PlusMiniPlayerOverlayState extends State<PlusMiniPlayerOverlay> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (!PlusMiniPlayer.supported) return const SizedBox.shrink();
    final c = widget.controller;
    return Obx(() {
      if (!PlusMiniPlayer.active.value) {
        if (!c.showControls.value) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 64, right: 16),
            child: _roundButton(Icons.picture_in_picture_alt_rounded,
                'Mini player', PlusMiniPlayer.enter),
          ),
        );
      }
      // Mini player: drag anywhere to move; buttons on hover.
      return LayoutBuilder(builder: (context, box) {
        // Safety net: a big window can't be a mini player.
        if (box.maxWidth >= 1000 || box.maxHeight >= 600) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => PlusMiniPlayer.grown());
        }
        return _mini(c);
      });
    });
  }

  Widget _mini(PlayerController c) {
      return MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => windowManager.startDragging(),
                onDoubleTap: PlusMiniPlayer.exit,
                onTap: c.togglePlayPause,
              ),
            ),
            if (_hover)
              Align(
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _roundButton(Icons.replay_10_rounded, 'Back 10 s',
                        () => c.seekTo(c.currentPosition.value -
                            const Duration(seconds: 10))),
                    const SizedBox(width: 10),
                    Obx(() => _roundButton(
                        c.isPlaying.value
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        c.isPlaying.value ? 'Pause' : 'Play',
                        c.togglePlayPause,
                        size: 30)),
                    const SizedBox(width: 10),
                    _roundButton(Icons.forward_10_rounded, 'Forward 10 s',
                        () => c.seekTo(c.currentPosition.value +
                            const Duration(seconds: 10))),
                  ],
                ),
              ),
            if (_hover)
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: _roundButton(Icons.open_in_full_rounded,
                      'Back to full size', PlusMiniPlayer.exit),
                ),
              ),
            if (_hover)
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
                  child: _opacitySlider(),
                ),
              ),
          ],
        ),
      );
  }

  // See-through slider at the bottom of the mini window.
  Widget _opacitySlider() {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        children: [
          const Tooltip(
            message: 'See-through',
            child: Icon(Icons.opacity_rounded, size: 16, color: Colors.white),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
              ),
              child: Obx(() => Slider(
                    value: PlusMiniPlayer.opacity.value,
                    min: 0.3,
                    max: 1.0,
                    onChanged: (v) => PlusMiniPlayer.setOpacity(v, save: false),
                    onChangeEnd: (v) => PlusMiniPlayer.setOpacity(v),
                  )),
            ),
          ),
          Obx(() => Text('${(PlusMiniPlayer.opacity.value * 100).round()}%',
              style: const TextStyle(color: Colors.white, fontSize: 11))),
        ],
      ),
    );
  }

  Widget _roundButton(IconData icon, String tooltip, VoidCallback onTap,
      {double size = 20}) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0x99000000),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: size, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
