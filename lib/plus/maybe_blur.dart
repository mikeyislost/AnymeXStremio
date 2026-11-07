import 'dart:ui';

import 'package:flutter/widgets.dart';

/// AnymeX+: a backdrop blur that is left out entirely when there is no
/// blur. A zero blur still makes Flutter copy and redraw everything behind
/// the widget on every frame while content scrolls under it.
class MaybeBlur extends StatelessWidget {
  final double sigma;
  final Widget child;

  const MaybeBlur({super.key, required this.sigma, required this.child});

  @override
  Widget build(BuildContext context) {
    if (sigma <= 0) return child;
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: child,
    );
  }
}
