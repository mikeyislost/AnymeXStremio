import 'package:anymex/controllers/services/stremio/stremio_models.dart';
import 'package:anymex/controllers/services/stremio/stremio_service.dart';
import 'package:anymex/controllers/services/stremio/watched_bitfield.dart';
import 'package:anymex/screens/stremio/stremio_player_bridge.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class StremioDetailsPage extends StatefulWidget {
  final String type;
  final String id;
  final StremioMetaPreview? preview;

  const StremioDetailsPage({
    super.key,
    required this.type,
    required this.id,
    this.preview,
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
  WatchedBitField? _watched;
  StremioLibraryItem? _libraryItem;

  @override
  void initState() {
    super.initState();
    _load();
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
        _meta = meta;
        if (!meta.isSingleVideo) {
          final seasons = meta.seasons;
          _season = seasons.isEmpty ? null : seasons.first;
        }
        await _loadLibraryState();
        // Jump to the season of the episode Stremio says you're on.
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

  void _openStreams(StremioVideo? video) {
    final meta = _meta;
    if (meta == null) return;
    final videoId = video?.id ?? meta.singleVideoId;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => StremioStreamsSheet(
        meta: meta,
        video: video,
        videoId: videoId,
      ),
    ).then((_) async {
      // Progress changed while watching; the sync writes the local cache
      // first, so give it a moment and read from there.
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
    try {
      await _service.setVideoWatched(meta, video, now);
      await _loadLibraryState();
      if (mounted) setState(() {});
    } catch (e) {
      snackBar('Could not update Stremio: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = _meta;
    final preview = widget.preview;
    final name = meta?.name ?? preview?.name ?? '';
    final background =
        meta?.background ?? preview?.background ?? meta?.poster ?? preview?.poster;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _header(theme, name, background)),
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              ),
            )
          else if (meta != null) ...[
            SliverToBoxAdapter(child: _info(theme, meta)),
            if (meta.isSingleVideo)
              SliverToBoxAdapter(child: _moviePlay(theme, meta))
            else ...[
              SliverToBoxAdapter(child: _seasonPicker(theme, meta)),
              _episodeList(theme, meta),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        ],
      ),
    );
  }

  Widget _header(ThemeData theme, String name, String? background) {
    final poster = _meta?.poster ?? widget.preview?.poster;
    return SizedBox(
      height: 320,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (background != null)
            CachedNetworkImage(
              imageUrl: background,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => const SizedBox.shrink(),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.35),
                  theme.scaffoldBackgroundColor,
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 12,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (poster != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CachedNetworkImage(
                      imageUrl: poster,
                      width: 100,
                      height: 150,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _info(ThemeData theme, StremioMeta meta) {
    final facts = [
      if (meta.releaseInfo != null) meta.releaseInfo!,
      if (meta.runtime != null) meta.runtime!,
      if (meta.imdbRating != null) '★ ${meta.imdbRating}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (facts.isNotEmpty)
            Text(facts.join('  ·  '),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          if (meta.genres.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: meta.genres
                  .take(6)
                  .map((g) => Chip(
                        label: Text(g),
                        visualDensity: VisualDensity.compact,
                      ))
                  .toList(),
            ),
          ],
          if (meta.description != null) ...[
            const SizedBox(height: 12),
            Text(meta.description!, style: theme.textTheme.bodyMedium),
          ],
          if (meta.cast.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Cast: ${meta.cast.take(5).join(', ')}',
                style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          if (!meta.isSingleVideo) _continueButton(theme, meta),
        ],
      ),
    );
  }

  Widget _continueButton(ThemeData theme, StremioMeta meta) {
    final item = _libraryItem;
    StremioVideo? target;
    if (item?.videoId != null) {
      for (final v in meta.videos) {
        if (v.id == item!.videoId) {
          target = v;
          break;
        }
      }
    }
    if (target == null) {
      final seasons = meta.seasons.where((s) => s != 0).toList();
      if (seasons.isNotEmpty) {
        final eps = meta.videosForSeason(seasons.first);
        if (eps.isNotEmpty) target = eps.first;
      }
    }
    if (target == null) return const SizedBox.shrink();
    final resume = item?.videoId == target.id && (item?.timeOffset ?? 0) > 1;
    final label = 'S${target.season ?? 1} E${target.episode ?? 1}';
    final t = target;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        icon: const Icon(Icons.play_arrow_rounded),
        label: Text(resume
            ? 'Resume $label'
            : (item?.videoId == target.id ? 'Continue $label' : 'Play $label')),
        onPressed: () => _openStreams(t),
      ),
    );
  }

  Widget _moviePlay(ThemeData theme, StremioMeta meta) {
    final item = _libraryItem;
    final resume = item != null &&
        item.timeOffset > 1 &&
        (item.videoId == null || item.videoId == meta.singleVideoId);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (resume && item!.progress > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(value: item!.progress),
            ),
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(resume ? 'Resume' : 'Play'),
            onPressed: () => _openStreams(null),
          ),
        ],
      ),
    );
  }

  Widget _seasonPicker(ThemeData theme, StremioMeta meta) {
    final seasons = meta.seasons;
    if (seasons.length <= 1) return const SizedBox(height: 8);
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: seasons
            .map((s) => Padding(
                  padding: const EdgeInsets.all(4),
                  child: ChoiceChip(
                    label: Text(s == 0 ? 'Specials' : 'Season $s'),
                    selected: _season == s,
                    onSelected: (_) => setState(() => _season = s),
                  ),
                ))
            .toList(),
      ),
    );
  }

  Widget _episodeList(ThemeData theme, StremioMeta meta) {
    final episodes =
        _season == null ? meta.videos : meta.videosForSeason(_season!);
    final currentId = _libraryItem?.videoId;
    return SliverList.builder(
      itemCount: episodes.length,
      itemBuilder: (context, i) {
        final v = episodes[i];
        final watched = _watched?.getVideo(v.id) ?? false;
        final isCurrent = v.id == currentId;
        final released = v.released;
        final upcoming = !v.isReleased;
        return ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          onTap: upcoming ? null : () => _openStreams(v),
          onLongPress: () => _toggleWatched(v),
          leading: SizedBox(
            width: 112,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: theme.colorScheme.surfaceContainerHighest),
                    if (v.thumbnail != null)
                      CachedNetworkImage(
                        imageUrl: v.thumbnail!,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    if (isCurrent && (_libraryItem?.progress ?? 0) > 0)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: LinearProgressIndicator(
                          value: _libraryItem!.progress.clamp(0.0, 1.0),
                          minHeight: 3,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          title: Text(
            '${v.episode ?? i + 1}. ${v.title.isEmpty ? 'Episode ${v.episode ?? i + 1}' : v.title}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
              color: upcoming ? theme.disabledColor : null,
            ),
          ),
          subtitle: released == null
              ? null
              : Text(
                  upcoming
                      ? 'Airs ${_date(released)}'
                      : _date(released),
                  style: theme.textTheme.bodySmall,
                ),
          trailing: watched
              ? Icon(Icons.check_circle_rounded,
                  color: theme.colorScheme.primary)
              : null,
        );
      },
    );
  }

  static String _date(DateTime d) {
    final l = d.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
  }
}

