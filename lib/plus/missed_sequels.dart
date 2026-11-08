// AnymeX+: "Missed sequels" on Home (AnymeX Desk #151): sequels of anime you
// completed on AniList that aren't on your list at all.

import 'dart:async';
import 'dart:convert';

import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:anymex/models/Media/relation.dart';
import 'package:anymex/plus/stremio/stremio_disk_cache.dart';
import 'package:anymex/utils/function.dart';
import 'package:anymex/utils/logger.dart';
import 'package:anymex/widgets/common/reusable_carousel.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// A sequel found for one of your completed anime (before filtering out
/// what's on your list).
class SequelCandidate {
  final int id;
  final String title;
  final String poster;
  final String cover;
  final String status;
  final String format;
  final bool isAdult;
  final String averageScore;

  const SequelCandidate({
    required this.id,
    required this.title,
    required this.poster,
    this.cover = '',
    required this.status,
    required this.format,
    this.isAdult = false,
    this.averageScore = '0',
  });

  factory SequelCandidate.fromJson(Map<String, dynamic> j) => SequelCandidate(
        id: (j['id'] as num).toInt(),
        title: '${j['title'] ?? ''}',
        poster: '${j['poster'] ?? ''}',
        cover: '${j['cover'] ?? ''}',
        status: '${j['status'] ?? ''}',
        format: '${j['format'] ?? ''}',
        isAdult: j['isAdult'] == true,
        averageScore: '${j['averageScore'] ?? '0'}',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'poster': poster,
        'cover': cover,
        'status': status,
        'format': format,
        'isAdult': isAdult,
        'averageScore': averageScore,
      };

  Relation toRelation() => Relation(
        id: id,
        title: title,
        poster: poster,
        cover: cover,
        type: 'ANIME',
        averageScore: averageScore,
        relationType: 'SEQUEL',
        status: status,
      );
}

class MissedSequels {
  MissedSequels._();

  static const _diskKey = 'anilist/missed_sequels';
  static const keepFor = Duration(days: 3);
  static const _chunk = 25;

  /// Sequels of your completed anime, in the order you completed them
  /// (newest first). Filtered against your list when shown.
  static final RxList<SequelCandidate> candidates = <SequelCandidate>[].obs;
  static String _signature = '';
  static Future<void>? _loading;

  /// Completed anime, most recently finished first.
  static List<TrackedMedia> completedOf(List<TrackedMedia> list) {
    final done = list
        .where((m) =>
            m.watchingStatus == 'COMPLETED' &&
            (m.type == null || m.type!.toUpperCase() == 'ANIME') &&
            int.tryParse(m.id ?? '') != null)
        .toList();
    int when(TrackedMedia m) =>
        m.completedAt?.millisecondsSinceEpoch ?? (m.updatedAt ?? 0) * 1000;
    done.sort((a, b) => when(b).compareTo(when(a)));
    return done;
  }

  static String signatureOf(List<TrackedMedia> completed) =>
      completed.map((m) => m.id).join(',');

  /// Loads the sequels for [list] once per change of your completed anime:
  /// from the phone if saved in the last [keepFor], else from AniList.
  static Future<void> ensure(List<TrackedMedia> list) {
    final completed = completedOf(list);
    final sig = signatureOf(completed);
    if (sig == _signature && _loading != null) return _loading!;
    _signature = sig;
    return _loading = _load(completed, sig);
  }

  static Future<void> _load(List<TrackedMedia> completed, String sig) async {
    if (completed.isEmpty) {
      candidates.clear();
      return;
    }
    final saved = await StremioDiskCache.read(_diskKey);
    final savedMap = saved?.value is Map ? saved!.value as Map : null;
    if (savedMap != null && savedMap['sig'] == sig) {
      candidates.assignAll(_decode(savedMap['items']));
      if (saved!.isFresherThan(keepFor)) return;
    }
    try {
      final found = await _fetch(completed.map((m) => int.parse(m.id!)).toList());
      if (sig != _signature) return; // the list changed meanwhile
      candidates.assignAll(found);
      unawaited(StremioDiskCache.write(_diskKey, {
        'sig': sig,
        'items': found.map((c) => c.toJson()).toList(),
      }));
    } catch (e) {
      Logger.i('Missed sequels: $e');
    }
  }

