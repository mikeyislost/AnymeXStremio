// AnymeX+: "Rate it?" after the last episode (AnymeX Desk #117). When the
// player marks a show Completed and you haven't scored it, a small sheet
// asks for a score once you're back from the player.

import 'dart:async';

import 'package:anymex/controllers/service_handler/params.dart';
import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/utils/logger.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class _Pending {
  final String id;
  final String title;
  final String? idMal;
  const _Pending(this.id, this.title, this.idMal);
}

class RatePrompt {
  RatePrompt._();

  static _Pending? _pending;
  static final Set<String> _asked = {};

  /// AniList scores you haven't given count as unscored.
  static bool isUnscored(String? score) =>
      (double.tryParse(score ?? '') ?? 0) <= 0;

  /// Called by the player when it marks [id] Completed. Asks once per show
  /// per launch, and only for AniList.
  static void finished({
    required ServicesType service,
    required String id,
    required String title,
    String? idMal,
    String? currentScore,
  }) {
    if (service != ServicesType.anilist) return;
    if (!isUnscored(currentScore) || _asked.contains(id)) return;
    final mal = (idMal == null || idMal.isEmpty || idMal == '0') ? null : idMal;
    _pending = _Pending(id, title, mal);
  }

  /// Called when the player closes: shows the sheet after the player's
  /// closing animation.
  static void showIfPending() {
    final p = _pending;
    if (p == null) return;
    _pending = null;
    _asked.add(p.id);
    Future.delayed(const Duration(milliseconds: 700), () {
      final context = Get.context;
      if (context == null || !context.mounted) return;
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => _RateSheet(pending: p),
      );
    });
  }
}

class _RateSheet extends StatelessWidget {
  final _Pending pending;
  const _RateSheet({required this.pending});

  Future<void> _save(BuildContext context, int outOfTen) async {
    Navigator.of(context).pop();
    try {
      final handler = Get.find<ServiceHandler>();
      // Scores are sent out of 100; AniList shows them in your format.
      await handler.anilistService.updateListEntry(UpdateListEntryParams(
        listId: pending.id,
        score: outOfTen * 10.0,
        status: 'COMPLETED',
        isAnime: true,
        syncIds: pending.idMal == null ? null : [pending.idMal!],
      ));
      snackBar('Rated ${pending.title} $outOfTen/10');
    } catch (e) {
      Logger.i('Rate prompt: $e');
      snackBar('Couldn\'t save the score: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnymeXText('You finished ${pending.title}',
                size: 16, variant: TextVariant.bold, maxLines: 2),
            const SizedBox(height: 4),
            AnymeXText('Rate it on AniList?',
                size: 13, color: colors.onSurfaceVariant),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var n = 1; n <= 10; n++)
                  ActionChip(
                    label: Text('$n'),
                    onPressed: () => _save(context, n),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Not now'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
