import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// The Yumori loading animation: two fireflies circle the dreaming tree.
///
/// Port of the canvas prototype (Loader.dc.html). Everything is drawn in a
/// 660 x 660 "icon space" and scaled to the widget's size. One lap takes
/// [lap]; the glowing trails are [trail] of a lap long.
class YumoriLoader extends StatefulWidget {
  /// Ignored. Kept so this can replace `ExpressiveLoadingIndicator(color: ..)`.
  final Color? color;
  final double? size;
  final Duration lap;
  final double trail;

  /// Draw the tree. null = automatic: the tree is left out when the loader is
  /// small (rows, buttons, list tiles), where only the fireflies are shown.
  final bool? tree;

  const YumoriLoader({
    super.key,
    this.color,
    this.size,
    this.lap = const Duration(seconds: 4),
    this.trail = 0.42,
    this.tree,
  });

  @override
  State<YumoriLoader> createState() => _YumoriLoaderState();
}

class _YumoriImages {
  static ui.Image? tree;
  static ui.Image? top;
  static ui.Image? bottom;
  static Future<void>? _loading;

  static bool get ready => tree != null && top != null && bottom != null;

  static Future<void> load() {
    return _loading ??= () async {
      Future<ui.Image> read(String name) async {
        final data = await rootBundle.load('assets/images/yumori/$name');
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        return (await codec.getNextFrame()).image;
      }

      final r = await Future.wait([
        read('tree.png'),
        read('ff_top.png'),
        read('ff_bot.png'),
      ]);
      tree = r[0];
      top = r[1];
      bottom = r[2];
    }();
  }
}

class _YumoriLoaderState extends State<YumoriLoader>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _elapsed = ValueNotifier<double>(0);
  bool _animate = true;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) => _elapsed.value = d.inMicroseconds / 1e6);
    if (_YumoriImages.ready) {
      _ticker.start();
    } else {
      _YumoriImages.load().then((_) {
        if (!mounted) return;
        setState(() {});
        if (_animate && !_ticker.isActive) _ticker.start();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate = !MediaQuery.disableAnimationsOf(context);
    if (!_animate) {
      _ticker.stop();
      _elapsed.value = 0;
    } else if (_YumoriImages.ready && !_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      double size = widget.size ?? 0;
      if (size <= 0) {
        final w = c.hasBoundedWidth ? c.maxWidth : double.infinity;
        final h = c.hasBoundedHeight ? c.maxHeight : double.infinity;
        size = math.min(w, h);
        if (!size.isFinite) size = 48;
        // Very large slots (e.g. Center on a whole page) get a sensible cap.
        size = size.clamp(16.0, 160.0);
      }
      final withTree = widget.tree ?? size >= 64;
      // Fireflies only: crop to the band the orbit occupies (2:1).
      final height = withTree ? size : size * 0.5;
      if (!_YumoriImages.ready) return SizedBox(width: size, height: height);
      return RepaintBoundary(
        child: SizedBox(
          width: size,
          height: height,
          child: CustomPaint(
            painter: _LoaderPainter(
              elapsed: _elapsed,
              lap: widget.lap.inMicroseconds / 1e6,
              trail: widget.trail,
              small: size < 120,
              tree: withTree,
            ),
          ),
        ),
      );
    });
  }
}

class _Fly {
  final double t;
  final ui.Image img;
  final double ax;
  final double ay;
  const _Fly(this.t, this.img, this.ax, this.ay);
}

class _Pt {
  final double x, y, nx, ny, w, u;
  final bool front;
  const _Pt(this.x, this.y, this.nx, this.ny, this.w, this.u, this.front);
}

class _Pos {
  final double x, y, depth;
  const _Pos(this.x, this.y, this.depth);
}

class _LoaderPainter extends CustomPainter {
  final ValueNotifier<double> elapsed;
  final double lap;
  final double trail;
  final bool small;
  final bool tree;

  _LoaderPainter({
    required this.elapsed,
    required this.lap,
    required this.trail,
    required this.small,
    required this.tree,
  }) : super(repaint: elapsed);

  static const double _cx = 346, _cy = 263, _a = 270, _b = 109;
  static final double _phi = -14 * math.pi / 180;

