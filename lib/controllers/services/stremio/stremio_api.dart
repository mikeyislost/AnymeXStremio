// Client for Stremio's account API (api.strem.io) and the addon protocol.
//
// Request/response shapes follow stremio-core:
//   src/types/api/request.rs, src/types/api/response.rs
// Addon protocol: https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/protocol.md

import 'dart:async';
import 'dart:convert';

import 'package:anymex/controllers/services/stremio/stremio_models.dart';
import 'package:http/http.dart' as http;

class StremioApiException implements Exception {
  final String message;
  final int code;
  StremioApiException(this.message, [this.code = 0]);

  @override
  String toString() => message;
}

class StremioAuthResult {
  final String authKey;
  final Map<String, dynamic> user;
  StremioAuthResult(this.authKey, this.user);
}

class StremioLinkCode {
  final String code;
  final String link;
  final String? qrcode;
  StremioLinkCode(this.code, this.link, this.qrcode);
}

class StremioApi {
  static const String apiBase = 'https://api.strem.io/api/';
  static const String linkBase = 'https://link.stremio.com/api/v2/';
  static const Duration _timeout = Duration(seconds: 20);

  final http.Client _client = http.Client();

  Future<dynamic> _call(String method, Map<String, dynamic> body) async {
    final resp = await _client
        .post(
          Uri.parse('$apiBase$method'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    dynamic decoded;
    try {
      decoded = jsonDecode(resp.body);
    } catch (_) {
      throw StremioApiException(
          'Stremio returned an invalid response (${resp.statusCode})');
    }
    if (decoded is Map) {
      final err = decoded['error'];
      if (err != null) {
        if (err is Map) {
          throw StremioApiException(
            err['message']?.toString() ?? 'Stremio error',
            err['code'] is int ? err['code'] as int : 0,
          );
        }
        throw StremioApiException(err.toString());
      }
      if (decoded.containsKey('result')) return decoded['result'];
    }
    throw StremioApiException(
        'Unexpected response from Stremio (${resp.statusCode})');
  }

  // ---- Auth ---------------------------------------------------------------

  Future<StremioAuthResult> login(String email, String password) async {
    final result = await _call('login', {
      'type': 'Login',
      'email': email,
      'password': password,
      'facebook': false,
    });
    final map = Map<String, dynamic>.from(result as Map);
    return StremioAuthResult(
      map['authKey'].toString(),
      Map<String, dynamic>.from((map['user'] ?? {}) as Map),
    );
  }

  Future<void> logout(String authKey) async {
    try {
      await _call('logout', {'type': 'Logout', 'authKey': authKey});
    } catch (_) {}
  }

  Future<Map<String, dynamic>> getUser(String authKey) async {
    final result = await _call('getUser', {
      'type': 'GetUser',
      'authKey': authKey,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// Starts a "log in on another device" flow: the user opens [link]
  /// (www.stremio.com/link) and enters the code, which works for accounts
  /// created with Google, Facebook or Apple.
  Future<StremioLinkCode> createLinkCode() async {
    final resp = await _client
        .get(Uri.parse('${linkBase}create?type=Create'))
        .timeout(_timeout);
    final decoded = jsonDecode(resp.body);
    final result = decoded is Map ? decoded['result'] : null;
    if (result is! Map) {
      throw StremioApiException('Could not create a Stremio link code');
    }
    return StremioLinkCode(
      result['code'].toString(),
      result['link'].toString(),
      result['qrcode']?.toString(),
    );
  }

  /// Returns the auth key once the user has confirmed the code, else null.
  Future<String?> readLinkCode(String code) async {
    final resp = await _client
        .get(Uri.parse(
            '${linkBase}read?type=Read&code=${Uri.encodeQueryComponent(code)}'))
        .timeout(_timeout);
    try {
      final decoded = jsonDecode(resp.body);
      final result = decoded is Map ? decoded['result'] : null;
      if (result is Map) {
        final key = result['authKey'] ?? result['auth_key'];
        if (key != null && key.toString().isNotEmpty) return key.toString();
      }
    } catch (_) {}
    return null;
  }

  // ---- Addons -------------------------------------------------------------

  Future<List<StremioAddon>> addonCollectionGet(String authKey) async {
    final result = await _call('addonCollectionGet', {
      'type': 'AddonCollectionGet',
      'authKey': authKey,
      'update': true,
    });
    final addons = (result is Map ? result['addons'] : null);
    if (addons is! List) return [];
    return addons
        .whereType<Map>()
        .map((e) => StremioAddon.fromDescriptor(Map<String, dynamic>.from(e)))
        .where((a) => a.transportUrl.isNotEmpty)
        .toList();
  }

  Future<void> addonCollectionSet(
      String authKey, List<StremioAddon> addons) async {
    await _call('addonCollectionSet', {
      'type': 'AddonCollectionSet',
      'authKey': authKey,
      'addons': addons.map((a) => a.toDescriptor()).toList(),
    });
  }

  // ---- Library ------------------------------------------------------------

  Future<List<StremioLibraryItem>> datastoreGet(String authKey,
      {List<String> ids = const [], bool all = false}) async {
    final result = await _call('datastoreGet', {
      'authKey': authKey,
      'collection': 'libraryItem',
      'ids': ids,
      'all': all,
    });
    if (result is! List) return [];
    return result
        .whereType<Map>()
        .map((e) => StremioLibraryItem(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> datastorePut(
      String authKey, List<StremioLibraryItem> changes) async {
    if (changes.isEmpty) return;
    await _call('datastorePut', {
      'authKey': authKey,
      'collection': 'libraryItem',
      'changes': changes.map((c) => c.toJson()).toList(),
    });
  }

  // ---- Addon protocol -----------------------------------------------------

  Future<StremioAddon> fetchManifest(String url) async {
    var manifestUrl = url.trim();
    if (manifestUrl.startsWith('stremio://')) {
      manifestUrl = 'https://${manifestUrl.substring('stremio://'.length)}';
    }
    if (!manifestUrl.contains('manifest.json')) {
      while (manifestUrl.endsWith('/')) {
        manifestUrl = manifestUrl.substring(0, manifestUrl.length - 1);
      }
      manifestUrl = '$manifestUrl/manifest.json';
    }
    final resp =
        await _client.get(Uri.parse(manifestUrl)).timeout(_timeout);
    if (resp.statusCode != 200) {
      throw StremioApiException(
          'Could not load addon manifest (HTTP ${resp.statusCode})');
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! Map || decoded['id'] == null) {
      throw StremioApiException('That URL is not a Stremio addon manifest');
    }
    return StremioAddon(
      transportUrl: manifestUrl,
      manifest: Map<String, dynamic>.from(decoded),
    );
  }

  String _extraPath(Map<String, String> extra) {
    if (extra.isEmpty) return '';
    final parts = extra.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return '/$parts';
  }

  Future<Map<String, dynamic>?> _resource(StremioAddon addon, String resource,
      String type, String id, [Map<String, String> extra = const {}]) async {
    final url = '${addon.baseUrl}/$resource/${Uri.encodeComponent(type)}/'
        '${Uri.encodeComponent(id)}${_extraPath(extra)}.json';
    final resp = await _client.get(Uri.parse(url)).timeout(_timeout);
    if (resp.statusCode != 200) return null;
    final decoded = jsonDecode(resp.body);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  Future<List<StremioMetaPreview>> catalog(
    StremioAddon addon,
    StremioCatalog catalog, {
    Map<String, String> extra = const {},
  }) async {
    final data =
        await _resource(addon, 'catalog', catalog.type, catalog.id, extra);
    final metas = data?['metas'];
    if (metas is! List) return [];
    return metas
        .whereType<Map>()
        .map((e) => StremioMetaPreview.fromJson(Map<String, dynamic>.from(e)))
        .where((m) => m.id.isNotEmpty)
        .toList();
  }

  Future<StremioMeta?> meta(StremioAddon addon, String type, String id) async {
    final data = await _resource(addon, 'meta', type, id);
    final meta = data?['meta'];
    if (meta is! Map) return null;
    return StremioMeta.fromJson(Map<String, dynamic>.from(meta));
  }

  Future<List<StremioStream>> streams(
      StremioAddon addon, String type, String videoId) async {
    final data = await _resource(addon, 'stream', type, videoId);
    final streams = data?['streams'];
    if (streams is! List) return [];
    return streams
        .whereType<Map>()
        .map((e) =>
            StremioStream.fromJson(Map<String, dynamic>.from(e), addon.name))
        .toList();
  }

  Future<List<Map<String, String>>> subtitles(
      StremioAddon addon, String type, String videoId) async {
    final data = await _resource(addon, 'subtitles', type, videoId);
    final subs = data?['subtitles'];
    if (subs is! List) return [];
    return subs
        .whereType<Map>()
        .where((s) => s['url'] != null)
        .map((s) => {
              'url': s['url'].toString(),
              'lang': s['lang']?.toString() ?? 'Unknown',
            })
        .toList();
  }
}
