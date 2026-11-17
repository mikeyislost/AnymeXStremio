// Movies & Series search for the unified Search page. One provider on
// purpose: Cinemeta (Stremio's public IMDb-based catalog). It is built into
// the app, needs no addon and no key.

import 'dart:convert';

import 'package:anymex/plus/categories/categories_data.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:http/http.dart' as http;

class CinemetaSearch {
  static const _base = 'https://v3-cinemeta.strem.io/catalog';

  /// One page of one type. [raw] is how many entries the catalog returned
  /// (that is the next `skip`); 0 means there is nothing more.
  static Future<({List<CatItem> items, int raw})> fetch(
      String type, String query,
      {int skip = 0}) async {
    final q = Uri.encodeComponent(query.trim());
    if (q.isEmpty) return (items: <CatItem>[], raw: 0);
    try {
      final extra = skip > 0 ? 'search=$q&skip=$skip' : 'search=$q';
      final r = await http
          .get(Uri.parse('$_base/$type/top/$extra.json'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return (items: <CatItem>[], raw: 0);
      final metas = (jsonDecode(r.body) as Map)['metas'];
      if (metas is! List) return (items: <CatItem>[], raw: 0);
      final items = <CatItem>[];
      for (final m in metas) {
        if (m is! Map) continue;
        final j = m.cast<String, dynamic>();
        j['type'] ??= type;
        final it = CatItem.fromStremio(StremioMetaPreview.fromJson(j));
        if (it.id.isNotEmpty && it.poster.isNotEmpty) items.add(it);
      }
      return (items: items, raw: metas.length);
    } catch (_) {
      return (items: <CatItem>[], raw: 0);
    }
  }
}