/// Lists streams from all addons, filling in as each addon answers.
class StremioStreamsSheet extends StatefulWidget {
  final StremioMeta meta;
  final StremioVideo? video;
  final String videoId;

  const StremioStreamsSheet({
    super.key,
    required this.meta,
    required this.video,
    required this.videoId,
  });

  @override
  State<StremioStreamsSheet> createState() => _StremioStreamsSheetState();
}

class _StremioStreamsSheetState extends State<StremioStreamsSheet> {
  final Map<String, List<StremioStream>> _byAddon = {};
  final List<String> _addonOrder = [];
  int _pending = 0;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final service = StremioService.to;
    await service.ensureAddons();
    if (!mounted) return;
    final sources = service.addons
        .where((a) => a.supports('stream', widget.meta.type, widget.videoId))
        .toList();
    setState(() {
      _started = true;
      _pending = sources.length;
      _addonOrder
        ..clear()
        ..addAll(sources.map((a) => a.name));
    });
    await service.fetchStreams(
      widget.meta.type,
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

  List<StremioStream> get _all =>
      _addonOrder.expand((a) => _byAddon[a] ?? const <StremioStream>[]).toList();

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
    final all = _all.where((e) => e.isPlayable).toList();
    await StremioPlayerBridge.play(
      meta: widget.meta,
      video: widget.video,
      selected: s,
      allStreams: all,
    );
    // Back from the player: close the picker so the details page refreshes.
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = widget.video;
    final title = v == null
        ? widget.meta.name
        : 'S${v.season ?? 1} E${v.episode ?? 1}'
            '${v.title.isNotEmpty ? ' · ${v.title}' : ''}';
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) {
        final children = <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          if (_pending > 0) const LinearProgressIndicator(),
        ];
        if (_started && _addonOrder.isEmpty) {
          children.add(const Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'No stream addons installed for this title. Add one (e.g. '
              'Torrentio) from the Stremio account page.',
              textAlign: TextAlign.center,
            ),
          ));
        }
        for (final addonName in _addonOrder) {
          final streams = _byAddon[addonName];
          if (streams == null) continue;
          children.add(Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              streams.isEmpty ? '$addonName — no streams' : addonName,
              style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold),
            ),
          ));
          for (final s in streams) {
            children.add(_streamTile(theme, s));
          }
        }
        if (_pending == 0 && _started && _all.isEmpty && _addonOrder.isNotEmpty) {
          children.add(const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No streams found.', textAlign: TextAlign.center),
          ));
        }
        return ListView(
          controller: scroll,
          padding: const EdgeInsets.only(bottom: 32),
          children: children,
        );
      },
    );
  }

  Widget _streamTile(ThemeData theme, StremioStream s) {
    final playable = s.isPlayable;
    final details = s.details;
    return ListTile(
      onTap: () => _select(s),
      leading: Icon(
        s.isTorrent
            ? Icons.downloading_rounded
            : (playable ? Icons.play_circle_outline_rounded : Icons.open_in_new_rounded),
        color: playable ? theme.colorScheme.primary : theme.disabledColor,
      ),
      title: Text(
        (s.name ?? s.addonName).replaceAll('\n', ' '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: details.isEmpty
          ? null
          : Text(details, maxLines: 4, overflow: TextOverflow.ellipsis),
    );
  }
}
