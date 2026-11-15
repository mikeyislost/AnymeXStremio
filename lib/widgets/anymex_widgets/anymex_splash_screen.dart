import 'package:anymex/theme/yumori_tokens.dart';
import 'package:anymex/widgets/anymex_widgets/yumori_loader.dart';
import 'package:flutter/material.dart';

/// Splash: the Yumori firefly-and-tree loader on night purple.
class AnymeXSplashScreen extends StatefulWidget {
  final VoidCallback? onAnimationComplete;

  const AnymeXSplashScreen({
    super.key,
    this.onAnimationComplete,
  });

  @override
  State<AnymeXSplashScreen> createState() => _AnymeXSplashScreenState();
}

class _AnymeXSplashScreenState extends State<AnymeXSplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2100), () {
      if (mounted) widget.onAnimationComplete?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final side = MediaQuery.sizeOf(context).shortestSide;
    return Scaffold(
      backgroundColor: YumoriColors.surface,
      body: Center(
        child: YumoriLoader(size: (side * 0.6).clamp(160.0, 420.0), tree: true),
      ),
    );
  }
}
