import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/controllers/services/mal/mal_service.dart';
import 'package:anymex/controllers/services/simkl/simkl_service.dart';
import 'package:anymex/database/data_keys/keys.dart';
import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/tv/flutter_tv_pair.dart';
import 'package:anymex/plus/tvui/tv_ext.dart';
import 'package:anymex/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:pointycastle/export.dart' show ECPrivateKey;

/// AnymeX+ TV (Flutter): takes your logins from the phone.
///
/// Listens on [PlusFlutterTvPair.port]. A first pairing needs the code on
/// the "Get logins from your phone" page ([open]); after that the phone's
/// saved key works by itself (`again`), so the phone can send fresh logins
/// whenever it finds the TV (Simkl logins renew every week).
class PlusTvPair {
  PlusTvPair._();
  static final instance = PlusTvPair._();

  static const _kKnown = 'plus_ftv_known'; // {id: key hex}

  /// The code to type on the phone ('' while the page is closed).
  final code = ValueNotifier<String>('');

  /// What happened last, for the page and Settings.
  final status = ValueNotifier<String>('');

  /// This TV's address on the home network.
  final address = ValueNotifier<String>('');

  HttpServer? _server;
  String _salt = '';

  /// The pairing page is showing (a code is valid).
  bool get isOpen => code.value.isNotEmpty;

  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, PlusFlutterTvPair.port, shared: true);
    } catch (e) {
      Logger.i('TV pair: listen failed: $e');
      status.value = "Couldn't listen for your phone ($e)";
      return;
    }
    unawaited(_findAddress());
    _server!.listen((req) async {
      try {
        if (req.uri.path == PlusFlutterTvPair.path && WebSocketTransformer.isUpgradeRequest(req)) {
          final ip = req.connectionInfo?.remoteAddress.address ?? '';
          _onSocket(await WebSocketTransformer.upgrade(req), ip);
        } else {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'app': 'anymexplus-flutter-tv', 'pairing': isOpen}));
          await req.response.close();
        }
      } catch (_) {}
    }, onError: (_) {});
  }

  Future<void> _findAddress() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in list) {
        for (final a in i.addresses) {
          if (!a.isLoopback && !a.address.startsWith('169.254.')) {
            address.value = a.address;
            return;
          }
        }
      }
    } catch (_) {}
  }

  /// The pairing page opened: show a fresh code.
  void openPage() {
    code.value = PlusFlutterTvPair.newCode();
    _salt = PlusFlutterTvPair.newSalt();
    unawaited(start());
    if (address.value.isEmpty) unawaited(_findAddress());
  }

  void closePage() {
    code.value = '';
    _salt = '';
  }

  Map<String, String> _known() {
    try {
      final raw = KvHelper.get<String>(_kKnown, defaultVal: '');
      if (raw.isNotEmpty) return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {}
    return {};
  }

  void _remember(String id, String key) {
    final k = _known()..[id] = key;
    if (k.length > 6) k.remove(k.keys.first);
    try {
      KvHelper.set(_kKnown, jsonEncode(k));
    } catch (_) {}
  }

  void _onSocket(WebSocket ws, String ip) {
    ECPrivateKey? priv;
    String phonePub = '';
    String usedCode = '';
    String usedSalt = '';
    String from = 'your phone';
    void send(Map<String, dynamic> m) {
      try {
        ws.add(jsonEncode(m));
      } catch (_) {}
    }

    ws.listen((raw) async {
      Map<String, dynamic> m;
      try {
        m = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
      } catch (_) {
        return;
      }
      switch (m['t']) {
        case 'hi':
          from = '${m['from'] ?? from}';
          if (!isOpen) {
            send({'t': 'closed'});
            return;
          }
          final keys = PlusFlutterTvPair.newKeys();
          priv = keys.$1;
          phonePub = '${m['pub'] ?? ''}';
          usedCode = code.value;
          usedSalt = _salt;
          send({'t': 'hi', 'pub': keys.$2, 'salt': usedSalt, 'name': 'LG TV'});
        case 'logins':
          if (priv == null || phonePub.isEmpty) return;
          String key;
          List<int> plain;
          try {
            key = PlusFlutterTvPair.lockKey(priv!, phonePub, usedCode, usedSalt);
            plain = PlusFlutterTvPair.open(key, '${m['iv']}', '${m['data']}');
          } catch (_) {
            // Wrong code (or a guess): never let the same code be tried twice.
            if (isOpen) openPage();
            status.value = 'A wrong code was typed on $from. Use the new one.';
            send({'t': 'bad'});
            return;
          }
          final what = await _apply(plain, from, ip);
          // The phone remembers this key under the same id, for `again`.
          final id = PlusFlutterTvPair.idFor(key);
          _remember(id, key);
          send({'t': 'ok', 'what': what, 'id': id});
          closePage();
        case 'again':
          from = '${m['from'] ?? from}';
          final key = _known()['${m['id']}'];
          if (key == null) {
            send({'t': 'unknown'});
            return;
          }
          try {
            final plain = PlusFlutterTvPair.open(key, '${m['iv']}', '${m['data']}');
            send({'t': 'ok', 'what': await _apply(plain, from, ip, quiet: true)});
          } catch (_) {
            send({'t': 'unknown'});
          }
      }
    }, onError: (_) {}, cancelOnError: true);
  }

  /// Saves and signs in with what came. Returns the names it took.
  Future<List<String>> _apply(List<int> plain, String from, String ip, {bool quiet = false}) async {
    Map<String, dynamic> b;
    try {
      b = Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)) as Map);
    } catch (_) {
      return const [];
    }
    final took = <String>[];
    String s(String k) => '${b[k] ?? ''}'.trim();

    if (s('anilist').isNotEmpty && s('anilist') != (AuthKeys.authToken.get<String?>() ?? '')) {
      try {
        AuthKeys.authToken.set(s('anilist'));
        await Get.find<AnilistAuth>().tryAutoLogin();
        took.add('AniList');
      } catch (e) {
        Logger.i('TV pair: AniList: $e');
      }
    } else if (s('anilist').isNotEmpty) {
      took.add('AniList');
    }
    if (s('simkl').isNotEmpty) {
      try {
        if (s('simkl') != (AuthKeys.simklAuthToken.get<String?>() ?? '')) {
          AuthKeys.simklAuthToken.set(s('simkl'));
          await Get.find<SimklService>().fetchUserInfo();
        }
        took.add('Simkl');
      } catch (e) {
        Logger.i('TV pair: Simkl: $e');
      }
    }
    if (s('mal').isNotEmpty) {
      try {
        if (s('mal') != (AuthKeys.malAuthToken.get<String?>() ?? '')) {
          AuthKeys.malAuthToken.set(s('mal'));
          await Get.find<MalService>().fetchUserInfo(token: s('mal'));
        }
        took.add('MyAnimeList');
      } catch (e) {
        Logger.i('TV pair: MAL: $e');
      }
    }
    if (s('stremio').isNotEmpty) {
      try {
        final st = StremioService.to;
        if (st.authKey != s('stremio')) await st.loginWithAuthKey(s('stremio'));
        took.add('Stremio');
      } catch (e) {
        Logger.i('TV pair: Stremio: $e');
      }
    }
    final link = b['link'];
    if (link is Map && ip.isNotEmpty) {
      final d = TvExtDevice.fromJson({...link, 'host': ip});
      if (d != null) {
        TvExt.instance.remember(d);
        took.add('extensions (${d.name})');
      }
    }
    final now = DateTime.now();
    if (!quiet || took.isNotEmpty) {
      status.value = took.isEmpty
          ? "$from sent logins, but none of them worked."
          : 'Logins from $from: ${took.join(', ')} (${now.hour}:${now.minute.toString().padLeft(2, '0')})';
    }
    return took;
  }
}
