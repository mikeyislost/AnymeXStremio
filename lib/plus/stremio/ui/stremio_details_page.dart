// Stremio title page, built from the same pieces as AnymeX's own details
// page: MediaHeader, the Info/Watch bottom bar, the continue button, the
// user's episode card style and AnymeX's section panels.

import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/stremio/watched_bitfield.dart';
import 'package:anymex/controllers/discord/discord_rpc.dart';
import 'package:anymex/controllers/settings/methods.dart';
import 'package:anymex/controllers/settings/settings.dart';
import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/screens/anime/widgets/comments/comments_section.dart';
import 'package:anymex/screens/anime/widgets/episode/episode_style_registry.dart';
import 'package:anymex/plus/movie_watch_card.dart';
import 'package:anymex/plus/stremio/ui/stremio_info_tab.dart';
import 'package:anymex/plus/stremio/ui/stremio_player_bridge.dart';
import 'package:anymex/plus/stremio/ui/stremio_widgets.dart';
import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anime/media_header.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_bottomsheet.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_chip.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_image.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_linear_indicator.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_progress.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/common/anymex_scaffold.dart';
import 'package:anymex/widgets/common/navbar.dart';
import 'package:anymex/widgets/helper/platform_builder.dart';
import 'package:anymex/widgets/helper/tv_wrapper.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart' show Obx;
import 'package:hugeicons/hugeicons.dart';
import 'package:iconsax/iconsax.dart';
import 'package:url_launcher/url_launcher.dart';

class StremioDetailsPage extends StatefulWidget {
  final String type;
  final String id;
  final String tag;
  final String? initialTitle;
  final String? initialPoster;

  const StremioDetailsPage({
    super.key,
    required this.type,
    required this.id,
    required this.tag,
    this.initialTitle,
    this.initialPoster,
  });

  @override
  State<StremioDetailsPage> createState() => _StremioDetailsPageState();
}

class _StremioDetailsPageState extends State<StremioDetailsPage> {
  final _service = StremioService.to;
  StremioMeta? _meta;
  bool _loading = true;
  String? _error;
  int? _season;
  int _page = 0; // 0 = Info, 1 = Watch, 2 = Comments (same tabs as AnymeX)