  static List<SequelCandidate> _decode(dynamic items) => items is List
      ? items
          .whereType<Map>()
          .map((m) => SequelCandidate.fromJson(Map<String, dynamic>.from(m)))
          .toList()
      : <SequelCandidate>[];

  static const _query = r'''
query ($ids: [Int]) {
  Page(perPage: 50) {
    media(id_in: $ids, type: ANIME) {
      id
      relations {
        edges {
          relationType(version: 2)
          node {
            id type format status isAdult averageScore bannerImage
            title { userPreferred english romaji }
            coverImage { large }
          }
        }
      }
    }
  }
}''';

  /// Asks AniList for the relations of [ids] (in groups) and keeps the
  /// sequels, in the order of [ids].
  static Future<List<SequelCandidate>> _fetch(List<int> ids) async {
    final byPrequel = <int, List<SequelCandidate>>{};
    for (var i = 0; i < ids.length; i += _chunk) {
      final part = ids.sublist(i, i + _chunk > ids.length ? ids.length : i + _chunk);
      final resp = await http
          .post(
            Uri.parse('https://graphql.anilist.co'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'query': _query,
              'variables': {'ids': part},
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw Exception('AniList HTTP ${resp.statusCode}');
      }
      final media = (jsonDecode(resp.body)['data']?['Page']?['media']
              as List?) ??
          const [];
      for (final m in media.whereType<Map>()) {
        final id = (m['id'] as num?)?.toInt();
        if (id == null) continue;
        byPrequel[id] = sequelsIn(m['relations']);
      }
    }
    final seen = <int>{};
    final out = <SequelCandidate>[];
    for (final id in ids) {
      for (final c in byPrequel[id] ?? const <SequelCandidate>[]) {
        if (seen.add(c.id)) out.add(c);
      }
    }
    return out;
  }

  /// The anime sequels in an AniList `relations` object.
  static List<SequelCandidate> sequelsIn(dynamic relations) {
    final edges = relations is Map ? relations['edges'] : null;
    if (edges is! List) return const [];
    final out = <SequelCandidate>[];
    for (final e in edges.whereType<Map>()) {
      if (e['relationType'] != 'SEQUEL') continue;
      final n = e['node'];
      if (n is! Map || n['type'] != 'ANIME') continue;
      final t = n['title'] is Map ? n['title'] as Map : const {};
      out.add(SequelCandidate(
        id: (n['id'] as num).toInt(),
        title: '${t['userPreferred'] ?? t['english'] ?? t['romaji'] ?? ''}',
        poster: '${(n['coverImage'] is Map ? n['coverImage']['large'] : null) ?? ''}',
        cover: '${n['bannerImage'] ?? ''}',
        status: '${n['status'] ?? ''}',
        format: '${n['format'] ?? ''}',
        isAdult: n['isAdult'] == true,
        averageScore: '${n['averageScore'] ?? 0}',
      ));
    }
    return out;
  }

  /// What to show: out already (finished or airing), not music videos or
  /// adult titles, and not on your list in any status.
  static List<SequelCandidate> visible(
      List<SequelCandidate> all, Set<String> onList) {
    return all
        .where((c) =>
            (c.status == 'FINISHED' || c.status == 'RELEASING') &&
            c.format != 'MUSIC' &&
            !c.isAdult &&
            !onList.contains('${c.id}'))
        .toList();
  }
}

/// The Home row. Hidden when there's nothing to show.
class PlusMissedSequelsRow extends StatelessWidget {
  const PlusMissedSequelsRow({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<AnilistAuth>()) return const SizedBox.shrink();
    final auth = Get.find<AnilistAuth>();
    return Obx(() {
      final list = auth.animeList.toList();
      if (!auth.isLoggedIn.value || list.isEmpty) {
        return const SizedBox.shrink();
      }
      // After this build: loading may update the list this row watches.
      Future.microtask(() => MissedSequels.ensure(list));
      final onList = list.map((m) => m.id).whereType<String>().toSet();
      final shown =
          MissedSequels.visible(MissedSequels.candidates.toList(), onList);
      if (shown.isEmpty) return const SizedBox.shrink();
      return ReusableCarousel(
        data: shown.take(30).map((c) => c.toRelation()).toList(),
        title: 'Missed sequels',
        variant: DataVariant.relation,
        type: ItemType.anime,
      );
    });
  }
}