  _Pos _pos(double t) {
    final x = _a * math.cos(t), y = _b * math.sin(t);
    return _Pos(
      _cx + x * math.cos(_phi) - y * math.sin(_phi),
      _cy + x * math.sin(_phi) + y * math.cos(_phi),
      math.sin(t),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final e = elapsed.value;
    final base = (e / lap) * math.pi * 2;
    final t0 = -49.8 * math.pi / 180;
    final flies = [
      _Fly(t0 + base, _YumoriImages.top!, 64, 64),
      _Fly(t0 + math.pi + base, _YumoriImages.bottom!, 28, 54),
    ];
    canvas.save();
    canvas.scale(size.width / 660, size.width / 660);
    if (!tree) canvas.translate(0, -98);
    final trailLen = trail * math.pi * 2;
    for (var pass = 0; pass < 2; pass++) {
      if (pass == 1 && tree) _drawTree(canvas, e);
      for (final f in flies) {
        _drawTrail(canvas, f.t, trailLen, pass);
      }
      for (final f in flies) {
        final p = _pos(f.t);
        if ((p.depth > 0 ? 1 : 0) == pass) _drawFly(canvas, f, p, e);
      }
    }
    canvas.restore();
  }

  void _drawTree(Canvas canvas, double e) {
    final pulse = 0.5 + 0.5 * math.sin(e * 2 * math.pi / 3.4);
    final glow = Paint()
      ..shader = ui.Gradient.radial(
        const Offset(330, 330),
        300,
        [
          Color.fromRGBO(190, 165, 245, 0.16 + 0.12 * pulse),
          const Color.fromRGBO(190, 165, 245, 0),
        ],
      );
    canvas.drawRect(const Rect.fromLTWH(0, 0, 660, 660), glow);
    final tree = _YumoriImages.tree!;
    canvas.drawImageRect(
      tree,
      Rect.fromLTWH(0, 0, tree.width.toDouble(), tree.height.toDouble()),
      const Rect.fromLTWH(0, 0, 660, 660),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  void _drawTrail(Canvas canvas, double t, double len, int pass) {
    const n = 90;
    final w0 = small ? 8.0 : 5.2;
    final pts = <_Pt>[];
    for (var i = 0; i < n; i++) {
      final u = i / (n - 1), tt = t - u * len;
      final p = _pos(tt), q = _pos(tt + 0.004);
      var tx = q.x - p.x, ty = q.y - p.y;
      final m = math.sqrt(tx * tx + ty * ty);
      final mm = m == 0 ? 1.0 : m;
      tx /= mm;
      ty /= mm;
      final sc = 0.82 + 0.18 * ((p.depth + 1) / 2);
      final w = w0 * math.pow(1 - u, 1.15) * sc + 0.25;
      pts.add(_Pt(p.x, p.y, -ty, tx, w, u, p.depth > 0));
    }
    var run = <_Pt>[];
    void flush() {
      if (run.length > 1 && (run[0].front ? 1 : 0) == pass) {
        _ribbon(canvas, run);
      }
      run = <_Pt>[];
    }

    for (final p in pts) {
      if (run.isNotEmpty && p.front != run.last.front) {
        final keep = run.last;
        flush();
        run.add(keep);
      }
      run.add(p);
    }
    flush();
  }

  double _alpha(double u) => 0.95 * math.pow(1 - u, 1.5).toDouble();

  void _ribbon(Canvas canvas, List<_Pt> run) {
    final path = Path();
    for (var i = 0; i < run.length; i++) {
      final p = run[i];
      final x = p.x + p.nx * p.w / 2, y = p.y + p.ny * p.w / 2;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    for (var i = run.length - 1; i >= 0; i--) {
      final p = run[i];
      path.lineTo(p.x - p.nx * p.w / 2, p.y - p.ny * p.w / 2);
    }
    path.close();
    final a = run.first, b = run.last;
    final from = Offset(a.x, a.y), to = Offset(b.x, b.y);
    if (!small) {
      final glow = Paint()
        ..shader = ui.Gradient.linear(from, to, [
          Color.fromRGBO(255, 190, 110, 0.85 * _alpha(a.u)),
          Color.fromRGBO(255, 190, 110, 0.85 * _alpha(b.u)),
        ])
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawPath(path, glow);
    }
    final fill = Paint()
      ..shader = ui.Gradient.linear(from, to, [
        Color.fromRGBO(255, 216, 155, _alpha(a.u)),
        Color.fromRGBO(255, 216, 155, _alpha(b.u)),
      ]);
    canvas.drawPath(path, fill);
    if (a.u == 0) {
      canvas.drawCircle(
        from,
        a.w / 2,
        Paint()..color = Color.fromRGBO(255, 216, 155, _alpha(0)),
      );
    }
  }

  void _drawFly(Canvas canvas, _Fly f, _Pos p, double e) {
    final ahead = _pos(f.t + 0.01);
    final vx = ahead.x - p.x, vy = ahead.y - p.y;
    final len = math.sqrt(vx * vx + vy * vy);
    final c = vx / (len == 0 ? 1 : len);
    final sign = c == 0 ? 1.0 : c.sign;
    final face = sign * math.max(0.16, math.pow(c.abs(), 0.7).toDouble());
    final tilt = math.max(
          -0.3,
          math.min(0.3, math.atan2(vy, vx.abs() + 0.001) * 0.4),
        ) *
        face.sign;
    final scale = (0.8 + 0.22 * ((p.depth + 1) / 2)) * (small ? 1.25 : 1.0);
    final bob = math.sin(e * 9 + f.t) * 1.5;
    final center = Offset(p.x, p.y + bob);
    canvas.drawCircle(
      center,
      34 * scale,
      Paint()
        ..shader = ui.Gradient.radial(center, 34 * scale, const [
          Color.fromRGBO(255, 220, 150, 0.5),
          Color.fromRGBO(255, 220, 150, 0),
        ]),
    );
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(tilt);
    canvas.scale(face * scale, scale);
    canvas.translate(-(f.ax + 6), -(f.ay + 6));
    canvas.scale(0.5, 0.5);
    canvas.drawImage(
      f.img,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LoaderPainter old) =>
      old.lap != lap ||
      old.trail != trail ||
      old.small != small ||
      old.tree != tree;
}

/// Determinate progress: a lavender ring with a cream firefly at the tip.
class YumoriRing extends StatelessWidget {
  final double value;
  final double strokeWidth;
  final Color? backgroundColor;
  final double? size;
  final Color? color;

  const YumoriRing({
    super.key,
    required this.value,
    this.strokeWidth = 4,
    this.backgroundColor,
    this.size,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      double s = size ?? 0;
      if (s <= 0) {
        final w = c.hasBoundedWidth ? c.maxWidth : double.infinity;
        final h = c.hasBoundedHeight ? c.maxHeight : double.infinity;
        s = math.min(w, h);
        if (!s.isFinite) s = 36;
      }
      return SizedBox(
        width: s,
        height: s,
        child: CustomPaint(
          painter: _RingPainter(
            value.clamp(0.0, 1.0),
            strokeWidth,
            backgroundColor ?? const Color(0x1FFFFFFF),
            color ?? const Color(0xFFCDB8F7),
          ),
        ),
      );
    });
  }
}

class _RingPainter extends CustomPainter {
  final double value;
  final double stroke;
  final Color track;
  final Color arc;
  _RingPainter(this.value, this.stroke, this.track, this.arc);

  static const _lavender = Color(0xFFCDB8F7);
  static const _firefly = Color(0xFFFDE4CA);

  @override
  void paint(Canvas canvas, Size size) {
    final r = (math.min(size.width, size.height) - stroke) / 2;
    final center = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: center, radius: r);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    if (value <= 0) return;
    final sweep = math.pi * 2 * value;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = arc,
    );
    final ang = -math.pi / 2 + sweep;
    final tip = center + Offset(math.cos(ang), math.sin(ang)) * r;
    canvas.drawCircle(
      tip,
      stroke * 1.4,
      Paint()
        ..color = const Color(0xB3FDE4CA)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke),
    );
    canvas.drawCircle(tip, stroke * 0.75, Paint()..color = _firefly);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.value != value || old.stroke != stroke || old.track != track || old.arc != arc;
}
