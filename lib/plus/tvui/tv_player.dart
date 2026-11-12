import 'dart:async';
import 'dart:convert';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/plus/skip_times.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/tv/subtitle_vtt.dart';
import 'package:anymex/plus/tv/tv_anime.dart';
import 'package:anymex/plus/tvui/tv_local_proxy.dart';
import 'package:anymex/plus/tvui/tv_playable.dart';
import 'package:anymex/plus/tvui/tv_shell.dart';
import 'package:anymex/plus/tvui/tv_sources.dart';
import 'package:anymex/plus/tvui/tv_widgets.dart';
import 'package:anymex/utils/aniskip.dart' as aniskip;
import 'package:anymex/utils/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

/// The player opens without a fade: LG's video sits under the app and only
/// shows once the page has stopped moving.
Route<T> tvPlayerRoute<T>(Widget page) => PageRouteBuilder<T>(
      pageBuilder: (ctx, __, ___) => Theme(data: PlusTvUi.theme(ctx), child: Scaffold(backgroundColor: Colors.black, body: page)),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );

class _Sub {
  final String label;
  final String lang;
  final String url;
  const _Sub(this.label, this.lang, this.url);
}

enum _Panel { none, subs, speed, eps }

/// AnymeX+ TV player (LG's own video player, through Flutter): Stremio-style
/// controls, sources, subtitles, speed, episodes, skip intro and next
/// episode. Progress goes to Stremio (and AniList for anime).
///
/// Remote: OK pauses/plays, Left/Right skip 10 s (hold to go faster), Up or
/// Down show the controls, the play/pause/⏪/⏩/stop keys work too.
class TvPlayerPage extends StatefulWidget {
  final TvPlayable playable;
  final TvEp ep;
  final StremioStream stream;
  final List<StremioStream> streams;
  final Duration startAt;
  const TvPlayerPage({super.key, required this.playable, required this.ep, required this.stream, required this.streams, this.startAt = Duration.zero});

  @override
  State<TvPlayerPage> createState() => _TvPlayerPageState();
}

class _TvPlayerPageState extends State<TvPlayerPage> {
  static const _kSubLang = 'plus_tv_sub_lang';
  static const _speeds = [0.75, 1.0, 1.25, 1.5, 2.0];

  late TvEp _ep = widget.ep;
  late StremioStream _stream = widget.stream;

  VideoPlayerController? _c;
  int _opening = 0;
  String _status = '';
  String _error = '';
  bool _controls = true;
  _Panel _panel = _Panel.none;
  Timer? _hide;
  Timer? _tick;
  Timer? _seekTimer;
  Duration? _seekTo;
  int _repeat = 0;
  bool _ended = false;
  bool _marked = false;
  bool _stopSent = false;
  double _speed = 1.0;

  List<_Sub> _subs = const [];
  int _sub = -1;
  aniskip.EpisodeSkipTimes? _skip;

  final _root = FocusNode(debugLabel: 'player');
  final _playNode = FocusNode(debugLabel: 'play');
  final _barNode = FocusNode(debugLabel: 'bar');
  final _skipNode = FocusNode(debugLabel: 'skip');
  final _panelScope = FocusScopeNode(debugLabel: 'panel');

