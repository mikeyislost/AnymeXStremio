// AnymeX+: the anime Watch tab when streams come from the user's Stremio
// addons instead of AnymeX extensions. The anime is matched to Kitsu / IMDb
// ids (ani.zip), episodes are listed with AnymeX's episode card style, and
// playback keeps the AniList/MAL media so tracking works as usual.

import 'dart:math';

import 'package:anymex/controllers/offline/offline_storage_controller.dart';
import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/controllers/settings/settings.dart';
import 'package:anymex/database/data_keys/keys.dart';
import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/database/isar_models/offline_media.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/screens/anime/widgets/episode/episode_style_registry.dart';
import 'package:anymex/screens/anime/widgets/episode_range.dart';
import 'package:anymex/plus/movie_watch_card.dart';
import 'package:anymex/screens/anime/widgets/track_dialog.dart';
import 'package:anymex/plus/stremio/ui/stremio_details_page.dart'
    show StremioStreamsSheet;
import 'package:anymex/plus/stremio/ui/stremio_player_bridge.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/utils/string_extensions.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_bottomsheet.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_progress.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/common/anymex_pills.dart';
import 'package:anymex/widgets/helper/platform_builder.dart';
import 'package:anymex/widgets/helper/tv_wrapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// Pills that switch the anime Watch tab between AnymeX extensions and
/// Stremio addons. Hidden when no Stremio stream addon is installed.
class AnimeStreamSourceSwitch extends StatelessWidget {
  /// False for titles that can't be matched to Stremio (extension-only).
  final bool available;

  const AnimeStreamSourceSwitch({super.key, this.available = true});

  @override
  Widget build(BuildContext context) {
    final service = StremioService.to;
    return Obx(() {
      // Touch the list so this rebuilds when addons load.
      final hasAddons = service.addons.isNotEmpty && service.hasStreamAddons;
      final mode = service.animeStreamSource.value;
      if (!available || (!hasAddons && mode != 'stremio')) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AnymeXPills(
          scrollPadding: EdgeInsets.zero,
          items: [
            PillItem(
              label: 'Extensions',
              icon: Icons.extension_rounded,
              isSelected: mode != 'stremio',
              onTap: () => service.setAnimeStreamSource('extensions'),
            ),
            PillItem(
              label: 'Stremio addons',
              icon: Icons.stream_rounded,
              isSelected: mode == 'stremio',
              onTap: () => service.setAnimeStreamSource('stremio'),
            ),
          ],
        ),
      );
    });
  }
}

/// Decides whether playback should update AniList/MAL, the same way the
/// extension server sheet does. Null means the user cancelled.
Future<bool?> resolveAnimeTracking(BuildContext context, Media media,
    {bool bypassDialog = false}) async {
  final auth = Get.find<ServiceHandler>();
  final online = auth.isLoggedIn.value &&
      auth.serviceType.value != ServicesType.extensions;
  if (!online) return false;
  final dbId = '${media.id}_${media.serviceType.name}_${media.type}';
  final saved = DynamicKeys.trackingPermission.get<bool?>(dbId);
  if (saved != null && !bypassDialog) return saved;
  if (General.shouldAskForTrack.get(true) == false) return true;
  if (!context.mounted) return false;
  return showTrackingDialog(context, dbId: dbId);
}

/// Opens the Stremio stream picker for one episode of [media] and plays the
/// chosen stream. [episode.link] must be a Stremio video id.
Future<void> openStremioAnimeStreams(
  BuildContext context, {
  required Media media,
  required Episode episode,
  required List<Episode> episodes,
  StremioMeta? meta,
  String? type,
  bool isMovie = false,
  bool bypassDialog = false,
}) async {
  final videoId = episode.link ?? '';
  if (videoId.isEmpty) return;
  HapticFeedback.lightImpact();
  final epTitle = episode.title ?? '';
  final title = isMovie
      ? media.title
      : 'Episode ${episode.number}'
          '${epTitle.isNotEmpty && !epTitle.startsWith('Episode') ? ' · $epTitle' : ''}';
  await AnymeXSheet.custom(
    StremioStreamsSheet(
      meta: meta,
      video: null,
      videoId: videoId,
      type: type ?? StremioIds.typeForVideoId(videoId),
      title: title,
      onPlay: (selected, all) async {
        final track = await resolveAnimeTracking(context, media,
            bypassDialog: bypassDialog);
        if (track == null) return;
        await StremioPlayerBridge.playAnime(
          media: media,
          episodes: episodes.isEmpty ? [episode] : episodes,
          current: episode,
          selected: selected,
          allStreams: all,
          shouldTrack: track,
        );
      },
    ),
    context,
    showDragHandle: true,
  );
}

