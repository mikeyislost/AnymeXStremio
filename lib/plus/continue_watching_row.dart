// AnymeX+: Home's Continue Watching row with Movies & TV in it too.

import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/database/isar_models/offline_media.dart';
import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/stremio/ui/stremio_widgets.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/widgets/common/reusable_carousel.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// One Continue Watching row: your AniList anime and your Stremio Continue
/// Watching (movies and shows), newest first. An anime that also has a
/// Stremio entry (because progress syncs there) shows once, as the AniList
/// card. Without anything from Stremio it is AnymeX's own row, unchanged.
class PlusContinueWatchingRow extends StatelessWidget {
  final List<TrackedMedia> anime;
  final String title;

  const PlusContinueWatchingRow({
    super.key,
    required this.anime,
    this.title = 'Continue Watching',
  });

  static const maxItems = 30;

  Widget _anilistOnly() => ReusableCarousel(
        data: anime,
        title: title,
        variant: DataVariant.anilist,
        type: ItemType.anime,
      );

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<StremioService>()) return _anilistOnly();
    final service = StremioService.to;
    return Obx(() {
      service.animeMatchesVersion.value;
      final stremio = service.isLoggedIn.value
          ? service.continueWatching.toList()
          : const <StremioLibraryItem>[];
      if (stremio.isEmpty) return _anilistOnly();
      final synced = service.stremioIdsForAnilist(
          anime.map((a) => a.id).whereType<String>());
      final items = mergeContinueWatching(anime, stremio, synced);
      if (items.isEmpty) return _anilistOnly();
      return ReusableCarousel(
        data: items,
        title: title,
        variant: DataVariant.offline,
        type: ItemType.anime,
      );
    });
  }
}

/// AniList anime + Stremio items, newest first, without doubles: a Stremio
/// item is dropped when its id is one of [syncedIds] (the anime's own
/// Stremio entries) or its name matches an AniList title.
List<OfflineMedia> mergeContinueWatching(List<TrackedMedia> anime,
    List<StremioLibraryItem> stremio, Set<String> syncedIds,
    {int max = PlusContinueWatchingRow.maxItems}) {
  final titles = <String>{};
  final entries = <(DateTime, OfflineMedia)>[];
  for (final a in anime) {
    if (a.id == null) continue;
    for (final t in [a.title, a.romajiTitle]) {
      final k = normalizeTitle(t);
      if (k.isNotEmpty) titles.add(k);
    }
    final when = a.updatedAt != null
        ? DateTime.fromMillisecondsSinceEpoch(a.updatedAt! * 1000)
        : DateTime.fromMillisecondsSinceEpoch(0);
    entries.add((
      when,
      OfflineMedia(
        mediaId: a.id,
        name: a.displayTitle,
        english: a.title,
        jname: a.romajiTitle,
        poster: a.poster ?? '',
        status: a.mediaStatus,
        serviceIndex: a.servicesType.index,
        // Same badge as AnymeX's own row ("3 | 12").
        currentEpisode: Episode(number: a.formattedProgress),
      ),
    ));
  }
  for (final item in stremio) {
    if (syncedIds.contains(item.id)) continue;
    if (titles.contains(normalizeTitle(item.name))) continue;
    final when = item.lastWatched ??
        item.mtime ??
        DateTime.fromMillisecondsSinceEpoch(0);
    entries.add((when, stremioContinueItem(item)));
  }
  entries.sort((x, y) => y.$1.compareTo(x.$1));
  return entries.take(max).map((e) => e.$2).toList();
}

/// Lower-case letters and digits only, for matching titles from different
/// sites ("Frieren: Beyond Journey’s End" = "Frieren: Beyond Journey's End").
String normalizeTitle(String? t) =>
    (t ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
