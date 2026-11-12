import 'dart:async';

import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/tvui/tv_playable.dart';
import 'package:anymex/plus/tvui/tv_player.dart';
import 'package:anymex/plus/tvui/tv_widgets.dart';
import 'package:flutter/material.dart';

/// Whether the TV can open this stream: a plain link (torrents, YouTube and
/// outside links need a player the TV doesn't have).
bool tvCanPlay(StremioStream s) {
  final u = s.url;
  return u != null && (u.startsWith('http://') || u.startsWith('https://'));
}

/// LG's 2023+ TVs play no DTS sound.
bool tvNoSound(StremioStream s) => RegExp(r'\bDTS', caseSensitive: false).hasMatch('${s.name ?? ''} ${s.details} ${s.filename ?? ''}');

/// The sources (streams) of one episode or film, from the user's Stremio
/// addons. Your usual addon and quality come first; with [auto] (the Play
/// button) it starts right away when that one turns up.
///
/// With [pick] (the player's Source button) the chosen stream is returned
/// instead of opening the player.
class TvSourcesPage extends StatefulWidget {
  final TvPlayable playable;
  final TvEp ep;
  final bool auto;
  final bool pick;
  final Duration startAt;
  const TvSourcesPage({super.key, required this.playable, required this.ep, this.auto = false, this.pick = false, this.startAt = Duration.zero});

  @override
  State<TvSourcesPage> createState() => _TvSourcesPageState();
}

class _TvSourcesPageState extends State<TvSourcesPage> {
  final _byAddon = <String, List<StremioStream>>{};
  final _order = <String>[];
  int _pending = 0;
  bool _started = false;
  bool _gone = false;
  String? _quality;
  late final _pref = StremioService.to.streamPrefFor(widget.playable.titleKey);

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  bool _preferred(StremioStream s) =>
      _pref.addon != null && s.addonName == _pref.addon && ((_pref.quality ?? '').isEmpty || s.quality == _pref.quality);

  Future<void> _fetch() async {
    final st = StremioService.to;
    await st.ensureAddons();
    if (!mounted) return;
    final type = widget.playable.type;
    final id = widget.ep.videoId;
    final sources = st.addons
        .where((a) => st.isAddonUsable(a) && (a.supports('stream', type, id) || a.supports('stream', 'anime', id)))
        .toList();
    setState(() {
      _started = true;
      _pending = sources.length;
      _order
        ..clear()
        ..addAll(sources.map((a) => a.name));
    });
    await st.fetchStreams(type, id, onAddonResult: (addon, streams) {
      if (!mounted) return;
      setState(() {
        _pending = _pending > 0 ? _pending - 1 : 0;
        _byAddon[addon.name] = streams;
      });
      _maybeAuto();
    });
    if (mounted) setState(() => _pending = 0);
  }

  void _maybeAuto() {
    if (!widget.auto || _gone) return;
    final s = _all.where((s) => tvCanPlay(s) && _preferred(s)).firstOrNull;
    if (s != null) _choose(s);
  }

  List<StremioStream> get _all {
    final order = [
      if (_pref.addon != null && _order.contains(_pref.addon)) _pref.addon!,
      ..._order.where((a) => a != _pref.addon),
    ];
    final out = <StremioStream>[];
    for (final a in order) {
      final list = _byAddon[a] ?? const <StremioStream>[];
      out.addAll(list.where(_preferred));
      out.addAll(list.where((s) => !_preferred(s)));
    }
    return out;
  }

