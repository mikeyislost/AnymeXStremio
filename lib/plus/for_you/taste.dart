// AnymeX+: what you've told the app you like — Like / Love on Movies & TV
// titles, and picks you marked "Not interested" — kept on the device.

import 'dart:convert';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/utils/logger.dart';
import 'package:get/get.dart';

enum TasteMark { none, like, love }

class PlusTaste {
  PlusTaste._();

  static const _kMarks = 'anymexplus_taste_marks';
  static const _kHidden = 'anymexplus_foryou_hidden';

  /// Stremio id (tt…, kitsu:…) → like / love.
  static final RxMap<String, TasteMark> marks = <String, TasteMark>{}.obs;

  /// Picks you marked "Not interested" (their keys and ids).
  static final RxSet<String> hidden = <String>{}.obs;

  /// "kind|genre" → how many hidden picks had that genre.
  static final Map<String, int> lessGenres = {};

  /// Goes up whenever any of the above changes (rows recompute).
  static final RxInt version = 0.obs;

  static bool _loaded = false;

  static void ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    try {
      final m = jsonDecode(KvHelper.get<String>(_kMarks, defaultVal: '{}'));
      if (m is Map) {
        m.forEach((k, v) {
          final mark = v == 'love'
              ? TasteMark.love
              : (v == 'like' ? TasteMark.like : TasteMark.none);
          if (mark != TasteMark.none) marks['$k'] = mark;
        });
      }
      final h = jsonDecode(KvHelper.get<String>(_kHidden, defaultVal: '{}'));
      if (h is Map) {
        hidden.addAll((h['ids'] is List ? h['ids'] as List : const [])
            .map((e) => '$e'));
        if (h['genres'] is Map) {
          (h['genres'] as Map).forEach((k, v) {
            if (v is num) lessGenres['$k'] = v.toInt();
          });
        }
      }
    } catch (e) {
      Logger.i('For you: saved taste unreadable: $e');
    }
  }

  static TasteMark markFor(String id) {
    ensureLoaded();
    return marks[id] ?? TasteMark.none;
  }

  static void setMark(String id, TasteMark mark) {
    ensureLoaded();
    if (mark == TasteMark.none) {
      marks.remove(id);
    } else {
      marks[id] = mark;
    }
    KvHelper.set(_kMarks,
        jsonEncode(marks.map((k, v) => MapEntry(k, v.name))));
    version.value++;
  }

  /// "Not interested": hide this pick for good, and count its genres a
  /// little less for this kind of title from now on.
  static void hide({
    required String key,
    required String id,
    required String kind,
    List<String> genres = const [],
  }) {
    ensureLoaded();
    hidden
      ..add(key)
      ..add(id);
    final group = kind == 'anime' ? 'anime' : 'video';
    for (final g in genres) {
      final k = '$group|$g';
      lessGenres[k] = (lessGenres[k] ?? 0) + 1;
    }
    KvHelper.set(
        _kHidden, jsonEncode({'ids': hidden.toList(), 'genres': lessGenres}));
    version.value++;
  }

  /// Genre counts for one kind ("anime" or "video"), without the prefix.
  static Map<String, int> lessGenresFor(String group) {
    ensureLoaded();
    final out = <String, int>{};
    lessGenres.forEach((k, v) {
      if (k.startsWith('$group|')) out[k.substring(group.length + 1)] = v;
    });
    return out;
  }
}
