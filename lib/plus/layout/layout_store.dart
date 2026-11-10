// AnymeX+: where the page layouts are saved (on the device, with the other
// settings, so backups include them).

import 'dart:convert';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/plus/layout/layout_model.dart';
import 'package:get/get.dart';

enum PlusLayoutPage { home, movies, manga }

class PlusLayoutStore {
  PlusLayoutStore._();

  /// Bumped on every save: pages rebuild on it.
  static final RxInt version = 0.obs;

  static final Map<PlusLayoutPage, List<PlusRowConfig>> _cache = {};

  static String _key(PlusLayoutPage p) => 'anymexplus_layout_${p.name}';

  static List<PlusRowConfig> saved(PlusLayoutPage page) {
    return _cache.putIfAbsent(page, () {
      try {
        final raw = KvHelper.get<String>(_key(page), defaultVal: '');
        if (raw.isEmpty) return <PlusRowConfig>[];
        return PlusRowConfig.listFromJson(jsonDecode(raw));
      } catch (_) {
        return <PlusRowConfig>[];
      }
    });
  }

  static bool hasSaved(PlusLayoutPage page) => saved(page).isNotEmpty;

  static void save(PlusLayoutPage page, List<PlusRowConfig> rows) {
    _cache[page] = List.of(rows);
    KvHelper.set(_key(page), jsonEncode(rows.map((r) => r.toJson()).toList()));
    version.value++;
  }

  static void reset(PlusLayoutPage page) {
    _cache[page] = <PlusRowConfig>[];
    KvHelper.remove(_key(page));
    version.value++;
  }

  /// After a backup restore: read everything again.
  static void reload() {
    _cache.clear();
    version.value++;
  }
}
