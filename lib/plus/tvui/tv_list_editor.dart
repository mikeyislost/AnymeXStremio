import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/plus/tvui/tv_widgets.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// What the list editor did, for the details page.
class TvListChange {
  final String status; // AniList status ('' = removed from the list)
  final int progress;
  final double score; // 0–100
  const TvListChange(this.status, this.progress, this.score);
  bool get removed => status.isEmpty;
}

/// AniList rules for one anime's list entry, kept apart from the screen so
/// they can be tested.
class TvListRules {
  static const statuses = ['CURRENT', 'PLANNING', 'COMPLETED', 'REPEATING', 'PAUSED', 'DROPPED'];

  static String label(String s) => switch (s.toUpperCase()) {
        'CURRENT' => 'Watching',
        'REPEATING' => 'Rewatching',
        'PLANNING' => 'Planning',
        'COMPLETED' => 'Completed',
        'PAUSED' => 'Paused',
        'DROPPED' => 'Dropped',
        _ => '',
      };

  /// Progress after a step, kept within 0…total (total 0 = unknown).
  static int step(int progress, int by, int total) {
    final p = progress + by;
    if (p < 0) return 0;
    if (total > 0 && p > total) return total;
    return p;
  }

  /// The status that goes with a new progress: the last episode completes
  /// it; starting to watch moves Planning (or nothing) to Watching.
  static String statusFor(String status, int progress, int total) {
    if (total > 0 && progress >= total && status != 'DROPPED') return 'COMPLETED';
    if (progress > 0 && (status.isEmpty || status == 'PLANNING')) return 'CURRENT';
    if (status == 'COMPLETED' && total > 0 && progress < total) return 'CURRENT';
    return status;
  }

  /// Progress that goes with a new status (Completed = all episodes).
  static int progressFor(String status, int progress, int total) =>
      status == 'COMPLETED' && total > 0 ? total : progress;

  /// Marking episode [n] watched (everything up to it) or not watched
  /// (progress goes back to just before it).
  static (String, int) markEpisode(String status, int progress, int total, int n, bool watched) {
    final p = watched ? (n > progress ? n : progress) : (n - 1 < progress ? n - 1 : progress);
    final clamped = p < 0 ? 0 : p;
    return (statusFor(status, clamped, total), clamped);
  }

  /// Score on AniList's 100 scale, shown out of 10 in steps of 0.5.
  static double stepScore(double score, int by) => (score + by * 5).clamp(0, 100).toDouble();
  static String scoreLabel(double score) =>
      score <= 0 ? 'No score' : '${(score / 10).toStringAsFixed(score % 10 == 0 ? 0 : 1)} / 10';
}

/// Change an anime's AniList entry from the TV: status, episodes, score,
/// or take it off your list. MAL and Simkl follow (AniList's own update
/// passes it on, like on the phone).
class TvListEditor extends StatefulWidget {
  final String anilistId;
  final String title;
  final String status;
  final int progress;
  final double score;
  final int total;
  const TvListEditor({
    super.key,
    required this.anilistId,
    required this.title,
    required this.status,
    required this.progress,
    required this.score,
    required this.total,
  });

  @override
  State<TvListEditor> createState() => _TvListEditorState();
}

class _TvListEditorState extends State<TvListEditor> {
  late String _status = widget.status.isEmpty ? 'CURRENT' : widget.status.toUpperCase();
  late int _progress = widget.progress;
  late double _score = widget.score;
  bool _saving = false;
  bool _confirmRemove = false;

  bool get _onList => widget.status.isNotEmpty;

  void _stepEp(int by) => setState(() {
        _progress = TvListRules.step(_progress, by, widget.total);
        _status = TvListRules.statusFor(_status, _progress, widget.total);
        _confirmRemove = false;
      });

