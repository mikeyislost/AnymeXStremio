// AnymeX+: a single "movie" card for the Watch tab, used instead of a
// one-item "Episode 1" list when a title is a movie.

import 'dart:math' as math;

import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_image.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/helper/tv_wrapper.dart';
import 'package:flutter/material.dart';

/// Whether [media] with [episodes] should be shown as a movie.
bool isMovieMedia(Media? media, List<Episode> episodes) {
  if (episodes.length != 1) return false;
  if (media == null) return false;
  final format = media.format.toUpperCase();
  return format == 'MOVIE' ||
      media.id.endsWith('*MOVIE') ||
      (media.type.toUpperCase() == 'MOVIE');
}

/// "46m", "1h 46m" from AniList-style durations ("46 mins", "106 min",
/// "1 hr 46 min") or plain minutes.
String formatMovieRuntime(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty || s == '?') return '';
  final hours = RegExp(r'(\d+)\s*h').firstMatch(s);
  final mins = RegExp(r'(\d+)\s*m').firstMatch(s);
  int total;
  if (hours != null || mins != null) {
    total = (int.tryParse(hours?.group(1) ?? '0') ?? 0) * 60 +
        (int.tryParse(mins?.group(1) ?? '0') ?? 0);
  } else {
    total = int.tryParse(RegExp(r'\d+').firstMatch(s)?.group(0) ?? '') ?? 0;
  }
  if (total <= 0) return raw;
  if (total < 60) return '${total}m';
  final h = total ~/ 60;
  final m = total % 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

class MovieWatchCard extends StatelessWidget {
  final String title;
  final String imageUrl;
  final String? fallbackImage;

  /// Short facts shown under the title, e.g. ['1h 46m', '2013'].
  final List<String> details;

  /// 0..1 progress through the movie; 0 hides the bar.
  final double progress;
  final bool watched;
  final VoidCallback onPlay;
  final VoidCallback? onLongPress;

  /// Optional widget in the top-right corner (e.g. a download button).
  final Widget? trailing;

  /// Label on the small chip in the top-left corner.
  final String badge;

  const MovieWatchCard({
    super.key,
    required this.title,
    required this.imageUrl,
    this.fallbackImage,
    this.details = const [],
    this.progress = 0,
    this.watched = false,
    required this.onPlay,
    this.onLongPress,
    this.trailing,
    this.badge = 'MOVIE',
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final p = progress.clamp(0.0, 1.0);
    final resuming = p > 0.01 && p < 0.97;
    final label = resuming ? 'Resume' : (watched ? 'Watch again' : 'Play');
    final facts = [
      ...details.where((d) => d.trim().isNotEmpty),
      if (resuming) '${(p * 100).round()}% watched',
      if (!resuming && watched) 'Watched',
    ];

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final double height =
          math.min(width * 9 / 16, 260.0).clamp(170.0, 260.0).toDouble();
      return AnymexOnTap(
        onTap: onPlay,
        onLongPress: onLongPress,
        child: Container(
          height: height,
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: colors.onSurface.opaque(0.08, iReallyMeanIt: true),
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnymeXImage(
                imageUrl: imageUrl,
                radius: 0,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                errorImage: fallbackImage,
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.opaque(0.05, iReallyMeanIt: true),
                      Colors.black.opaque(0.35, iReallyMeanIt: true),
                      Colors.black.opaque(0.88, iReallyMeanIt: true),
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: colors.primary.opaque(0.9, iReallyMeanIt: true),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.movie_rounded,
                          size: 13, color: colors.onPrimary),
                      const SizedBox(width: 5),
                      AnymeXText(
                        badge,
                        size: 11,
                        variant: TextVariant.bold,
                        color: colors.onPrimary,
                      ),
                    ],
                  ),
                ),
              ),
              if (trailing != null)
                Positioned(top: 8, right: 8, child: trailing!),
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AnymeXText(
                            title,
                            size: 19,
                            variant: TextVariant.bold,
                            color: Colors.white,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (facts.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            AnymeXText(
                              facts.join('  ·  '),
                              size: 12,
                              color: Colors.white
                                  .opaque(0.8, iReallyMeanIt: true),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: colors.primary,
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.opaque(0.3, iReallyMeanIt: true),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            watched && !resuming
                                ? Icons.replay_rounded
                                : Icons.play_arrow_rounded,
                            color: colors.onPrimary,
                            size: 22,
                          ),
                          const SizedBox(width: 6),
                          AnymeXText(
                            label,
                            size: 13,
                            variant: TextVariant.bold,
                            color: colors.onPrimary,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (resuming)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: p,
                      child: Container(height: 4, color: colors.primary),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}
