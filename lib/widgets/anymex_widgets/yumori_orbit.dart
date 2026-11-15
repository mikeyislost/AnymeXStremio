import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Draws [child] with a firefly circling its rounded outline.
/// One lap per [lap]; the firefly leaves a fading, tapering tail.
/// Static (no firefly motion, plain outline) when animations are disabled.
class YumoriOrbit extends StatefulWidget {
  final Widget child;
  final double radius;
  final Duration lap;
  final double strokeWidth;
  final Color outline;
  final Color tail;
  final Color firefly;

  const YumoriOrbit({
    super.key,
    required this.child,
    this.radius = 30,
    this.lap = const Duration(seconds: 4),
    this.strokeWidth = 1.2,
    this.outline = const Color(0x59CDB8F7),
    this.tail = const Color(0xFFCDB8F7),
    this.firefly = const Color(0xFFFDE4CA),
  });

  @override
  State<YumoriOrbit> createState() => _YumoriOrbitState();
}

class _YumoriOrbitState extends State<YumoriOrbit>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _t = ValueNotifier<double>(0);
  bool _animate = true;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) {
      _t.value = (d.inMicroseconds / widget.lap.inMicroseconds) % 1.0;
    });
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
    return CustomPaint(
      foregroundPainter: _OrbitPainter(
        t: _t,
        radius: widget.radius,
        stroke: widget.strokeWidth,
        outline: widget.outline,
        tail: widget.tail,
        firefly: widget.firefly,
        showFly: _animate,
      ),
      child: widget.child,
    );
  }
}

class _OrbitPainter extends CustomPainter {
  final ValueNotifier<double> t;
  final double radius, stroke;
  final Color outline, tail, firefly;
  final bool showFly;

  _OrbitPainter({
    required this.t,
    required this.radius,
    required this.stroke,
    required this.outline,
    required this.tail,
    required this.firefly,
    required this.showFly,
  }) : super(repaint: t);

  @override
  void paint(Canvas canvas, Size size) {
    final inset = stroke / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - stroke,
      size.height - stroke,
    );
    final r = math.min(radius, rect.shortestSide / 2);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(r));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = outline,
    );
    if (!showFly) return;

    final metric = (Path()..addRRect(rrect)).computeMetrics().first;
    final len = metric.length;
    final head = t.value * len;
    const segs = 28;
    final tailLen = len * 0.28;
    for (var i = segs - 1; i >= 0; i--) {
      final a = head - tailLen * (i + 1) / segs;
      final b = head - tailLen * i / segs;
      final u = i / segs;
      final seg = _extract(metric, a, b, len);
      canvas.drawPath(
        seg,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke * (2.4 - 1.4 * u)
          ..color = tail.withValues(alpha: 0.9 * math.pow(1 - u, 1.6).toDouble()),
      );
    }
    final tan = metric.getTangentForOffset(head % len);
    if (tan == null) return;
    canvas.drawCircle(
      tan.position,
      6,
      Paint()
        ..color = firefly.withValues(alpha: 0.7)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawCircle(tan.position, 2.4, Paint()..color = firefly);
  }

  Path _extract(ui.PathMetric m, double a, double b, double len) {
    if (a >= 0) return m.extractPath(a, b);
    final p = m.extractPath(len + a, len);
    p.addPath(m.extractPath(0, b < 0 ? 0 : b), Offset.zero);
    return p;
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) =>
      old.radius != radius ||
      old.stroke != stroke ||
      old.outline != outline ||
      old.showFly != showFly;
}
