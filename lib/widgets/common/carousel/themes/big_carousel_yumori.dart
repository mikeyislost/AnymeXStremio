import 'package:anymex/models/Media/media.dart';
import 'package:anymex/theme/yumori_tokens.dart';
import 'package:anymex/widgets/helper/platform_builder.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_image.dart';
import 'package:anymex/widgets/common/carousel/carousel_types.dart';
import 'package:anymex/widgets/common/carousel/themes/base_big_carousel.dart';
import 'package:carousel_slider/carousel_slider.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Yumori "Featured": full-width show art, serif title, short synopsis and a
/// lavender button, with page dots underneath (Moonlit 4 Home hero).
class BigCarouselYumori extends BaseBigCarousel {
  const BigCarouselYumori({
    super.key,
    required super.data,
    super.carouselType = CarouselType.anime,
  });

  @override
  State<BigCarouselYumori> createState() => _BigCarouselYumoriState();
}

class _BigCarouselYumoriState extends BaseBigCarouselState<BigCarouselYumori> {
  String _art(Media m) {
    for (final u in [m.cover, m.largePoster, m.poster]) {
      if (u != null && u.isNotEmpty && u != '?') return u;
    }
    return '';
  }

  String _meta(Media m) {
    final parts = <String>[];
    if (m.format.isNotEmpty && m.format != '?') parts.add(m.format);
    if (m.genres.isNotEmpty) parts.add(m.genres.first);
    if (m.seasonYear != null) parts.add('${m.seasonYear}');
    return parts.join(' · ');
  }

  String _plain(String html) => html
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Widget _card(BuildContext context, Media media, String tag) {
    final isManga = widget.carouselType == CarouselType.manga;
    final art = _art(media);
    final count = isManga ? media.totalChapters : media.totalEpisodes;
    final countLabel = (count == null || count.isEmpty || count == '?')
        ? null
        : '$count ${isManga ? 'Chapters' : 'Episodes'}';
    final score = media.rating;
    final desc = _plain(media.description);

    return GestureDetector(
      onTap: () => navigateToDetailsPage(media, tag),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: YumoriColors.card,
          borderRadius: BorderRadius.circular(24),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (art.isNotEmpty)
              AnymeXImage(
                imageUrl: art,
                radius: 0,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  stops: [0.0, 0.45, 0.8, 1.0],
                  colors: [
                    Color(0xF50D0A16),
                    Color(0xE60D0A16),
                    Color(0x400D0A16),
                    Color(0x800D0A16),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 18,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('FEATURED',
                          style: YumoriText.ui(
                                  size: 10,
                                  weight: FontWeight.w600,
                                  color: YumoriColors.text)
                              .copyWith(letterSpacing: 3.2)),
                      const SizedBox(width: 11),
                      Container(
                          width: 43, height: 1, color: YumoriColors.lavender),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    media.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: YumoriText.title(size: 30),
                  ),
                  const SizedBox(height: 6),
                  if (_meta(media).isNotEmpty)
                    Text(_meta(media),
                        style: YumoriText.ui(
                            size: 11,
                            color: YumoriColors.text.withOpacity(0.75))),
                  if (desc.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(desc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: YumoriText.ui(
                            size: 12,
                            color: YumoriColors.text.withOpacity(0.85))
                            .copyWith(height: 1.45)),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (score.isNotEmpty && score != '?' && score != '0.0') ...[
                        const Icon(Icons.star_rounded,
                            size: 14, color: YumoriColors.firefly),
                        const SizedBox(width: 4),
                        Text(score,
                            style: YumoriText.ui(
                                size: 11,
                                color: YumoriColors.firefly)),
                        const SizedBox(width: 14),
                      ],
                      if (countLabel != null)
                        Text(countLabel,
                            style: YumoriText.ui(
                                size: 11,
                                color:
                                    YumoriColors.text.withOpacity(0.8))),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        decoration: BoxDecoration(
                          color: YumoriColors.lavender,
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  YumoriColors.lavender.withOpacity(0.5),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                              spreadRadius: -6,
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.play_arrow_rounded,
                                size: 18, color: YumoriColors.onLavender),
                            const SizedBox(width: 6),
                            Text('View details',
                                style: YumoriText.ui(
                                    size: 13,
                                    weight: FontWeight.w700,
                                    color: YumoriColors.onLavender)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 9),
                      GestureDetector(
                        onTap: () =>
                            openDescriptionSheet(context, media.description),
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0x4D13101C),
                            border: Border.all(
                                color: YumoriColors.text.withOpacity(0.45)),
                          ),
                          child: const Icon(Icons.info_outline_rounded,
                              size: 18, color: YumoriColors.text),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaList = widget.data.where((m) => _art(m).isNotEmpty).toList();
    if (mediaList.isEmpty) return const SizedBox.shrink();
    final height =
        getResponsiveSize(context, mobileSize: 470, desktopSize: 520);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Column(
        children: [
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                onHorizontalScroll(e.scrollDelta, e.kind);
              }
            },
            onPointerPanZoomUpdate: (e) => onHorizontalScroll(e.panDelta, e.kind),
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.trackpad,
                },
              ),
              child: CarouselSlider.builder(
                itemCount: mediaList.length,
                carouselController: sliderController,
                itemBuilder: (ctx, index, _) {
                  final media = mediaList[index];
                  return _card(ctx, media,
                      '${media.id}-${widget.carouselType.name}-yumori-carousel-$index');
                },
                options: CarouselOptions(
                  height: height,
                  viewportFraction: 1,
                  enableInfiniteScroll: mediaList.length > 1,
                  autoPlay: mediaList.length > 1,
                  autoPlayInterval: const Duration(seconds: 6),
                  autoPlayAnimationDuration: const Duration(milliseconds: 800),
                  autoPlayCurve: Curves.easeInOutCubic,
                  onPageChanged: (i, _) => setState(() => activeIndex = i),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < mediaList.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  width: i == activeIndex ? 19 : 13,
                  height: 2,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: i == activeIndex
                        ? YumoriColors.lavender
                        : YumoriColors.text.withOpacity(0.3),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
