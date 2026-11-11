// AnymeX+: sharper, cleaner video on PC.
//
// media_kit draws each frame at the video's own size, and Flutter then
// stretches that picture to the window with a cheap filter, so mpv's good
// scaling and debanding never got used: the picture looked soft, grainy and
// blocky on PC. Here, while the video fits the window (the normal mode):
// - mpv draws at the window's real pixel size, so mpv does the scaling;
// - mpv's high-quality scaling and debanding are on (no added grain).
// Zoom / stretch modes keep the old way (they need the video's own size).

import 'dart:async';
import 'dart:io';

import 'package:anymex/screens/anime/watch/controller/player_controller.dart';
import 'package:anymex/utils/logger.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class PlusPcVideo {
  PlusPcVideo._();

  static bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// mpv options for PC (close to mpv's own "high-quality" profile).
  static const mpvOptions = <String, String>{
    'scale': 'ewa_lanczossharp',
    'cscale': 'ewa_lanczossharp',
    'dscale': 'mitchell',
    'correct-downscaling': 'yes',
    'linear-downscaling': 'yes',
    'sigmoid-upscaling': 'yes',
    'deband': 'yes',
    'deband-grain': '0', // mpv adds grain by default; the user found it grainy
    'dither-depth': 'auto',
  };

  static Future<void> applyMpvOptions(dynamic mpv) async {
    if (!supported) return;
    for (final e in mpvOptions.entries) {
      try {
        await mpv.setProperty(e.key, e.value);
      } catch (err) {
        Logger.i('PC video option ${e.key}: $err');
      }
    }
  }

  /// The size mpv should draw at: the box in physical pixels, even numbers,
  /// or null to use the video's own size.
  static ({int w, int h})? outputSize(Size box, double dpr, BoxFit fit) {
    if (fit != BoxFit.contain) return null;
    if (!box.width.isFinite || !box.height.isFinite) return null;
    var w = (box.width * dpr).round(), h = (box.height * dpr).round();
    if (w < 64 || h < 64) return null;
    w -= w % 2;
    h -= h % 2;
    // Nothing bigger than 8K.
    if (w > 7680 || h > 4320) return null;
    return (w: w, h: h);
  }
}

/// Wraps the video widget: tells mpv the size to draw at (PC only).
class PlusPcVideoSize extends StatefulWidget {
  final PlayerController controller;
  final Widget child;
  const PlusPcVideoSize({super.key, required this.controller, required this.child});

  @override
  State<PlusPcVideoSize> createState() => _PlusPcVideoSizeState();
}

class _PlusPcVideoSizeState extends State<PlusPcVideoSize> {
  Timer? _timer;
  Object? _lastController;
  ({int w, int h})? _last;
  bool _lastWasNull = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule(Size box, double dpr, BoxFit fit) {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 250), () => _apply(box, dpr, fit));
  }

  Future<void> _apply(Size box, double dpr, BoxFit fit) async {
    if (!mounted) return;
    dynamic native;
    try {
      native = (widget.controller.basePlayer as dynamic).nativeVideoController;
    } catch (_) {
      return; // player not ready yet
    }
    if (native == null) return;
    final size = PlusPcVideo.outputSize(box, dpr, fit);
    final same = identical(native, _lastController) &&
        ((size == null && _lastWasNull) || (size != null && size == _last));
    if (same) return;
    try {
      if (size == null) {
        await native.setSize(width: null, height: null);
      } else {
        await native.setSize(width: size.w, height: size.h);
      }
      _lastController = native;
      _last = size;
      _lastWasNull = size == null;
    } catch (e) {
      Logger.i('PC video size: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!PlusPcVideo.supported) return widget.child;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(builder: (context, box) {
      return Obx(() {
        final fit = widget.controller.videoFit.value;
        // Also after the player is rebuilt (new native controller).
        widget.controller.playerReloadVersion.value;
        _schedule(box.biggest, dpr, fit);
        return widget.child;
      });
    });
  }
}