  void _setStatus(String s) => setState(() {
        _status = s;
        _progress = TvListRules.progressFor(s, _progress, widget.total);
        _confirmRemove = false;
      });

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await Get.find<AnilistAuth>().updateListEntry(
        listId: widget.anilistId,
        status: _status,
        progress: _progress,
        score: _score > 0 ? _score : null,
        isAnime: true,
      );
      if (!mounted) return;
      Navigator.of(context).pop(TvListChange(_status, _progress, _score));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      tvToast(context, "Couldn't save to AniList: $e");
    }
  }

  Future<void> _remove() async {
    if (!_confirmRemove) {
      setState(() => _confirmRemove = true);
      return;
    }
    setState(() => _saving = true);
    try {
      await Get.find<AnilistAuth>().deleteMediaFromList(widget.anilistId, isAnime: true);
      if (!mounted) return;
      Navigator.of(context).pop(const TvListChange('', 0, 0));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      tvToast(context, "Couldn't remove it: $e");
    }
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 40, bottom: 16),
        child: Text(t, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: 2, color: TvStyle.dim)),
      );

  Widget _value(String t) => SizedBox(
        width: 260,
        child: Center(child: Text(t, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: Colors.white))),
      );

  @override
  Widget build(BuildContext context) {
    final total = widget.total > 0 ? '${widget.total}' : '?';
    return Padding(
      padding: const EdgeInsets.fromLTRB(TvStyle.pad, 80, TvStyle.pad, 0),
      child: FocusTraversalGroup(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 8),
          Text(_onList ? 'Your AniList entry' : 'Add to your AniList', style: const TextStyle(fontSize: 24, color: TvStyle.text2)),
          _label('STATUS'),
          Wrap(spacing: 14, runSpacing: 14, children: [
            for (final s in TvListRules.statuses)
              TvChip(label: TvListRules.label(s), on: _status == s, autofocus: _status == s, onSelect: () => _setStatus(s)),
          ]),
          _label('EPISODES'),
          Row(children: [
            TvButton(label: '−', onSelect: () => _stepEp(-1)),
            _value('$_progress / $total'),
            TvButton(label: '+', onSelect: () => _stepEp(1)),
            const SizedBox(width: 24),
            if (widget.total > 0) TvButton(label: 'All watched', onSelect: () => _stepEp(widget.total)),
            const SizedBox(width: 16),
            TvButton(label: 'None', onSelect: () => _stepEp(-_progress)),
          ]),
          _label('SCORE'),
          Row(children: [
            TvButton(label: '−', onSelect: () => setState(() => _score = TvListRules.stepScore(_score, -1))),
            _value(TvListRules.scoreLabel(_score)),
            TvButton(label: '+', onSelect: () => setState(() => _score = TvListRules.stepScore(_score, 1))),
          ]),
          const SizedBox(height: 56),
          Row(children: [
            TvButton(label: _saving ? 'Saving…' : 'Save', primary: true, icon: Icons.check_rounded, onSelect: _save),
            const SizedBox(width: 16),
            TvButton(label: 'Cancel', onSelect: () => Navigator.of(context).maybePop()),
            if (_onList) ...[
              const SizedBox(width: 16),
              TvButton(label: _confirmRemove ? 'Press again to remove' : 'Remove from list', onSelect: _remove),
            ],
          ]),
          const SizedBox(height: 24),
          const Text('MyAnimeList and Simkl get the same change if you\'re signed in to them.',
              style: TextStyle(fontSize: 19, color: TvStyle.dim)),
        ]),
      ),
    );
  }
}

/// Hold OK on an episode: watched / not watched.
class TvEpisodeMenu extends StatelessWidget {
  final String title;
  final bool watched;
  final String upToLabel; // e.g. "Watched up to E5" ('' = single episode)
  const TvEpisodeMenu({super.key, required this.title, required this.watched, this.upToLabel = ''});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(TvStyle.pad, 120, TvStyle.pad, 0),
      child: FocusTraversalGroup(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 40),
          Wrap(spacing: 16, runSpacing: 16, children: [
            TvButton(
              label: upToLabel.isNotEmpty ? upToLabel : 'Mark watched',
              icon: Icons.check_circle_outline_rounded,
              autofocus: !watched,
              onSelect: () => Navigator.of(context).pop(true),
            ),
            TvButton(
              label: 'Mark not watched',
              icon: Icons.remove_circle_outline_rounded,
              autofocus: watched,
              onSelect: () => Navigator.of(context).pop(false),
            ),
            TvButton(label: 'Cancel', onSelect: () => Navigator.of(context).maybePop()),
          ]),
        ]),
      ),
    );
  }
}
