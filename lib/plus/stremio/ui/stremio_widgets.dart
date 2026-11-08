// Shared helpers that let Stremio content use AnymeX's own UI components
// (cards, carousels, sections, chips) so the Stremio part looks native.

import 'dart:math' as math;

import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/plus/card_menu.dart';
import 'package:anymex/plus/row_perf.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/database/isar_models/offline_media.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/models/models_convertor/carousel_mapper.dart';
import 'package:anymex/plus/stremio/ui/stremio_details_page.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/common/cards/card_gate.dart';
import 'package:anymex/widgets/helper/platform_builder.dart';
import 'package:anymex/widgets/helper/tv_wrapper.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Opens the Stremio details page with AnymeX's page transition.
void openStremioDetails(String type, String id,
    {String? tag, String? title, String? poster}) {
  navigateWithAnimation(() => StremioDetailsPage(
        type: type,
        id: id,
        tag: tag ?? 'stremio-$type-$id',
        initialTitle: title,
        initialPoster: poster,
      ));
}

String stremioTypeLabel(String type, {bool plural = true}) {
  switch (type) {
    case 'movie':
      return plural ? 'Movies' : 'Movie';
    case 'series':
      return 'Series';
    case 'channel':
      return plural ? 'Channels' : 'Channel';
    case 'tv':
      return 'TV';
    case 'anime':
      return 'Anime';
    default:
      return type.isEmpty
          ? ''
          : '${type[0].toUpperCase()}${type.substring(1)}';
  }
}

/// "S2 E9" for `tt123:2:9`, "E4" for `kitsu:1:4` (Kitsu ids are
/// `kitsu:<show>:<episode>`, there is no season), else null.
String? stremioEpisodeLabel(String? videoId) {
  if (videoId == null) return null;
  final parts = videoId.split(':');
  if (parts.first == 'kitsu') {
    return parts.length >= 3 ? 'E${parts.last}' : null;
  }
  if (parts.length >= 3) {
    final s = int.tryParse(parts[parts.length - 2]);
    final e = int.tryParse(parts.last);
    if (s != null && e != null) return 'S$s E$e';
  }
  return null;
}

/// A catalog item as an AnymeX [Media], so AnymeX cards and carousels can
/// show it. Tapping it is routed to the Stremio details page.
Media stremioMediaFromPreview(StremioMetaPreview m) {
  final poster = m.poster ?? m.background ?? '';
  return Media(
    id: StremioIds.mediaId(m.type, m.id),
    idMal: '0',
    title: m.name,
    romajiTitle: m.name,
    englishTitle: m.name,
    poster: PlusRowPerf.smallPoster(poster),
    largePoster: poster,
    cover: m.background,
    description: m.description ?? '',
    rating: m.imdbRating ?? '?',
    genres: m.genres,
    status: stremioTypeLabel(m.type, plural: false),
    serviceType: ServicesType.extensions,
    sourceName: 'Stremio',
  );
}

/// A Stremio Continue Watching entry in the shape AnymeX uses for its own
/// continue-watching cards (play badge + episode).
OfflineMedia stremioContinueItem(StremioLibraryItem item) {
  final label = stremioEpisodeLabel(item.videoId) ??
      (item.progress > 0 ? '${(item.progress * 100).round()}%' : '');
  return OfflineMedia(
    mediaId: StremioIds.mediaId(item.type, item.id),
    name: item.name,
    english: item.name,
    poster: item.poster ?? '',
    serviceIndex: ServicesType.extensions.index,
    currentEpisode: Episode(number: label),
  );
}

/// The rounded translucent panel AnymeX uses on its details pages.
class StremioSection extends StatelessWidget {
  final String? title;
  final Widget? trailing;
  final List<Widget> children;

  const StremioSection({
    super.key,
    this.title,
    this.trailing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.opaque(0.3, iReallyMeanIt: true),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colors.onSurface.opaque(0.08, iReallyMeanIt: true),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Row(
              children: [
                Expanded(
                  child: AnymeXText(
                    title!,
                    size: 14,
                    variant: TextVariant.bold,
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 10),
          ],
          ...children,
        ],
      ),
    );
  }
}

/// Genre / info chip in AnymeX's details-page style.
class StremioChip extends StatelessWidget {
  final String label;
  final IconData? icon;

  const StremioChip(this.label, {super.key, this.icon});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.opaque(0.4, iReallyMeanIt: true),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colors.onSurface.opaque(0.08, iReallyMeanIt: true),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: colors.primary),
            const SizedBox(width: 4),
          ],
          AnymeXText(label, size: 11, variant: TextVariant.semiBold),
        ],
      ),
    );
  }
}