  void _choose(StremioStream s) {
    if (_gone) return;
    _gone = true;
    StremioService.to.rememberStreamChoice(widget.playable.titleKey, s);
    if (widget.pick) {
      Navigator.of(context).pop(s);
      return;
    }
    final all = _all.where(tvCanPlay).toList();
    Navigator.of(context).pushReplacement(tvPlayerRoute(TvPlayerPage(
      playable: widget.playable,
      ep: widget.ep,
      stream: s,
      streams: all,
      startAt: widget.startAt,
    )));
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    final playable = all.where(tvCanPlay).toList();
    final hidden = all.length - playable.length;
    final qualities = streamQualities.where((q) => playable.any((s) => s.quality == q)).toList();
    final shown = playable.where((s) => _quality == null || s.quality == _quality).toList();
    final it = widget.playable.item;
    final loading = !_started || _pending > 0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(TvStyle.pad, 64, TvStyle.pad, 200),
      children: [
        Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 46, fontWeight: FontWeight.w800, color: Colors.white)),
        const SizedBox(height: 6),
        Text(
          [
            if (!widget.playable.isMovie) '${widget.ep.label} · ${widget.ep.title}',
            loading ? 'Looking for sources… (${_order.length - _pending} of ${_order.length} addons)' : '${playable.length} sources',
          ].join('   •   '),
          style: const TextStyle(fontSize: 22, color: TvStyle.text2),
        ),
        const SizedBox(height: 26),
        if (qualities.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 22),
            child: FocusTraversalGroup(
              child: Wrap(spacing: 12, runSpacing: 12, children: [
                TvChip(label: 'All', on: _quality == null, onSelect: () => setState(() => _quality = null)),
                for (final q in qualities) TvChip(label: q, on: _quality == q, onSelect: () => setState(() => _quality = _quality == q ? null : q)),
              ]),
            ),
          ),
        if (_started && _order.isEmpty)
          const _Note("None of your Stremio addons give streams. Sign in to Stremio (Settings → Accounts) or add a stream addon in Stremio.")
        else if (!loading && playable.isEmpty)
          _Note(hidden > 0
              ? 'Only torrent links came back ($hidden). The TV plays direct links: add a debrid service (Real-Debrid, TorBox…) to your addon.'
              : 'No sources for this one yet.'),
        for (var i = 0; i < shown.length; i++)
          _SourceTile(
            stream: shown[i],
            preferred: _preferred(shown[i]),
            autofocus: i == 0,
            onSelect: () => _choose(shown[i]),
          ),
        if (hidden > 0 && playable.isNotEmpty)
          _Note('$hidden torrent links hidden: the TV plays direct links only (debrid works).'),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(text, style: const TextStyle(fontSize: 21, height: 1.4, color: TvStyle.dim)),
      );
}

class _SourceTile extends StatelessWidget {
  final StremioStream stream;
  final bool preferred;
  final bool autofocus;
  final VoidCallback onSelect;
  const _SourceTile({required this.stream, required this.preferred, required this.autofocus, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final s = stream;
    final accent = TvStyle.accent(context);
    final name = (s.name ?? s.addonName).replaceAll('\n', ' ').trim();
    final lines = s.details.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).take(3).join('\n');
    final q = s.quality;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TvFocusable(
        autofocus: autofocus,
        onSelect: onSelect,
        alignment: 0.4,
        builder: (context, f) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
          decoration: BoxDecoration(
            color: f ? Colors.white : TvStyle.panel,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 300,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: f ? Colors.black : Colors.white)),
                const SizedBox(height: 4),
                Text(s.addonName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, color: f ? Colors.black54 : TvStyle.dim)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  if (preferred) _badge('Your usual', f ? Colors.black : accent, f),
                  if (q.isNotEmpty) _badge(q, f ? Colors.black : Colors.white, f),
                  if (tvNoSound(s)) _badge('DTS: no sound on LG', f ? Colors.red.shade900 : Colors.orangeAccent, f),
                ]),
              ]),
            ),
            const SizedBox(width: 28),
            Expanded(
              child: Text(lines,
                  maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, height: 1.4, color: f ? Colors.black87 : const Color(0xFFA9A9A9))),
            ),
          ]),
        ),
      ),
    );
  }

  static Widget _badge(String t, Color c, bool f) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(border: Border.all(color: c, width: 1.5), borderRadius: BorderRadius.circular(8)),
        child: Text(t, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c)),
      );
}
