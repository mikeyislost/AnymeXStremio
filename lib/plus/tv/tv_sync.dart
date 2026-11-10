import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/plus/for_you/movies_for_you.dart';
import 'package:anymex/plus/layout/layout_store.dart';
import 'package:anymex/plus/stremio/builtin_rows.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/stremio/ui/stremio_home_page.dart' show stremioHomeRows;
import 'package:anymex/plus/tv/tv_link.dart';
import 'package:anymex/utils/logger.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:get/get.dart';
import 'package:pointycastle/export.dart';

/// AnymeX+: sends the TV app what it needs to browse by itself.
///
/// The bundle: your Stremio sign-in and addons, the rows of your Movies &
/// TV page (as you arranged them in Edit layout), the TMDB key and the
/// "watched" point. It is locked with AES-256-GCM using a key the TV got
/// through LG's own phone link, so the home network only sees locked bytes.
///
/// The TV answers `syncOk` / `syncFail`, asks with `need`, and reports
/// `watched` when something it played by itself crossed the watched point;
/// that goes on to the Stremio watched marks, AniList and Simkl.
class PlusTvSync {
  PlusTvSync._();
  static final instance = PlusTvSync._();

  static const _kDone = 'plus_tv_watched_done';

  /// What the TV last said about the sync, for the TV Remote page.
  final status = ''.obs;

  bool _attached = false;
  Timer? _debounce;
  String _lastSentHash = '';
  final _workers = <Worker>[];

  PlusTvLink get _link => PlusTvLink.instance;

  /// Starts listening (called when the link starts; safe to call again).
  void attach() {
    if (_attached) return;
    _attached = true;
    _link.listeners.add(_onMessage);
    _workers.add(ever(_link.status, (s) {
      if (s == PlusTvStatus.connected) {
        _onConnected();
      } else {
        status.value = '';
      }
    }));
    try {
      final st = StremioService.to;
      _workers.addAll([
        ever(st.addons, (_) => _soon()),
        ever(st.isLoggedIn, (_) => _soon()),
      ]);
    } catch (_) {}
    _workers.add(ever(PlusLayoutStore.version, (_) => _soon()));
    if (_link.isConnected) _onConnected();
  }

  bool get _tvCanSync => _link.hello['sync'] == true;
  bool get _tvHasKey => _link.hello['hasKey'] == true;

  void _onConnected() {
    _lastSentHash = '';
    if (!_tvCanSync) {
      status.value = 'This TV app is too old to sync. Update it in Homebrew Channel.';
      return;
    }
    if (!_tvHasKey) {
      status.value = 'Open the TV app from this page once (tap your TV) to sync.';
      return;
    }
    unawaited(sendNow(onlyIfChanged: true));
  }

