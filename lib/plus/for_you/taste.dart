// AnymeX+: what you've told the app you like — Like / Love / Dislike on
// anime and Movies & TV titles, and picks you marked "Not interested" —
// kept on the device. Anime marks use "al:<AniList id>" keys; Movies & TV
// use Stremio ids (tt…, kitsu:…).

import 'dart:convert';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/utils/logger.dart';
import 'package:get/get.dart';

enum TasteMark { none, like, love, dislike }

class PlusTaste {
  PlusTaste._();

  static const _kMarks = 'anymexplus_taste_marks';
  static const _kHidden = 'anymexplus_foryou_hidden';
  static const _kNotes = 'anymexplus_taste_notes';

  /// Stremio id (tt…, kitsu:…) → like / love.
  static final RxMap<String, TasteMark> marks = <String, TasteMark>{}.obs;

  /// Title and genres of marked anime, so For you can use marks on anime
  /// that aren't on your list. key → (title, genres).
  static final Map<String, ({String title, List<String> genres})> notes = {};

  /// The key anime marks are kept under.
  static String animeKey(String anilistId) => 'al:$anilistId';

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
          final mark = TasteMark.values.firstWhere((t) => t.name == v,
              orElse: () => TasteMark.none);
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
      final n = jsonDecode(KvHelper.get<String>(_kNotes, defaultVal: '{}'));
      if (n is Map) {
        n.forEach((k, v) {
          if (v is! Map) return;
          notes['$k'] = (
            title: '${v['t'] ?? ''}',
            genres: (v['g'] is List ? v['g'] as List : const [])
                .map((e) => '$e')
                .toList(),
          );
        });
      }
    } catch (e) {
      Logger.i('For you: saved taste unreadable: $e');
    }
  }

  static TasteMark markFor(String id) {
    ensureLoaded();
    return marks[id] ?? TasteMark.none;
  }

  /// Sets (or clears) a mark. [title] and [genres] are kept for anime.
  static void setMark(String id, TasteMark mark,
      {String? title, List<String>? genres}) {
    ensureLoaded();
    if (mark == TasteMark.none) {
      marks.remove(id);
      notes.remove(id);
    } else {
      marks[id] = mark;
      if (title != null) {
        notes[id] = (title: title, genres: genres ?? const []);
      }
    }
    KvHelper.set(_kMarks,
        jsonEncode(marks.map((k, v) => MapEntry(k, v.name))));
    KvHelper.set(
        _kNotes,
        jsonEncode(notes.map(
            (k, v) => MapEntry(k, {'t': v.title, 'g': v.genres}))));
    version.value++;
  }

  /// Ids you disliked: they never show in For you.
  static Set<String> get disliked {
    ensureLoaded();
    return {
      for (final e in marks.entries)
        if (e.value == TasteMark.dislike) e.key,
    };
  }

  /// Re-reads what's saved (after AnymeX restores a backup).
  static void reload() {
    marks.clear();
    hidden.clear();
    notes.clear();
    lessGenres.clear();
    _loaded = false;
    ensureLoaded();
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
