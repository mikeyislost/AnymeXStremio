import 'package:anymex/controllers/offline/offline_storage_controller.dart';
import 'package:anymex/controllers/service_handler/params.dart';
import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/database/isar_models/offline_media.dart';
import 'package:anymex/main.dart' show isar;
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// AnymeX+: long-press on an anime episode. With a tracker signed in
/// (AniList, MAL, Simkl) it offers to set your progress to that episode, as
/// long-press does on Movies & TV. A watched episode can be marked as not
/// watched (the mark kept on this device goes, and list progress steps back
/// to before it). "Choose a source" is what long-press did before; with
/// nothing else to offer it goes straight there.
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

  /// Forgets what this device remembers about watching [episode] (the eye
  /// mark and the resume point). True when something was removed.
  static Future<bool> forgetLocal(String mediaId, Episode episode) async {
    try {
      final storage = Get.find<OfflineStorageController>();
      final anime = storage.getAnimeById(mediaId);
      final watched = anime?.watchedEpisodes;
      if (anime == null || watched == null) return false;
      final kept = watched.where((e) => !e.isSameEpisode(episode)).toList();
      final wasCurrent = anime.currentEpisode?.isSameEpisode(episode) ?? false;
      if (kept.length == watched.length && !wasCurrent) return false;
      await isar.writeTxn(() async {
        anime.watchedEpisodes = kept;
        if (wasCurrent) {
          // "Continue" goes back to the one watched most recently before it.
          kept.sort((a, b) => (a.lastWatchedTime ?? 0).compareTo(b.lastWatchedTime ?? 0));
          if (kept.isNotEmpty) {
            anime.currentEpisode = kept.last;
          } else {
            anime.currentEpisode?.timeStampInMilliseconds = 0;
          }
        }
        await isar.offlineMedias.put(anime);
      });
      storage.update();
      return true;
    } catch (_) {
      return false;
    }
  }

  static const _unwatch = -2;
  static const _source = -1;

  /// [watched]: the list shows this episode as watched.
  static Future<void> show(
    BuildContext context, {
    required Media? media,
    required Episode episode,
    required VoidCallback chooseSource,
    bool watched = false,
    VoidCallback? onChanged,
  }) async {
    final auth = Get.find<ServiceHandler>();
    final number = double.tryParse(episode.number)?.toInt();
    final tracked = media != null &&
        number != null &&
        auth.serviceType.value != ServicesType.extensions &&
        auth.isLoggedIn.value &&
        media.serviceType != ServicesType.extensions;
    if (media == null || (!tracked && !watched)) {
      chooseSource();
      return;
    }
    final entry = tracked ? auth.onlineService.animeList.firstWhereOrNull((e) => e.id == media.id) : null;
    final progress = double.tryParse(entry?.episodeCount ?? '')?.toInt() ?? 0;
    final (upTo, before) = tracked ? offers(number, progress) : (null, null);

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
            if (watched || before != null)
              ListTile(
                leading: const Icon(Icons.visibility_off_rounded),
                title: const Text('Mark as not watched'),
                subtitle: before == null
                    ? null
                    : Text(before == 0
                        ? 'Your list progress goes back to 0'
                        : 'Your list progress goes back to episode $before'),
                onTap: () => Navigator.pop(ctx, _unwatch),
              ),
            ListTile(
              leading: const Icon(Icons.video_library_rounded),
              title: const Text('Choose a source'),
              onTap: () => Navigator.pop(ctx, _source),
            ),
          ],
        ),
      ),
    );
    if (pick == null) return;
    if (pick == _source) {
      chooseSource();
      return;
    }
    final newProgress = pick == _unwatch ? before : pick;
    try {
      if (pick == _unwatch) await forgetLocal(media.id, episode);
      if (newProgress != null) {
        await auth.onlineService.updateListEntry(UpdateListEntryParams(
          listId: media.id,
          progress: newProgress,
          isAnime: true,
          status: statusFor(
            progress: newProgress,
            totalEpisodes: int.tryParse(media.totalEpisodes),
            mediaStatus: media.status,
            listStatus: entry?.watchingStatus,
          ),
        ));
      }
      snackBar(pick == _unwatch ? 'Marked as not watched' : 'Progress set to episode $pick');
    } catch (e) {
      snackBar("Couldn't update your list: $e");
    }
    onChanged?.call();
  }
}
