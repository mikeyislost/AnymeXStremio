import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/tvui/tv_data.dart';
import 'package:anymex/plus/tvui/tv_playable.dart';
import 'package:anymex/plus/tvui/tv_sources.dart' show tvCanPlay;
import 'package:anymex/utils/logger.dart';
import 'package:flutter/foundation.dart';

/// A phone or PC that finds anime in your extensions for the TV.
class TvExtDevice {
  final String name;
  final String host;
  final int port;
  final String token;
  final bool pc;
  const TvExtDevice({required this.name, required this.host, required this.port, required this.token, this.pc = false});

  Map<String, dynamic> toJson() => {'name': name, 'host': host, 'port': port, 'token': token, 'pc': pc};
  static TvExtDevice? fromJson(Object? j) {
    if (j is! Map) return null;
    final host = '${j['host'] ?? ''}', token = '${j['token'] ?? ''}';
    final port = (j['port'] as num?)?.toInt() ?? 0;
    if (host.isEmpty || token.isEmpty || port <= 0) return null;
    return TvExtDevice(name: '${j['name'] ?? 'phone'}', host: host, port: port, token: token, pc: j['pc'] == true);
  }
}

/// One answer about an episode's servers.
class TvExtServers {
  final List<StremioStream> streams;
  final bool done;
  final String error;
  final String source; // the extension's name
  const TvExtServers(this.streams, this.done, this.error, this.source);
}

/// AnymeX+ TV (Flutter): your extensions, run by your phone or PC.
///
/// The TV can't run extensions itself (Java ones need a JVM, JS ones a
/// runtime with no webOS build yet), so it asks a paired phone or PC over
/// the same link the web TV app uses (`/tv` on PlusTvLink): `ext servers`
/// for an episode's servers and `anime eps` for the episode list. Videos and
/// subtitles come through that device's proxy (tv_proxy.dart).
class TvExt {
  TvExt._();
  static final instance = TvExt._();

  static const _kDevices = 'plus_ftv_sources';

  /// Which device answered last ('' = none yet), for the sources page.
  final using = ValueNotifier<String>('');

  WebSocket? _ws;
  TvExtDevice? _at;
  Future<bool>? _connecting;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();

  List<TvExtDevice> get devices {
    try {
      final raw = KvHelper.get<String>(_kDevices, defaultVal: '');
      if (raw.isNotEmpty) {
        return [for (final j in jsonDecode(raw) as List) TvExtDevice.fromJson(j)].whereType<TvExtDevice>().toList();
      }
    } catch (_) {}
    return [];
  }

  bool get hasDevices => devices.isNotEmpty;

  /// From the pairing: this device can find anime for the TV.
  void remember(TvExtDevice d) {
    final list = devices..removeWhere((x) => x.token == d.token || x.host == d.host);
    list.insert(0, d);
    while (list.length > 4) {
      list.removeLast();
    }
    try {
      KvHelper.set(_kDevices, jsonEncode([for (final x in list) x.toJson()]));
    } catch (_) {}
  }

  void forget() {
    try {
      KvHelper.set(_kDevices, '');
    } catch (_) {}
    unawaited(_ws?.close());
    _ws = null;
    using.value = '';
  }

