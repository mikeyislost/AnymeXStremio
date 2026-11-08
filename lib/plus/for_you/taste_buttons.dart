// AnymeX+: Like / Love on a Movies & TV title. Feeds "For you" on the
// Movies & TV page, and becomes your Simkl rating (Like 8, Love 10) when
// "Sync to Simkl" is on.

import 'dart:async';

import 'package:anymex/plus/for_you/taste.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/helper/tv_wrapper.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class PlusTasteButtons extends StatelessWidget {
  final String id;
  final String type;

  const PlusTasteButtons({super.key, required this.id, required this.type});

  static int? simklRatingFor(TasteMark mark) => switch (mark) {
        TasteMark.love => 10,
        TasteMark.like => 8,
        TasteMark.none => null,
      };

  void _set(TasteMark tapped) {
    final current = PlusTaste.markFor(id);
    final next = current == tapped ? TasteMark.none : tapped;
    PlusTaste.setMark(id, next);
    snackBar(switch (next) {
      TasteMark.love => 'Loved. For you will lean into this',
      TasteMark.like => 'Liked. For you will show more like this',
      TasteMark.none => 'Cleared',
    });
    final service = StremioService.to;
    unawaited(service.sendSimklRating(id, type, simklRatingFor(next)));
  }

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