  // Comments (Commentum v2), resolved when the tab is first opened.
  Media? _commentMedia;
  bool _resolvingComments = false;
  int? _commentSeason;
  WatchedBitField? _watched;
  StremioLibraryItem? _libraryItem;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Discord: back to "Browsing" when leaving the page.
    if (_meta != null) _discord((d) => d.updateBrowsingPresence());
    super.dispose();
  }

  /// Discord shows the title you're looking at ("Viewing <title>").
  void _showViewingStatus(StremioMeta meta) => _discord((d) =>
      d.updateMediaPresence(media: StremioPlayerBridge.mediaFor(meta)));

  void _discord(void Function(DiscordRPCController d) update) {
    try {
      update(DiscordRPCController.instance);
    } catch (_) {
      // Discord not set up.
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final meta = await _service.fetchMeta(widget.type, widget.id);
      if (meta == null) {
        _error = 'None of your addons have details for this title.';
      } else {
        final firstLoad = _meta == null;
        _meta = meta;
        if (firstLoad) _showViewingStatus(meta);
        if (!meta.isSingleVideo) {
          final seasons = meta.seasons;
          _season = seasons.isEmpty ? null : seasons.first;
        }
        await _loadLibraryState();
        final vid = _libraryItem?.videoId;
        if (vid != null && !meta.isSingleVideo) {
          for (final v in meta.videos) {
            if (v.id == vid) {
              _season = v.season ?? _season;
              break;
            }
          }
        }
      }
    } catch (e) {
      _error = 'Failed to load: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadLibraryState({bool refresh = true}) async {
    final meta = _meta;
    if (meta == null || !_service.isLoggedIn.value) return;
    _libraryItem = await _service.getLibraryItem(meta.id, refresh: refresh);
    if (_libraryItem != null && meta.videos.isNotEmpty) {
      _watched = WatchedBitField.construct(_libraryItem!.watchedField,
          WatchedBitField.orderedVideoIds(meta.videos));
    }
  }

  // ---- actions --------------------------------------------------------------

  void _openStreams(StremioVideo? video) {
    final meta = _meta;
    if (meta == null) return;
    HapticFeedback.lightImpact();
    AnymeXSheet.custom(
      StremioStreamsSheet(
        meta: meta,
        video: video,
        videoId: video?.id ?? meta.singleVideoId,
      ),
      context,
      showDragHandle: true,
    ).then((_) async {
      // The sync writes the local cache first; read from there.
      await Future.delayed(const Duration(milliseconds: 800));
      await _loadLibraryState(refresh: false);
      if (mounted) setState(() {});
    });
  }

  Future<void> _toggleWatched(StremioVideo video) async {
    final meta = _meta;
    if (meta == null) return;
    if (!_service.isLoggedIn.value) {
      snackBar('Log in to Stremio to mark episodes watched');
      return;
    }
    final now = !(_watched?.getVideo(video.id) ?? false);
    HapticFeedback.selectionClick();
    try {
      await _service.setVideoWatched(meta, video, now);
      await _loadLibraryState(refresh: false);
      if (mounted) setState(() {});
      snackBar(now ? 'Marked as watched' : 'Marked as unwatched');
    } catch (e) {
      snackBar('Could not update Stremio: $e');
    }
  }

  /// The episode Stremio says you're on, else the first released episode.
  StremioVideo? get _continueVideo {
    final meta = _meta;
    if (meta == null || meta.isSingleVideo) return null;
    final current = _libraryItem?.videoId;
    if (current != null) {
      for (final v in meta.videos) {
        if (v.id == current) return v;
      }
    }
    final seasons = meta.seasons.where((s) => s != 0).toList();
    if (seasons.isEmpty) return null;
    final eps = meta.videosForSeason(seasons.first);
    return eps.isEmpty ? null : eps.first;
  }

  // ---- media for AnymeX widgets -------------------------------------------

  Media get _headerMedia {
    final meta = _meta;
    if (meta == null) {
      return Media(
        id: StremioIds.mediaId(widget.type, widget.id),
        title: widget.initialTitle ?? 'Loading...',
        poster: widget.initialPoster ?? '',
        status: stremioTypeLabel(widget.type, plural: false),
        serviceType: ServicesType.extensions,
      );
    }
    final media = StremioPlayerBridge.mediaFor(meta);
    media.status = stremioTypeLabel(meta.type, plural: false);
    media.studios = [meta.releaseInfo ?? stremioTypeLabel(meta.type)];
    return media;
  }

  Episode _episodeFor(StremioVideo video) {
    final meta = _meta!;
    final ep = StremioPlayerBridge.episodeFor(meta, video);
    if (video.id == _libraryItem?.videoId &&
        (_libraryItem?.timeOffset ?? 0) > 1 &&
        (_libraryItem?.duration ?? 0) > 0) {
      ep.timeStampInMilliseconds = _libraryItem!.timeOffset;
      ep.durationInMilliseconds = _libraryItem!.duration;
    }
    return ep;
  }

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final media = _headerMedia;
    final poster = _meta?.poster ?? widget.initialPoster ?? '';

    return AnymeXScaffold(
      extendBody: true,
      resizeToAvoidBottomInset: false,
      bottomNavigationBar: _bottomBar(context),
      body: ScrollConfiguration(
        behavior:
            ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics()),
          slivers: [
            SliverToBoxAdapter(
              child: MediaHeader(
                tag: widget.tag,
                data: media,
                posterUrl: poster,
                enableVisuals: false,
              ),
            ),
            if (_loading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: AnymeXProgressIndicator()),
                ),
              )
            else if (_error != null)
              SliverToBoxAdapter(child: _errorView(context))
            else if (_meta != null) ...[
              SliverToBoxAdapter(child: _quickActions(context, _meta!)),
              if (_page == 0)
                SliverToBoxAdapter(
                  child: StremioInfoTab(
                    meta: _meta!,
                    season: _meta!.isSingleVideo
                        ? null
                        : (_season == 0 ? null : _season),
                  ),
                )
              else if (_page == 1)
                ..._watchTab(context, _meta!)
              else
                ..._commentsTab(context, _meta!),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 180)),
          ],
        ),
      ),
    );
  }

  /// Library / Continue Watching actions, like Stremio's details page.
  Widget _quickActions(BuildContext context, StremioMeta meta) {
    return Obx(() {
      if (!_service.isLoggedIn.value) return const SizedBox.shrink();
      // Rebuild when the library or Continue Watching changes.
      _service.library.length;
      _service.continueWatching.length;
      final inLibrary = _service.isInLibrary(meta.id);
      final inCw = _service.isInContinueWatching(meta.id);
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: _actionButton(
                context,
                icon: inLibrary
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_add_outlined,
                label: inLibrary ? 'In Library' : 'Add to Library',
                highlighted: inLibrary,
                onTap: () async {
                  try {
                    if (inLibrary) {
                      await _service.removeFromLibrary(meta.id);
                      snackBar('Removed from your Stremio library');
                    } else {
                      await _service.addToLibrary(
                        id: meta.id,
                        type: meta.type,
                        name: meta.name,
                        poster: meta.poster,
                      );
                      snackBar('Added to your Stremio library');
                    }
                  } catch (e) {
                    snackBar('Stremio: $e');
                  }
                },
              ),
            ),
            if (inCw) ...[
              const SizedBox(width: 10),
              Expanded(
                child: _actionButton(
                  context,
                  icon: Icons.history_toggle_off_rounded,
                  label: 'Remove from Continue',
                  onTap: () async {
                    try {
                      await _service.dismissFromContinueWatching(meta.id);
                      await _loadLibraryState(refresh: false);
                      if (mounted) setState(() {});
                      snackBar('Removed from Continue Watching');
                    } catch (e) {
                      snackBar('Stremio: $e');
                    }
                  },
                ),
              ),
            ],
          ],
        ),
      );
    });
  }

  Widget _actionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool highlighted = false,
  }) {
    final colors = context.colors;
    return AnymexOnTap(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: highlighted
              ? colors.primary.opaque(0.18, iReallyMeanIt: true)
              : colors.surfaceContainerHighest.opaque(0.3, iReallyMeanIt: true),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: highlighted
                ? colors.primary.opaque(0.4, iReallyMeanIt: true)
                : colors.onSurface.opaque(0.08, iReallyMeanIt: true),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 18,
                color: highlighted ? colors.primary : colors.onSurface),
            const SizedBox(width: 8),
            Flexible(
              child: AnymeXText(
                label,
                size: 12.5,
                variant: TextVariant.semiBold,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                color: highlighted ? colors.primary : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Comments tab ---------------------------------------------------------------

  /// Commentum needs an id in the commenting account's id space: anime is
  /// matched to its AniList entry (same thread as AnymeX's anime page),
  /// movies and series use their IMDb id.
  Future<void> _resolveCommentMedia() async {
    final meta = _meta;
    if (meta == null || _resolvingComments) return;
    final season = meta.isSingleVideo
        ? null
        : (_season == 0 ? null : _season);
    if (_commentMedia != null && _commentSeason == season) return;
    setState(() => _resolvingComments = true);
    final id = await _service.commentMediaId(meta, season: season);
    if (!mounted) return;
    final poster = meta.poster ?? meta.background ?? '';
    setState(() {
      _commentSeason = season;
      _commentMedia = Media(
        id: id,
        title: meta.name,
        romajiTitle: meta.name,
        englishTitle: meta.name,
        poster: poster,
        largePoster: poster,
        cover: meta.background,
        description: meta.description ?? '',
        aired: meta.releaseInfo ?? '?',
        serviceType: ServicesType.anilist,
      );
      _resolvingComments = false;
    });
  }

  List<Widget> _commentsTab(BuildContext context, StremioMeta meta) {
    final media = _commentMedia;
    if (media == null || _resolvingComments) {
      if (media == null && !_resolvingComments) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _resolveCommentMedia());
      }
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: AnymeXProgressIndicator()),
          ),
        ),
      ];
    }
    return [
      CommentSection(
        key: ValueKey('stremio-comments-${media.id}'),
        media: media,
        asSliver: true,
      ),
    ];
  }

  Widget _errorView(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: StremioSection(
        children: [
          AnymeXText(_error!, size: 13),
          const SizedBox(height: 8),
          AnymexOnTap(
            onTap: _load,
            child: AnymeXText('Retry',
                variant: TextVariant.bold, color: context.colors.primary),
          ),
        ],
      ),
    );
  }

  // Watch tab -----------------------------------------------------------------

  List<Widget> _watchTab(BuildContext context, StremioMeta meta) {
    final style = EpisodeStyleRegistry.activeStyle;

    if (meta.isSingleVideo) {
      final item = _libraryItem;
      final progress = (item != null && item.duration > 0)
          ? (item.timeOffset / item.duration).clamp(0.0, 1.0)
          : 0.0;
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          sliver: SliverToBoxAdapter(
            child: MovieWatchCard(
              title: meta.name,
              imageUrl: meta.background ?? meta.poster ?? '',
              fallbackImage: meta.poster,
              badge: meta.type == 'movie'
                  ? 'MOVIE'
                  : stremioTypeLabel(meta.type, plural: false).toUpperCase(),
              details: [
                formatMovieRuntime(meta.runtime ?? ''),
                meta.releaseInfo ?? '',
                if (meta.imdbRating != null) '★ ${meta.imdbRating}',
              ],
              progress: progress,
              watched: (item?.timesWatched ?? 0) > 0,
              onPlay: () => _openStreams(null),
            ),
          ),
        ),
      ];
    }

    final seasons = meta.seasons;
    final videos =
        _season == null ? meta.videos : meta.videosForSeason(_season!);
    final currentId = _libraryItem?.videoId;
    final currentProgress = _libraryItem?.progress ?? 0.0;

    Widget card(BuildContext context, int i) {
      final v = videos[i];
      final watched = _watched?.getVideo(v.id) ?? false;
      final isCurrent = v.id == currentId;
      return style.builder(
        context,
        _episodeFor(v),
        isCurrent,
        watched,
        isCurrent ? currentProgress : (watched ? 1.0 : 0.0),
        _headerMedia,
        v.isReleased ? () => _openStreams(v) : () => snackBar('Not released yet'),
        () => _toggleWatched(v),
      );
    }

    return [
      if (seasons.length > 1)
        SliverToBoxAdapter(
          child: SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: seasons.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final s = seasons[i];
                return AnymeXChip(
                  label: s == 0 ? 'Specials' : 'Season $s',
                  isSelected: _season == s,
                  showCheck: false,
                  onSelected: (_) => setState(() => _season = s),
                );
              },
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
          child: AnymeXText(
            '${videos.length} episodes · long-press to mark watched',
            size: 12,
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: style.isGrid
            ? SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: getResponsiveCrossAxisCount(
                    context,
                    baseColumns: 1,
                    maxColumns: 3,
                    mobileItemWidth: 400,
                    tabletItemWidth: 400,
                    desktopItemWidth: 200,
                  ),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  mainAxisExtent: style.id == 'minimal' ? 65 : 100,
                ),
                itemCount: videos.length,
                itemBuilder: card,
              )
            : SliverList.builder(
                itemCount: videos.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: card(context, i),
                ),
              ),
      ),
    ];
  }

  // Bottom bar (same as AnymeX details) ---------------------------------------

  Widget _bottomBar(BuildContext context) {
    final isDesktop =
        getResponsiveValue(context, mobileValue: false, desktopValue: true);
    final items = [
      NavItem(
        selectedIcon: Iconsax.info_circle5,
        unselectedIcon: Iconsax.info_circle,
        label: 'Info',
        onTap: (i) => setState(() => _page = i),
      ),
      NavItem(
        selectedIcon: Iconsax.play5,
        unselectedIcon: Iconsax.play,
        label: 'Watch',
        onTap: (i) => setState(() => _page = i),
      ),
      NavItem(
        selectedIcon: HugeIcons.strokeRoundedComment01,
        unselectedIcon: HugeIcons.strokeRoundedComment02,
        label: 'Comments',
        onTap: (i) {
          setState(() => _page = i);
          _resolveCommentMedia();
        },
      ),
    ];
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: (_page == 1 && !_loading && _meta != null)
              ? _continueButton(context)
              : const SizedBox.shrink(),
        ),
        SafeArea(
          child: ResponsiveNavBar(
            isDesktop: false,
            currentIndex: _page,
            margin: EdgeInsets.fromLTRB(
                32, 0, 32, settingsController.bottomNavBarMargin),
            items: items,
          ),
        ),
      ],
    );
    if (isDesktop == true) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: child,
        ),
      );
    }
    return child;
  }

  Widget _continueButton(BuildContext context) {
    final meta = _meta!;
    final item = _libraryItem;
    String title;
    String image;
    double progress = 0;
    VoidCallback onTap;

    if (meta.isSingleVideo) {
      final resume = item != null && item.timeOffset > 1;
      title = resume ? 'Resume ${meta.name}' : 'Play ${meta.name}';
      image = meta.background ?? meta.poster ?? '';
      progress = resume ? item!.progress : 0;
      onTap = () => _openStreams(null);
    } else {
      final v = _continueVideo;
      if (v == null) return const SizedBox.shrink();
      final label = 'S${v.season ?? 1} E${v.episode ?? 1}';
      title = v.title.isNotEmpty ? '$label - ${v.title}' : label;
      image = v.thumbnail ?? meta.background ?? meta.poster ?? '';
      if (item?.videoId == v.id) progress = item!.progress;
      onTap = () => _openStreams(v);
    }

    final theme = Theme.of(context);
    final clamped = progress.clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 52,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer
                .opaque(0.4, iReallyMeanIt: true),
            borderRadius: BorderRadius.circular(24.multiplyRadius()),
            border: Border.all(
              color: theme.colorScheme.outline.opaque(0.12, iReallyMeanIt: true),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.opaque(0.12, iReallyMeanIt: true),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 60,
                  height: 38,
                  child: AnymeXImage(
                      imageUrl: image, fit: BoxFit.cover, radius: 0),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnymeXText(
                      title,
                      size: 11.5,
                      variant: TextVariant.semiBold,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      isMarquee: true,
                    ),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(50),
                      child: AnymeXLinearIndicator(
                        value: clamped > 0 ? clamped : 0.05,
                        minHeight: 8,
                        color: theme.colorScheme.primary,
                        backgroundColor:
                            theme.colorScheme.onSurface.opaque(0.1, iReallyMeanIt: true),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.opaque(0.9),
                  borderRadius: BorderRadius.circular(32.multiplyRadius()),
                ),
                child: Icon(Icons.play_arrow_rounded,
                    size: 16, color: theme.colorScheme.onPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stream picker in AnymeX's sheet + server-list style. Fills in as each
/// addon answers.
class StremioStreamsSheet extends StatefulWidget {
  final StremioMeta? meta;
  final StremioVideo? video;
  final String videoId;

  /// Stremio type to request; defaults to the meta's type.
  final String? type;

  /// Header line under "Select stream"; defaults to the title / episode.
  final String? title;

  /// Plays the chosen stream; defaults to playing it as a Stremio title.
  final Future<void> Function(
      StremioStream selected, List<StremioStream> all)? onPlay;

  const StremioStreamsSheet({
    super.key,
    required this.meta,
    required this.video,
    required this.videoId,
    this.type,
    this.title,
    this.onPlay,
  });

  @override
  State<StremioStreamsSheet> createState() => _StremioStreamsSheetState();
}

enum _SizeSort { none, smallest, largest }

class _StremioStreamsSheetState extends State<StremioStreamsSheet> {
  final Map<String, List<StremioStream>> _byAddon = {};
  final List<String> _addonOrder = [];
  int _pending = 0;
  bool _started = false;

  // AnymeX+: filters and the choice remembered for this title.
  String? _quality;
  String? _addonFilter;
  _SizeSort _sizeSort = _SizeSort.none;
  late final String _titleKey =
      StremioService.streamTitleKey(widget.meta?.id, widget.videoId);
  late final ({String? addon, String? quality}) _pref =
      StremioService.to.streamPrefFor(_titleKey);

  bool _isPreferred(StremioStream s) =>
      _pref.addon != null &&
      s.addonName == _pref.addon &&
      ((_pref.quality ?? '').isEmpty || s.quality == _pref.quality);

  bool _matches(StremioStream s) =>
      (_quality == null || s.quality == _quality) &&
      (_addonFilter == null || s.addonName == _addonFilter);

  /// Your usual picks first, the rest in the addon's order.
  List<StremioStream> _ordered(List<StremioStream> list) {
    final pref = list.where(_isPreferred).toList();
    return [...pref, ...list.where((e) => !_isPreferred(e))];
  }

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final service = StremioService.to;
    await service.ensureAddons();
    if (!mounted) return;
    final type = widget.type ?? widget.meta?.type ?? 'movie';
    final sources = service.addons
        .where((a) =>
            service.isAddonUsable(a) &&
            (a.supports('stream', type, widget.videoId) ||
                a.supports('stream', 'anime', widget.videoId)))
        .toList();
    setState(() {
      _started = true;
      _pending = sources.length;
      _addonOrder
        ..clear()
        ..addAll(sources.map((a) => a.name));
    });
    await service.fetchStreams(
      type,
      widget.videoId,
      onAddonResult: (addon, streams) {
        if (!mounted) return;
        setState(() {
          _pending = _pending > 0 ? _pending - 1 : 0;
          _byAddon[addon.name] = streams;
        });
      },
    );
  }

  List<StremioStream> get _all => _addonOrder
      .expand((a) => _byAddon[a] ?? const <StremioStream>[])
      .toList();

  Future<void> _select(StremioStream s) async {
    if (!s.isPlayable) {
      final external = s.externalUrl ??
          (s.ytId != null ? 'https://www.youtube.com/watch?v=${s.ytId}' : null);
      if (external != null) {
        await launchUrl(Uri.parse(external),
            mode: LaunchMode.externalApplication);
      } else {
        snackBar('This stream type is not supported');
      }
      return;
    }
    StremioService.to.rememberStreamChoice(_titleKey, s);
    final all = _all.where((e) => e.isPlayable).toList();
    if (widget.onPlay != null) {
      await widget.onPlay!(s, all);
    } else {
      await StremioPlayerBridge.play(
        meta: widget.meta!,
        video: widget.video,
        selected: s,
        allStreams: all,
      );
    }
    // Back from the player: close the picker so the details page refreshes.
    if (mounted) Navigator.of(context).pop();
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => setState(onTap),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        showCheckmark: false,
        selectedColor: colors.primaryContainer,
        side: BorderSide(
            color: colors.onSurface.opaque(0.12, iReallyMeanIt: true)),
      ),
    );
  }

  /// Quality, addon and size filters (only the options these streams have).
  Widget _filterBar(BuildContext context) {
    final all = _all;
    final qualities =
        streamQualities.where((q) => all.any((s) => s.quality == q)).toList();
    final addonsWithStreams =
        _addonOrder.where((a) => (_byAddon[a] ?? const []).isNotEmpty).toList();
    final hasSizes = all.any((s) => s.sizeGb != null);
    final sizeLabel = switch (_sizeSort) {
      _SizeSort.none => 'Size',
      _SizeSort.smallest => 'Smallest first',
      _SizeSort.largest => 'Largest first',
    };
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        children: [
          if (qualities.length > 1) ...[
            _chip('All', _quality == null, () => _quality = null),
            for (final q in qualities)
              _chip(q, _quality == q, () => _quality = _quality == q ? null : q),
          ],
          if (addonsWithStreams.length > 1)
            for (final a in addonsWithStreams)
              _chip(a, _addonFilter == a,
                  () => _addonFilter = _addonFilter == a ? null : a),
          if (hasSizes)
            _chip(sizeLabel, _sizeSort != _SizeSort.none, () {
              _sizeSort = _SizeSort
                  .values[(_sizeSort.index + 1) % _SizeSort.values.length];
            }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final v = widget.video;
    final title = widget.title ??
        (v == null
            ? (widget.meta?.name ?? '')
            : 'S${v.season ?? 1} E${v.episode ?? 1}'
                '${v.title.isNotEmpty ? ' · ${v.title}' : ''}');

    final children = <Widget>[];
    if (_started && _addonOrder.isEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.all(24),
        child: AnymeXText(
          'No stream addons installed for this title. Add one (e.g. '
          'Torrentio) from the Stremio account page.',
          textAlign: TextAlign.center,
          color: colors.onSurfaceVariant,
        ),
      ));
    }
    if (_sizeSort != _SizeSort.none) {
      // One list across addons, by file size (unknown sizes last).
      final list = _all.where(_matches).toList()
        ..sort((a, b) {
          final x = a.sizeGb, y = b.sizeGb;
          if (x == null && y == null) return 0;
          if (x == null) return 1;
          if (y == null) return -1;
          return _sizeSort == _SizeSort.smallest
              ? x.compareTo(y)
              : y.compareTo(x);
        });
      for (final s in list) {
        children.add(_StreamTile(
            stream: s, preferred: _isPreferred(s), onTap: () => _select(s)));
      }
    } else {
      // Your usual addon first.
      final order = [
        if (_pref.addon != null && _addonOrder.contains(_pref.addon))
          _pref.addon!,
        ..._addonOrder.where((a) => a != _pref.addon),
      ];
      for (final addonName in order) {
        if (_addonFilter != null && addonName != _addonFilter) continue;
        final all = _byAddon[addonName];
        if (all == null) continue;
        final streams = _ordered(all.where(_matches).toList());
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
          child: AnymeXText(
            streams.isEmpty
                ? '$addonName — ${all.isEmpty ? 'no streams' : 'none match'}'
                : addonName,
            size: 13,
            variant: TextVariant.bold,
            color: streams.isEmpty ? colors.onSurfaceVariant : colors.primary,
          ),
        ));
        for (final s in streams) {
          children.add(_StreamTile(
              stream: s, preferred: _isPreferred(s), onTap: () => _select(s)));
        }
      }
    }
    if (_pending == 0 && _started && _all.isEmpty && _addonOrder.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.all(24),
        child: AnymeXText('No streams found.',
            textAlign: TextAlign.center, color: colors.onSurfaceVariant),
      ));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              Icon(Iconsax.play_circle, color: colors.primary, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const AnymeXText('Select stream',
                        size: 16, variant: TextVariant.bold),
                    AnymeXText(title,
                        size: 12,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        color: colors.onSurfaceVariant),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (_all.isNotEmpty) _filterBar(context),
        if (_pending > 0 || !_started)
          ClipRRect(
            borderRadius: BorderRadius.circular(50),
            child: AnymeXLinearIndicator(
              minHeight: 3,
              color: colors.primary,
              backgroundColor: colors.onSurface.opaque(0.08, iReallyMeanIt: true),
            ),
          ),
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.6,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              children: children,
            ),
          ),
        ),
      ],
    );
  }
}

class _StreamTile extends StatelessWidget {
  final StremioStream stream;
  final VoidCallback onTap;

  /// Matches the addon and quality you picked last time for this title.
  final bool preferred;

  const _StreamTile(
      {required this.stream, required this.onTap, this.preferred = false});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final playable = stream.isPlayable;
    final details = stream.details;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: AnymexOnTap(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest
                .opaque(0.3, iReallyMeanIt: true),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: colors.onSurface.opaque(0.06, iReallyMeanIt: true),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: colors.primaryContainer
                      .opaque(0.3, iReallyMeanIt: true),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  stream.isTorrent
                      ? Icons.downloading_rounded
                      : (playable
                          ? Icons.play_arrow_rounded
                          : Icons.open_in_new_rounded),
                  size: 20,
                  color: playable ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnymeXText(
                      (stream.name ?? stream.addonName).replaceAll('\n', ' '),
                      size: 13,
                      variant: TextVariant.semiBold,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (details.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      AnymeXText(
                        details,
                        size: 11,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                    if (preferred) ...[
                      const SizedBox(height: 4),
                      AnymeXText('★ Your usual pick',
                          size: 11,
                          variant: TextVariant.semiBold,
                          color: colors.primary),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