  /// Connected to a phone or PC (tries each, the last one that worked first).
  Future<bool> connect() {
    if (_ws != null) return Future.value(true);
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<bool> _connect() async {
    final list = devices;
    if (_at != null) {
      list.sort((a, b) => (a.host == _at!.host ? 0 : 1).compareTo(b.host == _at!.host ? 0 : 1));
    }
    for (final d in list) {
      try {
        final ws = await WebSocket.connect('ws://${d.host}:${d.port}/tv').timeout(const Duration(seconds: 4));
        ws.pingInterval = const Duration(seconds: 15);
        final welcome = Completer<bool>();
        ws.listen((raw) {
          Map<String, dynamic> m;
          try {
            m = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
          } catch (_) {
            return;
          }
          if (!welcome.isCompleted) {
            welcome.complete(m['t'] == 'welcome');
            return;
          }
          _messages.add(m);
        }, onDone: () {
          if (!welcome.isCompleted) welcome.complete(false);
          if (identical(_ws, ws)) {
            _ws = null;
            using.value = '';
          }
        }, onError: (_) {}, cancelOnError: true);
        ws.add(jsonEncode({
          't': 'hello',
          'app': 'anymexplus-tv',
          'token': d.token,
          'flutter': true,
          'info': {'app': 'AnymeX+ (Flutter)', 'model': 'LG TV'},
        }));
        final ok = await welcome.future.timeout(const Duration(seconds: 6), onTimeout: () => false);
        if (!ok) {
          await ws.close();
          continue;
        }
        _ws = ws;
        _at = d;
        using.value = d.name;
        return true;
      } catch (e) {
        Logger.i('TV ext: ${d.host}: $e');
      }
    }
    return false;
  }

  void _send(Map<String, dynamic> m) {
    try {
      _ws?.add(jsonEncode(m));
    } catch (_) {}
  }

  static String _q() => '${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(9999)}';

  static Map<String, dynamic> _show(TvItem item) =>
      {'name': item.title, 'romaji': item.title, 'poster': item.poster};

  /// The anime's episodes in your extension: (number, title, thumb), or
  /// null when no device answered.
  Future<List<TvEp>?> episodes(TvItem item) async {
    if (!await connect()) return null;
    final q = _q();
    final reply = _messages.stream
        .firstWhere((m) => m['t'] == 'animeEps' && '${m['q']}' == q)
        .timeout(const Duration(seconds: 70));
    _send({'t': 'anime', 'cmd': 'eps', 'q': q, 'id': item.id, ..._show(item)});
    try {
      final m = await reply;
      final out = <TvEp>[];
      for (final e in (m['eps'] as List?) ?? const []) {
        if (e is! Map) continue;
        final n = '${e['n'] ?? ''}';
        final number = double.tryParse(n)?.floor() ?? 0;
        if (number <= 0) continue;
        out.add(TvEp(
          videoId: extVideoId(item.id, n),
          season: 1,
          number: number,
          title: '${e['title'] ?? 'Episode $n'}',
          thumb: '${e['thumb'] ?? ''}',
        ));
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// The servers of episode [n], as they arrive (the last one has done).
  Stream<TvExtServers> servers(TvItem item, int n) async* {
    if (!await connect()) {
      yield const TvExtServers([], true, "Your phone or PC isn't reachable. Open AnymeX+ on it.", '');
      return;
    }
    final q = _q();
    final device = _at?.name ?? 'your phone';
    final updates = _messages.stream
        .where((m) => m['t'] == 'extServers' && '${m['q']}' == q)
        .timeout(const Duration(seconds: 75), onTimeout: (sink) => sink.close());
    _send({'t': 'ext', 'cmd': 'servers', 'q': q, 'a': item.id, 'n': '$n', ..._show(item)});
    await for (final m in updates) {
      final source = '${m['source'] ?? ''}';
      final list = [
        for (final s in (m['list'] as List?) ?? const [])
          if (s is Map) toStream(Map<String, dynamic>.from(s), source, device),
      ].where(tvCanPlay).toList();
      final done = m['done'] == true;
      yield TvExtServers(list, done, '${m['err'] ?? ''}', source);
      if (done) return;
    }
    yield const TvExtServers([], true, 'Your phone or PC stopped answering.', '');
  }

  static String extVideoId(String anilistId, String n) => 'anilist:$anilistId:$n';

  static String addonFor(String source) => 'Extension · ${source.isEmpty ? 'yours' : source}';

  /// A server from the phone as a stream the sources page and player know.
  static StremioStream toStream(Map<String, dynamic> s, String source, String device) {
    final name = '${s['name'] ?? ''}'.trim();
    final kind = '${s['kind'] ?? ''}';
    return StremioStream(
      addonName: addonFor(source),
      url: '${s['url'] ?? ''}',
      name: name.isEmpty ? 'Server' : name,
      title: 'From $device${s['dead'] == true ? ' · may not work' : ''}',
      bingeGroup: 'ext|$name',
      filename: kind.isEmpty ? null : 'video.${kind == 'hls' ? 'm3u8' : kind}',
      subtitles: [
        for (final t in (s['subs'] as List?) ?? const [])
          if (t is Map && '${t['url'] ?? ''}'.isNotEmpty) {'lang': '${t['lang'] ?? '?'}', 'url': '${t['url']}'},
      ],
    );
  }
}

/// Every source for an episode: your Stremio addons and, for anime, your
/// extensions (through the phone or PC). For the player's next episode.
class TvStreams {
  static Future<List<StremioStream>> all(TvPlayable p, TvEp ep) async {
    final st = StremioService.to;
    final stremio = p.metaId.startsWith('anilist:')
        ? Future.value(<StremioStream>[])
        : st.fetchStreams(p.type, ep.videoId).then((l) => l.where(tvCanPlay).toList()).catchError((_) => <StremioStream>[]);
    var ext = <StremioStream>[];
    if (p.isAnime && TvExt.instance.hasDevices) {
      try {
        await for (final r in TvExt.instance.servers(p.item, ep.number)) {
          ext = r.streams;
          if (r.done) break;
        }
      } catch (_) {}
    }
    return [...ext, ...await stremio];
  }
}
