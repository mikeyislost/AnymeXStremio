// AnymeX+: one Library for everything — your anime list and your Stremio
// Movies & TV together, with the same status filters (Watching, Completed,
// Paused, Dropped, Planning) and a kind filter (Anime / Movies / Series).
// Shown by the "Everything" chip in AnymeX's Library tab.

import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:anymex/plus/continue_watching_row.dart' show normalizeTitle;
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/stremio/ui/stremio_widgets.dart';
import 'package:anymex/widgets/helper/tv_wrapper.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/media_items/media_item.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Status filters, in the order the chips show.
enum PlusLibStatus { watching, completed, paused, dropped, planning }

/// Kind filters.
enum PlusLibKind { anime, movie, series }

String plusLibStatusLabel(PlusLibStatus s) => switch (s) {
      PlusLibStatus.watching => 'Watching',
      PlusLibStatus.completed => 'Completed',
      PlusLibStatus.paused => 'Paused',
      PlusLibStatus.dropped => 'Dropped',
      PlusLibStatus.planning => 'Planning',
    };

String plusLibKindLabel(PlusLibKind k) => switch (k) {
      PlusLibKind.anime => 'Anime',
      PlusLibKind.movie => 'Movies',
      PlusLibKind.series => 'Series',
    };

/// An anime list status (AniList / MAL / Simkl, as AnymeX stores it).
PlusLibStatus? plusAnimeStatus(String? s) {
  switch ((s ?? '').toUpperCase()) {
    case 'CURRENT':
    case 'WATCHING':
    case 'REPEATING':
    case 'REWATCHING':
      return PlusLibStatus.watching;
    case 'COMPLETED':
      return PlusLibStatus.completed;
    case 'PAUSED':
    case 'ON_HOLD':
    case 'HOLD':
      return PlusLibStatus.paused;
    case 'DROPPED':
      return PlusLibStatus.dropped;
    case 'PLANNING':
    case 'PLAN_TO_WATCH':
    case 'PLANTOWATCH':
      return PlusLibStatus.planning;
  }
  return null;
}

/// A Stremio library item's status: watched → Completed, started →
/// Watching, otherwise Planning. (Stremio has no Paused or Dropped.)
PlusLibStatus plusStremioStatus(StremioLibraryItem i) {
  if (i.flaggedWatched > 0) return PlusLibStatus.completed;
  if (i.type == 'movie' && i.timesWatched > 0) return PlusLibStatus.completed;
  final started = i.timeOffset > 0 ||
      i.overallTimeWatched > 0 ||
      (i.type != 'movie' && (i.watchedField ?? '').isNotEmpty);
  return started ? PlusLibStatus.watching : PlusLibStatus.planning;
}

/// One card in the Everything view: an anime or a Movies & TV title.
class PlusLibEntry {
  final TrackedMedia? anime;
  final StremioLibraryItem? stremio;
  final PlusLibStatus? status;
  final PlusLibKind kind;
  final DateTime when;
  final String title;

  PlusLibEntry._(this.anime, this.stremio, this.status, this.kind, this.when,
      this.title);

  factory PlusLibEntry.fromAnime(TrackedMedia a) => PlusLibEntry._(
        a,
        null,
        plusAnimeStatus(a.watchingStatus),
        PlusLibKind.anime,
        a.updatedAt != null
            ? DateTime.fromMillisecondsSinceEpoch(a.updatedAt! * 1000)
            : DateTime.fromMillisecondsSinceEpoch(0),
        a.displayTitle,
      );

  factory PlusLibEntry.fromStremio(StremioLibraryItem i) => PlusLibEntry._(
        null,
        i,
        plusStremioStatus(i),
        i.type == 'movie' ? PlusLibKind.movie : PlusLibKind.series,
        i.lastWatched ?? i.mtime ?? DateTime.fromMillisecondsSinceEpoch(0),
        i.name,
      );
}

/// Your anime and your Stremio library in one list, most recent activity
/// first. A Stremio item that is one of your anime (its synced Stremio
/// entry, [syncedIds], or the same title) shows once, as the anime.
List<PlusLibEntry> plusMergeLibrary(List<TrackedMedia> anime,
    List<StremioLibraryItem> stremio, Set<String> syncedIds) {
  final titles = <String>{};
  final out = <PlusLibEntry>[];
  final seenAnime = <String>{};
  for (final a in anime) {
    if (a.id == null || !seenAnime.add(a.id!)) continue;
    for (final t in [a.title, a.romajiTitle]) {
      final k = normalizeTitle(t);
      if (k.isNotEmpty) titles.add(k);
    }
    out.add(PlusLibEntry.fromAnime(a));
  }
  final seenStremio = <String>{};
  for (final i in stremio) {
    if (!seenStremio.add(i.id)) continue;
    if (syncedIds.contains(i.id)) continue;
    if (titles.contains(normalizeTitle(i.name))) continue;
    out.add(PlusLibEntry.fromStremio(i));
  }
  out.sort((x, y) => y.when.compareTo(x.when));
  return out;
}

/// [entries] narrowed by status, kind and search text.
List<PlusLibEntry> plusFilterLibrary(List<PlusLibEntry> entries,
    {PlusLibStatus? status, PlusLibKind? kind, String query = ''}) {
  final q = query.trim().toLowerCase();
  return entries.where((e) {
    if (status != null && e.status != status) return false;
    if (kind != null && e.kind != kind) return false;
    if (q.isNotEmpty) {
      final names = [
        e.title,
        e.anime?.title,
        e.anime?.romajiTitle,
      ].whereType<String>().map((s) => s.toLowerCase());
      if (!names.any((n) => n.contains(q))) return false;
    }
    return true;
  }).toList();
}

