import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A loading placeholder: a night-purple block with a soft lavender sweep and
/// a small cream firefly drifting across it. Use it where a card or tile will
/// appear. Stops moving when animations are disabled.
class YumoriSkeleton extends StatefulWidget {
  final double? width;
  final double? height;
  final double radius;

  /// Seconds of delay so neighbouring placeholders don't move in lockstep.
  final double phase;

  const YumoriSkeleton({
    super.key,
    this.width,
    this.height,
    this.radius = 16,
    this.phase = 0,
  });

  @override
  State<YumoriSkeleton> createState() => _YumoriSkeletonState();
}

class _YumoriSkeletonState extends State<YumoriSkeleton>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _t = ValueNotifier<double>(0);
  bool _animate = true;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) => _t.value = d.inMicroseconds / 1e6);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate = !MediaQuery.disableAnimationsOf(context);
    if (_animate && !_ticker.isActive) {
      _ticker.start();
    } else if (!_animate && _ticker.isActive) {
      _ticker.stop();
      _t.value = 0;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: CustomPaint(
          painter: _SkeletonPainter(_t, widget.radius, widget.phase, _animate),
        ),
      ),
    );
  }
}

class _SkeletonPainter extends CustomPainter {
  final ValueNotifier<double> t;
  final double radius, phase;
  final bool animate;

  _SkeletonPainter(this.t, this.radius, this.phase, this.animate)
      : super(repaint: t);

  static const _base = Color(0xFF1B152A);
  static const _lavender = Color(0xFFCDB8F7);
  static const _firefly = Color(0xFFFDE4CA);

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, Radius.circular(radius));
    canvas.drawRRect(rrect, Paint()..color = _base);
    final s = t.value + phase;

    canvas.save();
    canvas.clipRRect(rrect);
    // Soft sweep, 2.6 s per pass.
    final sweep = ((s / 2.6) % 1.0) * 1.8 - 0.4;
    final x = size.width * sweep;
    final band = size.width * 0.45;
    canvas.drawRect(
      Rect.fromLTWH(x - band, 0, band * 2, size.height),
      Paint()
        ..shader = ui_linear(x - band, x + band),
    );
    canvas.restore();

    if (!animate) {
      _fly(canvas, Offset(size.width * 0.5, size.height * 0.5), 1);
      return;
    }
    // Firefly drifts in a lazy figure-eight around the middle.
    final a = s * 2 * math.pi / 5.2;
    final c = Offset(size.width / 2, size.height / 2);
    final p = c +
        Offset(
          math.sin(a) * size.width * 0.28,
          math.sin(a * 2) * size.height * 0.12,
        );
    final glow = 0.75 + 0.25 * math.sin(s * 5);
    _fly(canvas, p, glow);
  }

  Shader ui_linear(double a, double b) => LinearGradient(
        colors: [
          _lavender.withValues(alpha: 0),
          _lavender.withValues(alpha: 0.09),
          _lavender.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromLTRB(a, 0, b, 1));

  void _fly(Canvas canvas, Offset p, double glow) {
    canvas.drawCircle(
      p,
      9,
      Paint()
        ..color = _firefly.withValues(alpha: 0.55 * glow)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(p, 2.2, Paint()..color = _firefly);
  }

  @override
  bool shouldRepaint(covariant _SkeletonPainter old) =>
      old.radius != radius || old.animate != animate || old.phase != phase;
}
