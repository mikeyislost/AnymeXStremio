import 'package:anymex/database/isar_models/offline_media.dart';
import 'package:anymex/theme/yumori_tokens.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_image.dart';
import 'package:anymex/widgets/common/cards/yumori_continue_card.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:flutter/material.dart';

/// Library row (Moonlit 4): wide art with a progress line and firefly,
/// title and "EP 6 / 28" next to it.
class YumoriLibraryRow extends StatelessWidget {
  final OfflineMedia item;
  final ItemType type;
  final VoidCallback onTap;

  const YumoriLibraryRow({
    super.key,
    required this.item,
    required this.type,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isManga = type != ItemType.anime;
    final unit = isManga ? 'CH' : 'EP';
    final cur = isManga
        ? (double.tryParse('${item.currentChapter?.number ?? ''}') ?? 0)
            .floor()
        : (int.tryParse('${item.currentEpisode?.number ?? ''}') ?? 0);
    var total = isManga ? item.chapterCountInt : item.episodeCountInt;
    if (total == 0) {
      total = isManga ? (item.chapters?.length ?? 0) : (item.episodes?.length ?? 0);
    }
    final hasProgress = total > 0 && cur > 0;
    final progress = hasProgress ? (cur / total).clamp(0.0, 1.0) : null;
    final sub = hasProgress
        ? '$unit $cur / $total'
        : (cur > 0 ? '$unit $cur' : (total > 0 ? '$total ${isManga ? 'chapters' : 'episodes'}' : ''));

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Row(
        children: [
          SizedBox(
            width: 132,
            height: 74,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AnymeXImage(
                    imageUrl: (item.cover?.isNotEmpty == true
                            ? item.cover
                            : item.poster) ??
                        '',
                    radius: 0,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: const LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.center,
                      colors: [Color(0xCC0D0A16), Color(0x000D0A16)],
                    ),
                    border: Border.all(color: const Color(0x2EFFFFFF)),
                  ),
                ),
                if (progress != null)
                  Positioned(
                    left: 9,
                    right: 9,
                    bottom: 9,
                    child: YumoriProgressLine(progress: progress),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(item.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: YumoriText.ui(size: 14, weight: FontWeight.w600)),
                if (sub.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(sub,
                      maxLines: 1,
                      style: YumoriText.ui(
                          size: 11,
                          color: YumoriColors.text.withOpacity(0.65))),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
