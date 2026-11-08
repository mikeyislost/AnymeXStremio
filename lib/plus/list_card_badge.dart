// AnymeX+: your score on Library cards (AnymeX Desk #87).

import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:get/get.dart';

/// The badge on a card in your list: progress, plus your score when you've
/// given one ("3 | 12 · ★8.5").
String listCardBadge(TrackedMedia m) {
  final progress = m.formattedProgress;
  final raw = double.tryParse(m.score ?? '') ?? 0;
  if (raw <= 0) return progress;
  final score = formatListScore(raw, m.servicesType);
  // AniList's 3-point format is a face, not a number.
  return score.startsWith(':') ? '$progress · $score' : '$progress · ★$score';
}

/// A score in your AniList score format (other services: as it is).
String formatListScore(double raw, ServicesType service) {
  if (service == ServicesType.anilist && Get.isRegistered<AnilistAuth>()) {
    return Get.find<AnilistAuth>().formatScore(raw);
  }
  return raw == raw.roundToDouble()
      ? raw.toInt().toString()
      : raw.toStringAsFixed(1);
}
