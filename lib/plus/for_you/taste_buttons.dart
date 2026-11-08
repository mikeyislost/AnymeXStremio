// AnymeX+: Like / Love / Dislike on a title. Feeds "For you" (Home for
// anime, Movies & TV for the rest). On Movies & TV it also becomes your
// Simkl rating (Dislike 4, Like 8, Love 10) when "Sync to Simkl" is on.

import 'dart:async';

import 'package:anymex/controllers/service_handler/service_handler.dart'
    show ServicesType;
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/plus/for_you/taste.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/helper/tv_wrapper.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class PlusTasteButtons extends StatelessWidget {
  /// Stremio id, or [PlusTaste.animeKey] for an anime.
  final String id;

  /// movie | series | anime
  final String type;

  /// Kept with anime marks so For you can use them.
  final String? title;
  final List<String> genres;

  const PlusTasteButtons({
    super.key,
    required this.id,
    required this.type,
    this.title,
    this.genres = const [],
  });

  /// Like / Love / Dislike for an anime page (AniList id).
  factory PlusTasteButtons.anime({
    Key? key,
    required String anilistId,
    required String title,
    List<String> genres = const [],
  }) =>
      PlusTasteButtons(
        key: key,
        id: PlusTaste.animeKey(anilistId),
        type: 'anime',
        title: title,
        genres: genres,
      );

  static int? simklRatingFor(TasteMark mark) => switch (mark) {
        TasteMark.love => 10,
        TasteMark.like => 8,
        TasteMark.dislike => 4,
        TasteMark.none => null,
      };

  /// Toggles [tapped] on [id] (tapping the current mark clears it).
  static void toggle(String id, String type, TasteMark tapped,
      {String? title, List<String> genres = const []}) {
    final current = PlusTaste.markFor(id);
    final next = current == tapped ? TasteMark.none : tapped;
    PlusTaste.setMark(id, next, title: title, genres: genres);
    snackBar(switch (next) {
      TasteMark.love => 'Loved. For you will lean into this',
      TasteMark.like => 'Liked. For you will show more like this',
      TasteMark.dislike => 'Disliked. For you will show less like this',
      TasteMark.none => 'Cleared',
    });
    if (type == 'anime') return;
    final service = StremioService.to;
    unawaited(service.sendSimklRating(id, type, simklRatingFor(next)));
  }

  void _set(TasteMark tapped) =>
      toggle(id, type, tapped, title: title, genres: genres);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      PlusTaste.ensureLoaded();
      final mark = PlusTaste.marks[id] ?? TasteMark.none;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _button(
            context,
            icon: mark == TasteMark.like
                ? Icons.thumb_up_alt_rounded
                : Icons.thumb_up_alt_outlined,
            tooltip: 'Like',
            on: mark == TasteMark.like,
            onTap: () => _set(TasteMark.like),
          ),
          const SizedBox(width: 8),
          _button(
            context,
            icon: mark == TasteMark.love
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            tooltip: 'Love',
            on: mark == TasteMark.love,
            onTap: () => _set(TasteMark.love),
          ),
          const SizedBox(width: 8),
          _button(
            context,
            icon: mark == TasteMark.dislike
                ? Icons.thumb_down_alt_rounded
                : Icons.thumb_down_alt_outlined,
            tooltip: 'Dislike',
            on: mark == TasteMark.dislike,
            onTap: () => _set(TasteMark.dislike),
          ),
        ],
      );
    });
  }

  Widget _button(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required bool on,
    required VoidCallback onTap,
  }) {
    final colors = context.colors;
    return Tooltip(
      message: tooltip,
      child: AnymexOnTap(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: on
                ? colors.primary.opaque(0.18, iReallyMeanIt: true)
                : colors.surfaceContainerHighest.opaque(0.3, iReallyMeanIt: true),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: on
                  ? colors.primary.opaque(0.4, iReallyMeanIt: true)
                  : colors.onSurface.opaque(0.08, iReallyMeanIt: true),
            ),
          ),
          child: Icon(icon,
              size: 19, color: on ? colors.primary : colors.onSurface),
        ),
      ),
    );
  }
}

/// Like / Love / Dislike on an anime's page (Overview tab). Hidden when the
/// anime has no AniList id.
class PlusAnimeTasteRow extends StatelessWidget {
  final Media media;

  const PlusAnimeTasteRow({super.key, required this.media});

  static String? anilistIdOf(Media m) {
    final id = m.serviceType == ServicesType.anilist
        ? m.id.split('*').first
        : m.mediaIds?.anilistId;
    if (id == null || int.tryParse(id) == null) return null;
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final id = anilistIdOf(media);
    if (id == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Row(children: [
        PlusTasteButtons.anime(
          anilistId: id,
          title: media.title,
          genres: media.genres,
        ),
      ]),
    );
  }
}