/// The Everything view, as a sliver for the Library tab.
class PlusEverythingLibrarySliver extends StatefulWidget {
  final String searchQuery;
  const PlusEverythingLibrarySliver({super.key, this.searchQuery = ''});

  @override
  State<PlusEverythingLibrarySliver> createState() =>
      _PlusEverythingLibrarySliverState();
}

class _PlusEverythingLibrarySliverState
    extends State<PlusEverythingLibrarySliver> {
  static const _kStatus = 'anymexplus_everything_status';
  static const _kKind = 'anymexplus_everything_kind';

  PlusLibStatus? _status;
  PlusLibKind? _kind;

  @override
  void initState() {
    super.initState();
    final s = KvHelper.get<int>(_kStatus, defaultVal: -1);
    final k = KvHelper.get<int>(_kKind, defaultVal: -1);
    if (s >= 0 && s < PlusLibStatus.values.length) {
      _status = PlusLibStatus.values[s];
    }
    if (k >= 0 && k < PlusLibKind.values.length) _kind = PlusLibKind.values[k];
    if (Get.isRegistered<StremioService>()) {
      final service = StremioService.to;
      if (service.isLoggedIn.value && service.library.isEmpty) {
        service.refreshLibrary();
      }
    }
  }

  void _setStatus(PlusLibStatus? s) {
    setState(() => _status = s);
    KvHelper.set(_kStatus, s?.index ?? -1);
  }

  void _setKind(PlusLibKind? k) {
    setState(() => _kind = k);
    KvHelper.set(_kKind, k?.index ?? -1);
  }

  @override
  Widget build(BuildContext context) {
    final handler = Get.find<ServiceHandler>();
    final hasStremio = Get.isRegistered<StremioService>();
    return Obx(() {
      final anime = handler.animeList.toList();
      var stremio = const <StremioLibraryItem>[];
      var synced = const <String>{};
      var loading = false;
      if (hasStremio) {
        final service = StremioService.to;
        service.animeMatchesVersion.value;
        service.libraryRevision.value;
        if (service.isLoggedIn.value) {
          stremio = service.library.toList();
          loading = service.libraryLoading.value;
          synced = service.stremioIdsForAnilist(
              anime.map((a) => a.id).whereType<String>());
        }
      }
      final all = plusMergeLibrary(anime, stremio, synced);
      final byKind = plusFilterLibrary(all, kind: _kind);
      final items = plusFilterLibrary(byKind,
          status: _status, query: widget.searchQuery);
      final kinds = PlusLibKind.values
          .where((k) => all.any((e) => e.kind == k))
          .toList();
      final statuses = PlusLibStatus.values
          .where((s) => byKind.any((e) => e.status == s) || s == _status)
          .toList();

      return SliverMainAxisGroup(
        slivers: [
          if (kinds.length > 1 || _kind != null)
            _chipRow(context, [
              _chip(context, 'All (${all.length})', _kind == null,
                  () => _setKind(null)),
              for (final k in kinds)
                _chip(
                    context,
                    '${plusLibKindLabel(k)} '
                    '(${all.where((e) => e.kind == k).length})',
                    _kind == k,
                    () => _setKind(k)),
            ]),
          _chipRow(context, [
            _chip(context, 'Any status', _status == null,
                () => _setStatus(null)),
            for (final s in statuses)
              _chip(
                  context,
                  '${plusLibStatusLabel(s)} '
                  '(${byKind.where((e) => e.status == s).length})',
                  _status == s,
                  () => _setStatus(s)),
          ]),
          if (items.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: loading && all.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : AnymeXText(
                        all.isEmpty
                            ? 'Nothing here yet. Anime you track and Movies & '
                                'TV in your Stremio library show up here.'
                            : 'Nothing matches.',
                        textAlign: TextAlign.center,
                        color: context.colors.onSurfaceVariant,
                      ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 130),
              sliver: SliverGrid.builder(
                gridDelegate: stremioGridDelegate(context),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final e = items[i];
                  if (e.anime != null) {
                    return GridAnimeCard(
                      data: e.anime,
                      isManga: false,
                      variant: CardVariant.onlinelist,
                      tagPrefix: 'everything',
                    );
                  }
                  return StremioGridCard(
                    item: stremioPreviewFromLibraryItem(e.stremio!),
                    tagPrefix: 'everything',
                  );
                },
              ),
            ),
        ],
      );
    });
  }

  Widget _chipRow(BuildContext context, List<Widget> chips) =>
      SliverToBoxAdapter(
        child: SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            children: chips,
          ),
        ),
      );

  Widget _chip(
      BuildContext context, String label, bool selected, VoidCallback onTap) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: AnymexOnTap(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? colors.primary
                : colors.surfaceContainerHighest
                    .opaque(0.3, iReallyMeanIt: true),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: colors.onSurface.opaque(0.08, iReallyMeanIt: true),
              width: 0.5,
            ),
          ),
          child: AnymeXText(
            label,
            size: 12,
            variant: selected ? TextVariant.bold : TextVariant.semiBold,
            color: selected ? colors.onPrimary : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// The Library's "Everything" chip state, remembered between launches.
RxBool plusEverythingChipFlag() {
  const key = 'anymexplus_everything_chip';
  final flag = KvHelper.get<bool>(key, defaultVal: false).obs;
  ever<bool>(flag, (v) => KvHelper.set(key, v));
  return flag;
}
