// AnymeX+: one quick menu for cards — long-press on iPhone, right-click on
// Windows. Anime and Movies & TV get the same layout: Open, Play (Movies &
// TV), Library, Like / Love / Dislike, Not interested.

import 'dart:async';

import 'package:anymex/models/Media/media.dart';
import 'package:anymex/plus/for_you/taste.dart';
import 'package:anymex/plus/for_you/taste_buttons.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/stremio/ui/stremio_streams_sheet.dart';
import 'package:anymex/plus/stremio/ui/stremio_widgets.dart';
import 'package:anymex/screens/anime/details_page.dart';
import 'package:anymex/screens/anime/widgets/custom_list_dialog.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_bottomsheet.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_tile.dart';
import 'package:anymex/widgets/media_items/media_peek_popup.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class PlusCardMenu {
  PlusCardMenu._();

  /// Menu for an anime card.
  static void anime(
    BuildContext context,
    Media media,
    String tag, {
    String? reason,
    List<String> genres = const [],
    VoidCallback? onHidden,
  }) {
    final anilistId = PlusAnimeTasteRow.anilistIdOf(media);
    _sheet(
      context,
      title: media.title,
      reason: reason,
      children: [
        _tile(context, Icons.info_outline_rounded, 'Open', () {
          navigate(() => AnimeDetailsPage(media: media, tag: tag));
        }),
        _tile(context, Icons.visibility_outlined, 'Quick look',
            () => MediaPeekPopup.show(context, media, ItemType.anime, tag),
            subtitle: 'Synopsis, your list status and Watch'),
        _tile(context, Icons.bookmark_add_rounded, 'Add to Library',
            () => showCustomListDialog(context, media)),
        if (anilistId != null)
          _taste(PlusTasteButtons.anime(
            anilistId: anilistId,
            title: media.title,
            genres: media.genres.isNotEmpty ? media.genres : genres,
          )),
        _notInterested(context,
            key: anilistId == null ? media.id : PlusTaste.animeKey(anilistId),
            id: anilistId ?? media.id,
            kind: 'anime',
            genres: media.genres.isNotEmpty ? media.genres : genres,
            onHidden: onHidden),
      ],
    );
  }

  /// Menu for a Movies & TV card (Stremio id).
  static void stremio({
    required String type,
    required String id,
    required String name,
    String? poster,
    String? reason,
    String? hideKey,
    List<String> genres = const [],
    VoidCallback? onHidden,
  }) {
    final context = Get.context;
    if (context == null) return;
    final service = StremioService.to;
    final loggedIn = service.isLoggedIn.value;
    final inLibrary = loggedIn && service.isInLibrary(id);
    final inCw = loggedIn && service.isInContinueWatching(id);

    Future<void> run(Future<void> Function() action, String done) async {
      try {
        await action();
        snackBar(done);
      } catch (e) {
        snackBar('Stremio: $e');
      }
    }

    _sheet(
      context,
      title: name,
      reason: reason,
      children: [
        _tile(context, Icons.info_outline_rounded, 'Open',
            () => openStremioDetails(type, id, title: name, poster: poster)),
        _tile(
            context,
            Icons.play_arrow_rounded,
            inCw
                ? 'Resume'
                : (type == 'movie' ? 'Play' : 'Play next episode'),
            () => unawaited(play(type, id, name)),
            subtitle: type == 'movie' ? null : 'Or the first one if you haven\'t started'),
        if (inCw)
          _tile(
              context,
              Icons.history_toggle_off_rounded,
              'Remove from Continue Watching',
              () => run(() => service.dismissFromContinueWatching(id),
                  'Removed from Continue Watching'),
              subtitle: 'Also removed in Stremio'),
        if (loggedIn)
          inLibrary
              ? _tile(context, Icons.bookmark_remove_rounded,
                  'Remove from Library',
                  () => run(() => service.removeFromLibrary(id),
                      'Removed from Library'))
              : _tile(
                  context,
                  Icons.bookmark_add_rounded,
                  'Add to Library',
                  () => run(
                      () => service.addToLibrary(
                          id: id, type: type, name: name, poster: poster),
                      'Added to Library')),
        if (id.startsWith('tt')) _taste(PlusTasteButtons(id: id, type: type)),
        _notInterested(context,
            key: hideKey ?? id,
            id: id,
            kind: type,
            genres: genres,
            onHidden: onHidden),
      ],
    );
  }

  /// Which episode Play starts: the one you're partway through, else the
  /// one after the last you watched, else the first. [ids] in order.
  static int nextIndex(List<String> ids, String? current,
      {bool partway = false}) {
    if (ids.isEmpty) return -1;
    final at = current == null ? -1 : ids.indexOf(current);
    if (at < 0) return 0;
    if (partway) return at;
    return at + 1 < ids.length ? at + 1 : at;
  }

  /// Opens the streams sheet for the episode (or movie) Play should start.
  static Future<void> play(String type, String id, String name) async {
    final service = StremioService.to;
    final meta = await service.fetchMeta(type, id);
    final context = Get.context;
    if (meta == null || context == null) {
      snackBar("Couldn't load $name");
      return;
    }
    StremioVideo? video;
    if (meta.type != 'movie' && meta.videos.isNotEmpty) {
      final eps = meta.videos.where((v) => (v.season ?? 1) > 0).toList()
        ..sort((a, b) {
          final s = (a.season ?? 0).compareTo(b.season ?? 0);
          return s != 0 ? s : (a.episode ?? 0).compareTo(b.episode ?? 0);
        });
      final list = eps.isEmpty ? meta.videos : eps;
      final item =
          service.isLoggedIn.value ? await service.getLibraryItem(meta.id) : null;
      final partway = item != null &&
          item.timeOffset > 0 &&
          item.progress < 0.9;
      final i = nextIndex([for (final v in list) v.id], item?.videoId,
          partway: partway);
      if (i >= 0) video = list[i];
    }
    if (!context.mounted) return;
    AnymeXSheet.custom(
      StremioStreamsSheet(
        meta: meta,
        video: video,
        videoId: video?.id ?? meta.singleVideoId,
      ),
      context,
      showDragHandle: true,
    );
  }

  // ---- parts ----------------------------------------------------------------

  static void _sheet(BuildContext context,
      {required String title, String? reason, required List<Widget> children}) {
    AnymeXSheet.custom(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(8, 0, 8, reason == null ? 10 : 4),
            child: AnymeXText(title,
                size: 16,
                variant: TextVariant.bold,
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
          if (reason != null && reason.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              child: AnymeXText(reason,
                  size: 12.5,
                  color: context.colors.onSurfaceVariant,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
          ...children,
        ],
      ),
      context,
      showDragHandle: true,
    );
  }

  /// A row that closes the menu, then runs [action].
  static Widget _tile(
      BuildContext context, IconData icon, String title, VoidCallback action,
      {String? subtitle}) {
    return Builder(
      builder: (sheetContext) => AnymeXTile(
        icon: icon,
        title: title,
        subtitle: subtitle,
        showChevron: false,
        onTap: () {
          Navigator.of(sheetContext).pop();
          action();
        },
      ),
    );
  }

  static Widget _taste(Widget buttons) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(children: [buttons]),
      );

  static Widget _notInterested(
    BuildContext context, {
    required String key,
    required String id,
    required String kind,
    List<String> genres = const [],
    VoidCallback? onHidden,
  }) {
    return _tile(
      context,
      Icons.visibility_off_outlined,
      'Not interested',
      () {
        PlusTaste.hide(key: key, id: id, kind: kind, genres: genres);
        onHidden?.call();
        snackBar("Got it. You'll see fewer picks like this");
      },
      subtitle: 'Hide it from For you and show fewer like it',
    );
  }
}
