import 'package:anymex/widgets/anymex_widgets/yumori_loader.dart';
import 'package:flutter/material.dart';

/// Kept under its old name so every place that showed the AnymeX logo now
/// shows Yumori instead (call sites will be renamed later). Small sizes show
/// the still tree mark; big ones (splash) the firefly-and-tree loader.
/// The old size/colour parameters are accepted and ignored.
class AnymeXAnimatedLogo extends StatefulWidget {
  final double size;
  final bool autoPlay;
  final VoidCallback? onAnimationComplete;
  final Color? color;
  final Gradient? gradient;
  final bool? useOriginalSize;

  const AnymeXAnimatedLogo({
    super.key,
    this.size = 200,
    this.autoPlay = true,
    this.onAnimationComplete,
    this.color,
    this.gradient,
    this.useOriginalSize,
  });

  @override
  State<AnymeXAnimatedLogo> createState() => _AnymeXAnimatedLogoState();
}

class _AnymeXAnimatedLogoState extends State<AnymeXAnimatedLogo> {
  @override
  void initState() {
    super.initState();
    if (widget.autoPlay && widget.onAnimationComplete != null) {
      // One lap of the fireflies, then carry on.
      Future.delayed(const Duration(milliseconds: 1600), () {
        if (mounted) widget.onAnimationComplete?.call();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    if (s >= 120) {
      return YumoriLoader(size: s, tree: true);
    }
    return Image.asset(
      'assets/images/yumori/tree.png',
      width: s,
      height: s,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }
}
