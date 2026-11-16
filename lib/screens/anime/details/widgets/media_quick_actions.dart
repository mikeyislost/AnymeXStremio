import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/screens/anime/details/controller/media_details_controller.dart';
import 'package:anymex/screens/anime/widgets/custom_list_dialog.dart';
import 'package:anymex/screens/anime/widgets/list_editor.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_bottomsheet.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';

Widget buildMediaQuickActions(
    BuildContext context, MediaDetailsController controller) {
  final isOnlineService =
      controller.media.value.serviceType != ServicesType.extensions;

  final isLoggedIn = isOnlineService &&
      controller.media.value.serviceType.onlineService.isLoggedIn.value;

  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Obx(() {
      controller.media.value;
      return Row(
        children: [
          if (isLoggedIn) ...[
            Expanded(
              child: Obx(() {
                final isListed = controller.isListedMedia.value;
                final statusText = isListed
                    ? (controller.mediaStatus.value.isNotEmpty
                        ? controller.mediaStatus.value
                        : 'TRACKING')
                    : 'ADD TO LIST';

                return _buildQuickActionButton(
                  context: context,
                  radius: const BorderRadius.horizontal(
                    right: Radius.circular(5),
                    left: Radius.circular(16),
                  ),
                  icon:
                      isListed ? Icons.check_circle_rounded : Icons.add_rounded,
                  label: statusText,
                  isPrimary: true,
                  onTap: () {
                    AnymeXSheet.custom(
                        ListEditorModal(
                          animeStatus: controller.mediaStatus,
                          animeScore: controller.mediaScore,
                          animeProgress: controller.mediaProgress,
                          currentAnime: controller.trackedMedia,
                          media: controller.media.value,
                          isManga: !controller.isAnime,
                          onUpdate: (id, score, status, progress, season,
                              startedAt, completedAt, isPrivate) {
                            controller.updateListEntry(
                              status: status,
                              progress: progress,
                              score: score,
                              season: season,
                              startedAt: startedAt,
                              completedAt: completedAt,
                              isPrivate: isPrivate,
                            );
                          },
                          onDelete: (id) {
                            controller.deleteListEntry();
                          },
                        ),
                        context);
                  },
                );
              }),
            ),
          ],
          const SizedBox(width: 9),
          Expanded(
            child: Obx(() {
              final inList = controller.isInCustomList.value;
              return _buildQuickActionButton(
                context: context,
                icon: inList ? Icons.bookmark_added_rounded : Icons.bookmark_add_outlined,
                label: inList ? 'In Custom List' : 'Custom List',
                isPrimary: inList,
                radius: BorderRadius.horizontal(
                  left: Radius.circular(isLoggedIn ? 5 : 16),
                  right: const Radius.circular(16),
                ),
                onTap: () async {
                  await showDialog(
                    context: context,
                    builder: (context) => CustomListDialog(
                      original: controller.media.value,
                    ),
                  );
                  controller.checkIfInCustomList();
                },
              );
            }),
          ),
        ],
      );
    }),
  );
}

Widget _buildQuickActionButton({
  required BuildContext context,
  required IconData icon,
  required String label,
  required VoidCallback onTap,
  required BorderRadius radius,
  bool isPrimary = false,
}) {
  // Moonlit 4: pill buttons — filled lavender when active, outlined otherwise.
  final colors = context.colors;
  const pill = BorderRadius.all(Radius.circular(999));
  final bgClr = isPrimary ? colors.primary : colors.surface.withOpacity(0.3);
  final textClr = isPrimary ? colors.onPrimary : colors.onSurface;

  return Material(
    color: bgClr,
    borderRadius: pill,
    child: InkWell(
      borderRadius: pill,
      onTap: onTap,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: pill,
          border: isPrimary
              ? null
              : Border.all(
                  color: colors.onSurface.withOpacity(0.45), width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: textClr),
            const SizedBox(width: 7),
            Flexible(
              child: AnymeXText(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: textClr,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
