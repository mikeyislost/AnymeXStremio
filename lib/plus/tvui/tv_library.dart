import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:anymex/plus/continue_watching_row.dart' show normalizeTitle;
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/tvui/tv_categories.dart';
import 'package:anymex/plus/tvui/tv_data.dart';
import 'package:anymex/plus/tvui/tv_widgets.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Library: your AniList anime and your Stremio library, together by default.
class TvLibraryPage extends StatefulWidget {
  const TvLibraryPage({super.key});

  @override
  State<TvLibraryPage> createState() => _TvLibraryPageState();
}

class _TvLibraryPageState extends State<TvLibraryPage> {
  String _kind = 'all'; // all | anime | movies
  String _status = 'CURRENT';

  static const _statuses = [
    ('CURRENT', 'Watching'),
    ('PLANNING', 'Planning'),
    ('COMPLETED', 'Completed'),
    ('PAUSED', 'Paused'),
    ('DROPPED', 'Dropped'),
  ];

  /// Stremio items without the shows AniList already has (synced ids or
  /// the same title), and without Stremio's own doubles (an anime under its
  /// Kitsu id and its IMDb id): one entry per show.
  static List<StremioLibraryItem> _merged(List<TrackedMedia> anime, List<StremioLibraryItem> library) {
    final titles = <String>{};
    for (final a in anime) {
      for (final n in [a.title, a.romajiTitle]) {
        final k = normalizeTitle(n);
        if (k.isNotEmpty) titles.add(k);
      }
    }
    var synced = const <String>{};
    try {
      final ids = [for (final a in anime) if (a.id != null) a.id!];
      if (ids.isNotEmpty) synced = StremioService.to.stremioIdsForAnilist(ids);
    } catch (_) {}
    // Newest first, so the copy that stays is the one you watched last.
    final sorted = library.toList()
      ..sort((a, b) => (b.lastWatched?.millisecondsSinceEpoch ?? 0).compareTo(a.lastWatched?.millisecondsSinceEpoch ?? 0));
    final out = <StremioLibraryItem>[];
    final ids = <String>{};
    final seen = <String>{}; // Stremio's own: title + type
    for (final i in sorted) {
      if (synced.contains(i.id) || !ids.add(i.id)) continue;
      final k = normalizeTitle(i.name);
      if (k.isNotEmpty) {
        if (titles.contains(k)) continue; // AniList has it
        // Kitsu ids are "series" in some addons and "anime" in others.
        final type = i.id.startsWith('kitsu:') || i.type == 'anime' ? 'series' : i.type;
        if (!seen.add('$k|$type')) continue;
      }
      out.add(i);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final auth = Get.find<AnilistAuth>();
      final svc = StremioService.to;
      final anime = auth.isLoggedIn.value ? auth.animeList.toList() : const <TrackedMedia>[];
      final library = _merged(
          anime, svc.isLoggedIn.value ? svc.allLibraryItems.where((i) => i.isInLibrary || i.isInContinueWatching).toList() : const <StremioLibraryItem>[]);
      final signedIn = auth.isLoggedIn.value || svc.isLoggedIn.value;

      String animeStatus(String? s) {
        final u = (s ?? '').toUpperCase();
        return u == 'REPEATING' ? 'CURRENT' : u;
      }

      String movieStatus(StremioLibraryItem i) {
        if (i.type == 'movie' && i.timesWatched > 0) return 'COMPLETED';
        if (i.isInContinueWatching || i.timeOffset > 0) return 'CURRENT';
        return 'PLANNING';
      }

      final counts = <String, int>{};
      for (final s in _statuses) {
        var n = 0;
        if (_kind != 'movies') n += anime.where((a) => animeStatus(a.watchingStatus) == s.$1).length;
        if (_kind != 'anime') n += library.where((i) => movieStatus(i) == s.$1).length;
        counts[s.$1] = n;
      }
      final items = TvCategory.interleave([
        if (_kind != 'movies')
          [for (final a in anime) if (animeStatus(a.watchingStatus) == _status) TvItem.fromTracked(a)],
        if (_kind != 'anime')
          [for (final i in library) if (movieStatus(i) == _status) TvItem.fromLibrary(i)],
      ]);

      return TvGrid(
        header: [
          const Text('Library', style: TextStyle(fontSize: 48, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 24),
          FocusTraversalGroup(
            child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
              TvChip(label: 'Everything', on: _kind == 'all', autofocus: true, onSelect: () => setState(() => _kind = 'all')),
              TvChip(label: 'Anime', on: _kind == 'anime', onSelect: () => setState(() => _kind = 'anime')),
              TvChip(label: 'Movies & TV', on: _kind == 'movies', onSelect: () => setState(() => _kind = 'movies')),
              Container(width: 2, height: 32, color: const Color(0xFF2A2A2A), margin: const EdgeInsets.symmetric(horizontal: 12)),
              for (final s in _statuses)
                TvChip(label: '${s.$2} · ${counts[s.$1] ?? 0}', on: _status == s.$1, onSelect: () => setState(() => _status = s.$1)),
            ]),
          ),
        ],
        items: items,
        showKind: _kind == 'all',
        empty: signedIn
            ? 'Nothing here yet.'
            : 'Your library shows here once you are signed in: Settings → Accounts → Get logins from your phone.',
      );
    });
  }
}
