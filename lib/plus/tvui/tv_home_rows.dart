import 'dart:convert';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/plus/stremio/builtin_rows.dart';
import 'package:flutter/foundation.dart';

/// One Home row on the TV, as Settings → Home rows shows it.
class TvHomeRow {
  final String key;
  final bool on;
  const TvHomeRow(this.key, this.on);
  TvHomeRow shown(bool v) => TvHomeRow(key, v);
}

/// The TV's Home rows: which show and in what order (Settings → Home rows).
///
/// Keys: continue, forYou, trending, popular, recent, upcoming (anime from
/// AniList) and `m:<id>` for the built-in Movies & TV rows.
class TvHomeRows {
  static const _kRows = 'plus_tv_home_rows';

  /// Bumped on every change, so Home rebuilds.
  static final version = ValueNotifier<int>(0);

  static const movieIds = [
    'trending-movies', 'trending-series', 'popular-movies', 'popular-series', 'airing', 'theaters',
    'top-movies', 'top-series', 'netflix', 'disney', 'prime', 'max', 'appletv', 'upcoming',
  ];

  /// The order Home had before it could be changed.
  static List<String> get defaults => [
        'continue',
        'forYou',
        'trending',
        for (final id in movieIds.take(2)) 'm:$id',
        'popular',
        'recent',
        for (final id in movieIds.skip(2)) 'm:$id',
        'upcoming',
      ];

  static String title(String key) {
    switch (key) {
      case 'continue':
        return 'Continue Watching';
      case 'forYou':
        return 'For you';
      case 'trending':
        return 'Trending Anime';
      case 'popular':
        return 'Popular Anime';
      case 'recent':
        return 'Recently Updated';
      case 'upcoming':
        return 'Upcoming Anime';
    }
    if (key.startsWith('m:')) {
      final id = key.substring(2);
      for (final r in PlusBuiltinRows.all) {
        if (r.id == id) return r.title;
      }
      return id;
    }
    return key;
  }

  /// Saved rows merged with [defaults]: unknown keys dropped, new rows added
  /// where the default order puts them.
  static List<TvHomeRow> merge(List<TvHomeRow> saved, List<String> all) {
    final known = all.toSet();
    final out = <TvHomeRow>[];
    final seen = <String>{};
    for (final r in saved) {
      if (known.contains(r.key) && seen.add(r.key)) out.add(r);
    }
    for (var i = 0; i < all.length; i++) {
      final k = all[i];
      if (seen.contains(k)) continue;
      // After the row that comes before it by default, else at the start.
      var at = 0;
      for (var j = i - 1; j >= 0; j--) {
        final p = out.indexWhere((r) => r.key == all[j]);
        if (p >= 0) {
          at = p + 1;
          break;
        }
      }
      out.insert(at, TvHomeRow(k, true));
      seen.add(k);
    }
    return out;
  }

  static List<TvHomeRow> load() {
    var saved = <TvHomeRow>[];
    try {
      final raw = KvHelper.get<String>(_kRows, defaultVal: '');
      if (raw.isNotEmpty) {
        saved = [
          for (final j in jsonDecode(raw) as List)
            if (j is Map && j['k'] is String) TvHomeRow(j['k'] as String, j['on'] != false),
        ];
      }
    } catch (_) {}
    return merge(saved, defaults);
  }

  static void save(List<TvHomeRow> rows) {
    try {
      KvHelper.set(_kRows, jsonEncode([for (final r in rows) {'k': r.key, 'on': r.on}]));
    } catch (_) {}
    version.value++;
  }

  static void reset() {
    try {
      KvHelper.set(_kRows, '');
    } catch (_) {}
    version.value++;
  }

  /// [rows] with the row at [i] moved by [by] (−1 up, +1 down).
  static List<TvHomeRow> move(List<TvHomeRow> rows, int i, int by) {
    final j = i + by;
    if (i < 0 || i >= rows.length || j < 0 || j >= rows.length) return rows;
    final out = rows.toList();
    final r = out.removeAt(i);
    out.insert(j, r);
    return out;
  }
}