/// Sliver: the Stremio-addon episode list for an AniList/MAL anime.
class StremioAnimeEpisodes extends StatefulWidget {
  final Media media;

  const StremioAnimeEpisodes({super.key, required this.media});

  @override
  State<StremioAnimeEpisodes> createState() => _StremioAnimeEpisodesState();
}

class _StremioAnimeEpisodesState extends State<StremioAnimeEpisodes> {
  final _service = StremioService.to;
  StremioAnimeTarget? _target;
  bool _loading = true;
  bool _noAddons = false;
  final RxInt _chunk = 0.obs;
  List<List<Episode>> _chunks = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant StremioAnimeEpisodes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.id != widget.media.id) _load();
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() => _loading = true);
    StremioAnimeTarget? target;
    try {
      await _service.ensureAddons();
      _noAddons = !_service.hasStreamAddons;
      if (!_noAddons) {
        target = await _service.animeTarget(widget.media, refresh: refresh);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _target = target;
      _loading = false;
      if (target != null && !target.isMovie) {
        _chunks = chunkEpisodes(
            target.episodes, calculateChunkSize(target.episodes));
        _chunk.value = findChunkIndexFromProgress(_progress, _chunks);
      } else {
        _chunks = const [];
      }
    });
  }

  // ---- progress -------------------------------------------------------------

  int get _progress {
    var tracker = 0;
    try {
      final auth = Get.find<ServiceHandler>();
      if (auth.serviceType.value != ServicesType.extensions &&
          auth.isLoggedIn.value) {
        final tracked = auth.onlineService.animeList
            .firstWhereOrNull((e) => e.id == widget.media.id);
        tracker = double.tryParse(tracked?.episodeCount ?? '')?.toInt() ?? 0;
      }
    } catch (_) {}
    var local = 0;
    final current = _saved?.currentEpisode;
    if (current != null) {
      final n = current.number.toInt();
      local = _isComplete(current) ? n : max(0, n - 1);
    }
    return max(tracker, local);
  }

  OfflineMedia? get _saved {
    try {
      return Get.find<OfflineStorageController>()
          .getAnimeById(widget.media.id);
    } catch (_) {
      return null;
    }
  }

  bool _isComplete(Episode e) {
    final ts = e.timeStampInMilliseconds ?? 0;
    final dur = e.durationInMilliseconds ?? 0;
    return dur > 0 && (ts / dur) * 100 >= settingsController.markAsCompleted;
  }

  Episode? _savedFor(Episode ep) {
    final saved = _saved;
    if (saved == null) return null;
    for (final w in saved.watchedEpisodes ?? const <Episode>[]) {
      if (w.number == ep.number) return w;
    }
    final current = saved.currentEpisode;
    if (current != null && current.number == ep.number) return current;
    return null;
  }

  double _progressFor(Episode ep) {
    final s = _savedFor(ep);
    final ts = s?.timeStampInMilliseconds ?? 0;
    final dur = s?.durationInMilliseconds ?? 0;
    return dur > 0 ? (ts / dur).clamp(0.0, 1.0) : 0.0;
  }

  bool _watched(Episode ep, int progress) {
    final n = ep.number.toInt();
    if (n > 0 && n <= progress) return true;
    final s = _savedFor(ep);
    return s != null && _isComplete(s);
  }

  // ---- actions --------------------------------------------------------------

  void _openStreams(Episode ep, {bool bypassDialog = false}) {
    final target = _target;
    if (target == null) return;
    openStremioAnimeStreams(
      context,
      media: widget.media,
      episode: ep,
      episodes: target.episodes,
      meta: target.meta,
      type: target.type,
      isMovie: target.isMovie,
      bypassDialog: bypassDialog,
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: AnymeXProgressIndicator()),
        ),
      );
    }
    final target = _target;
    if (target == null) {
      return SliverToBoxAdapter(child: _unmatched(context));
    }

    final progress = _progress;
    final header = _header(context, target);

    if (target.isMovie) {
      final ep = target.episodes.first;
      final year = widget.media.seasonYear?.toString() ?? '';
      return SliverToBoxAdapter(
        child: Column(
          children: [
            header,
            MovieWatchCard(
              title: widget.media.title,
              imageUrl: target.meta?.background ??
                  widget.media.cover ??
                  widget.media.poster,
              fallbackImage: widget.media.poster,
              details: [formatMovieRuntime(widget.media.duration), year],
              progress: _progressFor(ep),
              watched: _watched(ep, progress),
              onPlay: () => _openStreams(ep),
              onLongPress: () => _openStreams(ep, bypassDialog: true),
            ),
          ],
        ),
      );
    }

    final style = EpisodeStyleRegistry.activeStyle;
    return Obx(() {
      final idx = _chunks.isEmpty
          ? 0
          : _chunk.value.clamp(0, _chunks.length - 1);
      final episodes = _chunks.isEmpty ? target.episodes : _chunks[idx];
      final next = '${progress + 1}';

      Widget card(BuildContext context, int i) {
        final ep = episodes[i];
        return style.builder(
          context,
          ep,
          ep.number == next,
          _watched(ep, progress),
          _progressFor(ep),
          widget.media,
          () => _openStreams(ep),
          () => _openStreams(ep, bypassDialog: true),
        );
      }

      return SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(child: header),
          style.isGrid
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
                  itemCount: episodes.length,
                  itemBuilder: card,
                )
              : SliverList.builder(
                  itemCount: episodes.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: card(context, i),
                  ),
                ),
        ],
      );
    });
  }

  Widget _header(BuildContext context, StremioAnimeTarget target) {
    final colors = context.colors;
    final matched = target.meta?.name ?? target.libraryId;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.opaque(0.2, iReallyMeanIt: true),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.onSurface.opaque(0.08, iReallyMeanIt: true),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: colors.primaryContainer
                      .opaque(0.35, iReallyMeanIt: true),
                  borderRadius: BorderRadius.circular(12),
                ),
                child:
                    Icon(Icons.stream_rounded, size: 20, color: colors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnymeXText(
                      'Found: $matched',
                      size: 13,
                      variant: TextVariant.semiBold,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    AnymeXText(
                      'Streams from ${target.addonNames.join(', ')}',
                      size: 11,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Match again',
                onPressed: () => _load(refresh: true),
                icon: Icon(Icons.refresh_rounded,
                    size: 20, color: colors.primary),
              ),
            ],
          ),
          if (_chunks.length > 2)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: EpisodeChunkSelector(
                chunks: _chunks,
                selectedChunkIndex: _chunk,
                onChunkSelected: (i) => _chunk.value = i,
              ),
            ),
        ],
      ),
    );
  }

  Widget _unmatched(BuildContext context) {
    final colors = context.colors;
    final message = _noAddons
        ? 'You have no Stremio addons that provide streams. Add one (for '
            'example AIOStreams or Torrentio) in Settings → Accounts → Stremio.'
        : 'Couldn\'t match this anime to your Stremio addons. Its Kitsu/IMDb '
            'ids weren\'t found, or none of your stream addons accept them.';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.opaque(0.2, iReallyMeanIt: true),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.onSurface.opaque(0.08, iReallyMeanIt: true),
        ),
      ),
      child: Column(
        children: [
          Icon(Icons.link_off_rounded, size: 32, color: colors.onSurfaceVariant),
          const SizedBox(height: 10),
          AnymeXText(
            message,
            size: 13,
            maxLines: 6,
            textAlign: TextAlign.center,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              if (!_noAddons)
                AnymexOnTap(
                  onTap: () => _load(refresh: true),
                  child: AnymeXText('Try again',
                      variant: TextVariant.bold, color: colors.primary),
                ),
              AnymexOnTap(
                onTap: () => _service.setAnimeStreamSource('extensions'),
                child: AnymeXText('Use extensions',
                    variant: TextVariant.bold, color: colors.primary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
