// AnymeX+ Flutter test 1: does a Flutter app draw at all on the TV?
//
// No plugins, nothing but Flutter itself. If this screen shows, Flutter
// works on the TV; the clock and the moving bar show it keeps drawing, and
// the arrow keys move the highlight between the three boxes.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const TestApp());

class TestApp extends StatelessWidget {
  const TestApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'AnymeX+ Flutter test 1',
        theme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: const Color(0xFF7C4DFF), useMaterial3: true),
        home: const TestPage(),
      );
}

class TestPage extends StatefulWidget {
  const TestPage({super.key});

  @override
  State<TestPage> createState() => _TestPageState();
}

class _TestPageState extends State<TestPage> with SingleTickerProviderStateMixin {
  late final AnimationController _bar =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  late final Timer _clock;
  final _started = DateTime.now();
  int _presses = 0;
  String _lastKey = '-';

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent) {
      setState(() {
        _presses++;
        _lastKey = '${e.logicalKey.keyLabel.isEmpty ? e.logicalKey.debugName : e.logicalKey.keyLabel} (${e.physicalKey.usbHidUsage.toRadixString(16)})';
      });
    }
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _clock.cancel();
    _bar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final up = DateTime.now().difference(_started).inSeconds;
    final size = MediaQuery.sizeOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      body: Padding(
        padding: const EdgeInsets.all(64),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('AnymeX+ Flutter test 1', style: text.displaySmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Text('If you can read this, Flutter draws on your TV.', style: text.headlineSmall),
            const SizedBox(height: 32),
            AnimatedBuilder(
              animation: _bar,
              builder: (_, __) => Container(
                width: 800,
                height: 12,
                alignment: Alignment(_bar.value * 2 - 1, 0),
                decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(6)),
                child: Container(
                    width: 120,
                    decoration: BoxDecoration(color: const Color(0xFF7C4DFF), borderRadius: BorderRadius.circular(6))),
              ),
            ),
            const SizedBox(height: 32),
            Text('Running for $up s  ·  window ${size.width.round()} × ${size.height.round()} at ×$ratio',
                style: text.titleLarge),
            const SizedBox(height: 8),
            Text('Remote presses: $_presses  ·  last: $_lastKey', style: text.titleLarge),
            const SizedBox(height: 40),
            Text('Move between these with the arrows:', style: text.titleMedium),
            const SizedBox(height: 16),
            const Row(children: [_Box('One', autofocus: true), _Box('Two'), _Box('Three')]),
          ],
        ),
      ),
    );
  }
}

class _Box extends StatefulWidget {
  final String label;
  final bool autofocus;
  const _Box(this.label, {this.autofocus = false});

  @override
  State<_Box> createState() => _BoxState();
}

class _BoxState extends State<_Box> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 24),
        child: Focus(
          autofocus: widget.autofocus,
          onFocusChange: (f) => setState(() => _focus = f),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 220,
            height: 130,
            alignment: Alignment.center,
            transform: Matrix4.identity()..scale(_focus ? 1.08 : 1.0),
            decoration: BoxDecoration(
              color: _focus ? const Color(0xFF7C4DFF) : Colors.white10,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _focus ? Colors.white : Colors.transparent, width: 3),
            ),
            child: Text(widget.label, style: Theme.of(context).textTheme.headlineSmall),
          ),
        ),
      );
}
