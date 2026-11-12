import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/stremio/watched_bitfield.dart';
import 'package:anymex/plus/tvui/tv_data.dart';
import 'package:anymex/plus/tvui/tv_playable.dart';
import 'package:anymex/plus/tvui/tv_sources.dart';
import 'package:anymex/plus/tvui/tv_widgets.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// One episode on the details page.
class _Ep {
  final String id; // Stremio video id, or the episode number for anime
  final int season;
  final int number;
  final String title;
  final String thumb;
  final double progress;
  final bool watched;
  const _Ep(this.id, this.season, this.number, this.title, {this.thumb = '', this.progress = 0, this.watched = false});
}

/// Details of an anime, film or series: banner, info, buttons and episodes.
class TvDetailsPage extends StatefulWidget {
  final TvItem item;
  const TvDetailsPage({super.key, required this.item});

  @override
  State<TvDetailsPage> createState() => _TvDetailsPageState();
}

class _TvDetailsPageState extends State<TvDetailsPage> {
  late TvItem _item = widget.item;
  String _studio = '';
  List<_Ep> _eps = const [];
  List<(String, List<_Ep>)> _parts = const [];
  int _part = 0;
  int _progress = 0; // anime: episodes watched (AniList)
  String _status = '';
  bool _loading = true;
  String _error = '';
  TvPlayable? _playable;
  StremioMeta? _meta;
  String _resumeVideo = ''; // Stremio: the episode you're on
  bool _inLibrary = false; // Stremio: saved in your library
  bool _matching = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final it = widget.item;
    if (it.isAnime) {
      final d = await TvAnilist.details(it.id);
      if (!mounted) return;
      if (d == null) {
        setState(() {
          _loading = false;
          _error = "Couldn't load this anime. Check the TV's internet.";
        });
        return;
      }
      try {
        final auth = Get.find<AnilistAuth>();
        final mine = auth.animeList.firstWhereOrNull((m) => m.id == it.id);
        if (mine != null) {
          _progress = int.tryParse(mine.episodeCount ?? '') ?? 0;
          _status = _statusLabel(mine.watchingStatus);
        }
      } catch (_) {}
      final (full, out, studio) = d;
      _item = full;
      _studio = studio;
      _eps = [
        for (var n = 1; n <= out && n <= 3000; n++)
          _Ep('$n', 1, n, 'Episode $n', watched: n <= _progress),
      ];
    } else {
      StremioMeta? meta;
      try {
        final id = await TvMovies.stremioId(it);
        if (id != null) meta = await StremioService.to.fetchMeta(it.kind, id);
      } catch (_) {}
      if (!mounted) return;
      if (meta == null) {
        setState(() {
          _loading = false;
          _error = "Couldn't load this title. Check the TV's internet.";
        });
        return;
      }
      _item = TvItem.fromStremio(meta);
      _playable = TvPlayable.stremio(_item, meta);
      _meta = meta;
      await _applyLibrary(meta);
      if (!mounted) return;
    }
    _parts = _split(_eps);
    _goToCurrent();
    setState(() => _loading = false);
  }

  ScrollController _epScroll = ScrollController();

  /// Opens on the season (part) and episode you're at.
  void _goToCurrent() {
    bool isCurrent(_Ep e) => _item.isAnime ? e.number == _progress + 1 : e.id == _resumeVideo;
    if (_item.isAnime ? _progress <= 0 : _resumeVideo.isEmpty) return;
    for (var i = 0; i < _parts.length; i++) {
      final at = _parts[i].$2.indexWhere(isCurrent);
      if (at < 0) continue;
      _part = i;
      // Cards are 360 wide with 24 between: the one before shows too.
      _newScroll((at > 0 ? at - 1 : 0) * 384.0);
      return;
    }
  }

  void _newScroll(double offset) {
    final old = _epScroll;
    _epScroll = ScrollController(initialScrollOffset: offset);
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  void dispose() {
    _epScroll.dispose();
    super.dispose();
  }

  /// Watched episodes and where you are, from Stremio's library as it is
  /// now (so what you watched on the phone shows here too).
  Future<void> _applyLibrary(StremioMeta meta) async {
    StremioLibraryItem? lib;
    try {
      lib = await StremioService.to.getLibraryItem(meta.id, refresh: true).timeout(const Duration(seconds: 10));
    } catch (_) {}
    WatchedBitField? bits;
    try {
      if (lib != null) bits = WatchedBitField.construct(lib.watchedField, WatchedBitField.orderedVideoIds(meta.videos));
    } catch (_) {}
    _inLibrary = lib?.isInLibrary ?? StremioService.to.isInLibrary(meta.id);
    final at = lib?.videoId ?? widget.item.videoId;
    final progress = lib != null && lib.duration > 0 ? (lib.timeOffset / lib.duration).clamp(0.0, 1.0).toDouble() : widget.item.progress;
    _resumeVideo = (lib != null && lib.timeOffset > 0) || widget.item.videoId.isNotEmpty ? at : '';
    final videos = meta.videos.toList()
      ..sort((a, b) => ((a.season ?? 1) * 100000 + (a.episode ?? 0)).compareTo((b.season ?? 1) * 100000 + (b.episode ?? 0)));
    _eps = [
      for (final v in videos)
        _Ep(v.id, v.season ?? 1, v.episode ?? 0, v.title.isEmpty ? 'Episode ${v.episode ?? ''}' : v.title,
            thumb: v.thumbnail ?? '',
            progress: v.id == at ? progress : 0,
            watched: bits?.getVideo(v.id) ?? false),
    ];
  }

  /// Adds to / removes from your Stremio library (like the phone's button).
  Future<void> _toggleLibrary() async {
    final st = StremioService.to;
    final meta = _meta;
    if (!st.isLoggedIn.value) {
      tvToast(context, 'Sign in to Stremio first (Settings → Accounts).');
      return;
    }
    if (meta == null) return;
    final was = _inLibrary;
    setState(() => _inLibrary = !was);
    try {
      if (was) {
        await st.removeFromLibrary(meta.id);
        if (mounted) tvToast(context, 'Removed from your library');
      } else {
        await st.addToLibrary(id: meta.id, type: meta.type, name: meta.name, poster: meta.poster);
        if (mounted) tvToast(context, 'Added to your library');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _inLibrary = was);
        tvToast(context, "Couldn't change your library: $e");
      }
    }
  }

  static String _statusLabel(String? s) => switch ((s ?? '').toUpperCase()) {
        'CURRENT' => 'Watching',
        'REPEATING' => 'Rewatching',
        'PLANNING' => 'Planning',
        'COMPLETED' => 'Completed',
        'PAUSED' => 'Paused',
        'DROPPED' => 'Dropped',
        _ => '',
      };

  /// Seasons, and long seasons 50 episodes at a time.
  static List<(String, List<_Ep>)> _split(List<_Ep> eps) {
    final bySeason = <int, List<_Ep>>{};
    for (final e in eps) {
      bySeason.putIfAbsent(e.season, () => []).add(e);
    }
    final seasons = bySeason.keys.toList()..sort((a, b) => (a == 0 ? 1 << 20 : a).compareTo(b == 0 ? 1 << 20 : b));
    final out = <(String, List<_Ep>)>[];
    for (final s in seasons) {
      final list = bySeason[s]!;
      final name = s == 0 ? 'Specials' : 'Season $s';
      if (list.length <= 50) {
        out.add((seasons.length > 1 ? name : (list.length > 1 ? '${list.first.number} – ${list.last.number}' : name), list));
        continue;
      }
      for (var i = 0; i < list.length; i += 50) {
        final piece = list.sublist(i, i + 50 > list.length ? list.length : i + 50);
        final range = '${piece.first.number} – ${piece.last.number}';
        out.add((seasons.length > 1 ? '$name · $range' : range, piece));
      }
    }
    return out;
  }

  String? _resumeLabel() {
    if (_resumeVideo.isEmpty) return null;
    for (final e in _eps) {
      if (e.id == _resumeVideo) return '${e.progress > 0 && !e.watched ? 'Resume' : 'Play'} S${e.season} E${e.number}';
    }
    return null;
  }

  Future<void> _play([_Ep? e]) async {
    if (_loading || _matching) return;
    final st = StremioService.to;
    var p = _playable;
    if (p == null && _item.isAnime) {
      if (!st.addons.any((a) => st.isAddonUsable(a) && a.hasResource('stream'))) {
        tvToast(context, 'Sign in to Stremio first (Settings → Accounts): anime plays from your Stremio addons for now.');
        return;
      }
      setState(() => _matching = true);
      tvToast(context, 'Matching with your Stremio addons…');
      try {
        p = await TvPlayable.forAnime(_item);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _matching = false;
        _playable = p;
      });
      if (p == null) {
        tvToast(context, "None of your Stremio addons has this anime. (Extensions on the TV come next.)");
        return;
      }
    }
    if (p == null) return;
    TvEp? ep;
    if (e != null) {
      ep = p.isAnime ? p.epFor(number: e.number) : p.epFor(videoId: e.id);
    } else if (p.isAnime) {
      ep = p.epFor(number: _progress + 1) ?? p.epFor(number: _progress);
    } else if (_resumeVideo.isNotEmpty) {
      ep = p.epFor(videoId: _resumeVideo);
    }
    ep ??= p.eps.where((x) => x.season != 0).firstOrNull ?? p.eps.firstOrNull;
    if (ep == null) {
      tvToast(context, "This episode isn't out on your Stremio addons yet.");
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(tvRoute(TvSourcesPage(playable: p, ep: ep, auto: true)));
    // Back from the player: show what's watched now.
    final meta = _meta;
    if (meta != null && mounted) {
      await _applyLibrary(meta);
      if (mounted) {
        setState(() {
          _parts = _split(_eps);
          _goToCurrent();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = _item;
    final accent = TvStyle.accent(context);
    final meta = <String>[
      if (it.year.isNotEmpty) it.year,
      if (it.format.isNotEmpty) it.format else it.kindLabel,
      if (it.episodes.isNotEmpty && it.kind != 'movie') '${it.episodes} episodes',
      if (it.rating.isNotEmpty) '★ ${it.rating}',
      if (_studio.isNotEmpty) _studio,
    ];
    final next = it.isAnime ? (_progress + 1 <= _eps.length ? _progress + 1 : (_eps.isEmpty ? 1 : _eps.length)) : 0;
    final playLabel = it.kind == 'movie'
        ? 'Play'
        : it.isAnime
            ? (_progress > 0 ? 'Continue E$next' : 'Play E1')
            : (_resumeLabel() ?? 'Play S1 E1');
    final pic = it.backdrop.isNotEmpty ? it.backdrop : it.poster;
    final part = _parts.isEmpty ? const <_Ep>[] : _parts[_part.clamp(0, _parts.length - 1).toInt()].$2;

    return Stack(children: [
      Positioned.fill(child: TvImage(url: pic, width: 1920, height: 1080, seed: it.key)),
      const Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [Colors.black, Color(0xE0000000), Color(0x33000000)], stops: [0.0, 0.4, 0.8]),
          ),
        ),
      ),
      const Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: 600,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black, Colors.black, Color(0x00000000)], stops: [0.0, 0.45, 1.0]),
          ),
        ),
      ),
      ListView(
        padding: const EdgeInsets.fromLTRB(0, 72, 0, 200),
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: TvStyle.pad),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(borderRadius: BorderRadius.circular(16), child: TvImage(url: it.poster, width: 230, height: 345, seed: it.key)),
              const SizedBox(width: 40),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(it.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 60, height: 1.05, fontWeight: FontWeight.w800, color: Colors.white)),
                  const SizedBox(height: 16),
                  Text(meta.join('   •   '), style: const TextStyle(fontSize: 22, color: Color(0xFFCFCFCF))),
                  const SizedBox(height: 14),
                  if (it.genres.isNotEmpty)
                    Wrap(spacing: 10, runSpacing: 10, children: [
                      for (final g in it.genres.take(5))
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          decoration: BoxDecoration(color: TvStyle.chip, borderRadius: BorderRadius.circular(999)),
                          child: Text(g, style: const TextStyle(fontSize: 18, color: Color(0xFFCFCFCF))),
                        ),
                    ]),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: 980,
                    child: Text(it.description,
                        maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 21, height: 1.5, color: Color(0xFFA9A9A9))),
                  ),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 36),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: TvStyle.pad),
            child: FocusTraversalGroup(
              child: Wrap(spacing: 16, runSpacing: 16, children: [
                TvButton(label: playLabel, icon: Icons.play_arrow_rounded, primary: true, autofocus: true, onSelect: _play),
                if (it.isAnime)
                  TvButton(
                    label: _status.isEmpty ? 'Add to list' : '$_status · $_progress / ${it.episodes.isEmpty ? '?' : it.episodes}',
                    onSelect: () => tvToast(context, 'Changing your list from the TV comes with the logins from your phone.'),
                  ),
                if (!it.isAnime)
                  TvButton(label: _inLibrary ? 'In library ✓' : 'Add to library', onSelect: _toggleLibrary),
                if (it.isAnime) TvButton(label: 'Source: Stremio addons', onSelect: () => tvToast(context, 'Anime plays from your Stremio addons for now. Extensions on the TV come next.')),
              ]),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(TvStyle.pad),
              child: Text('Loading…', style: TextStyle(fontSize: 22, color: TvStyle.dim)),
            ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(TvStyle.pad),
              child: Text(_error, style: const TextStyle(fontSize: 22, color: TvStyle.dim)),
            ),
          if (it.kind != 'movie' && _parts.isNotEmpty) ...[
            const SizedBox(height: 40),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: TvStyle.pad),
              child: FocusTraversalGroup(
                child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  const Padding(
                    padding: EdgeInsets.only(right: 18),
                    child: Text('Episodes', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                  if (_parts.length > 1)
                    for (var i = 0; i < _parts.length; i++)
                      TvChip(
                        label: _parts[i].$1,
                        on: i == _part,
                        onSelect: () => setState(() {
                          _part = i;
                          _newScroll(0);
                        }),
                      ),
                ]),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 300,
              child: FocusTraversalGroup(
                child: ListView.separated(
                  key: ValueKey('part$_part'),
                  controller: _epScroll,
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  padding: const EdgeInsets.symmetric(horizontal: TvStyle.pad, vertical: 6),
                  itemCount: part.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 24),
                  itemBuilder: (context, i) {
                    final e = part[i];
                    return TvFocusable(
                      onSelect: () => _play(e),
                      builder: (context, f) => AnimatedScale(
                        scale: f ? 1.06 : 1,
                        duration: const Duration(milliseconds: 120),
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: 360,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Container(
                              width: 360,
                              height: 203,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: f ? Colors.white : Colors.transparent, width: 4),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Stack(children: [
                                  e.thumb.isNotEmpty
                                      ? TvImage(url: e.thumb, width: 360, height: 203, seed: '${it.key}${e.number}')
                                      : Container(color: const Color(0xFF161616)),
                                  Positioned(
                                    left: 12,
                                    top: 10,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(8)),
                                      child: Text('E${e.number}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white)),
                                    ),
                                  ),
                                  if (e.watched || e.progress > 0)
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 0,
                                      child: Container(
                                        height: 6,
                                        color: const Color(0xFF333333),
                                        alignment: Alignment.centerLeft,
                                        child: FractionallySizedBox(widthFactor: e.watched ? 1 : e.progress, child: Container(color: accent)),
                                      ),
                                    ),
                                ]),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(e.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: f ? Colors.white : const Color(0xFFBDBDBD))),
                            Text(e.watched ? 'Watched' : '', style: const TextStyle(fontSize: 16, color: TvStyle.dim)),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    ]);
  }
}
