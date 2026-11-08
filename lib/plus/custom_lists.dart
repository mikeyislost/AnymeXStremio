// AnymeX+: your AniList custom anime lists as Home rows (AnymeX Desk #98).

import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/widgets/common/reusable_carousel.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class PlusCustomLists {
  PlusCustomLists._();

  /// Your custom lists (name, entries newest first), in AniList's order.
  static final RxList<(String, List<TrackedMedia>)> lists =
      <(String, List<TrackedMedia>)>[].obs;

  /// Picks the custom lists out of AniList's MediaListCollection `lists`
  /// (the ones with `isCustomList: true`).
  static void setFromLists(List<dynamic> raw) {
    lists.assignAll(customListsIn(raw));
  }

  static List<(String, List<TrackedMedia>)> customListsIn(List<dynamic> raw) {
    final out = <(String, List<TrackedMedia>)>[];
    for (final l in raw.whereType<Map>()) {
      if (l['isCustomList'] != true) continue;
      final name = '${l['name'] ?? ''}'.trim();
      final entries = (l['entries'] is List ? l['entries'] as List : const [])
          .whereType<Map>()
          .map((e) => TrackedMedia.fromJson(Map<String, dynamic>.from(e)))
          .toList()
          .reversed // AniList sends oldest first
          .toList();
      if (name.isEmpty || entries.isEmpty) continue;
      out.add((name, entries));
    }
    return out;
  }
}

/// One Home row per custom list. Nothing when you have none.
class PlusCustomListRows extends StatelessWidget {
  const PlusCustomListRows({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final lists = PlusCustomLists.lists.toList();
      if (lists.isEmpty) return const SizedBox.shrink();
      return Column(
        children: [
          for (final (name, entries) in lists)
            ReusableCarousel(
              data: entries,
              title: name,
              variant: DataVariant.anilist,
              type: ItemType.anime,
            ),
        ],
      );
    });
  }
}
