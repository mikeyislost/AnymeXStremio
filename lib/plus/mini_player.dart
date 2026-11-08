// AnymeX+: mini player on Windows. Shrinks the window to a small video
// that stays on top of other windows (bottom-right of the screen); drag it
// anywhere, double-click or the expand button to go back. Leaving the
// player always restores the window.

import 'dart:io';

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
    } catch (e) {
      Logger.i('Mini player: $e');
    } finally {
      _switching = false;
    }
  }

  static Future<void> exit() async {
    if (!active.value || _switching) return;
    _switching = true;
    try {
      active.value = false;
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
          ],
        ),
      );
    });
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
