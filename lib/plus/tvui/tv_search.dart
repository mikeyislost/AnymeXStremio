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
  final _node = FocusNode(skipTraversal: true); // the text field
  final _box = FocusNode(); // the box around it, highlighted like a button
  Timer? _debounce;
  String _query = '';
  List<TvItem> _anime = const [];
  List<TvItem> _movies = const [];
  bool _busy = false;
  final _animeRow = GlobalKey<TvRowState>();
  final _moviesRow = GlobalKey<TvRowState>();

  @override
  void initState() {
    super.initState();
    _node.addListener(() {
      // The keyboard closed (the text field let go): back to the box.
      if (!_node.hasFocus && mounted) {
        final now = FocusManager.instance.primaryFocus;
        if (now == null || now is FocusScopeNode) _box.requestFocus();
      }
    });
  }

  void _startTyping() => _node.requestFocus();

  void _stopTyping() {
    _box.requestFocus();
    _run(_text.text);
  }

  void _toResults() {
    if (_animeRow.currentState?.isEmpty == false) {
      _animeRow.currentState!.focus();
    } else if (_moviesRow.currentState?.isEmpty == false) {
      _moviesRow.currentState!.focus();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    _node.dispose();
    _box.dispose();
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
    Future<List<TvItem>> one(String kind) async {
      final path = kind == 'movie' ? 'search/movie' : 'search/tv';
      final data = await MoviesForYou.tmdbGet(path, 'tv/search/$kind/${q.toLowerCase()}', const Duration(hours: 6),
          query: '&include_adult=false&query=${Uri.encodeQueryComponent(q)}');
      final list = data is Map ? (data['results'] as List?) ?? const [] : const [];
      final out = <TvItem>[];
      for (final r in list.whereType<Map>()) {
        final p = PlusBuiltinRows.previewFrom(r, kind, 'tt0');
        if (p == null) continue;
        out.add(TvItem(
          id: 'tmdb:$kind:${r['id']}',
          kind: kind,
          title: p.name,
          poster: p.poster ?? '',
          backdrop: p.background ?? '',
          description: p.description ?? '',
          year: p.releaseInfo ?? '',
          rating: p.imdbRating ?? '',
          genres: p.genres,
        ));
      }
      return out;
    }

    final both = await Future.wait([one('movie'), one('series')]);
    return TvCategory.interleave(both).take(40).toList();
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
          // The box is highlighted like any button; OK starts typing (the
          // TV's keyboard opens). Closing the keyboard, Back, Up or Down end
          // typing and the highlight is on the box again.
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (n, e) {
              if (e is! KeyDownEvent || !_node.hasFocus) return KeyEventResult.ignored;
              final k = e.logicalKey;
              if (tvIsBack(k) || k == LogicalKeyboardKey.arrowUp) {
                _stopTyping();
                return KeyEventResult.handled;
              }
              if (k == LogicalKeyboardKey.arrowDown) {
                _stopTyping();
                _toResults();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TvFocusable(
              focusNode: _box,
              autofocus: true,
              alignment: 0.3,
              onSelect: _startTyping,
              builder: (context, f) => AnimatedBuilder(
                animation: _node,
                builder: (context, _) {
                  final on = f || _node.hasFocus;
                  return Container(
                    width: 1100,
                    height: 76,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    decoration: BoxDecoration(
                      color: TvStyle.panel,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: on ? Colors.white : const Color(0xFF2A2A2A), width: 3),
                    ),
                    child: Row(children: [
                      const Icon(Icons.search_rounded, size: 32, color: TvStyle.dim),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ExcludeFocusTraversal(
                          child: TextField(
                            controller: _text,
                            focusNode: _node,
                            onChanged: _changed,
                            onSubmitted: (v) {
                              _run(v);
                              _stopTyping();
                            },
                            onTapOutside: (_) {},
                            cursorColor: accent,
                            style: const TextStyle(fontSize: 26, color: Colors.white),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              hintText: f && !_node.hasFocus ? 'Press OK to type' : 'Anime, movies and series',
                              hintStyle: const TextStyle(fontSize: 26, color: Color(0xFF6D6D6D)),
                            ),
                          ),
                        ),
                      ),
                    ]),
                  );
                },
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
            _box.requestFocus();
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
            _box.requestFocus();
            return true;
          },
          onDown: () => true,
        ),
      ],
    );
  }
}
