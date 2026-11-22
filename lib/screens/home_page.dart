import 'package:anymex/widgets/common/media_row_drag.dart';
import 'dart:math' as math;

import 'package:anymex/controllers/offline/offline_storage_controller.dart';
import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/settings/settings.dart';
import 'package:anymex/controllers/source/source_controller.dart';
import 'package:anymex/database/data_keys/keys.dart';
import 'package:anymex/plus/layout/home_layout.dart';
import 'package:anymex/plus/layout/page_rows.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/screens/search/search_view.dart';
import 'package:anymex/screens/search/source_search_page.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/widgets/common/reusable_carousel.dart';
import 'package:anymex/widgets/common/search_bar.dart';
import 'package:anymex/widgets/common/scroll_aware_app_bar.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_textspan.dart';
import 'package:anymex/widgets/header/header.dart';
import 'package:anymex/widgets/helper/platform_builder.dart';
import 'package:anymex/widgets/history/tap_history_cards.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/widgets/media_items/media_item.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:anymex/theme/yumori_tokens.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:anymex/plus/home/home_hero.dart';
import 'package:flutter_iconly/flutter_iconly.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

void openAnimeSearch(ServiceHandler handler) {
  switch (handler.serviceType.value) {
    case ServicesType.simkl:
      navigate(() => const SearchPage(
            searchTerm: '',
            isManga: false,
            type: ItemType.anime,
          ));
    case ServicesType.extensions:
      navigateWithAnimation(() => const SourceSearchPage(
            initialTerm: '',
            type: ItemType.anime,
          ));
    default:
      navigate(() => const SearchPage(searchTerm: '', isManga: false));
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late ScrollController _scrollController;
  Timer? _heroFallback;
  final ValueNotifier<bool> _isAppBarVisibleExternally =
      ValueNotifier<bool>(true);
  final List<Worker> _workers = [];

  Widget _buildNewEpisodesSection() {
    final serviceHandler = Get.find<ServiceHandler>();
    return Obx(() {
      final entries = <(Media, int, int, DateTime?)>[];

      if (serviceHandler.isLoggedIn.value ||
          serviceHandler.animeList.isNotEmpty) {
        final now = DateTime.now();
        for (final item in serviceHandler.animeList) {
          if (item.type?.toUpperCase() == 'MANGA' || item.id == null) continue;
          final watched = item.effectiveProgress;
          int latestReleased = 0;
          if (item.releasedEpisodes != null &&
              item.releasedEpisodes!.isNotEmpty) {
            latestReleased = int.tryParse(item.releasedEpisodes!) ?? 0;
          } else if (item.mediaStatus?.toUpperCase() == 'COMPLETED' ||
              item.mediaStatus?.toUpperCase() == 'FINISHED') {
            latestReleased = int.tryParse(item.totalEpisodes ?? '') ?? 0;
          }

          final status = item.watchingStatus?.toUpperCase();
          final isWatching = status == 'CURRENT' ||
              status == 'WATCHING' ||
              status == 'REPEATING' ||
              status == 'REWATCHING';

          if (!isWatching || latestReleased <= watched) {
            continue;
          }

          final media = CardData.fromTrackedMedia(item).data;
          final releaseDate = NewEpisodeReleaseCard.calculateReleaseDate(
            media: media,
            latestReleasedEpisode: latestReleased,
            itemEndDate: item.endDate,
            mediaStatus: item.mediaStatus,
          );

          final mediaStatus = item.mediaStatus?.toUpperCase();
          final isStillAiring = mediaStatus == 'RELEASING' ||
              mediaStatus == 'AIRING' ||
              item.nextAiringEpisode != null;

          if (!isStillAiring) {
            if (releaseDate == null ||
                now.isAfter(releaseDate.add(const Duration(days: 7)))) {
              continue;
            }
          }

          entries.add((media, watched, latestReleased, releaseDate));
        }

        entries.sort((a, b) {
          final dateA = a.$4;
          final dateB = b.$4;
          if (dateA == null && dateB == null) return 0;
          if (dateA == null) return 1;
          if (dateB == null) return -1;
          return dateB.compareTo(dateA);
        });
      }

      if (entries.isEmpty) {
        return const SizedBox.shrink();
      }

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5.0),
        child: SizedBox(
          height: 110,
          child: RepaintBoundary(
            child: MediaRowDrag(child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: entries.length,
              itemBuilder: (context, i) => NewEpisodeReleaseCard(
                media: entries[i].$1,
                watchedEpisode: entries[i].$2,
                latestReleasedEpisode: entries[i].$3,
                releaseDate: entries[i].$4,
              ),
            )),
          ),
        ),
      );
    });
  }

  List<Widget> _buildHomeWidgets({
    required BuildContext context,
    required ServiceHandler serviceHandler,
    required OfflineStorageController offlineStorageController,
    required Settings settings,
  }) {
    final baseWidgets = serviceHandler.homeWidgets(context);
    final localSections = <Widget>[
      _buildNewEpisodesSection(),
    ];

    int insertionIndex;
    if (serviceHandler.serviceType.value == ServicesType.simkl) {
      insertionIndex = serviceHandler.isLoggedIn.value ? 3 : 2;
    } else if (!serviceHandler.isLoggedIn.value ||
        serviceHandler.serviceType.value == ServicesType.extensions) {
      insertionIndex = 0;
    } else {
      insertionIndex = 2;
    }
    insertionIndex = math.min(insertionIndex, baseWidgets.length);

    return [
      ...baseWidgets.take(insertionIndex),
      ...localSections,
      ...baseWidgets.skip(insertionIndex),
    ];
  }

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(() {
      if (_scrollController.hasClients &&
          YumoriHeroBus.scope.value != 'manga') {
        YumoriHeroBus.offset.value = _scrollController.offset;
      }
    });
    YumoriHeroBus.scope.addListener(_syncHeroOffset);
    YumoriHeroBus.offset.value = 0;
    // Hold Home's content until the Featured hero has its first picture, but
    // never longer than 7 s (a slow network shows the page anyway).
    if (!YumoriHeroBus.ready.value) {
      _heroFallback = Timer(const Duration(seconds: 7), () {
        YumoriHeroBus.ready.value = true;
      });
    }
    final serviceHandler = Get.find<ServiceHandler>();
    _workers.add(ever(serviceHandler.serviceType, (_) {
      if (mounted) setState(() {});
    }));
    _workers.add(ever(serviceHandler.isLoggedIn, (_) {
      if (mounted) setState(() {});
    }));
  }

  void _syncHeroOffset() {
    if (YumoriHeroBus.scope.value == 'home' && _scrollController.hasClients) {
      YumoriHeroBus.offset.value = _scrollController.offset;
    }
  }

  ScrollController get scrollController => _scrollController;

  /// Exactly what the Anime tab's search button opened.
  bool _showDiscoverOnHome(Settings settings, ServiceHandler handler) {
    if (handler.serviceType.value == ServicesType.extensions) return false;
    final tabs = settings.navigationTabOrder;
    return !tabs.contains('Anime') && !tabs.contains('Discover');
  }

  @override
  void dispose() {
    _heroFallback?.cancel();
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
    YumoriHeroBus.scope.removeListener(_syncHeroOffset);
    YumoriHeroBus.active.value = false;
    _scrollController.dispose();
    _isAppBarVisibleExternally.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offlineStorageController = Get.find<OfflineStorageController>();
    final serviceHandler = Get.find<ServiceHandler>();
    final settings = Get.find<Settings>();
    final sourceController = Get.find<SourceController>();
    final isDesktop = MediaQuery.sizeOf(context).width > 600;
    final statusBarHeight = MediaQuery.paddingOf(context).top;
    const appBarHeight = kToolbarHeight + 20;
    final double bottomNavBarHeight =
        isDesktop ? 20.0 : (MediaQuery.paddingOf(context).bottom + 65.0);

    final List<dynamic> novelData = [];

    return RefreshIndicator(
      onRefresh: () {
        if (!serviceHandler.isLoggedIn.value) {
          snackBar(
              "W-what are you doing step-bro, login before you do that (●´⌓`●)",
              duration: 1200);
        }
        return serviceHandler.refresh();
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        body: Stack(
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: YumoriHeroBus.ready,
              builder: (context, ready, child) => IgnorePointer(
                ignoring: !ready,
                child: AnimatedOpacity(
                  opacity: ready ? 1 : 0,
                  duration: const Duration(milliseconds: 350),
                  child: child,
                ),
              ),
              child: CustomScrollView(
              controller: _scrollController,
              cacheExtent: 1200.0, // AnymeX+: nearby rows stay built
              slivers: [
                // Moonlit 4: the Featured hero fills the top, behind the header.
                SliverToBoxAdapter(
                  child: PlusPageRows.appliesTo(serviceHandler)
                      ? PlusHomeHero(
                          topInset: statusBarHeight + appBarHeight,
                          isDesktop: isDesktop,
                          discoverByDefault:
                              _showDiscoverOnHome(settings, serviceHandler),
                        )
                      : YumoriHomeHero(
                          topInset: statusBarHeight + appBarHeight,
                          fullScreen: isDesktop,
                          height: isDesktop
                              ? (MediaQuery.sizeOf(context).height - 250)
                                  .clamp(420.0, 900.0)
                              : 560),
                ),
                // AnymeX+: with AniList, Home is your layout (Edit layout):
                // your rows and the Anime tab's, in your order.
                if (PlusPageRows.appliesTo(serviceHandler))
                  PlusHomeLayoutSliver(
                    newEpisodes: _buildNewEpisodesSection,
                    discoverByDefault:
                        _showDiscoverOnHome(settings, serviceHandler),
                  )
                else
                () {
                  final homeWidgets = _buildHomeWidgets(
                    context: context,
                    serviceHandler: serviceHandler,
                    offlineStorageController: offlineStorageController,
                    settings: settings,
                  );
                  return SliverList.builder(
                    itemCount: homeWidgets.length,
                    itemBuilder: (context, index) => RepaintBoundary(
                      child: homeWidgets[index],
                    ),
                  );
                }(),
                // AnymeX+: the Anime tab's discover rows live on Home now
                // (unless an Anime/Discover tab is still in the bar).
                if (!PlusPageRows.appliesTo(serviceHandler) &&
                    _showDiscoverOnHome(settings, serviceHandler))
                  SliverToBoxAdapter(
                    child: Obx(() {
                      final isSimkl = serviceHandler.serviceType.value ==
                          ServicesType.simkl;
                      final widgets = serviceHandler.animeWidgets(context);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                                isDesktop ? 24.0 : 20.0, 24, 20, 6),
                            child: AnymeXText(
                              isSimkl ? 'Discover movies' : 'Discover anime',
                              size: 20,
                              variant: TextVariant.bold,
                              color: context.colors.primary,
                            ),
                          ),
                          ...widgets.skip(1).map((w) => RepaintBoundary(child: w)),
                        ],
                      );
                    }),
                  ),
                if (novelData.isNotEmpty)
                  SliverToBoxAdapter(
                    child: ReusableCarousel(
                      title: "Recommended Novels",
                      data: novelData,
                      type: ItemType.novel,
                      source: sourceController.activeNovelSource.value,
                    ),
                  ),
                SliverToBoxAdapter(
                  child: SizedBox(height: bottomNavBarHeight + 150),
                ),
              ],
            ),
            ),
            if (!isDesktop)
              CustomAnimatedAppBar(
                isVisible: _isAppBarVisibleExternally,
                scrollController: _scrollController,
                headerContent: Header(
                  plain: true,
                  leading: const HeaderWordmarkButton(),
                  actions: [
                    HeaderActionButton(
                      icon: IconlyLight.search,
                      onTap: () =>
                          openAnimeSearch(Get.find<ServiceHandler>()),
                    ),
                    const SizedBox(width: 8),
                    const HeaderProfileAvatar(),
                  ],
                ),
                visibleStatusBarStyle: SystemUiOverlayStyle(
                  statusBarIconBrightness:
                      Theme.of(context).brightness == Brightness.light
                          ? Brightness.dark
                          : Brightness.light,
                  statusBarBrightness: Theme.of(context).brightness,
                  statusBarColor: Colors.transparent,
                ),
                hiddenStatusBarStyle: SystemUiOverlayStyle(
                  statusBarIconBrightness:
                      Theme.of(context).brightness == Brightness.light
                          ? Brightness.light
                          : Brightness.dark,
                  statusBarBrightness:
                      Theme.of(context).brightness == Brightness.light
                          ? Brightness.dark
                          : Brightness.light,
                  statusBarColor: Colors.transparent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
