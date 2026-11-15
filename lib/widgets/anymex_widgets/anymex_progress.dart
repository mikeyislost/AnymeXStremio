import 'package:anymex/widgets/anymex_widgets/yumori_loader.dart';
import 'package:flutter/material.dart';

/// Single entry point for progress UI.
/// Indeterminate: the Yumori firefly-and-tree loader.
/// Determinate: a lavender ring with a cream firefly at the tip.
class AnymeXProgressIndicator extends StatelessWidget {
  final double? value;
  final double? strokeWidth;
  final Color? backgroundColor;

  const AnymeXProgressIndicator({
    super.key,
    this.value,
    this.strokeWidth,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return value != null
        ? YumoriRing(
            value: value!,
            strokeWidth: strokeWidth ?? 4,
            backgroundColor: backgroundColor,
          )
        : const YumoriLoader();
  }
}
