import 'package:anymex/controllers/service_handler/params.dart';
import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// AnymeX+: long-press on an anime episode. With a tracker signed in
/// (AniList, MAL, Simkl) it offers to set your progress to that episode, as
/// long-press does on Movies & TV; "Choose a source" is what long-press did
/// before. Without a tracker it goes straight to the source picker.
class PlusEpisodeHold {
  /// The progress a long-press on episode [number] offers, given the
  /// [progress] on your list: (watched up to it, back to before it). Null =
  /// not offered.
  static (int?, int?) offers(int number, int progress) => (
        number > 0 && number != progress ? number : null,
        number > 0 && progress >= number ? number - 1 : null,
      );

  /// The list status that goes with [progress].
  static String statusFor({
    required int progress,
    required int? totalEpisodes,
    required String mediaStatus,
    required String? listStatus,
  }) {
    final aired = mediaStatus.toUpperCase();
    final finished = (aired == 'COMPLETED' || aired == 'FINISHED') &&
        totalEpisodes != null &&
        totalEpisodes > 0 &&
        progress >= totalEpisodes;
    if (finished) return 'COMPLETED';
    return (listStatus ?? '').toUpperCase() == 'REPEATING' ? 'REPEATING' : 'CURRENT';
  }

  static Future<void> show(
    BuildContext context, {
    required Media? media,
    required Episode episode,
    required VoidCallback chooseSource,
    VoidCallback? onChanged,
  }) async {
    final auth = Get.find<ServiceHandler>();
    final number = double.tryParse(episode.number)?.toInt();
    final tracked = media != null &&
        auth.serviceType.value != ServicesType.extensions &&
        auth.isLoggedIn.value &&
        media.serviceType != ServicesType.extensions;
    if (!tracked || number == null) {
      chooseSource();
      return;
    }
    final entry = auth.onlineService.animeList.firstWhereOrNull((e) => e.id == media.id);
    final progress = double.tryParse(entry?.episodeCount ?? '')?.toInt() ?? 0;
    final (upTo, before) = offers(number, progress);

    HapticFeedback.selectionClick();
    final pick = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (upTo != null)
              ListTile(
                leading: const Icon(Icons.done_all_rounded),
                title: Text('Mark watched up to episode $upTo'),
                onTap: () => Navigator.pop(ctx, upTo),
              ),
            if (before != null)
              ListTile(
                leading: const Icon(Icons.remove_done_rounded),
                title: Text(before == 0 ? 'Mark as not watched' : 'Set progress back to episode $before'),
                onTap: () => Navigator.pop(ctx, before),
              ),
            ListTile(
              leading: const Icon(Icons.video_library_rounded),
              title: const Text('Choose a source'),
              onTap: () => Navigator.pop(ctx, -1),
            ),
          ],
        ),
      ),
    );
    if (pick == null) return;
    if (pick == -1) {
      chooseSource();
      return;
    }
    try {
      await auth.onlineService.updateListEntry(UpdateListEntryParams(
        listId: media.id,
        progress: pick,
        isAnime: true,
        status: statusFor(
          progress: pick,
          totalEpisodes: int.tryParse(media.totalEpisodes),
          mediaStatus: media.status,
          listStatus: entry?.watchingStatus,
        ),
      ));
      snackBar(pick == 0 ? 'Marked as not watched' : 'Progress set to episode $pick');
    } catch (e) {
      snackBar("Couldn't update your list: $e");
    }
    onChanged?.call();
  }
}
