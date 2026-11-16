import 'package:anymex/utils/function.dart';
import 'package:anymex/models/models_convertor/carousel/carousel_data.dart';
import 'package:anymex/theme/yumori_tokens.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_image.dart';
import 'package:anymex/widgets/common/cards/card_components.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:flutter/material.dart';

/// Continue Watching card (Moonlit 4): wide art, a lavender progress line with
/// a firefly at its tip, title and "EP 7 · 5 left" underneath.
class YumoriContinueCard extends StatelessWidget {
  final CarouselData itemData;
  final DataVariant variant;
  final ItemType type;
  final double width;

  const YumoriContinueCard({
    super.key,
    required this.itemData,
    required this.variant,
    required this.type,
    this.width = 200,
  });

  @override
  Widget build(BuildContext context) {
    final badge = getBadgeText(itemData, variant, type);
    final progress = badgeProgress(badge);
    final unit = type == ItemType.manga ? 'CH' : 'EP';
    final m = RegExp(r'^(\d+)\s*\|\s*(\d+)').firstMatch(badge.trim());
    String sub;
    if (m != null) {
      final left = int.parse(m.group(2)!) - int.parse(m.group(1)!);
      sub = '$unit ${m.group(1)}${left > 0 ? ' · $left left' : ''}';
    } else {
      sub = badge;
    }
    const h = 112.0;

    return Container(
      width: width,
      margin: const EdgeInsets.only(right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: width,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AnymeXImage(
                    imageUrl: itemData.poster ?? '',
                    radius: 0,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    sourceId: itemData.source,
                    isAnime: type == ItemType.anime,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Text(
              itemData.title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: YumoriText.ui(size: 13, weight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
            child: Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: YumoriText.ui(
                  size: 11, color: YumoriColors.text.withOpacity(0.65)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lavender progress line with a cream firefly at its tip.
class YumoriProgressLine extends StatelessWidget {
  final double progress;
  const YumoriProgressLine({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
                      final x = c.maxWidth * progress;
                      return SizedBox(
                        height: 7,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned(
                              left: 0,
                              right: 0,
                              top: 2,
                              child: Container(
                                height: 3,
                                decoration: BoxDecoration(
                                  color: const Color(0x38FFFFFF),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                            Positioned(
                              left: 0,
                              top: 2,
                              child: Container(
                                width: x,
                                height: 3,
                                decoration: BoxDecoration(
                                  color: YumoriColors.lavender,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                            Positioned(
                              left: x - 3.5,
                              top: 0,
                              child: Container(
                                width: 7,
                                height: 7,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: YumoriColors.firefly,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    });
  }
}
