// AnymeX+ Flutter test 2: a small AnymeX+-style screen with video, to see
// whether Flutter could carry the whole app on the TV.
//
// A row of cards (the same four test videos the first TV test used) and a
// player above them, using LG's own video plugin for Flutter. Pick a card
// with OK; OK again pauses / plays; Back stops the video.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

void main() => runApp(const TestApp());

const _accent = Color(0xFF7C4DFF);

const _videos = <(String, String)>[
  ('MP4 (H.264)', 'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/1080/Big_Buck_Bunny_1080_10s_5MB.mp4'),
  ('MKV (H.264)', 'https://test-videos.co.uk/vids/bigbuckbunny/mkv/1080/Big_Buck_Bunny_1080_10s_5MB.mkv'),
  ('MP4 (HEVC)', 'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h265/1080/Big_Buck_Bunny_1080_10s_5MB.mp4'),
  ('HLS stream', 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
];

class TestApp extends StatelessWidget {
  const TestApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'AnymeX+ Flutter test 2',
        theme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: _accent, useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  VideoPlayerController? _c;
  int _playing = -1;
  String _status = 'Pick a video below and press OK.';
  final _results = <int, String>{};
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_c != null && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _c?.dispose();
    super.dispose();
  }

  Future<void> _play(int i) async {
    if (_playing == i && _c != null && _c!.value.isInitialized) {
      _c!.value.isPlaying ? await _c!.pause() : await _c!.play();
      return;
    }
    final old = _c;
    _c = null;
    await old?.dispose();
    final hls = _videos[i].$2.contains('.m3u8');
    final c = VideoPlayerController.networkUrl(Uri.parse(_videos[i].$2),
        formatHint: hls ? VideoFormat.hls : null);
    setState(() {
      _c = c;
      _playing = i;
      _status = 'Opening ${_videos[i].$1}…';
    });
    c.addListener(() {
      final v = c.value;
      if (v.hasError && _results[i] != 'error') {
        setState(() {
          _results[i] = 'error';
          _status = '${_videos[i].$1}: ${v.errorDescription ?? 'error'}';
        });
      } else if (v.isPlaying && v.position > const Duration(milliseconds: 500) && _results[i] != 'ok') {
        setState(() {
          _results[i] = 'ok';
          _status = '${_videos[i].$1} plays (${v.size.width.round()}×${v.size.height.round()}).';
        });
      }
    });
    try {
      await c.initialize().timeout(const Duration(seconds: 30));
      if (!identical(_c, c)) return;
      await c.setLooping(true);
      await c.play();
    } catch (e) {
      if (identical(_c, c)) {
        setState(() {
          _results[i] = 'error';
          _status = '${_videos[i].$1}: $e';
        });
      }
    }
  }

  Future<void> _stop() async {
    final c = _c;
    setState(() {
      _c = null;
      _playing = -1;
      _status = 'Stopped.';
    });
    await c?.dispose();
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = _c;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.goBack): () => _stop(),
        const SingleActivator(LogicalKeyboardKey.browserBack): () => _stop(),
        const SingleActivator(LogicalKeyboardKey.escape): () => _stop(),
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0E0E12),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(64, 40, 64, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text('AnymeX', style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                Text('+', style: text.headlineMedium?.copyWith(color: _accent, fontWeight: FontWeight.w800)),
                const SizedBox(width: 16),
                Text('Flutter test 2', style: text.titleLarge?.copyWith(color: Colors.white54)),
              ]),
              const SizedBox(height: 20),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    color: Colors.black,
                    alignment: Alignment.center,
                    child: c != null && c.value.isInitialized
                        ? AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))
                        : Icon(Icons.movie_outlined, size: 96, color: Colors.white24),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: Text(_status, style: text.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis)),
                if (c != null && c.value.isInitialized)
                  Text('${_fmt(c.value.position)} / ${_fmt(c.value.duration)}', style: text.titleMedium),
              ]),
              if (c != null && c.value.isInitialized)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: VideoProgressIndicator(c, allowScrubbing: false,
                      colors: const VideoProgressColors(playedColor: _accent)),
                ),
              const SizedBox(height: 20),
              Text('Test videos', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              SizedBox(
                height: 150,
                child: Row(children: [
                  for (var i = 0; i < _videos.length; i++)
                    _Card(
                      label: _videos[i].$1,
                      result: _results[i],
                      playing: _playing == i,
                      autofocus: i == 0,
                      onPress: () => _play(i),
                    ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Card extends StatefulWidget {
  final String label;
  final String? result;
  final bool playing;
  final bool autofocus;
  final VoidCallback onPress;
  const _Card({required this.label, required this.result, required this.playing, required this.autofocus, required this.onPress});

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final mark = switch (widget.result) { 'ok' => '  ✓', 'error' => '  ✗', _ => '' };
    return Padding(
      padding: const EdgeInsets.only(right: 24),
      child: Focus(
        autofocus: widget.autofocus,
        onFocusChange: (f) => setState(() => _focus = f),
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent &&
              (e.logicalKey == LogicalKeyboardKey.enter ||
                  e.logicalKey == LogicalKeyboardKey.select ||
                  e.logicalKey == LogicalKeyboardKey.numpadEnter)) {
            widget.onPress();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 260,
          padding: const EdgeInsets.all(16),
          transform: Matrix4.identity()..scale(_focus ? 1.06 : 1.0),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: widget.playing ? [_accent, const Color(0xFF3D1D99)] : [const Color(0xFF2A2A35), const Color(0xFF1A1A22)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _focus ? Colors.white : Colors.transparent, width: 3),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Icon(widget.playing ? Icons.play_circle_fill : Icons.play_circle_outline, size: 40),
              const Spacer(),
              Text('${widget.label}$mark', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}
