import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:anymex/database/data_keys/keys.dart';
import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/tv/tv_link.dart';
import 'package:anymex/plus/tv/tv_sync.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:pointycastle/export.dart';

/// AnymeX+: hands your logins from the phone (or PC) to the Flutter TV app.
///
/// The TV app listens on [port] and, while "Get logins from your phone" is
/// open, shows a 6-digit code. The phone connects, both make a one-time
/// P-256 key pair and swap the public halves (ECDH), and the lock key is
/// SHA-256(shared secret ‖ code ‖ salt). So someone listening on the home
/// network can't read anything, and a fake TV or phone would have to guess
/// the code in one try (the TV makes a new code after a wrong one).
///
/// Messages (JSON over a websocket at /pair):
///   phone → `{t: hi, from, pub}`      TV → `{t: hi, pub, salt, name}` or `{t: closed}`
///   phone → `{t: logins, iv, data}`   TV → `{t: ok, what: [...]}` or `{t: bad}`
class PlusFlutterTvPair {
  PlusFlutterTvPair._();

  static const port = 41744;
  static const path = '/pair';

  // ---- crypto (both sides) ----------------------------------------------

  static SecureRandom _random() {
    final r = Random.secure();
    return FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)))));
  }

  /// A one-time key pair: (private, public as uncompressed point hex).
  static (ECPrivateKey, String) newKeys() {
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(ECCurve_secp256r1()), _random()));
    final pair = gen.generateKeyPair();
    final pub = pair.publicKey as ECPublicKey;
    return (pair.privateKey as ECPrivateKey, _hex(pub.Q!.getEncoded(false)));
  }

  /// The lock key (64 hex chars) from my private key, their public key,
  /// the code shown on the TV and the TV's salt.
  static String lockKey(ECPrivateKey mine, String theirPubHex, String code, String salt) {
    final curve = ECCurve_secp256r1();
    final q = curve.curve.decodePoint(_unhex(theirPubHex));
    if (q == null) throw const FormatException('bad public key');
    final agree = ECDHBasicAgreement()..init(mine);
    final shared = agree.calculateAgreement(ECPublicKey(q, curve));
    final s = shared.toRadixString(16).padLeft(64, '0');
    return sha256.convert([..._unhex(s), ...utf8.encode(code.trim()), ...utf8.encode(salt)]).toString();
  }

  /// Opens what [PlusTvSync.seal] locked. Throws when the key is wrong.
  static List<int> open(String keyHex, String ivB64, String dataB64) {
    final key = _unhex(keyHex);
    if (key.length != 32) throw ArgumentError('bad key');
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, base64.decode(ivB64), Uint8List(0)));
    return gcm.process(Uint8List.fromList(base64.decode(dataB64)));
  }

  /// The name a saved key goes by (shows nothing of the key itself).
  static String idFor(String keyHex) => sha256.convert(utf8.encode('anymexplus-ftv:$keyHex')).toString().substring(0, 16);

  static String newCode() {
    final r = Random.secure();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }

  static String newSalt() {
    final r = Random.secure();
    return _hex(List.generate(16, (_) => r.nextInt(256)));
  }

  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  static Uint8List _unhex(String h) =>
      Uint8List.fromList([for (var i = 0; i + 1 < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

  // ---- what is sent ------------------------------------------------------

  /// Your logins and the bits the TV needs to browse like your phone.
  /// Only access tokens are sent (no refresh tokens), so a refresh on the
  /// TV can never sign the phone out.
  static Map<String, dynamic> buildLogins() {
    String tok(AuthKeys k) {
      try {
        return k.get<String?>() ?? '';
      } catch (_) {
        return '';
      }
    }

    var stremio = '';
    try {
      stremio = StremioService.to.authKey ?? '';
    } catch (_) {}
    return {
      'v': 1,
      'from': PlusTvLink.deviceName,
      'at': DateTime.now().millisecondsSinceEpoch,
      'anilist': tok(AuthKeys.authToken),
      'simkl': tok(AuthKeys.simklAuthToken),
      'mal': tok(AuthKeys.malAuthToken),
      'stremio': stremio,
    };
  }

  /// Names of what [m] carries, for "Sent: AniList, Stremio".
  static List<String> carried(Map<String, dynamic> m) => [
        if ('${m['anilist'] ?? ''}'.isNotEmpty) 'AniList',
        if ('${m['simkl'] ?? ''}'.isNotEmpty) 'Simkl',
        if ('${m['mal'] ?? ''}'.isNotEmpty) 'MyAnimeList',
        if ('${m['stremio'] ?? ''}'.isNotEmpty) 'Stremio',
      ];

  // ---- the phone's side --------------------------------------------------

  /// Sends your logins to the Flutter TV app at [host] with the [code] it
  /// shows. Returns what the TV took (e.g. ["AniList", "Stremio"]).
  static Future<List<String>> send(String host, String code) async {
    final logins = buildLogins();
    if (carried(logins).isEmpty) throw Exception('This device is not signed in to anything yet');
    WebSocket ws;
    try {
      ws = await WebSocket.connect('ws://${host.trim()}:$port$path').timeout(const Duration(seconds: 6));
    } catch (_) {
      throw Exception("Couldn't reach AnymeX+ (Flutter) on that TV. Is it open on the TV's Accounts page?");
    }
    final (priv, pub) = newKeys();
    final replies = StreamController<Map<String, dynamic>>();
    ws.listen((raw) {
      try {
        final d = jsonDecode(raw as String);
        if (d is Map) replies.add(Map<String, dynamic>.from(d));
      } catch (_) {}
    }, onDone: replies.close, onError: (_) => replies.close());
    final it = StreamIterator(replies.stream);
    Future<Map<String, dynamic>> next() async {
      final ok = await it.moveNext().timeout(const Duration(seconds: 15), onTimeout: () => false);
      if (!ok) throw Exception('The TV stopped answering');
      return it.current;
    }

    try {
      ws.add(jsonEncode({'t': 'hi', 'from': PlusTvLink.deviceName, 'pub': pub}));
      final hi = await next();
      if (hi['t'] == 'closed') {
        throw Exception('On the TV, open Settings → Accounts → Get logins from your phone first');
      }
      if (hi['t'] != 'hi') throw Exception('Unexpected answer from the TV');
      final key = lockKey(priv, '${hi['pub']}', code, '${hi['salt']}');
      final sealed = PlusTvSync.seal(key, utf8.encode(jsonEncode(logins)));
      ws.add(jsonEncode({'t': 'logins', 'iv': sealed.$1, 'data': sealed.$2}));
      final done = await next();
      if (done['t'] == 'bad') throw Exception('Wrong code. The TV shows a new one now; try again with it.');
      if (done['t'] != 'ok') throw Exception('The TV couldn\'t use the logins (${done['why'] ?? done['t']})');
      _savePair(host.trim(), '${done['id'] ?? idFor(key)}', key);
      return List<String>.from((done['what'] as List?) ?? const []);
    } finally {
      await it.cancel();
      try {
        await ws.close();
      } catch (_) {}
    }
  }

  // ---- later: fresh logins by themselves ---------------------------------

  static const _kPairs = 'plus_ftv_pairs'; // [{host, id, key}]

  static List<Map<String, String>> savedPairs() {
    try {
      final raw = KvHelper.get<String>(_kPairs, defaultVal: '');
      if (raw.isNotEmpty) {
        return [for (final p in jsonDecode(raw) as List) Map<String, String>.from(p as Map)];
      }
    } catch (_) {}
    return [];
  }

  static void _savePair(String host, String id, String key) {
    final list = savedPairs()..removeWhere((p) => p['host'] == host || p['id'] == id);
    list.add({'host': host, 'id': id, 'key': key});
    while (list.length > 4) {
      list.removeAt(0);
    }
    try {
      KvHelper.set(_kPairs, jsonEncode(list));
    } catch (_) {}
  }

  static void forgetPairs() {
    try {
      KvHelper.set(_kPairs, '');
    } catch (_) {}
  }

  /// Sends fresh logins to every TV this device was paired with, quietly
  /// (TVs that are off or moved are skipped). Called after start-up.
  static Future<void> pushSaved() async {
    final pairs = savedPairs();
    if (pairs.isEmpty) return;
    final logins = buildLogins();
    if (carried(logins).isEmpty) return;
    for (final p in pairs) {
      WebSocket? ws;
      try {
        ws = await WebSocket.connect('ws://${p['host']}:$port$path').timeout(const Duration(seconds: 4));
        final sealed = PlusTvSync.seal(p['key']!, utf8.encode(jsonEncode(logins)));
        ws.add(jsonEncode({'t': 'again', 'from': PlusTvLink.deviceName, 'id': p['id'], 'iv': sealed.$1, 'data': sealed.$2}));
        await ws.first.timeout(const Duration(seconds: 20));
      } catch (_) {
      } finally {
        try {
          await ws?.close();
        } catch (_) {}
      }
    }
  }

  /// Called once the app has started (not on the TV itself).
  static void autoPush() {
    Future.delayed(const Duration(seconds: 8), () async {
      try {
        await pushSaved();
      } catch (_) {}
    });
  }
}
