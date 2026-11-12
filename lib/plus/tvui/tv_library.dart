import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/models/Anilist/anilist_media_user.dart';
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

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final auth = Get.find<AnilistAuth>();
      final svc = StremioService.to;
      final anime = auth.isLoggedIn.value ? auth.animeList.toList() : const <TrackedMedia>[];
      final library = svc.isLoggedIn.value ? svc.allLibraryItems.where((i) => i.isInLibrary || i.isInContinueWatching).toList() : const <StremioLibraryItem>[];
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
            : 'Your library shows here once you are signed in. Getting the logins from your phone comes in a coming test build.',
      );
    });
  }
}
