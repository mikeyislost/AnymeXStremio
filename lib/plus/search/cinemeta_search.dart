// Movies & Series search for the unified Search page. One provider on
// purpose: Cinemeta (Stremio's public IMDb-based catalog). It is built into
// the app, needs no addon and no key.

import 'dart:convert';

import 'package:anymex/plus/categories/categories_data.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:http/http.dart' as http;

class CinemetaSearch {
  static const _base = 'https://v3-cinemeta.strem.io/catalog';

  static Future<List<CatItem>> search(String query) async {
    final q = Uri.encodeComponent(query.trim());
    if (q.isEmpty) return const [];

    Future<List<CatItem>> one(String type) async {
      try {
        final r = await http
            .get(Uri.parse('$_base/$type/top/search=$q.json'))
            .timeout(const Duration(seconds: 10));
        if (r.statusCode != 200) return const [];
        final metas = (jsonDecode(r.body) as Map)['metas'];
        if (metas is! List) return const [];
        return [
          for (final m in metas)
            if (m is Map)
              () {
                final j = m.cast<String, dynamic>();
                j['type'] ??= type;
                return CatItem.fromStremio(StremioMetaPreview.fromJson(j));
              }()
        ].where((i) => i.id.isNotEmpty && i.poster.isNotEmpty).toList();
      } catch (_) {
        return const [];
      }
    }

    final both = await Future.wait([one('movie'), one('series')]);
    // Movies and series alternate, best matches first.
    final out = <CatItem>[];
    final n = both[0].length > both[1].length ? both[0].length : both[1].length;
    for (var i = 0; i < n; i++) {
      if (i < both[0].length) out.add(both[0][i]);
      if (i < both[1].length) out.add(both[1][i]);
    }
    return out;
  }
}
