// AnymeX+: "Up next" on Movies & TV episodes. When the episode's credits
// start (TheIntroDB or chapter marks), a card counts down and plays the
// next episode; without credit times, a "Next episode" button shows from
// your watched point (the "mark as watched" percentage) and the countdown
// only runs over the last seconds. The next episode's streams are looked up
// in the background before this (your usual stream when there is one).

import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/screens/anime/watch/controller/player_controller.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/helper/tv_wrapper.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// What the Up next card shows at a moment of playback.
typedef UpNextState = ({bool show, int? countdown, bool playNow});

class PlusUpNext extends StatefulWidget {
  final PlayerController controller;

  const PlusUpNext({super.key, required this.controller});

  static const countdownSeconds = 10;

  /// Pure rule (unit-tested). Positions in seconds; [creditsStart] null
  /// when the episode has no credit times; [watchedPoint] 0..1.
  static UpNextState stateAt({
    required int position,
    required int duration,
    int? creditsStart,
    required double watchedPoint,
  }) {
    const hidden = (show: false, countdown: null, playNow: false);
    if (duration < 60 || position <= 0) return hidden;
    if (creditsStart != null &&
        creditsStart > duration * 0.5 &&
        position >= creditsStart) {
      final left = countdownSeconds - (position - creditsStart);
      return (show: true, countdown: left.clamp(0, countdownSeconds).toInt(),
          playNow: left <= 0);
    }
    final left = duration - position;
    if (left <= countdownSeconds) {
      // AnymeX plays the next episode itself when this one ends.
      return (show: true, countdown: left.clamp(0, countdownSeconds).toInt(),
          playNow: false);
    }
    if (position >= duration * watchedPoint) {
      return (show: true, countdown: null, playNow: false);
    }
    return hidden;
  }

  @override
  State<PlusUpNext> createState() => _PlusUpNextState();
}

class _PlusUpNextState extends State<PlusUpNext> {
  String? _dismissedFor;
  String? _startedFor;

  PlayerController get c => widget.controller;

  String get _episodeKey =>
      '${c.anilistData.id}#${c.currentEpisode.value.link ?? c.currentEpisode.value.number}';

  bool get _applies =>
      !c.isOffline.value &&
      (StremioIds.isStremioMediaId(c.anilistData.id) ||
          c.currentEpisode.value.source == 'Stremio') &&
      c.hasNextEpisode;

  void _playNext() {
    final key = _episodeKey;
    if (_startedFor == key) return;
    _startedFor = key;
    c.navigator(true);
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final pos = c.currentPosition.value.inSeconds;
      final dur = c.episodeDuration.value.inSeconds;
      c.currentEpisode.value;
      if (!_applies || _dismissedFor == _episodeKey) {
        return const SizedBox.shrink();
      }
      final credits = c.skipTimes?.ed;
      final state = PlusUpNext.stateAt(
        position: pos,
        duration: dur,
        creditsStart: credits?.start,
        watchedPoint: (c.settings.markAsCompleted.clamp(50, 99)) / 100,
      );
      if (!state.show) return const SizedBox.shrink();
      if (state.playNow) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _playNext());
      }
      final next = c.nextEpisode;
      return Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 24, bottom: 110),
          child: _card(context, state.countdown, next?.title),
        ),
      );
    });
  }

  Widget _card(BuildContext context, int? countdown, String? nextTitle) {
    final colors = context.colors;
    return Material(
      color: const Color(0xB8000000),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnymeXText(
                    countdown == null
                        ? 'Up next'
                        : 'Next episode in $countdown',
                    size: 12,
                    color: Colors.white70,
                  ),
                  if (nextTitle != null && nextTitle.isNotEmpty)
                    AnymeXText(nextTitle,
                        size: 14,
                        variant: TextVariant.semiBold,
                        color: Colors.white,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 10),
            AnymexOnTap(
              onTap: _playNext,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.skip_next_rounded,
                      size: 18, color: colors.onPrimary),
                  const SizedBox(width: 4),
                  AnymeXText('Play now',
                      size: 13,
                      variant: TextVariant.semiBold,
                      color: colors.onPrimary),
                ]),
              ),
            ),
            IconButton(
              tooltip: 'Keep watching',
              onPressed: () => setState(() => _dismissedFor = _episodeKey),
              icon: const Icon(Icons.close_rounded,
                  size: 18, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
