import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

/// For strips that are NOT media rows (chips, tabs, pills): a mouse can't drag
/// them out of place. Touch / trackpad / pen still scroll; media rows keep
/// full mouse dragging.
class NoMouseDrag extends StatelessWidget {
  final Widget child;
  const NoMouseDrag({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: const {
            PointerDeviceKind.touch,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
          },
          scrollbars: false,
        ),
        child: child,
      );
}