  /// Something changed on the phone: send it along in a moment.
  void _soon() {
    if (!_link.isConnected) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () => sendNow(onlyIfChanged: true));
  }

  /// Builds, locks and sends the bundle. With [onlyIfChanged] nothing is
  /// sent when the TV already has the same one.
  Future<void> sendNow({bool onlyIfChanged = false}) async {
    if (!_link.isConnected) return;
    if (!_tvCanSync || !_tvHasKey) {
      _onConnected();
      return;
    }
    try {
      final b = buildBundle();
      final h = bundleHash(b);
      if (onlyIfChanged && (h == _lastSentHash || h == _link.hello['have'])) {
        if (status.value.isEmpty) status.value = 'Synced';
        return;
      }
      final sealed = seal(PlusTvLink.syncKey, utf8.encode(jsonEncode(b)));
      _lastSentHash = h;
      status.value = 'Syncing…';
      _link.send({'t': 'sync', 'h': h, 'iv': sealed.$1, 'data': sealed.$2});
    } catch (e) {
      Logger.i('TV sync: $e');
      status.value = "Couldn't sync: $e";
    }
  }

  Future<void> _onMessage(Map<String, dynamic> m) async {
    switch (m['t']) {
      case 'need':
        // Asked by the TV, or after it got a new key: send even if unchanged.
        _link.hello['hasKey'] = true;
        _link.hello['sync'] = true;
        await sendNow();
      case 'syncOk':
        _link.hello['have'] = m['h'];
        status.value = 'Synced: ${m['addons'] ?? 0} addons, ${m['rows'] ?? 0} rows';
      case 'syncFail':
        _lastSentHash = '';
        status.value = m['why'] == 'wrong key' || m['why'] == 'no key'
            ? 'The TV has an old key. Tap your TV above to open it again, then it syncs.'
            : "The TV couldn't read the sync (${m['why']}).";
      case 'watched':
        await _onWatched(m);
    }
  }

  Future<void> _onWatched(Map<String, dynamic> m) async {
    final q = '${m['q'] ?? ''}';
    final id = '${m['id'] ?? ''}';
    final videoId = '${m['videoId'] ?? ''}';
    if (q.isEmpty || id.isEmpty) return;
    final done = _done();
    if (!done.contains(q)) {
      done.add(q);
      if (done.length > 200) done.removeRange(0, done.length - 200);
      try {
        KvHelper.set(_kDone, jsonEncode(done));
      } catch (_) {}
      try {
        await StremioService.to.markWatchedFromTv('${m['type'] ?? 'movie'}', id, videoId.isEmpty ? id : videoId);
      } catch (e) {
        Logger.i('TV sync: watched mark failed: $e');
      }
    }
    _link.send({'t': 'watchedOk', 'q': q});
  }

  List<String> _done() {
    try {
      final raw = KvHelper.get<String>(_kDone, defaultVal: '');
      if (raw.isNotEmpty) return List<String>.from(jsonDecode(raw) as List);
    } catch (_) {}
    return <String>[];
  }

  /// Types a search on the TV.
  void search(String q) => _link.send({'t': 'search', 'q': q});

  // ---- the bundle --------------------------------------------------------

  static Map<String, dynamic> buildBundle() {
    final st = StremioService.to;
    return {
      'v': 1,
      'from': PlusTvLink.deviceName,
      'at': DateTime.now().millisecondsSinceEpoch,
      'stremio': {
        'authKey': st.authKey ?? '',
        'email': st.userEmail.value,
        'addons': [
          for (final a in st.addons)
            if (st.isAddonUsable(a)) {'url': a.transportUrl, 'manifest': a.manifest},
        ],
      },
      'tmdb': {'key': MoviesForYou.tmdbKey ?? '', 'region': PlusBuiltinRows.region},
      'rows': tvRows(),
      'settings': {'watchedPoint': StremioService.watchedPoint},
    };
  }

  /// Your Movies & TV rows, in your order, as the TV understands them.
  /// "For you" and rows you added yourself need the phone, so they stay
  /// on the phone for now.
  static List<Map<String, dynamic>> tvRows() {
    final st = StremioService.to;
    final byKey = {
      for (final a in st.addons)
        for (final c in a.catalogs) 'cat:${StremioService.rowKey(a, c)}': (a, c),
    };
    final out = <Map<String, dynamic>>[];
    for (final r in stremioHomeRows()) {
      if (r.config.hidden || r.config.added) continue;
      if (r.key == 'cw') {
        out.add({'kind': 'cw', 'title': r.title});
        continue;
      }
      final b = PlusBuiltinRows.byLayoutKey(r.key);
      if (b != null) {
        if (!PlusBuiltinRows.enabled) continue;
        out.add({
          'kind': 'tmdb',
          'title': r.title,
          'type': b.type,
          'path': b.path,
          'query': PlusBuiltinRows.queryFor(b, PlusBuiltinRows.region),
        });
        continue;
      }
      final cat = byKey[r.key];
      if (cat == null || !st.isAddonUsable(cat.$1)) continue;
      out.add({'kind': 'cat', 'title': r.title, 'base': cat.$1.baseUrl, 'type': cat.$2.type, 'id': cat.$2.id});
    }
    return out;
  }

  /// Same bundle → same hash (the time it was made doesn't count).
  static String bundleHash(Map<String, dynamic> b) {
    final copy = Map<String, dynamic>.from(b)..remove('at');
    return sha256.convert(utf8.encode(jsonEncode(copy))).toString().substring(0, 16);
  }

  /// AES-256-GCM: (iv, locked bytes + 16-byte check), both base64. The TV
  /// opens it with tv/gcm.js.
  static (String, String) seal(String keyHex, List<int> plain, {Uint8List? iv}) {
    final key = Uint8List.fromList([
      for (var i = 0; i < keyHex.length; i += 2) int.parse(keyHex.substring(i, i + 2), radix: 16),
    ]);
    if (key.length != 32) throw ArgumentError('bad key');
    final r = Random.secure();
    final nonce = iv ?? Uint8List.fromList(List.generate(12, (_) => r.nextInt(256)));
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    final out = gcm.process(Uint8List.fromList(plain));
    return (base64.encode(nonce), base64.encode(out));
  }
}
