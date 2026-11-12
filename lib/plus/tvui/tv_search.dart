import 'dart:async';

import 'package:anymex/plus/for_you/movies_for_you.dart';
import 'package:anymex/plus/stremio/builtin_rows.dart';
import 'package:anymex/plus/tvui/tv_data.dart';
import 'package:anymex/plus/tvui/tv_home.dart';
import 'package:anymex/plus/tvui/tv_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Search: type with the TV's keyboard; anime and Movies & TV results.
class TvSearchPage extends StatefulWidget {
  const TvSearchPage({super.key});

  @override
  State<TvSearchPage> createState() => _TvSearchPageState();
}

class _TvSearchPageState extends State<TvSearchPage> {
  final _text = TextEditingController();
  final _node = FocusNode();
  Timer? _debounce;
  String _query = '';
  List<TvItem> _anime = const [];
  List<TvItem> _movies = const [];
  bool _busy = false;
  final _animeRow = GlobalKey<TvRowState>();
  final _moviesRow = GlobalKey<TvRowState>();

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    _node.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => _run(v));
  }

  Future<void> _run(String v) async {
    final q = v.trim();
    if (q == _query) return;
    _query = q;
    if (q.length < 2) {
      setState(() {
        _anime = const [];
        _movies = const [];
      });
      return;
    }
    setState(() => _busy = true);
    final results = await Future.wait([
      TvAnilist.list({'search': q, 'sort': ['SEARCH_MATCH']}),
      _tmdb(q),
    ]);
    if (!mounted || q != _query) return;
    setState(() {
      _busy = false;
      _anime = results[0];
      _movies = results[1];
    });
  }

  static Future<List<TvItem>> _tmdb(String q) async {
    if (MoviesForYou.tmdbKey == null) return const [];
    final data = await MoviesForYou.tmdbGet('search/multi', 'tv/search/${q.toLowerCase()}', const Duration(hours: 6),
        query: '&include_adult=false&query=${Uri.encodeQueryComponent(q)}');
    final list = data is Map ? (data['results'] as List?) ?? const [] : const [];
    final picks = list.whereType<Map>().where((r) => r['media_type'] == 'movie' || r['media_type'] == 'tv').take(20).toList();
    final out = await Future.wait(picks.map((r) async {
      final kind = r['media_type'] == 'tv' ? 'series' : 'movie';
      final imdb = await MoviesForYou.imdbFor(kind, '${r['id']}');
      if (imdb == null) return null;
      final p = PlusBuiltinRows.previewFrom(r, kind, imdb);
      return p == null ? null : TvItem.fromStremio(p);
    }));
    return out.whereType<TvItem>().toList();
  }

  @override
  Widget build(BuildContext context) {
    final accent = TvStyle.accent(context);
    return ListView(
      padding: const EdgeInsets.only(top: 64, bottom: 300),
      clipBehavior: Clip.none,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: TvStyle.pad),
          child: Text('Search', style: TextStyle(fontSize: 48, fontWeight: FontWeight.w800, color: Colors.white)),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: TvStyle.pad),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            // Down / Up leave the box (the TV's keyboard closes first).
            onKeyEvent: (n, e) {
              if (e is KeyDownEvent && (e.logicalKey == LogicalKeyboardKey.arrowDown)) {
                final ok = (_animeRow.currentState?.focus() ?? false) || (_moviesRow.currentState?.focus() ?? false);
                return ok ? KeyEventResult.handled : KeyEventResult.ignored;
              }
              if (e is KeyDownEvent && tvIsSelect(e.logicalKey) && e.logicalKey != LogicalKeyboardKey.space) {
                _run(_text.text);
              }
              return KeyEventResult.ignored;
            },
            child: AnimatedBuilder(
              animation: _node,
              builder: (context, _) => Container(
                width: 1100,
                height: 76,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                decoration: BoxDecoration(
                  color: TvStyle.panel,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _node.hasFocus ? Colors.white : const Color(0xFF2A2A2A), width: 3),
                ),
                child: Row(children: [
                  const Icon(Icons.search_rounded, size: 32, color: TvStyle.dim),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      focusNode: _node,
                      onChanged: _changed,
                      onSubmitted: _run,
                      cursorColor: accent,
                      style: const TextStyle(fontSize: 26, color: Colors.white),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Anime, movies and series',
                        hintStyle: TextStyle(fontSize: 26, color: Color(0xFF6D6D6D)),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
        const SizedBox(height: 36),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: TvStyle.pad),
            child: Text('Searching…', style: TextStyle(fontSize: 22, color: TvStyle.dim)),
          ),
        if (!_busy && _query.length >= 2 && _anime.isEmpty && _movies.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: TvStyle.pad),
            child: Text('Nothing found.', style: TextStyle(fontSize: 22, color: TvStyle.dim)),
          ),
        TvRow(
          key: _animeRow,
          title: 'Anime',
          items: _anime,
          onOpen: (i) => tvOpen(context, i),
          onUp: () {
            _node.requestFocus();
            return true;
          },
          onDown: () => _moviesRow.currentState?.focus() ?? true,
        ),
        TvRow(
          key: _moviesRow,
          title: 'Movies & TV',
          items: _movies,
          showKind: true,
          onOpen: (i) => tvOpen(context, i),
          onUp: () {
            if (_animeRow.currentState?.isEmpty == false) return _animeRow.currentState!.focus();
            _node.requestFocus();
            return true;
          },
          onDown: () => true,
        ),
      ],
    );
  }
}