  TvEp? get _next => widget.playable.isMovie ? null : widget.playable.next(_ep);

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_open(widget.startAt));
    });
  }

  @override
  void dispose() {
    _report(stopped: true);
    _hide?.cancel();
    _tick?.cancel();
    _seekTimer?.cancel();
    final c = _c;
    _c = null;
    unawaited(c?.dispose());
    _root.dispose();
    _playNode.dispose();
    _barNode.dispose();
    _skipNode.dispose();
    _panelScope.dispose();
    super.dispose();
  }

  // ---- opening ------------------------------------------------------------

  Future<void> _open(Duration startAt) async {
    final id = ++_opening;
    final old = _c;
    setState(() {
      _c = null;
      _error = '';
      _ended = false;
      _skip = null;
      _status = 'Opening ${_stream.addonName}…';
    });
    await old?.dispose();
    try {
      final r = await TvLocalProxy.instance.route(_stream.url!, _stream.requestHeaders);
      if (id != _opening || !mounted) return;
      final c = VideoPlayerController.networkUrl(Uri.parse(r.url), formatHint: r.kind == 'hls' ? VideoFormat.hls : null);
      setState(() => _c = c);
      c.addListener(_onValue);
      await c.initialize().timeout(const Duration(seconds: 45));
      if (id != _opening || !mounted) return;
      var at = startAt;
      if (at == Duration.zero) at = _resumePoint(c.value.duration);
      if (at > Duration.zero) await c.seekTo(at);
      if (_speed != 1.0) await c.setPlaybackSpeed(_speed);
      await c.play();
      if (!mounted) return;
      _stopSent = false;
      setState(() => _status = '');
      _showControls();
      unawaited(_loadSubs(id));
      unawaited(_loadSkip(id, c.value.duration));
      _prefetchNext();
    } catch (e) {
      if (id != _opening || !mounted) return;
      Logger.i('TV player: ${_stream.addonName} failed: $e');
      setState(() {
        _status = '';
        _error = _explain(e.toString());
      });
      _showControls(stay: true);
    }
  }

  String _explain(String e) {
    if (e.contains('Timeout')) return "This source didn't start in time.";
    if (tvNoSound(_stream)) return "This source didn't play (its DTS sound doesn't work on LG TVs).";
    return "This source doesn't play on the TV.";
  }

  Duration _resumePoint(Duration dur) {
    try {
      final (media, episode) = widget.playable.reportFor(_ep);
      final ms = StremioService.to.resumePositionMs(media, episode);
      if (ms > 30000 && (dur.inMilliseconds == 0 || ms < dur.inMilliseconds * 0.95)) return Duration(milliseconds: ms);
    } catch (_) {}
    return Duration.zero;
  }

  void _onValue() {
    final c = _c;
    if (c == null || !mounted) return;
    final v = c.value;
    if (v.hasError && _error.isEmpty && _status.isEmpty) {
      setState(() => _error = _explain(v.errorDescription ?? ''));
      _showControls(stay: true);
      return;
    }
    final done = v.isCompleted ||
        (v.duration > Duration.zero && v.position >= v.duration - const Duration(milliseconds: 400) && !v.isPlaying && !v.isBuffering);
    if (done && !_ended && v.isInitialized) {
      _ended = true;
      unawaited(_finished());
    }
  }

  Future<void> _finished() async {
    _markWatched();
    _report(stopped: true);
    final next = _next;
    if (next != null) {
      await _playEp(next);
    } else if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  // ---- episodes and sources -------------------------------------------------

  void _prefetchNext() {
    final n = _next;
    if (n != null) StremioService.to.prefetchStreams(widget.playable.type, n.videoId);
  }

  /// Plays [ep] with a source like the current one (same addon, same
  /// "binge group" or quality); asks when there's none.
  Future<void> _playEp(TvEp ep) async {
    _report(stopped: true);
    setState(() {
      _panel = _Panel.none;
      _status = 'Finding ${ep.label}…';
      _error = '';
    });
    final old = _stream;
    List<StremioStream> found = const [];
    try {
      found = (await StremioService.to.fetchStreams(widget.playable.type, ep.videoId)).where(tvCanPlay).toList();
    } catch (_) {}
    if (!mounted) return;
    StremioStream? pick;
    pick = found.where((s) => s.addonName == old.addonName && old.bingeGroup != null && s.bingeGroup == old.bingeGroup).firstOrNull;
    pick ??= found.where((s) => s.addonName == old.addonName && s.quality == old.quality).firstOrNull;
    pick ??= found.where((s) => s.addonName == old.addonName).firstOrNull;
    if (pick == null) {
      final chosen = await Navigator.of(context).push<StremioStream>(tvRoute(TvSourcesPage(playable: widget.playable, ep: ep, pick: true)));
      if (!mounted) return;
      if (chosen == null) {
        setState(() => _status = '');
        if (_c == null || _ended) Navigator.of(context).maybePop();
        return;
      }
      pick = chosen;
    }
    setState(() {
      _ep = ep;
      _stream = pick!;
      _marked = false;
      _sub = -1;
      _subs = const [];
    });
    await _open(Duration.zero);
  }

  Future<void> _pickSource() async {
    final at = _c?.value.position ?? Duration.zero;
    setState(() => _panel = _Panel.none);
    final chosen = await Navigator.of(context).push<StremioStream>(tvRoute(TvSourcesPage(playable: widget.playable, ep: _ep, pick: true)));
    if (chosen == null || !mounted) {
      _playNode.requestFocus();
      return;
    }
    setState(() => _stream = chosen);
    await _open(at > const Duration(seconds: 5) ? at : Duration.zero);
  }

  // ---- subtitles ------------------------------------------------------------

  static const _langs = {
    'eng': 'English', 'en': 'English', 'spa': 'Spanish', 'es': 'Spanish', 'fre': 'French', 'fra': 'French', 'fr': 'French',
    'ger': 'German', 'deu': 'German', 'de': 'German', 'ita': 'Italian', 'it': 'Italian', 'por': 'Portuguese', 'pob': 'Portuguese (BR)',
    'pt': 'Portuguese', 'jpn': 'Japanese', 'ja': 'Japanese', 'ara': 'Arabic', 'rus': 'Russian', 'chi': 'Chinese', 'zho': 'Chinese',
    'kor': 'Korean', 'dut': 'Dutch', 'nld': 'Dutch', 'pol': 'Polish', 'tur': 'Turkish', 'swe': 'Swedish', 'hin': 'Hindi',
  };

  static String _langName(String l) => _langs[l.toLowerCase()] ?? (l.isEmpty ? 'Unknown' : l);

  Future<void> _loadSubs(int id) async {
    final st = StremioService.to;
    final out = <_Sub>[
      for (final s in _stream.subtitles)
        if ((s['url'] ?? '').isNotEmpty) _Sub('${_langName(s['lang'] ?? '')} · ${_stream.addonName}', (s['lang'] ?? '').toLowerCase(), s['url']!),
    ];
    final type = widget.playable.type;
    final vid = _ep.videoId;
    final addons = st.addons.where((a) => st.isAddonUsable(a) && a.supports('subtitles', type, vid)).toList();
    await Future.wait(addons.map((a) async {
      try {
        final list = await st.api.subtitles(a, type, vid).timeout(const Duration(seconds: 15));
        for (final s in list) {
          out.add(_Sub('${_langName(s['lang'] ?? '')} · ${a.name}', (s['lang'] ?? '').toLowerCase(), s['url']!));
        }
      } catch (_) {}
    }));
    if (id != _opening || !mounted) return;
    out.sort((a, b) => a.label.compareTo(b.label));
    setState(() => _subs = out);
    final want = KvHelper.get<String>(_kSubLang, defaultVal: '');
    if (want.isNotEmpty) {
      final i = out.indexWhere((s) => s.lang == want);
      if (i >= 0) unawaited(_setSub(i, remember: false));
    }
  }

  Future<void> _setSub(int i, {bool remember = true}) async {
    final c = _c;
    if (c == null) return;
    setState(() {
      _sub = i;
      _panel = _Panel.none;
    });
    if (i < 0) {
      await c.setClosedCaptionFile(null);
      if (remember) KvHelper.set(_kSubLang, '');
      return;
    }
    final s = _subs[i];
    if (remember) KvHelper.set(_kSubLang, s.lang);
    try {
      final resp = await http.get(Uri.parse(s.url)).timeout(const Duration(seconds: 20));
      if (resp.statusCode >= 400) throw Exception('HTTP ${resp.statusCode}');
      final vtt = plusSubtitleToVtt(utf8.decode(resp.bodyBytes, allowMalformed: true));
      if (!mounted || _sub != i || !identical(c, _c)) return;
      await c.setClosedCaptionFile(Future.value(WebVTTCaptionFile(vtt)));
    } catch (e) {
      Logger.i('TV subtitle failed: $e');
      if (mounted && _sub == i) {
        setState(() => _sub = -1);
        tvToast(context, "That subtitle didn't load. Try another one.");
      }
    }
  }

  // ---- skip intro -------------------------------------------------------------

  Future<void> _loadSkip(int id, Duration dur) async {
    aniskip.EpisodeSkipTimes? t;
    try {
      final p = widget.playable;
      if (p.isAnime) {
        if (p.item.idMal.isNotEmpty) {
          t = await aniskip.AniSkipApi().getSkipTimes(
              aniskip.SkipSearchQuery(idMAL: p.item.idMal, episodeNumber: '${_ep.number}', episodeLength: dur.inSeconds));
        }
      } else {
        final (media, _) = p.reportFor(_ep);
        final target = PlusSkipTimes.targetFor(media.id, _ep.videoId);
        if (target != null) t = await PlusSkipTimes.load(target, durationMs: dur.inMilliseconds);
      }
    } catch (_) {}
    if (id != _opening || !mounted) return;
    setState(() => _skip = t);
  }

  /// The skip button showing now: (label, where it jumps to).
  (String, Duration)? get _skipNow {
    final c = _c, t = _skip;
    if (c == null || t == null || !c.value.isInitialized) return null;
    final s = c.value.position.inSeconds;
    for (final (iv, label) in [(t.recap, 'Skip recap'), (t.op, 'Skip intro'), (t.ed, 'Skip credits')]) {
      if (iv == null || iv.end <= iv.start) continue;
      if (s >= iv.start && s < iv.end - 1) {
        if (label == 'Skip credits' && _next != null && iv.end >= c.value.duration.inSeconds - 5) return ('Next episode', Duration.zero);
        return (label, Duration(seconds: iv.end));
      }
    }
    return null;
  }

  void _doSkip() {
    final s = _skipNow;
    if (s == null) return;
    if (s.$1 == 'Next episode') {
      final n = _next;
      if (n != null) {
        _markWatched();
        unawaited(_playEp(n));
      }
      return;
    }
    unawaited(_c?.seekTo(s.$2));
  }

  // ---- progress ----------------------------------------------------------------

  void _onTick() {
    if (!mounted) return;
    final c = _c;
    if (c != null && c.value.isInitialized && c.value.isPlaying) {
      _report();
      final d = c.value.duration.inMilliseconds;
      if (d > 0 && c.value.position.inMilliseconds >= d * 0.85) _markWatched();
    }
    setState(() {}); // clock, bar
  }

  void _report({bool stopped = false}) {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    if (stopped) {
      if (_stopSent) return;
      _stopSent = true;
    }
    try {
      final (media, episode) = widget.playable.reportFor(_ep);
      final st = StremioService.to;
      if (stopped) {
        st.onPlaybackStopped(media: media, episode: episode, position: c.value.position, duration: c.value.duration);
      } else {
        st.onPlaybackProgress(media: media, episode: episode, position: c.value.position, duration: c.value.duration);
      }
    } catch (_) {}
  }

  void _markWatched() {
    if (_marked) return;
    _marked = true;
    final p = widget.playable;
    if (p.isAnime) unawaited(PlusTvAnime.markWatched(p.item.id, _ep.number));
  }

  // ---- controls -----------------------------------------------------------------

  void _showControls({bool stay = false, bool focusBar = false}) {
    _hide?.cancel();
    if (!_controls) setState(() => _controls = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _panel != _Panel.none) return;
      final f = FocusManager.instance.primaryFocus;
      if (focusBar) {
        _barNode.requestFocus();
      } else if (f == null || f == _root || !f.hasPrimaryFocus || f.context == null) {
        _playNode.requestFocus();
      }
    });
    if (!stay) _armHide();
  }

  void _armHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 5), () {
      final c = _c;
      if (!mounted || _panel != _Panel.none || _error.isNotEmpty || c == null || !c.value.isPlaying) return;
      setState(() => _controls = false);
      _root.requestFocus();
    });
  }

  void _togglePlay() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    c.value.isPlaying ? c.pause() : c.play();
    setState(() {});
  }

  void _seekBy(int seconds, {bool held = false}) {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    _repeat = held ? _repeat + 1 : 0;
    final step = _repeat > 15 ? 60 : (_repeat > 5 ? 30 : 10);
    final from = _seekTo ?? c.value.position;
    var to = from + Duration(seconds: seconds.sign * (held ? step : seconds.abs()));
    if (to < Duration.zero) to = Duration.zero;
    if (to > c.value.duration) to = c.value.duration;
    setState(() => _seekTo = to);
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 600), () {
      final t = _seekTo;
      _seekTo = null;
      if (t != null && identical(c, _c)) {
        _ended = false;
        unawaited(c.seekTo(t));
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _close() async {
    _report(stopped: true);
    if (mounted) Navigator.of(context).maybePop();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final held = e is KeyRepeatEvent;
    if (k == LogicalKeyboardKey.mediaPlayPause || k == LogicalKeyboardKey.mediaPlay || k == LogicalKeyboardKey.mediaPause) {
      final c = _c;
      if (c != null) {
        if (k == LogicalKeyboardKey.mediaPlay) {
          c.play();
        } else if (k == LogicalKeyboardKey.mediaPause) {
          c.pause();
        } else {
          _togglePlay();
        }
      }
      _showControls();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(30, held: held);
      _showControls(focusBar: true);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-10, held: held);
      _showControls(focusBar: true);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaStop) {
      unawaited(_close());
      return KeyEventResult.handled;
    }
    if (tvIsBack(k)) {
      if (_panel != _Panel.none) {
        _closePanel();
      } else if (_controls && _error.isEmpty && _c != null) {
        setState(() => _controls = false);
        _root.requestFocus();
      } else {
        unawaited(_close());
      }
      return KeyEventResult.handled;
    }
    if (_panel != _Panel.none) return KeyEventResult.ignored;
    if (!_controls) {
      if (tvIsSelect(k)) {
        if (_skipNow != null) {
          _doSkip();
        } else {
          _togglePlay();
          _showControls();
        }
      } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
        _seekBy(k == LogicalKeyboardKey.arrowLeft ? -10 : 10, held: held);
        _showControls(focusBar: true);
      } else if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
        _showControls();
      }
      return KeyEventResult.handled;
    }
    _armHide();
    return KeyEventResult.ignored;
  }

  KeyEventResult _onBarKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      _seekBy(k == LogicalKeyboardKey.arrowLeft ? -10 : 10, held: e is KeyRepeatEvent);
      _armHide();
      return KeyEventResult.handled;
    }
    if (tvIsSelect(k)) {
      _togglePlay();
      _armHide();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _playNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      if (_skipNow != null) _skipNode.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _openPanel(_Panel p) {
    _hide?.cancel();
    setState(() => _panel = p);
  }

  void _closePanel() {
    setState(() => _panel = _Panel.none);
    _showControls();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playNode.requestFocus();
    });
  }

  // ---- drawing --------------------------------------------------------------------

  static String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0'), ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  static String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final v = c?.value;
    final ready = v != null && v.isInitialized;
    final pos = _seekTo ?? v?.position ?? Duration.zero;
    final dur = v?.duration ?? Duration.zero;
    final accent = TvStyle.accent(context);
    final skip = _skipNow;
    final p = widget.playable;
    final showUi = _controls || _error.isNotEmpty || !ready;
    final now = DateTime.now();
    final left = dur - pos;
    final caption = v?.caption.text.replaceAll(RegExp(r'<[^>]+>'), '').trim() ?? '';

    return Focus(
      focusNode: _root,
      autofocus: true,
      onKeyEvent: _onKey,
      child: MouseRegion(
        onHover: (e) {
          if (!_controls && e.delta.distance > 4) _showControls();
        },
        child: Stack(children: [
          if (c != null)
            Positioned.fill(
              child: Center(
                child: AspectRatio(
                  aspectRatio: ready && v!.aspectRatio > 0 ? v.aspectRatio : 16 / 9,
                  child: VideoPlayer(c),
                ),
              ),
            ),
          if (caption.isNotEmpty && _sub >= 0)
            Positioned(
              left: 160,
              right: 160,
              bottom: showUi ? 330 : 90,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(8)),
                  child: Text(caption,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 40, height: 1.3, fontWeight: FontWeight.w600, color: Colors.white, shadows: [Shadow(blurRadius: 4)])),
                ),
              ),
            ),
          if (_status.isNotEmpty || (!ready && _error.isEmpty))
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 64, height: 64, child: CircularProgressIndicator(strokeWidth: 5, color: accent)),
                const SizedBox(height: 26),
                Text(_status.isEmpty ? 'Loading…' : _status, style: const TextStyle(fontSize: 24, color: TvStyle.text2)),
              ]),
            )
          else if (ready && v!.isBuffering)
            Center(child: SizedBox(width: 64, height: 64, child: CircularProgressIndicator(strokeWidth: 5, color: accent))),
          if (showUi) ...[
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 240,
              child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xD9000000), Color(0x00000000)]))),
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 420,
              child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color(0xEB000000), Color(0x00000000)]))),
            ),
            Positioned(
              left: 80,
              right: 80,
              top: 56,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w700, color: Colors.white)),
                    const SizedBox(height: 6),
                    Text(
                      [if (!p.isMovie) '${_ep.label} · ${_ep.title}', _stream.addonName].join('   •   '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 22, color: TvStyle.text2),
                    ),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(_clock(now), style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w600, color: Colors.white)),
                  if (ready && dur > Duration.zero)
                    Text('Ends at ${_clock(now.add(Duration(milliseconds: (left.inMilliseconds / _speed).round())))}',
                        style: const TextStyle(fontSize: 19, color: Color(0xFF9A9A9A))),
                ]),
              ]),
            ),
          ],
          if (skip != null)
            Positioned(
              right: 80,
              bottom: showUi ? 300 : 90,
              child: TvFocusable(
                focusNode: _skipNode,
                autoScroll: false,
                onSelect: _doSkip,
                builder: (context, f) => Container(
                  height: 60,
                  padding: const EdgeInsets.symmetric(horizontal: 30),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: f ? Colors.white : Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: f ? 1 : 0.5), width: 2),
                  ),
                  child: Text(_controls ? skip.$1 : '${skip.$1}  (OK)', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600, color: f ? Colors.black : Colors.white)),
                ),
              ),
            ),
          if (showUi)
            Positioned(
              left: 80,
              right: 80,
              bottom: 80,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 26),
                    child: Text(_error, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: Colors.white)),
                  ),
                if (ready) _bar(pos, dur, v!, accent),
                const SizedBox(height: 22),
                Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: (node, e) {
                    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.arrowUp) {
                      if (ready) {
                        _barNode.requestFocus();
                      } else if (skip != null) {
                        _skipNode.requestFocus();
                      }
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Row(children: [
                    _round(),
                    const SizedBox(width: 14),
                    if (_next != null) _btn('Next episode', () => unawaited(_playEp(_next!))),
                    _btn(_sub >= 0 ? 'Subtitles: ${_subs[_sub].label.split(' · ').first}' : 'Subtitles', () => _openPanel(_Panel.subs)),
                    _btn(_error.isNotEmpty ? 'Try another source' : 'Source', () => unawaited(_pickSource())),
                    if (!p.isMovie) _btn('Episodes', () => _openPanel(_Panel.eps)),
                    _btn('Speed ${_speed == 1.0 ? '1' : _speed}×', () => _openPanel(_Panel.speed)),
                    _btn('Close', () => unawaited(_close())),
                  ]),
                ),
              ]),
            ),
          if (_panel != _Panel.none) _panelView(),
        ]),
      ),
    );
  }

  Widget _bar(Duration pos, Duration dur, VideoPlayerValue v, Color accent) {
    final total = dur.inMilliseconds <= 0 ? 1 : dur.inMilliseconds;
    final played = (pos.inMilliseconds / total).clamp(0.0, 1.0);
    var buffered = 0.0;
    for (final r in v.buffered) {
      if (r.end.inMilliseconds / total > buffered) buffered = (r.end.inMilliseconds / total).clamp(0.0, 1.0);
    }
    return Focus(
      focusNode: _barNode,
      onKeyEvent: _onBarKey,
      child: Builder(builder: (context) {
        final f = Focus.of(context).hasFocus;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: 28,
            child: LayoutBuilder(builder: (context, box) {
              final w = box.maxWidth;
              final h = f ? 10.0 : 8.0;
              return Stack(clipBehavior: Clip.none, alignment: Alignment.centerLeft, children: [
                Container(height: h, decoration: BoxDecoration(color: const Color(0xFF3A3A3A), borderRadius: BorderRadius.circular(5))),
                Container(width: w * buffered, height: h, decoration: BoxDecoration(color: const Color(0xFF6B6B6B), borderRadius: BorderRadius.circular(5))),
                Container(width: w * played, height: h, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(5))),
                Positioned(
                  left: w * played - (f ? 14 : 10),
                  child: Container(
                    width: f ? 28 : 20,
                    height: f ? 28 : 20,
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  ),
                ),
              ]);
            }),
          ),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_fmt(pos), style: TextStyle(fontSize: 20, color: f || _seekTo != null ? Colors.white : const Color(0xFFCFCFCF), fontWeight: _seekTo != null ? FontWeight.w700 : FontWeight.w400)),
            Text('-${_fmt(dur - pos)}', style: const TextStyle(fontSize: 20, color: Color(0xFFCFCFCF))),
          ]),
        ]);
      }),
    );
  }

  Widget _round() {
    final playing = _c?.value.isPlaying ?? false;
    return TvFocusable(
      focusNode: _playNode,
      autoScroll: false,
      onSelect: _togglePlay,
      builder: (context, f) => AnimatedScale(
        scale: f ? 1.08 : 1,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(color: f ? Colors.white : const Color(0xE6282828), shape: BoxShape.circle),
          child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 42, color: f ? Colors.black : Colors.white),
        ),
      ),
    );
  }

  Widget _btn(String label, VoidCallback onSelect) => Padding(
        padding: const EdgeInsets.only(right: 14),
        child: TvFocusable(
          autoScroll: false,
          onSelect: onSelect,
          builder: (context, f) => Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: f ? Colors.white : const Color(0xE6282828), borderRadius: BorderRadius.circular(14)),
            child: Text(label, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: f ? Colors.black : Colors.white)),
          ),
        ),
      );

  Widget _panelView() {
    final items = <(String, bool, VoidCallback)>[];
    var title = '';
    switch (_panel) {
      case _Panel.subs:
        title = 'Subtitles';
        items.add(('Off', _sub < 0, () => unawaited(_setSub(-1))));
        for (var i = 0; i < _subs.length; i++) {
          items.add((_subs[i].label, _sub == i, () => unawaited(_setSub(i))));
        }
      case _Panel.speed:
        title = 'Speed';
        for (final s in _speeds) {
          items.add(('${s == 1.0 ? 'Normal' : '$s×'}', _speed == s, () {
            setState(() => _speed = s);
            unawaited(_c?.setPlaybackSpeed(s));
            _closePanel();
          }));
        }
      case _Panel.eps:
        title = 'Episodes';
        for (final e in widget.playable.eps) {
          items.add(('${e.label} · ${e.title}', e.videoId == _ep.videoId, () {
            if (e.videoId == _ep.videoId) {
              _closePanel();
            } else {
              unawaited(_playEp(e));
            }
          }));
        }
      case _Panel.none:
        break;
    }
    final current = items.indexWhere((x) => x.$2);
    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      width: 620,
      child: FocusScope(
        node: _panelScope,
        autofocus: true,
        onKeyEvent: (node, e) {
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _closePanel();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          color: const Color(0xF2101010),
          padding: const EdgeInsets.fromLTRB(40, 60, 40, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w800, color: Colors.white)),
            const SizedBox(height: 8),
            Text(_panel == _Panel.subs && _subs.isEmpty ? 'No subtitles from your addons for this one.' : 'Left closes this',
                style: const TextStyle(fontSize: 18, color: TvStyle.dim)),
            const SizedBox(height: 22),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 120),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final (label, on, go) = items[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TvFocusable(
                      autofocus: i == (current < 0 ? 0 : current),
                      alignment: 0.4,
                      onSelect: go,
                      builder: (context, f) => Container(
                        height: 62,
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                          color: f ? Colors.white : (on ? TvStyle.accent(context).withValues(alpha: 0.2) : Colors.transparent),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(children: [
                          Expanded(
                            child: Text(label,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600, color: f ? Colors.black : Colors.white)),
                          ),
                          if (on) Icon(Icons.check_rounded, size: 26, color: f ? Colors.black : Colors.white),
                        ]),
                      ),
                    ),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
