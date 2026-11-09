// AnymeX+: Home and Manga drawn from your layout (Edit layout). Used when
// AniList is your service; other services keep AnymeX's own pages.

import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/controllers/settings/settings.dart';
import 'package:anymex/plus/custom_lists.dart';
import 'package:anymex/plus/for_you/for_you_row.dart';
import 'package:anymex/plus/layout/layout_editor.dart';
import 'package:anymex/plus/layout/layout_model.dart';
import 'package:anymex/plus/layout/layout_store.dart';
import 'package:anymex/plus/layout/page_rows.dart';
import 'package:anymex/plus/missed_sequels.dart';
import 'package:anymex/utils/function.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Home's rows, in your order, as a sliver.
class PlusHomeLayoutSliver extends StatelessWidget {
  /// AnymeX's "new episodes" strip (built by the Home page).
  final Widget Function() newEpisodes;

  /// Show the Anime tab's rows when you haven't arranged Home yet (false
  /// when an Anime / Discover tab is still in the bar).
  final bool discoverByDefault;

  const PlusHomeLayoutSliver({
    super.key,
    required this.newEpisodes,
    required this.discoverByDefault,
  });

  @override
  Widget build(BuildContext context) {
    final handler = Get.find<ServiceHandler>();
    final settings = Get.find<Settings>();
    return Obx(() {
      PlusLayoutStore.version.value;
      settings.uiSettings.value;
      PlusCustomLists.lists.length;
      final loggedIn = Get.find<AnilistAuth>().isLoggedIn.value;
      final rows = PlusPageRows.homeRows(discoverByDefault: discoverByDefault)
          .where((r) => !r.config.hidden)
          .toList();
      final anilist = handler.anilistService;
      List<Widget>? base, discover;
      Widget? buttons() {
        if (!loggedIn) return null;
        base ??= anilist.homeWidgets(context);
        return base!.isEmpty ? null : base!.first;
      }

      Widget? disc(String key) {
        discover ??= anilist.animeWidgets(context);
        final i = plusDiscoverRows.indexWhere((e) => e.$1 == key);
        return (i < 0 || i >= discover!.length) ? null : discover![i];
      }

      Widget rowWidget(PlusPlacedRow r) {
        final k = r.key;
        Widget? w;
        if (r.config.added) {
          w = PlusPageRows.addedRow(r);
        } else if (k == 'buttons') {
          w = buttons();
          if (w != null) {
            w = Padding(padding: const EdgeInsets.only(bottom: 10), child: w);
          }
        } else if (k == 'newEpisodes') {
          w = newEpisodes();
        } else if (k.startsWith('list:')) {
          w = PlusPageRows.listRow(plusListLabel(k), home: true);
        } else if (k == 'forYou') {
          w = const PlusForYouAnimeRow();
        } else if (k.startsWith('custom:')) {
          w = PlusPageRows.customListRow(k.substring('custom:'.length));
        } else if (k == 'missedSequels') {
          w = const PlusMissedSequelsRow();
        } else if (k == 'rec:anime') {
          w = PlusPageRows.recommendedRow(manga: false);
        } else if (k == 'rec:manga') {
          w = PlusPageRows.recommendedRow(manga: true);
        } else if (k.startsWith('disc:')) {
          w = disc(k);
        } else if (k.startsWith(plusHomeMoviesPrefix)) {
          w = PlusPageRows.homeMoviesRow(k);
        }
        if (w == null) return const SizedBox.shrink();
        return PlusPageRows.scoped(r, w);
      }

      return SliverList.builder(
        itemCount: rows.length + 1,
        itemBuilder: (context, i) => i == rows.length
            ? PlusPageRows.editButton(context,
                () => navigate(() => const PlusLayoutEditorPage(
                    page: PlusLayoutPage.home)))
            : rowWidget(rows[i]),
      );
    });
  }
}

/// The Manga tab's rows, in your order.
class PlusMangaLayout extends StatelessWidget {
  const PlusMangaLayout({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = Get.find<ServiceHandler>();
    final settings = Get.find<Settings>();
    return Obx(() {
      PlusLayoutStore.version.value;
      settings.uiSettings.value;
      final rows =
          PlusPageRows.mangaRows().where((r) => !r.config.hidden).toList();
      final all = handler.anilistService.mangaWidgets(context);
      // [banner, 4 rows, …novel rows…, community]
      Widget? at(String key) {
        if (all.isEmpty) return null;
        switch (key) {
          case 'm:carousel':
            return all[0];
          case 'm:trending':
          case 'm:latest':
          case 'm:popular':
          case 'm:more':
            final i = plusMangaRows.indexWhere((e) => e.$1 == key);
            return i < all.length - 1 ? all[i] : null;
          case 'm:novels':
            if (all.length <= 6) return null;
            return Column(children: all.sublist(5, all.length - 1));
          case 'm:community':
            return all.length > 5 ? all.last : null;
        }
        return null;
      }

      return Column(
        children: [
          for (final r in rows)
            () {
              Widget? w;
              if (r.config.added) {
                w = PlusPageRows.addedRow(r);
              } else if (r.key.startsWith('list:')) {
                w = PlusPageRows.listRow(plusListLabel(r.key), home: false);
              } else {
                w = at(r.key);
              }
              return w == null
                  ? const SizedBox.shrink()
                  : PlusPageRows.scoped(r, w);
            }(),
          PlusPageRows.editButton(
              context,
              () => navigate(() =>
                  const PlusLayoutEditorPage(page: PlusLayoutPage.manga))),
        ],
      );
    });
  }
}