/// Grid delegate matching AnymeX's library grid (respects the card style).
SliverGridDelegate stremioGridDelegate(BuildContext context) {
  const horizontalPadding = 32.0;
  const spacing = 10.0;
  final width = MediaQuery.sizeOf(context).width - horizontalPadding;
  final itemWidth = getPlatform(context) == true ? 170.0 : 140.0;
  final count =
      math.max(1, ((width + spacing) / (itemWidth + spacing)).floor());
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: count,
    crossAxisSpacing: spacing,
    mainAxisSpacing: 20,
    childAspectRatio: getGridCardAspectRatio(
      context: context,
      crossAxisCount: count,
      spacing: spacing,
      padding: horizontalPadding,
    ),
  );
}

StremioMetaPreview stremioPreviewFromLibraryItem(StremioLibraryItem i) =>
    StremioMetaPreview(id: i.id, type: i.type, name: i.name, poster: i.poster);

/// Long-press actions for a Stremio title (Continue Watching / library).
/// Long-press / right-click menu for a Movies & TV card.
void showStremioItemActions({
  required String type,
  required String id,
  required String name,
  String? poster,
}) =>
    PlusCardMenu.stremio(type: type, id: id, name: name, poster: poster);

/// One grid cell: an AnymeX media card that opens the Stremio details page.
class StremioGridCard extends StatelessWidget {
  final StremioMetaPreview item;
  final String tagPrefix;

  const StremioGridCard(
      {super.key, required this.item, required this.tagPrefix});

  @override
  Widget build(BuildContext context) {
    final data = stremioMediaFromPreview(item).toCarouselData();
    final tag = '$tagPrefix-${item.type}-${item.id}';
    void menu() => showStremioItemActions(
        type: item.type, id: item.id, name: item.name, poster: item.poster);
    return GestureDetector(
      onSecondaryTap: menu, // right-click (Windows)
      child: AnymexOnTap(
        onTap: () => openStremioDetails(item.type, item.id,
            tag: tag, title: item.name, poster: item.poster),
        onLongPress: menu,
        child: MediaCardGate(
          itemData: data,
          tag: tag,
          variant: DataVariant.regular,
          type: ItemType.anime,
        ),
      ),
    );
  }
}

/// The user's Stremio library, shown as a section of AnymeX's Library tab.
class StremioLibrarySliver extends StatefulWidget {
  final String searchQuery;
  const StremioLibrarySliver({super.key, this.searchQuery = ''});

  @override
  State<StremioLibrarySliver> createState() => _StremioLibrarySliverState();
}

class _StremioLibrarySliverState extends State<StremioLibrarySliver> {
  String? _type; // null = all

  @override
  void initState() {
    super.initState();
    final service = StremioService.to;
    if (service.isLoggedIn.value && service.library.isEmpty) {
      service.refreshLibrary();
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = StremioService.to;
    return Obx(() {
      final colors = context.colors;
      if (!service.isLoggedIn.value) {
        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: AnymeXText(
              'Log in to Stremio (Settings → Accounts → Stremio) to see your '
              'Stremio library here.',
              textAlign: TextAlign.center,
              color: colors.onSurfaceVariant,
            ),
          ),
        );
      }
      final all = service.library.toList();
      final types = all.map((i) => i.type).toSet().toList()..sort();
      final q = widget.searchQuery.trim().toLowerCase();
      final items = all
          .where((i) => _type == null || i.type == _type)
          .where((i) => q.isEmpty || i.name.toLowerCase().contains(q))
          .toList();

      return SliverMainAxisGroup(
        slivers: [
          if (types.length > 1)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  children: [
                    _typeChip(context, null, 'All (${all.length})'),
                    ...types.map((t) => _typeChip(
                        context,
                        t,
                        '${stremioTypeLabel(t)} '
                        '(${all.where((i) => i.type == t).length})')),
                  ],
                ),
              ),
            ),
          if (service.libraryLoading.value && all.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (items.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: AnymeXText(
                  all.isEmpty
                      ? 'Your Stremio library is empty. Add titles from their '
                          'page or by long-pressing a card.'
                      : 'Nothing matches.',
                  textAlign: TextAlign.center,
                  color: colors.onSurfaceVariant,
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 130),
              sliver: SliverGrid.builder(
                gridDelegate: stremioGridDelegate(context),
                itemCount: items.length,
                itemBuilder: (context, i) => StremioGridCard(
                  item: stremioPreviewFromLibraryItem(items[i]),
                  tagPrefix: 'stremio-library',
                ),
              ),
            ),
        ],
      );
    });
  }

  Widget _typeChip(BuildContext context, String? type, String label) {
    final selected = _type == type;
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: AnymexOnTap(
        onTap: () => setState(() => _type = type),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? colors.primary
                : colors.surfaceContainerHighest.opaque(0.3, iReallyMeanIt: true),
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
