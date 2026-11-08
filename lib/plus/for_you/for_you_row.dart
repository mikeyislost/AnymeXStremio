// AnymeX+: the "For you" rows — anime on Home, and Movies & TV on its home
// page. Normal AnymeX cards with a short "Because you loved X" line under
// each; long-press for "Not interested".

import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/controllers/settings/settings.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/models/models_convertor/carousel/carousel_data.dart';
import 'package:anymex/models/models_convertor/carousel_mapper.dart';
import 'package:anymex/plus/card_menu.dart';
import 'package:anymex/plus/for_you/anime_for_you.dart';
import 'package:anymex/plus/for_you/movies_for_you.dart';
import 'package:anymex/plus/for_you/ranking.dart';
import 'package:anymex/plus/for_you/taste.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/stremio/ui/stremio_widgets.dart';
import 'package:anymex/screens/anime/details_page.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/common/cards/card_gate.dart';
import 'package:anymex/widgets/helper/platform_builder.dart';
import 'package:anymex/widgets/helper/tv_wrapper.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// "For you" on Home (anime), from your AniList list and favourites.
class PlusForYouAnimeRow extends StatelessWidget {
  const PlusForYouAnimeRow({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<AnilistAuth>()) return const SizedBox.shrink();
    final auth = Get.find<AnilistAuth>();
    return Obx(() {
      final list = auth.animeList.toList();
      PlusTaste.version.value; // recompute after "Not interested"
      if (!auth.isLoggedIn.value || list.isEmpty) {
        return const SizedBox.shrink();
      }
      final favourites = <AnimeFavourite>[
        for (final f in auth.profileData.value.favourites?.anime ?? const [])
          if (f.id != null)
            (id: f.id!, title: f.title ?? '?', genres: f.genres),
      ];
      // After this build: computing updates the list this row watches.
      Future.microtask(() => AnimeForYou.ensure(list, favourites));
      final picks = AnimeForYou.picks.toList();
      if (picks.isEmpty) return const SizedBox.shrink();
      return PlusForYouRow(
        picks: picks,
        onHidden: (p) => AnimeForYou.picks.removeWhere((x) => x.key == p.key),
      );
    });
  }
}

/// "For you" on Movies & TV, from your Stremio library and history plus
/// what you Liked / Loved.
class PlusForYouMoviesRow extends StatelessWidget {
  const PlusForYouMoviesRow({super.key});

  @override
  Widget build(BuildContext context) {
    if (MoviesForYou.tmdbKey == null) return const SizedBox.shrink();
    final service = StremioService.to;
    return Obx(() {
      service.libraryRevision.value;
      PlusTaste.version.value;
      PlusTaste.ensureLoaded();
      final marks = Map<String, TasteMark>.of(PlusTaste.marks);
      if (!service.libraryLoading.value) {
        final items = service.allLibraryItems.toList();
        Future.microtask(() => MoviesForYou.ensure(items, marks));
      }
      final picks = MoviesForYou.picks.toList();
      if (picks.isEmpty) return const SizedBox.shrink();
      return PlusForYouRow(
        picks: picks,
        onHidden: (p) => MoviesForYou.picks.removeWhere((x) => x.key == p.key),
      );
    });
  }
}

/// A horizontal row of picks with their reason under each card.
class PlusForYouRow extends StatelessWidget {
  final List<ForYouPick> picks;
  final void Function(ForYouPick) onHidden;
  final String title;

  const PlusForYouRow({
    super.key,
    required this.picks,
    required this.onHidden,
    this.title = 'For you',
  });

  static CarouselData cardData(ForYouPick p) {
    if (p.kind == 'anime') {
      return CarouselData(
        id: p.id,
        title: p.title,
        romajiTitle: p.title,
        englishTitle: p.title,
        poster: p.poster,
        extraData: p.rating.isEmpty ? '?' : p.rating,
        servicesType: ServicesType.anilist,
        releasing: false,
      );
    }
    return stremioMediaFromPreview(StremioMetaPreview(
      id: p.id,
      type: p.kind,
      name: p.title,
      poster: p.poster,
      imdbRating: p.rating.isEmpty ? null : p.rating,
      genres: p.genres,
    )).toCarouselData();
  }

  static void open(ForYouPick p, String tag) {
    if (p.kind == 'anime') {
      final media = Media.fromCarouselData(cardData(p), ItemType.anime);
      navigateWithAnimation(() => AnimeDetailsPage(media: media, tag: tag));
    } else {
      openStremioDetails(p.kind, p.id, tag: tag, title: p.title, poster: p.poster);
    }
  }

  void _actions(BuildContext context, ForYouPick p, String tag) {
    void hidden() => onHidden(p);
    if (p.kind == 'anime') {
      PlusCardMenu.anime(
        context,
        Media.fromCarouselData(cardData(p), ItemType.anime),
        tag,
        reason: p.reason,
        genres: p.genres,
        onHidden: hidden,
      );
    } else {
      PlusCardMenu.stremio(
        type: p.kind,
        id: p.id,
        name: p.title,
        poster: p.poster,
        reason: p.reason,
        hideKey: p.key,
        genres: p.genres,
        onHidden: hidden,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 20.0, bottom: 2.0),
            child: AnymeXText(title,
                variant: TextVariant.semiBold,
                size: 17,
                color: colors.primary),
          ),
          const SizedBox(height: 10),
          Obx(() {
            final style = settingsController.cardStyle;
            final desktop = getPlatform(context);
            final cardHeight = getCardHeight(style, desktop);
            final captionWidth = settingsController.customCardStyle
                .cardWidth(desktop, style)
                .clamp(100.0, 240.0);
            return SizedBox(
              height: cardHeight + 15 + 34,
              child: ListView.builder(
                key: PageStorageKey<String>('foryou-$title-${picks.first.kind}'),
                itemCount: picks.length,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: 15, top: 5, bottom: 10),
                itemBuilder: (context, i) {
                  final p = picks[i];
                  final tag = 'foryou-${p.key}-$i';
                  return KeyedSubtree(
                    key: ValueKey(tag),
                    child: AnymexOnTap(
                      onTap: () => open(p, tag),
                      child: GestureDetector(
                        onLongPress: () => _actions(context, p, tag),
                        onSecondaryTap: () => _actions(context, p, tag),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Cards fill the height they're given; in a
                            // Column that's none, so give the card height.
                            SizedBox(
                              height: cardHeight,
                              child: MediaCardGate(
                                itemData: cardData(p),
                                tag: tag,
                                variant: DataVariant.regular,
                                type: ItemType.anime,
                              ),
                            ),
                            SizedBox(
                              width: captionWidth,
                              child: Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(4, 2, 10, 0),
                                child: AnymeXText(
                                  p.reason,
                                  size: 11,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          }),
        ],
      ),
    );
  }
}
