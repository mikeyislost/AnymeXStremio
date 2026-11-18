import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

/// Wrap a horizontal media row so it can be dragged with the mouse on PC.
/// Everything else in the app ignores mouse dragging.
class MediaRowDrag extends StatelessWidget {
  final Widget child;
  const MediaRowDrag({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: const {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
          },
        ),
        child: child,
      );
}
