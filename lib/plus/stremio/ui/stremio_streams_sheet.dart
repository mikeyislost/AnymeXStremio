// AnymeX+: the Stremio stream picker (Movies & TV and the anime Watch tab),
// with quality / addon filters, your usual pick first, and downloads.

import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/stremio/ui/stremio_download.dart';
import 'package:anymex/plus/stremio/ui/stremio_player_bridge.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_linear_indicator.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/helper/tv_wrapper.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:url_launcher/url_launcher.dart';

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

  /// Download button for direct links on Movies & TV titles.
  VoidCallback? _downloadFor(StremioStream s) {
    final meta = widget.meta;
    if (meta == null || widget.onPlay != null) return null;
    if (!canDownloadStremioStream(s)) return null;
    return () async {
      StremioService.to.rememberStreamChoice(_titleKey, s);
      final started = await downloadStremioStream(
          meta: meta, video: widget.video, stream: s);
      if (started && mounted) Navigator.of(context).pop();
    };
  }

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
            stream: s,
            preferred: _isPreferred(s),
            onTap: () => _select(s),
            onDownload: _downloadFor(s)));
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
              stream: s,
              preferred: _isPreferred(s),
              onTap: () => _select(s),
              onDownload: _downloadFor(s)));
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

  final VoidCallback? onDownload;

  const _StreamTile(
      {required this.stream,
      required this.onTap,
      this.preferred = false,
      this.onDownload});

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
              if (onDownload != null)
                IconButton(
                  tooltip: 'Download',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDownload,
                  icon: Icon(Icons.download_rounded,
                      size: 20, color: colors.primary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
